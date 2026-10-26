import Foundation

/// Where one server's connection stands.
public enum MCPConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case ready(toolCount: Int)
    /// `log` is the tail of the server's stderr at the moment it failed.
    case failed(reason: String, log: [String])
    case stopped
}

/// How a crashed server is brought back.
public struct MCPRestartPolicy: Sendable {
    public var maxRestarts: Int
    /// Wait before restart n (the last value repeats).
    public var backoff: [Duration]
    /// A connection that stayed up this long earns its restarts back, so a
    /// server that crashes once a day is not given up on after three days.
    public var stableAfter: Duration

    public init(maxRestarts: Int = 3, backoff: [Duration] = [.seconds(1), .seconds(3), .seconds(10)], stableAfter: Duration = .seconds(60)) {
        self.maxRestarts = maxRestarts
        self.backoff = backoff
        self.stableAfter = stableAfter
    }
}

/// A server's tools as the provider sees them.
public struct MCPServerTools: Equatable, Sendable {
    public var config: MCPServerConfig
    /// Empty unless the server is connected.
    public var tools: [MCPTool]

    public init(config: MCPServerConfig, tools: [MCPTool]) {
        self.config = config
        self.tools = tools
    }
}

/// Something that offers one server's tools. `MCPServerConnection` in the
/// app; fakes in tests.
public protocol MCPToolSource: Sendable {
    var serverID: String { get }
    func toolSnapshot() async -> MCPServerTools
    func callTool(_ name: String, arguments: JSONValue) async throws -> MCPToolResult
}

/// One configured server kept connected: launches it, restarts it after a
/// crash (up to `MCPRestartPolicy.maxRestarts` times, with backoff), and
/// reports every state change.
public actor MCPServerConnection: MCPToolSource {
    public struct Snapshot: Equatable, Sendable {
        public var serverID: String
        public var state: MCPConnectionState
        public var tools: [MCPTool]
        public var restarts: Int
    }

    public typealias TransportFactory = @Sendable () throws -> any MCPTransport

    public nonisolated let serverID: String
    public private(set) var config: MCPServerConfig
    public private(set) var state: MCPConnectionState = .idle
    public private(set) var tools: [MCPTool] = []
    /// Automatic restarts used from the current budget.
    public private(set) var restarts = 0

    private let makeTransport: TransportFactory
    private let policy: MCPRestartPolicy
    private let timeouts: MCPClient.Timeouts
    private let onChange: @Sendable (Snapshot) -> Void
    private var client: MCPClient?
    private var transport: (any MCPTransport)?
    /// Bumped on every launch and stop; events of an older launch are ignored.
    private var generation = 0
    private var restartTask: Task<Void, Never>?
    private var readySince: ContinuousClock.Instant?

    public init(
        config: MCPServerConfig,
        timeouts: MCPClient.Timeouts = MCPClient.Timeouts(),
        policy: MCPRestartPolicy = MCPRestartPolicy(),
        makeTransport: @escaping TransportFactory,
        onChange: @escaping @Sendable (Snapshot) -> Void = { _ in }
    ) {
        serverID = config.id
        self.config = config
        self.timeouts = timeouts
        self.policy = policy
        self.makeTransport = makeTransport
        self.onChange = onChange
    }

    /// Connects with a fresh restart budget. Returns once the server is ready
    /// or the first attempt failed (restarts continue in the background).
    public func start() async {
        restarts = 0
        await launch()
    }

    public func stop() async {
        generation += 1
        restartTask?.cancel()
        restartTask = nil
        await tearDown()
        tools = []
        set(.stopped)
    }

    /// Name, risk, origin and tool switches change without a reconnect.
    public func update(config newValue: MCPServerConfig) {
        config = newValue
        report()
    }

    /// The live stderr tail (empty for HTTP servers).
    public func diagnostics() -> [String] {
        transport?.diagnostics() ?? []
    }

    public func toolSnapshot() async -> MCPServerTools {
        guard case .ready = state else { return MCPServerTools(config: config, tools: []) }
        return MCPServerTools(config: config, tools: tools)
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> MCPToolResult {
        guard let client, case .ready = state else {
            throw MCPError.notConnected("MCP 服务器「\(config.name)」未连接")
        }
        return try await client.callTool(name, arguments: arguments)
    }

    // MARK: Lifecycle

    private func launch() async {
        generation += 1
        let current = generation
        await tearDown()
        tools = []
        set(.connecting)

        let transport: any MCPTransport
        do {
            transport = try makeTransport()
        } catch {
            set(.failed(reason: Self.describe(error), log: []))
            return
        }
        let client = MCPClient(transport: transport, timeouts: timeouts) { [weak self] event in
            Task { await self?.clientEvent(event, generation: current) }
        }
        self.transport = transport
        self.client = client
        do {
            try await client.connect()
            guard current == generation else { return }
            tools = await client.tools
            readySince = .now
            set(.ready(toolCount: tools.count))
        } catch {
            guard current == generation else { return }
            await crashed(reason: Self.describe(error), permanent: (error as? MCPError)?.isPermanent ?? false)
        }
    }

    private func clientEvent(_ event: MCPClient.Event, generation eventGeneration: Int) async {
        guard eventGeneration == generation else { return }
        switch event {
        case .toolsChanged(let fresh):
            tools = fresh
            if case .ready = state { set(.ready(toolCount: fresh.count)) }
        case .closed(let reason):
            // While connecting, `launch` handles the failure itself.
            guard case .ready = state else { return }
            await crashed(reason: reason, permanent: false)
        }
    }

    private func crashed(reason: String, permanent: Bool) async {
        let log = transport?.diagnostics() ?? []
        generation += 1
        let current = generation
        await tearDown()
        tools = []
        if let readySince, readySince.duration(to: .now) >= policy.stableAfter {
            restarts = 0
        }
        readySince = nil
        set(.failed(reason: reason, log: log))
        guard !permanent, restarts < policy.maxRestarts, !policy.backoff.isEmpty else { return }
        let delay = policy.backoff[min(restarts, policy.backoff.count - 1)]
        restarts += 1
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.relaunch(ifGeneration: current)
        }
    }

    private func relaunch(ifGeneration expected: Int) async {
        guard expected == generation else { return }
        await launch()
    }

    private func tearDown() async {
        let client = self.client
        self.client = nil
        self.transport = nil
        await client?.close()
    }

    private func set(_ newState: MCPConnectionState) {
        state = newState
        report()
    }

    private func report() {
        onChange(Snapshot(serverID: serverID, state: state, tools: tools, restarts: restarts))
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
