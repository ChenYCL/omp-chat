import Foundation

/// One MCP server the agent can connect to.
public struct MCPServerConfig: Codable, Hashable, Identifiable, Sendable {
    /// Stable key, `[a-z0-9_-]`. Part of every tool's wire name.
    public var id: String
    public var name: String
    /// stdio transport: the program to run. Nil for a remote server.
    public var command: String?
    public var args: [String]
    /// Non-secret environment. Secret values are kept in the secrets vault
    /// under `MCPServerConfig.vaultAccount(serverID:variable:)`.
    public var env: [String: String]
    /// Streamable-HTTP transport: the endpoint. Nil for a local server.
    public var url: String?
    public var enabled: Bool
    /// Risk assigned to every tool of this server unless the server marks a
    /// tool read-only. Computer-use servers use `.control`.
    public var risk: ToolRisk
    /// Where the entry came from: "custom", "catalog" or "plugin:<id>".
    public var origin: String
    /// stdio transport: the child's working directory. Nil runs it in the
    /// user's real home; a relative path is resolved against that home.
    public var cwd: String? = nil
    /// Tool names the user switched off. They are not offered to the model
    /// and a call to one is refused.
    public var disabledTools: [String] = []

    public init(
        id: String, name: String, command: String? = nil, args: [String] = [],
        env: [String: String] = [:], url: String? = nil, enabled: Bool = true,
        risk: ToolRisk = .execute, origin: String = "custom"
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.enabled = enabled
        self.risk = risk
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try container.decodeIfPresent(String.self, forKey: .url)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        risk = try container.decodeIfPresent(ToolRisk.self, forKey: .risk) ?? .execute
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? "custom"
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        disabledTools = try container.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, args, env, url, enabled, risk, origin, cwd, disabledTools
    }

    public static func vaultAccount(serverID: String, variable: String) -> String {
        "mcp.\(serverID).\(variable)"
    }

    /// `id` for a name typed or found in a config: lowercased, anything outside
    /// `[a-z0-9_-]` becomes `-`, runs and edges of `-` collapse. Nil when
    /// nothing usable is left.
    public static func sanitizedID(_ raw: String) -> String? {
        var result = ""
        for scalar in raw.lowercased().unicodeScalars {
            let allowed = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
                || scalar == "_" || scalar == "-"
            let character: Character = allowed ? Character(scalar) : "-"
            if character == "-", result.last == "-" { continue }
            result.append(character)
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct MCPConfigParse: Equatable, Sendable {
    public var servers: [MCPServerConfig]
    /// Entries that were left out and why, in file order: `(name, reason)`.
    public var skipped: [(name: String, reason: String)]

    public static func == (lhs: MCPConfigParse, rhs: MCPConfigParse) -> Bool {
        lhs.servers == rhs.servers
            && lhs.skipped.map(\.name) == rhs.skipped.map(\.name)
            && lhs.skipped.map(\.reason) == rhs.skipped.map(\.reason)
    }
}

public extension MCPServerConfig {
    enum ParseError: Error, Equatable {
        case notJSON
        case noServers
    }

    /// Reads the three shapes MCP configs come in:
    ///
    /// - `{"mcpServers": {name: {...}}}` (Claude Desktop, Cursor, plugin `.mcp.json`)
    /// - `{"mcp_servers": {name: {...}}}` (Codex)
    /// - a bare `{name: {...}}` map
    ///
    /// An entry needs `command` (stdio) or `url` (remote). The rest of the file
    /// is kept when one entry is unusable; the reason is reported in `skipped`.
    static func parse(_ data: Data, origin: String) throws -> MCPConfigParse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        let table: [String: Any]
        if let wrapped = object["mcpServers"] as? [String: Any] {
            table = wrapped
        } else if let wrapped = object["mcp_servers"] as? [String: Any] {
            table = wrapped
        } else {
            table = object
        }

        var servers: [MCPServerConfig] = []
        var skipped: [(name: String, reason: String)] = []
        var seen = Set<String>()
        for key in table.keys.sorted() {
            guard let entry = table[key] as? [String: Any] else {
                skipped.append((key, "不是一个服务器配置"))
                continue
            }
            guard let id = sanitizedID(key) else {
                skipped.append((key, "名字里没有可用的字符"))
                continue
            }
            guard seen.insert(id).inserted else {
                skipped.append((key, "和另一个条目的 id「\(id)」重复"))
                continue
            }
            let command = (entry["command"] as? String)?.trimmingCharacters(in: .whitespaces)
            let url = (entry["url"] as? String)?.trimmingCharacters(in: .whitespaces)
            let hasCommand = !(command ?? "").isEmpty
            let hasURL = !(url ?? "").isEmpty
            guard hasCommand != hasURL else {
                skipped.append((key, hasCommand ? "command 和 url 只能写一个" : "缺少 command 或 url"))
                continue
            }
            let args = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            var env: [String: String] = [:]
            for (name, value) in (entry["env"] as? [String: Any]) ?? [:] {
                if let text = value as? String { env[name] = text }
            }
            var server = MCPServerConfig(
                id: id, name: key,
                command: hasCommand ? command : nil, args: args, env: env,
                url: hasURL ? url : nil,
                enabled: (entry["enabled"] as? Bool) ?? !((entry["disabled"] as? Bool) ?? false),
                origin: origin
            )
            if let cwd = (entry["cwd"] as? String)?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
                server.cwd = cwd
            }
            servers.append(server)
        }
        guard !servers.isEmpty || !skipped.isEmpty else { throw ParseError.noServers }
        return MCPConfigParse(servers: servers, skipped: skipped)
    }
}
