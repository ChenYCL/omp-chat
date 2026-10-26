import XCTest
@testable import OMPCore

/// MCP configs arrive from users and plugins in three shapes; a wrong reading
/// here means a server silently never starts, or starts with the wrong command.
final class MCPServerConfigTests: XCTestCase {
    private func parse(_ json: String, origin: String = "custom") throws -> MCPConfigParse {
        try MCPServerConfig.parse(Data(json.utf8), origin: origin)
    }

    func testClaudeStyleWrapper() throws {
        let result = try parse(#"""
        {"mcpServers": {"Playwright": {"command": "npx", "args": ["-y", "@playwright/mcp@latest"], "env": {"A": "1"}}}}
        """#, origin: "catalog")
        XCTAssertEqual(result.servers.count, 1)
        let server = try XCTUnwrap(result.servers.first)
        XCTAssertEqual(server.id, "playwright", "id is the sanitised key")
        XCTAssertEqual(server.name, "Playwright", "the typed name is kept for display")
        XCTAssertEqual(server.command, "npx")
        XCTAssertEqual(server.args, ["-y", "@playwright/mcp@latest"])
        XCTAssertEqual(server.env, ["A": "1"])
        XCTAssertEqual(server.origin, "catalog")
        XCTAssertTrue(server.enabled)
    }

    func testCodexStyleWrapperAndBareMap() throws {
        let codex = try parse(#"{"mcp_servers": {"docs": {"url": "https://example.com/mcp"}}}"#)
        XCTAssertEqual(codex.servers.first?.url, "https://example.com/mcp")
        XCTAssertNil(codex.servers.first?.command)

        let bare = try parse(#"{"docs": {"command": "node", "args": ["server.js"]}}"#)
        XCTAssertEqual(bare.servers.first?.command, "node")
    }

    func testEnabledAndDisabledFlags() throws {
        let result = try parse(#"""
        {"a": {"command": "x", "enabled": false}, "b": {"command": "x", "disabled": true}, "c": {"command": "x"}}
        """#)
        let enabled = Dictionary(uniqueKeysWithValues: result.servers.map { ($0.id, $0.enabled) })
        XCTAssertEqual(enabled, ["a": false, "b": false, "c": true])
    }

    func testBadEntriesAreSkippedWithAReasonAndTheRestKept() throws {
        let result = try parse(#"""
        {"good": {"command": "x"}, "neither": {"args": []}, "both": {"command": "x", "url": "https://e"}, "text": "nope"}
        """#)
        XCTAssertEqual(result.servers.map(\.id), ["good"])
        XCTAssertEqual(Set(result.skipped.map(\.name)), ["neither", "both", "text"])
        XCTAssertTrue(result.skipped.allSatisfy { !$0.reason.isEmpty })
    }

    func testCollidingIDsKeepTheFirstOnly() throws {
        // "My Server" and "my-server" sanitise to the same id; both cannot own
        // the same tool names.
        let result = try parse(#"{"My Server": {"command": "x"}, "my-server": {"command": "y"}}"#)
        XCTAssertEqual(result.servers.count, 1)
        XCTAssertEqual(result.skipped.count, 1)
    }

    func testNotJSONAndEmptyAreErrors() {
        XCTAssertThrowsError(try parse("not json")) { XCTAssertEqual($0 as? MCPServerConfig.ParseError, .notJSON) }
        XCTAssertThrowsError(try parse("[]")) { XCTAssertEqual($0 as? MCPServerConfig.ParseError, .notJSON) }
        XCTAssertThrowsError(try parse("{}")) { XCTAssertEqual($0 as? MCPServerConfig.ParseError, .noServers) }
    }

    func testSanitizedID() {
        XCTAssertEqual(MCPServerConfig.sanitizedID("  Chrome DevTools!! "), "chrome-devtools")
        XCTAssertEqual(MCPServerConfig.sanitizedID("a__b--c"), "a__b-c")
        XCTAssertNil(MCPServerConfig.sanitizedID("中文"), "nothing usable survives")
        XCTAssertNil(MCPServerConfig.sanitizedID("---"))
    }

    func testOldSettingsDocumentsDecodeWithTheNewFields() throws {
        let old = Data(#"{"version": 1, "fontSize": 17}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(settings.mcpServers, [])
        XCTAssertEqual(settings.defaultPermissionMode, "ask")
        XCTAssertEqual(settings.fontSize, 17)
    }

    func testServersRoundTripThroughSettings() throws {
        var settings = AppSettings()
        settings.mcpServers = [MCPServerConfig(id: "fs", name: "fs", command: "npx", args: ["x"], risk: .write)]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).mcpServers, settings.mcpServers)
    }
}
