#if os(macOS)
import Foundation
import Observation
import OMPCore

/// What 设置 → MCP 服务器 shows for one server.
public enum MCPServerStatus: Equatable, Sendable {
    case disabled
    /// The launcher (`npx`, `uvx`) is not installed.
    case needsRuntime(MCPRuntime)
    case connecting
    case ready(toolCount: Int)
    /// `log` is the stderr tail when it failed.
    case failed(reason: String, log: [String])
}

/// Keeps one connection per enabled server in `settings.mcpServers` and the
/// enabled plugins' servers, and offers their tools to the agent as the
/// "mcp" provider.
///
/// Both lists are observed: a change restarts only the servers whose launch
/// (command, arguments, environment, URL, working directory, secrets)
/// changed; renames, risk and per-tool switches apply in place.
@MainActor
@Observable
public final class MCPManager {
    public private(set) var statuses: [String: MCPServerStatus] = [:]
    /// Tools of the connected servers, by server id.
    public private(set) var tools: [String: [MCPTool]] = [:]

    @ObservationIgnored private weak var model: ChatAppModel?
    @ObservationIgnored private let http: HTTPTransport
    @ObservationIgnored private let timeouts: MCPClient.Timeouts
    @ObservationIgnored private let policy: MCPRestartPolicy
    @ObservationIgnored private let provider = MCPToolProvider()
    @ObservationIgnored private var connections: [String: MCPServerConnection] = [:]
    /// Which launch each connection belongs to; snapshots from a replaced
    /// connection are ignored.
    @ObservationIgnored private var tokens: [String: UUID] = [:]
    @ObservationIgnored private var launchKeys: [String: MCPLaunchKey] = [:]
    /// The latest stop per server id; a relaunch of that id waits for it.
    @ObservationIgnored private var stopping: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private let preparer: MCPPackagePreparer

    init(
        model: ChatAppModel, http: HTTPTransport = URLSessionTransport(),
        timeouts: MCPClient.Timeouts = MCPClient.Timeouts(), policy: MCPRestartPolicy = MCPRestartPolicy(),
        packageRoot: URL? = nil, packageRunner: MCPPackagePreparer.Runner? = nil
    ) {
        self.model = model
        self.http = http
        self.timeouts = timeouts
        self.policy = policy
        preparer = MCPPackagePreparer(root: packageRoot ?? Self.defaultPackageRoot, run: packageRunner ?? Self.shellRunner)
    }

    /// Where `npx` / `uvx` packages are installed: the app's own support
    /// folder (its container, when sandboxed).
    static var defaultPackageRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OMPChat/mcp-packages", isDirectory: true)
    }

    /// Runs an installer through the same shell runner the host terminal uses
    /// (pipes drained on threads, process tree stopped on timeout).
    static let shellRunner: MCPPackagePreparer.Runner = { argv, timeout in
        let command = argv.map(HostExecutor.shellQuote).joined(separator: " ")
        let run = await HostExecutor.runCommand(
            command, cwd: HostExecutor.realHomeDirectory(), timeout: timeout,
            outputCap: 32 * 1024, mergeStderr: true
        )
        var output = run.stdout
        if let error = run.launchError { output += "\n" + error }
        if run.timedOut { output += "\n超时（\(Int(timeout)) 秒）" }
        return MCPPackagePreparer.Outcome(exitCode: Int32(truncatingIfNeeded: run.exitCode), output: output)
    }

    /// The servers the manager runs: settings first, then plugin servers
    /// whose id is not already taken by one in settings.
    public var servers: [MCPServerConfig] {
        guard let model else { return [] }
        let own = model.settings.mcpServers
        let taken = Set(own.map(\.id))
        return own + model.pluginMCPServers.filter { !taken.contains($0.id) }
    }

    public func status(of id: String) -> MCPServerStatus {
        statuses[id] ?? .disabled
    }

    /// Connects the enabled servers and starts following settings.
    public func start() {
        guard !started, let model else { return }
        started = true
        model.setToolProvider(id: "mcp", provider)
        observeSettings()
        sync()
    }

    /// Brings the connections in line with settings.
    public func sync() {
        guard started, let model else { return }
        var byID: [String: MCPServerConfig] = [:]
        var desired: [String: MCPLaunchKey] = [:]
        for config in servers where byID[config.id] == nil {
            byID[config.id] = config
            guard config.enabled else { continue }
            let secrets = MCPLaunchPlanner.secrets(for: config) { model.mcpSecret(serverID: config.id, variable: $0) }
            desired[config.id] = MCPLaunchKey(config: config, secrets: secrets)
        }
        let diff = MCPServerDiff.compute(running: launchKeys, desired: desired)
        for id in diff.stop + diff.restart { stopConnection(id) }
        for id in diff.restart + diff.start {
            if let config = byID[id], let key = desired[id] { launch(config, key: key) }
        }
        for id in diff.keep {
            guard let config = byID[id], let connection = connections[id] else { continue }
            Task { await connection.update(config: config) }
        }
        for (id, config) in byID where !config.enabled {
            statuses[id] = .disabled
            tools[id] = nil
        }
        for id in Array(statuses.keys) where byID[id] == nil {
            statuses[id] = nil
            tools[id] = nil
        }
        publishProvider()
    }

    /// Reconnects one server with a fresh restart budget; also re-checks a
    /// missing runtime the user may have installed since.
    public func retry(_ id: String) {
        stopConnection(id)
        sync()
    }

    /// The live stderr tail, or the one captured when it failed.
    public func log(for id: String) async -> [String] {
        if let connection = connections[id] {
            let live = await connection.diagnostics()
            if !live.isEmpty { return live }
        }
        if case .failed(_, let log) = statuses[id] { return log }
        return []
    }

    /// Stops every server and stops following settings (app quit). Waits
    /// for the processes to end; `start()` brings them back.
    public func stopAll() async {
        started = false
        let running = Array(connections.values)
        let pending = Array(stopping.values)
        connections.removeAll()
        tokens.removeAll()
        launchKeys.removeAll()
        stopping.removeAll()
        statuses.removeAll()
        tools.removeAll()
        provider.setSources([])
        for task in pending { await task.value }
        for connection in running { await connection.stop() }
    }

    // MARK: Internals

    @ObservationIgnored private var observing = false

    private func observeSettings() {
        guard !observing else { return }
        observing = true
        withObservationTracking {
            _ = model?.settings.mcpServers
            _ = model?.pluginMCPServers
        } onChange: { [weak self] in
            // Fires before the new value is stored; act on the next turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observing = false
                guard self.started else { return }
                self.observeSettings()
                self.sync()
            }
        }
    }

    private func launch(_ config: MCPServerConfig, key: MCPLaunchKey) {
        let id = config.id
        launchKeys[id] = key
        tools[id] = []

        /// What the connection will run, before any package is prepared.
        enum Source {
            case stdio(MCPStdioTransport.Launch, command: String)
            case http(URL)
        }
        let source: Source
        if let command = config.command {
            let home = HostExecutor.realHomeDirectory()
            let environment = MCPLaunchPlanner.environment(
                base: HostExecutor.childEnvironment(home: home), config: config, secret: { key.secrets[$0] }
            )
            guard let executable = MCPLaunchPlanner.locate(command, path: environment["PATH"] ?? "", home: home) else {
                if let runtime = MCPRuntime.required(byCommand: command) {
                    statuses[id] = .needsRuntime(runtime)
                } else {
                    statuses[id] = .failed(reason: MCPError.commandNotFound(command).errorDescription ?? command, log: [])
                }
                return
            }
            source = .stdio(
                MCPStdioTransport.Launch(
                    executable: executable, arguments: config.args, environment: environment,
                    workingDirectory: MCPLaunchPlanner.workingDirectory(for: config, home: home)
                ),
                command: command
            )
        } else if let raw = config.url, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            source = .http(url)
        } else {
            statuses[id] = .failed(reason: "「\(config.url ?? "")」不是 http 或 https 地址", log: [])
            return
        }
        let token = UUID()
        tokens[id] = token
        statuses[id] = .connecting
        // A replaced process must be gone first: servers lock profile folders
        // and data files that two copies cannot share.
        let previous = stopping[id]
        Task { [weak self] in
            await previous?.value
            guard let self, self.tokens[id] == token else { return }
            let factory: MCPServerConnection.TransportFactory
            switch source {
            case .http(let url):
                let http = self.http
                factory = { MCPHTTPTransport(endpoint: url, http: http) }
            case .stdio(var launch, let command):
                // npx / uvx servers are installed once and run through their
                // interpreter; see MCPPackageLaunch. The first start downloads.
                let plan = MCPPackageLaunch.plan(command: command, arguments: config.args)
                let prepared = await self.preparer.prepare(
                    plan, path: launch.environment["PATH"] ?? "", home: HostExecutor.realHomeDirectory()
                )
                // Stopped or replaced while the package was downloading.
                guard self.tokens[id] == token else { return }
                switch prepared {
                case .unchanged:
                    break
                case .launch(let executable, let arguments):
                    launch.executable = executable
                    launch.arguments = arguments
                case .needsRuntime(let runtime):
                    self.statuses[id] = .needsRuntime(runtime)
                    return
                case .failure(let reason, let log):
                    self.statuses[id] = .failed(reason: reason, log: log)
                    return
                }
                let ready = launch
                factory = { MCPStdioTransport(launch: ready, stopTree: { HostExecutor.stopTree(of: $0, escalated: $1) }) }
            }
            let connection = MCPServerConnection(
                config: config, timeouts: self.timeouts, policy: self.policy, makeTransport: factory
            ) { [weak self] snapshot in
                Task { @MainActor [weak self] in self?.apply(snapshot, token: token) }
            }
            self.connections[id] = connection
            await connection.start()
        }
    }

    private func stopConnection(_ id: String) {
        launchKeys[id] = nil
        tokens[id] = nil
        tools[id] = nil
        guard let connection = connections.removeValue(forKey: id) else { return }
        let previous = stopping[id]
        stopping[id] = Task {
            await previous?.value
            await connection.stop()
        }
    }

    private func apply(_ snapshot: MCPServerConnection.Snapshot, token: UUID) {
        let id = snapshot.serverID
        guard tokens[id] == token else { return }
        switch snapshot.state {
        case .idle, .connecting: statuses[id] = .connecting
        case .ready(let count): statuses[id] = .ready(toolCount: count)
        case .failed(let reason, let log): statuses[id] = .failed(reason: reason, log: log)
        case .stopped: statuses[id] = .disabled
        }
        tools[id] = snapshot.tools
        publishProvider()
    }

    /// Points the provider at the current connections and bumps the model's
    /// provider revision so the agent re-reads the tool list.
    private func publishProvider() {
        provider.setSources(connections.keys.sorted().compactMap { connections[$0] })
        model?.setToolProvider(id: "mcp", provider)
    }
}
#endif
