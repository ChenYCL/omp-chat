import Foundation

/// Wire names for MCP tools: `mcp__<serverID>__<tool>`, the form Codex and
/// Claude Code hook matchers use, whenever that string is already a valid
/// function name (`^[a-zA-Z0-9_-]{1,64}$`) and not taken. Anything else is
/// sanitised, cut to fit and suffixed with `_` plus a stable 6-character hash
/// of the original identity.
public enum MCPToolNaming {
    public struct Identity: Hashable, Sendable, Comparable {
        public var serverID: String
        public var tool: String

        public init(serverID: String, tool: String) {
            self.serverID = serverID
            self.tool = tool
        }

        public static func < (lhs: Identity, rhs: Identity) -> Bool {
            (lhs.serverID, lhs.tool) < (rhs.serverID, rhs.tool)
        }
    }

    public static let maxLength = 64

    /// A unique name for every identity, deterministic for the same set.
    ///
    /// Uniqueness holds by construction: plain names are handed out first and
    /// a duplicate falls through to the hashed form; a hashed name that is
    /// already taken (by a plain name or a hash collision) is re-hashed with a
    /// salt until it is free.
    public static func assign(_ identities: [Identity]) -> [Identity: String] {
        let ordered = Set(identities).sorted()
        var names: [Identity: String] = [:]
        var taken = Set<String>()
        var needsHash: [Identity] = []
        for identity in ordered {
            let plain = "mcp__\(identity.serverID)__\(identity.tool)"
            if isValid(plain), taken.insert(plain).inserted {
                names[identity] = plain
            } else {
                needsHash.append(identity)
            }
        }
        for identity in needsHash {
            var salt = 0
            var name = hashedName(identity, salt: salt)
            while !taken.insert(name).inserted {
                salt += 1
                name = hashedName(identity, salt: salt)
            }
            names[identity] = name
        }
        return names
    }

    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= maxLength && name.unicodeScalars.allSatisfy(isAllowed)
    }

    static func hashedName(_ identity: Identity, salt: Int) -> String {
        let raw = "mcp__\(identity.serverID)__\(identity.tool)"
        let sanitised = String(String.UnicodeScalarView(raw.unicodeScalars.map { isAllowed($0) ? $0 : "_" }))
        var key = identity.serverID + "\u{1F}" + identity.tool
        if salt > 0 { key += "#\(salt)" }
        return String(sanitised.prefix(maxLength - 7)) + "_" + stableHash(key)
    }

    /// FNV-1a 64 in base 36, six characters. Stable across launches, unlike
    /// `Hasher`.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let space: UInt64 = 2_176_782_336 // 36^6
        let digits = String(hash % space, radix: 36)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-"
    }
}

/// Every connected MCP server's tools as one agent tool provider (id "mcp").
public final class MCPToolProvider: AgentToolProvider, @unchecked Sendable {
    struct Entry: Equatable {
        var serverID: String
        var serverName: String
        var tool: MCPTool
        var risk: ToolRisk
    }

    private let lock = NSLock()
    private var sources: [any MCPToolSource]
    /// Wire name → tool, from the latest `tools()`. `summary` and `target`
    /// are synchronous and read it.
    private var table: [String: Entry] = [:]

    public init(sources: [any MCPToolSource] = []) {
        self.sources = sources
    }

    /// Swaps the servers behind the provider. One provider lives as long as
    /// the app, so wire names already handed to the model keep resolving.
    public func setSources(_ newValue: [any MCPToolSource]) {
        lock.withLock { sources = newValue }
    }

    /// Risk of one server tool. The server's configured risk applies, except
    /// that a catalog server's tool marked read-only *and* closed-world
    /// becomes `.read`. Annotations are self-reported, so a custom or plugin
    /// server cannot talk its way past approval; an open-world tool (fetching
    /// URLs, driving a browser) reaches outside the working directory, which
    /// is not what `.read` means; `.control` is never downgraded.
    public static func risk(of tool: MCPTool, on server: MCPServerConfig) -> ToolRisk {
        guard server.risk != .control, server.origin == "catalog",
              tool.readOnlyHint == true, tool.openWorldHint == false else { return server.risk }
        return .read
    }

    /// The specs for `servers`, and the wire-name table behind them. Disabled
    /// servers and switched-off tools are left out.
    static func build(_ servers: [MCPServerTools]) -> (specs: [AgentToolSpec], table: [String: Entry]) {
        var entries: [MCPToolNaming.Identity: Entry] = [:]
        for server in servers where server.config.enabled {
            let disabled = Set(server.config.disabledTools)
            for tool in server.tools where !disabled.contains(tool.name) {
                entries[MCPToolNaming.Identity(serverID: server.config.id, tool: tool.name)] = Entry(
                    serverID: server.config.id, serverName: server.config.name,
                    tool: tool, risk: risk(of: tool, on: server.config)
                )
            }
        }
        let names = MCPToolNaming.assign(Array(entries.keys))
        var table: [String: Entry] = [:]
        var specs: [AgentToolSpec] = []
        for (identity, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let name = names[identity] else { continue }
            table[name] = entry
            let description = entry.tool.description.isEmpty ? entry.tool.displayName : entry.tool.description
            specs.append(AgentToolSpec(
                name: name, description: description,
                parametersJSON: parametersJSON(entry.tool.inputSchema),
                risk: entry.risk, source: "MCP · \(entry.serverName)"
            ))
        }
        return (specs, table)
    }

    /// The schema as the model API wants it: an object with `properties`.
    static func parametersJSON(_ schema: JSONValue) -> String {
        guard case .object(var object) = schema else {
            return #"{"properties":{},"type":"object"}"#
        }
        if object["type"] == nil { object["type"] = .string("object") }
        if object["properties"] == nil { object["properties"] = .object([:]) }
        return JSONValue.object(object).mcpJSONText()
    }

    public func tools() async -> [AgentToolSpec] {
        var servers: [MCPServerTools] = []
        for source in lock.withLock({ sources }) { servers.append(await source.toolSnapshot()) }
        let built = Self.build(servers)
        lock.withLock { table = built.table }
        return built.specs
    }

    /// The server and original tool name behind a wire name, from the latest
    /// `tools()`. Hook matchers map calls back with it.
    public func target(forWireName name: String) -> (serverID: String, tool: String)? {
        lock.withLock { table[name].map { ($0.serverID, $0.tool.name) } }
    }

    public func summary(forCall name: String, argumentsJSON: String) -> String {
        let toolName = lock.withLock { table[name]?.tool.name } ?? name
        let preview = Self.argumentPreview(argumentsJSON)
        return preview.isEmpty ? toolName : "\(toolName) \(preview)"
    }

    public func call(_ name: String, argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolOutput {
        // Rebuilt on every call, so a tool switched off or a server stopped
        // since the model saw the list is refused rather than run.
        _ = await tools()
        let (entry, current) = lock.withLock { (table[name], sources) }
        guard let entry, let source = current.first(where: { $0.serverID == entry.serverID }) else {
            throw MCPError.unknownTool(name)
        }
        let arguments = try Self.arguments(argumentsJSON)
        return try await source.callTool(entry.tool.name, arguments: arguments).agentOutput
    }

    /// The model's argument text as a JSON object; blank means none.
    static func arguments(_ text: String) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object([:]) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            throw MCPError.badArguments(String(trimmed.prefix(120)))
        }
        guard case .object = value else { throw MCPError.badArguments(String(trimmed.prefix(120))) }
        return value
    }

    /// `key=value` pairs on one line, at most 160 characters.
    static func argumentPreview(_ text: String) -> String {
        let limit = 160
        let flat: String
        if let value = try? arguments(text), case .object(let object) = value {
            flat = object.keys.sorted().map { key in
                let rendered: String
                switch object[key] {
                case .string(let string)?: rendered = string
                case let other?: rendered = other.mcpJSONText()
                case nil: rendered = ""
                }
                return "\(key)=\(rendered)"
            }.joined(separator: " ")
        } else {
            flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let oneLine = flat.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit - 1)) + "…" : oneLine
    }
}
