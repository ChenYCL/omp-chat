import XCTest
@testable import OMPCore

/// MCP tools reach the model under generated names and with a risk that
/// decides whether the user is asked. A clash calls the wrong server; a risk
/// slip runs a tool without approval.
final class MCPToolProviderTests: XCTestCase {
    private typealias Identity = MCPToolNaming.Identity

    private func isValidWireName(_ name: String) -> Bool {
        name.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    // MARK: Naming

    func testPlainNamesWhenValidAndHashedOtherwise() throws {
        let plain = Identity(serverID: "playwright", tool: "browser_navigate")
        let dotted = Identity(serverID: "docs", tool: "search.pages v2")
        let long = Identity(serverID: "a-very-long-server-identifier", tool: String(repeating: "tool_name_", count: 6))
        let names = MCPToolNaming.assign([plain, dotted, long])

        XCTAssertEqual(names[plain], "mcp__playwright__browser_navigate", "the Codex/Claude form when it is already valid")
        let dottedName = try XCTUnwrap(names[dotted])
        XCTAssertTrue(dottedName.hasPrefix("mcp__docs__search_pages_v2_"), dottedName)
        let longName = try XCTUnwrap(names[long])
        XCTAssertEqual(longName.count, 64)
        XCTAssertTrue(longName.hasPrefix("mcp__a-very-long-server-identifier__tool_name_"))
        for name in names.values {
            XCTAssertTrue(isValidWireName(name), name)
        }
        XCTAssertEqual(MCPToolNaming.assign([long, dotted, plain]), names, "stable regardless of input order")
    }

    func testAmbiguousSeparatorsAndSanitisingClashesStillGetDistinctNames() {
        // Both spell mcp__a__b__c in plain form.
        let first = Identity(serverID: "a__b", tool: "c")
        let second = Identity(serverID: "a", tool: "b__c")
        // Both sanitise to the same characters.
        let dot = Identity(serverID: "s", tool: "x.y")
        let space = Identity(serverID: "s", tool: "x y")
        let names = MCPToolNaming.assign([first, second, dot, space])
        XCTAssertEqual(Set(names.values).count, 4)
        XCTAssertEqual(names[second], "mcp__a__b__c", "the first in sorted order keeps the plain name")
        XCTAssertNotEqual(names[first], names[second])
        XCTAssertNotEqual(names[dot], names[space])
    }

    func testAHashedNameThatMatchesAnotherToolsPlainNameIsResalted() {
        let needsHash = Identity(serverID: "x", tool: "t.y")
        let hashed = MCPToolNaming.hashedName(needsHash, salt: 0)
        // A tool whose plain name is exactly that hashed name.
        let squatter = Identity(serverID: "x", tool: String(hashed.dropFirst("mcp__x__".count)))
        XCTAssertEqual("mcp__x__\(squatter.tool)", hashed)

        let names = MCPToolNaming.assign([needsHash, squatter])
        XCTAssertEqual(names[squatter], hashed, "plain names are handed out first")
        XCTAssertNotEqual(names[needsHash], hashed)
        XCTAssertTrue(isValidWireName(names[needsHash] ?? ""))
    }

    func testManyLongNamesSharingAPrefixAreAllUniqueAndValid() {
        let prefix = String(repeating: "p", count: 70)
        var identities = (0..<500).map { Identity(serverID: "srv", tool: "\(prefix)\($0)") }
        identities += (0..<500).map { Identity(serverID: "srv-\($0 % 7)", tool: "工具\($0)") }
        let names = MCPToolNaming.assign(identities)
        XCTAssertEqual(names.count, identities.count)
        XCTAssertEqual(Set(names.values).count, identities.count, "no two tools share a wire name")
        XCTAssertTrue(names.values.allSatisfy(isValidWireName))
    }

    // MARK: Risk

    func testRiskHonoursReadOnlyHintOnlyForClosedWorldCatalogTools() {
        let readOnly = MCPTool(name: "read_file", readOnlyHint: true, openWorldHint: false)
        let readOnlyOpenWorld = MCPTool(name: "fetch", readOnlyHint: true, openWorldHint: true)
        let readOnlyUnspecifiedWorld = MCPTool(name: "list_pages", readOnlyHint: true)
        let writer = MCPTool(name: "write_file", readOnlyHint: false, openWorldHint: false)

        let catalog = MCPServerConfig(id: "fs", name: "FS", command: "npx", risk: .write, origin: "catalog")
        XCTAssertEqual(MCPToolProvider.risk(of: readOnly, on: catalog), .read)
        XCTAssertEqual(MCPToolProvider.risk(of: writer, on: catalog), .write)
        XCTAssertEqual(MCPToolProvider.risk(of: readOnlyOpenWorld, on: catalog), .write, "reaching the network is not a plain read")
        XCTAssertEqual(MCPToolProvider.risk(of: readOnlyUnspecifiedWorld, on: catalog), .write, "openWorldHint defaults to true")

        for origin in ["custom", "plugin:evil"] {
            let untrusted = MCPServerConfig(id: "fs", name: "FS", command: "npx", risk: .execute, origin: origin)
            XCTAssertEqual(MCPToolProvider.risk(of: readOnly, on: untrusted), .execute, "\(origin) annotations are not trusted")
        }

        let computer = MCPServerConfig(id: "cu", name: "CU", command: "npx", risk: .control, origin: "catalog")
        XCTAssertEqual(MCPToolProvider.risk(of: readOnly, on: computer), .control, ".control is never downgraded")
    }

    // MARK: Provider

    private actor FakeSource: MCPToolSource {
        nonisolated let serverID: String
        var config: MCPServerConfig
        var tools: [MCPTool]
        private(set) var calls: [(String, JSONValue)] = []

        init(config: MCPServerConfig, tools: [MCPTool]) {
            serverID = config.id
            self.config = config
            self.tools = tools
        }

        func setConfig(_ newValue: MCPServerConfig) { config = newValue }

        func toolSnapshot() async -> MCPServerTools { MCPServerTools(config: config, tools: tools) }

        func callTool(_ name: String, arguments: JSONValue) async throws -> MCPToolResult {
            calls.append((name, arguments))
            return MCPToolResult(blocks: [.text("ran \(name)")])
        }
    }

    private let context = AgentToolContext(conversationID: UUID(), workingDirectory: nil)

    func testDisabledToolsAndServersAreNeitherOfferedNorCallable() async throws {
        var config = MCPServerConfig(id: "fs", name: "Files", command: "npx", risk: .write, origin: "catalog")
        let source = FakeSource(config: config, tools: [
            MCPTool(name: "read_file", description: "Read", inputSchema: .object(["type": .string("object")]), readOnlyHint: true, openWorldHint: false),
            MCPTool(name: "write_file", description: "Write"),
        ])
        let off = FakeSource(config: MCPServerConfig(id: "off", name: "Off", command: "x", enabled: false), tools: [MCPTool(name: "t")])
        let provider = MCPToolProvider(sources: [source, off])

        var specs = await provider.tools()
        XCTAssertEqual(specs.map(\.name), ["mcp__fs__read_file", "mcp__fs__write_file"])
        XCTAssertEqual(specs.map(\.risk), [.read, .write])
        XCTAssertEqual(specs.first?.source, "MCP · Files")
        XCTAssertEqual(specs.first?.parametersJSON, #"{"properties":{},"type":"object"}"#, "properties added for the model API")
        let target = try XCTUnwrap(provider.target(forWireName: "mcp__fs__write_file"))
        XCTAssertEqual(target.serverID, "fs")
        XCTAssertEqual(target.tool, "write_file")

        // Switched off after the model saw it: refused, not run.
        config.disabledTools = ["write_file"]
        await source.setConfig(config)
        do {
            _ = try await provider.call("mcp__fs__write_file", argumentsJSON: "{}", context: context)
            XCTFail("a disabled tool must not run")
        } catch let error as MCPError {
            XCTAssertEqual(error, .unknownTool("mcp__fs__write_file"))
        }
        specs = await provider.tools()
        XCTAssertEqual(specs.map(\.name), ["mcp__fs__read_file"])
        let calls = await source.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCallForwardsArgumentsAndRejectsNonObjectArguments() async throws {
        let source = FakeSource(config: MCPServerConfig(id: "web", name: "Web", command: "npx"), tools: [MCPTool(name: "open")])
        let provider = MCPToolProvider(sources: [source])
        _ = await provider.tools()

        let output = try await provider.call("mcp__web__open", argumentsJSON: #"{"url":"https://example.com","n":3}"#, context: context)
        XCTAssertEqual(output.text, "ran open")
        let calls = await source.calls
        XCTAssertEqual(calls.first?.0, "open", "the server gets its own tool name back")
        XCTAssertEqual(calls.first?.1, .object(["url": .string("https://example.com"), "n": .number(3)]))

        _ = try await provider.call("mcp__web__open", argumentsJSON: "  ", context: context)
        let blank = await source.calls
        XCTAssertEqual(blank.last?.1, .object([:]), "blank arguments mean an empty object")

        for bad in ["[1,2]", "{oops", "\"text\""] {
            do {
                _ = try await provider.call("mcp__web__open", argumentsJSON: bad, context: context)
                XCTFail("\(bad) must be rejected")
            } catch let error as MCPError {
                guard case .badArguments = error else { return XCTFail("unexpected \(error)") }
            }
        }
    }

    func testSummaryIsToolNameAndATrimmedArgumentPreview() async {
        let source = FakeSource(config: MCPServerConfig(id: "web", name: "Web", command: "npx"), tools: [MCPTool(name: "browser_navigate")])
        let provider = MCPToolProvider(sources: [source])
        _ = await provider.tools()

        XCTAssertEqual(provider.summary(forCall: "mcp__web__browser_navigate", argumentsJSON: #"{"url":"https://example.com"}"#),
                       "browser_navigate url=https://example.com")
        XCTAssertEqual(provider.summary(forCall: "mcp__web__browser_navigate", argumentsJSON: "{}"), "browser_navigate")
        let long = provider.summary(forCall: "mcp__web__browser_navigate",
                                    argumentsJSON: #"{"text":"\#(String(repeating: "长", count: 400))\nnext"}"#)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertFalse(long.contains("\n"), "one line")
        XCTAssertLessThanOrEqual(long.count, "browser_navigate ".count + 160)
    }

    // MARK: Results

    func testToolResultContentBlocksBecomeTextAndImages() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"content": [
            {"type": "text", "text": "first"},
            {"type": "image", "data": "\#(png.base64EncodedString())", "mimeType": "image/png"},
            {"type": "resource", "resource": {"uri": "file:///notes.txt", "mimeType": "text/plain", "text": "embedded body"}},
            {"type": "resource", "resource": {"uri": "file:///blob.bin", "blob": "AAAA"}},
            {"type": "resource_link", "uri": "file:///src/main.rs", "name": "main.rs", "description": "entry point"}
        ], "isError": true}
        """#.utf8))
        let output = MCPToolResult(json: json).agentOutput
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.images, [AgentToolImage(data: png, mimeType: "image/png")])
        XCTAssertEqual(output.text.components(separatedBy: "\n"), [
            "first",
            "资源 file:///notes.txt：", "embedded body",
            "[二进制资源 file:///blob.bin]",
            "链接 main.rs <file:///src/main.rs>：entry point",
        ])

        let structured = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"content": [], "structuredContent": {"t": 22.5}}"#.utf8))
        XCTAssertEqual(MCPToolResult(json: structured).agentOutput.text, #"{"t":22.5}"#, "structured content stands in for missing text")
        XCTAssertFalse(MCPToolResult(json: .object([:])).agentOutput.text.isEmpty, "an empty result still says so")
    }
}
