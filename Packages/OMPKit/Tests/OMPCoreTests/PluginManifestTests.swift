import XCTest
@testable import OMPCore

/// `.codex-plugin/plugin.json` as Codex plugins write it: a misread path
/// drops a plugin's skills or hooks, a lenient one lets a plugin reach
/// outside its folder.
final class PluginManifestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-manifest-\(UUID().uuidString)/my-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    private func parse(_ json: String) throws -> PluginManifest {
        try PluginManifest.parse(Data(json.utf8), pluginRoot: root.path)
    }

    private func error(_ json: String) -> PluginManifest.ParseError? {
        do {
            _ = try parse(json)
            return nil
        } catch {
            return error as? PluginManifest.ParseError
        }
    }

    private func inRoot(_ relative: String) -> String {
        ((root.path as NSString).appendingPathComponent(relative) as NSString).standardizingPath
    }

    func testFullManifestResolvesComponentPathsAndIgnoresUnknownKeys() throws {
        let manifest = try parse("""
        {
          "name": "my-plugin", "version": " 0.1.0 ", "description": "Bundle",
          "author": {"name": "Team", "email": "t@example.com", "url": "https://example.com"},
          "homepage": "https://example.com/p", "repository": "https://github.com/e/p", "license": "MIT",
          "keywords": ["research", "crm"],
          "skills": "./skills/", "mcpServers": "./.mcp.json", "apps": "./.app.json", "hooks": "./hooks/hooks.json",
          "interface": {"displayName": "My Plugin", "capabilities": ["Read"], "websiteURL": "https://example.com",
                        "defaultPrompt": "Use My Plugin", "composerIcon": "./assets/icon.png", "screenshots": ["./assets/s1.png"]},
          "futureField": {"anything": [1, 2, 3]}, "extensions": {"com.openai": {}}
        }
        """)
        XCTAssertEqual(manifest.name, "my-plugin")
        XCTAssertEqual(manifest.version, "0.1.0")
        XCTAssertEqual(manifest.author, PluginManifest.Author(name: "Team", email: "t@example.com", url: "https://example.com"))
        XCTAssertEqual(manifest.keywords, ["research", "crm"])
        XCTAssertEqual(manifest.skills, [inRoot("skills")])
        XCTAssertEqual(manifest.mcpServers, .file(inRoot(".mcp.json")))
        XCTAssertEqual(manifest.apps, inRoot(".app.json"))
        XCTAssertEqual(manifest.hooks, .files([inRoot("hooks/hooks.json")]))
        XCTAssertEqual(manifest.displayName, "My Plugin")
        XCTAssertEqual(manifest.interface?.defaultPrompts, ["Use My Plugin"])
        XCTAssertEqual(manifest.interface?.composerIcon, inRoot("assets/icon.png"))
        XCTAssertEqual(manifest.interface?.screenshots, [inRoot("assets/s1.png")])
        XCTAssertTrue(manifest.warnings.isEmpty, "\(manifest.warnings)")
        XCTAssertTrue(manifest.escapingPaths.isEmpty)
    }

    func testEmptyNameFallsBackToFolderAndEmptyVersionIsNil() throws {
        let manifest = try parse(#"{"name": "  ", "version": "  "}"#)
        XCTAssertEqual(manifest.name, "my-plugin")
        XCTAssertNil(manifest.version)
        XCTAssertTrue(manifest.skills.isEmpty, "no skills key: the store falls back to skills/")
        XCTAssertNil(manifest.hooks)
    }

    func testWrongTypesAndBadNamesAreClearErrors() {
        XCTAssertEqual(error(#"{"name": "p", "version": 1}"#), .wrongType(field: "version", expected: "字符串"))
        XCTAssertEqual(error(#"{"name": "p", "keywords": "crm"}"#), .wrongType(field: "keywords", expected: "字符串数组"))
        XCTAssertEqual(error(#"{"name": "p", "author": 3}"#), .wrongType(field: "author", expected: "对象"))
        XCTAssertEqual(error(#"{"name": "p", "interface": {"displayName": false}}"#), .wrongType(field: "interface.displayName", expected: "字符串"))
        XCTAssertEqual(error(#"{"name": "my plugin"}"#), .invalidName("只能包含 ASCII 字母、数字、点、下划线和连字符"))
        XCTAssertEqual(error(#"{"name": ".hidden"}"#), .invalidName("点号只能用在两段名字之间"))
        XCTAssertEqual(error(#"{"name": "a..b"}"#), .invalidName("点号只能用在两段名字之间"))
        XCTAssertEqual(error("not json"), .notJSON)
        XCTAssertEqual(error("[1, 2]"), .notObject)
        XCTAssertNil(error(#"{"name": "v1.2_ok-name"}"#))
    }

    func testPathRules() throws {
        let manifest = try parse(#"{"name": "p", "skills": ["skills", "./ok", "../outside", "./a/../../b", "/etc/codex"]}"#)
        XCTAssertEqual(manifest.skills, [inRoot("ok")])
        XCTAssertEqual(manifest.escapingPaths, ["../outside", "./a/../../b", "/etc/codex"])
        XCTAssertEqual(manifest.warnings.filter { $0.contains("必须以 ./ 开头") }.count, 1, "a bare relative path is dropped, not refused")
    }

    func testHooksAcceptEveryDocumentedShape() throws {
        XCTAssertEqual(try parse(#"{"name": "p", "hooks": ["./hooks/a.json", "./hooks/b.json"]}"#).hooks,
                       .files([inRoot("hooks/a.json"), inRoot("hooks/b.json")]))
        guard case .inline(let single)? = try parse(#"{"name": "p", "hooks": {"hooks": {"Stop": []}}}"#).hooks else {
            return XCTFail("inline object")
        }
        XCTAssertEqual(single.count, 1)
        guard case .inline(let list)? = try parse(#"{"name": "p", "hooks": [{"hooks": {}}, {"hooks": {}}]}"#).hooks else {
            return XCTFail("inline list")
        }
        XCTAssertEqual(list.count, 2)
        let invalid = try parse(#"{"name": "p", "hooks": 7}"#)
        XCTAssertNil(invalid.hooks)
        XCTAssertEqual(invalid.warnings.count, 1)
    }

    func testInlineMCPServers() throws {
        guard case .inline(let data)? = try parse(#"{"name": "p", "mcpServers": {"docs": {"command": "docs-mcp"}}}"#).mcpServers else {
            return XCTFail("inline servers")
        }
        XCTAssertEqual(try MCPServerConfig.parse(data, origin: "plugin:p").servers.map(\.name), ["docs"])
    }

    func testDefaultPromptLimits() throws {
        let long = String(repeating: "x", count: 129)
        let manifest = try parse(#"{"name": "p", "interface": {"defaultPrompt": ["  one   two ", "\#(long)", "three", "four", "five"]}}"#)
        XCTAssertEqual(manifest.interface?.defaultPrompts, ["one two", "three", "four"])
        XCTAssertEqual(manifest.warnings.count, 2, "one too long, then the cap of three")
    }

    func testCodexLocationWinsOverClaudeLocation() throws {
        let claude = root.appendingPathComponent(".claude-plugin")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try #"{"name": "claude-name", "author": "Someone"}"#.write(to: claude.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let legacy = try PluginManifest.load(pluginRoot: root.path)
        XCTAssertEqual(legacy.name, "claude-name")
        XCTAssertEqual(legacy.author?.name, "Someone", "Claude manifests give the author as a string")

        let codex = root.appendingPathComponent(".codex-plugin")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try #"{"name": "codex-name"}"#.write(to: codex.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try PluginManifest.load(pluginRoot: root.path).name, "codex-name")
    }

    func testMissingManifest() {
        XCTAssertThrowsError(try PluginManifest.load(pluginRoot: root.path)) { error in
            XCTAssertEqual(error as? PluginManifest.ParseError, .missing)
        }
    }
}
