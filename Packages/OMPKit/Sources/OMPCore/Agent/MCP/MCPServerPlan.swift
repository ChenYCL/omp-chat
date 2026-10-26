import Foundation

/// A runtime an `npx`/`uvx` server needs on this Mac.
public enum MCPRuntime: String, Codable, CaseIterable, Sendable {
    case node
    case uv

    public var title: String {
        switch self {
        case .node: "Node.js"
        case .uv: "uv"
        }
    }

    /// The command that proves the runtime is installed.
    public var probeCommand: String {
        switch self {
        case .node: "npx"
        case .uv: "uvx"
        }
    }

    public var installHint: String {
        switch self {
        case .node: "需要 Node.js：从 https://nodejs.org 安装，或 brew install node，然后重试。"
        case .uv: "需要 uv：按 https://docs.astral.sh/uv/ 安装，或 brew install uv，然后重试。"
        }
    }

    /// The runtime a launcher command belongs to, if it is a known one.
    public static func required(byCommand command: String) -> MCPRuntime? {
        switch (command as NSString).lastPathComponent {
        case "npx", "node", "npm", "pnpm", "pnpx", "yarn", "bunx", "bun": .node
        case "uvx", "uv": .uv
        default: nil
        }
    }
}

/// Pure decisions behind launching servers: finding the executable, building
/// the environment, and which servers a settings change restarts.
public enum MCPLaunchPlanner {
    /// The absolute path `command` runs as: itself when it contains a `/`
    /// (with `~` expanded), otherwise the first executable match on `path`.
    public static func locate(_ command: String, path: String, home: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let fileManager = FileManager.default
        if trimmed.contains("/") {
            let expanded = expandTilde(trimmed, home: home)
            let absolute = expanded.hasPrefix("/") ? expanded : (home as NSString).appendingPathComponent(expanded)
            return fileManager.isExecutableFile(atPath: absolute) ? absolute : nil
        }
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = (String(directory) as NSString).appendingPathComponent(trimmed)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// The server's environment: `base` (the app's child environment), then
    /// the config's non-blank values, then secrets from the vault, which win.
    /// Only variables named in `config.env` are looked up in the vault;
    /// secret ones are stored there with a blank value in the config.
    public static func environment(
        base: [String: String], config: MCPServerConfig, secret: (String) -> String?
    ) -> [String: String] {
        var environment = base
        for (name, value) in config.env {
            if let stored = secret(name), !stored.isEmpty {
                environment[name] = stored
            } else if !value.isEmpty {
                environment[name] = value
            }
        }
        return environment
    }

    /// Vault values for the config's variables that have one.
    public static func secrets(for config: MCPServerConfig, secret: (String) -> String?) -> [String: String] {
        var result: [String: String] = [:]
        for name in config.env.keys {
            if let value = secret(name), !value.isEmpty { result[name] = value }
        }
        return result
    }

    /// The child's working directory: the config's `cwd` (relative to home)
    /// or home itself.
    public static func workingDirectory(for config: MCPServerConfig, home: String) -> String {
        guard let cwd = config.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty else { return home }
        let expanded = expandTilde(cwd, home: home)
        return expanded.hasPrefix("/") ? expanded : (home as NSString).appendingPathComponent(expanded)
    }

    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }
}

/// Everything about a server that needs a relaunch when it changes. Name,
/// risk, origin and tool switches are not part of it.
public struct MCPLaunchKey: Hashable, Sendable {
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var cwd: String?
    /// Vault values, compared in memory only.
    public var secrets: [String: String]

    public init(config: MCPServerConfig, secrets: [String: String]) {
        command = config.command
        args = config.args
        env = config.env
        url = config.url
        cwd = config.cwd
        self.secrets = secrets
    }
}

/// What a settings change does to the running servers.
public struct MCPServerDiff: Equatable, Sendable {
    public var start: [String] = []
    public var stop: [String] = []
    public var restart: [String] = []
    /// Running and unchanged in launch terms; may still take a config update.
    public var keep: [String] = []

    public init(start: [String] = [], stop: [String] = [], restart: [String] = [], keep: [String] = []) {
        self.start = start
        self.stop = stop
        self.restart = restart
        self.keep = keep
    }

    /// `running`: what is launched now. `desired`: the enabled servers.
    public static func compute(running: [String: MCPLaunchKey], desired: [String: MCPLaunchKey]) -> MCPServerDiff {
        var diff = MCPServerDiff()
        for id in desired.keys.sorted() {
            guard let current = running[id] else {
                diff.start.append(id)
                continue
            }
            if current == desired[id] { diff.keep.append(id) } else { diff.restart.append(id) }
        }
        diff.stop = running.keys.filter { desired[$0] == nil }.sorted()
        return diff
    }
}
