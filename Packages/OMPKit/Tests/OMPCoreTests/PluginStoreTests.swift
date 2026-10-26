import XCTest
@testable import OMPCore

/// Installing, refusing, switching and listing plugins on real folders. A
/// wrong answer here either runs code the user never approved or installs a
/// plugin that can read and write outside its own folder.
final class PluginStoreTests: XCTestCase {
    private var root: URL!
    private var store: PluginStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PluginStore(root: root.appendingPathComponent("store", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A plugin folder with a manifest plus `files` (relative path → text).
    @discardableResult
    private func makePlugin(_ name: String, manifest: String? = nil, files: [String: String] = [:]) throws -> URL {
        let folder = root.appendingPathComponent("src/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
        try (manifest ?? #"{"name": "\#(name)", "version": "1.0.0"}"#)
            .write(to: folder.appendingPathComponent(".codex-plugin/plugin.json"), atomically: true, encoding: .utf8)
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return folder
    }

    private let hooksJSON = #"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 ${PLUGIN_ROOT}/hooks/check.py"}]}]}}"#
    private let mcpJSON = #"{"mcpServers": {"docs": {"command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/server.js", "--stdio"], "cwd": "./bin"}}}"#

    @discardableResult
    private func install(_ folder: URL) throws -> InstalledPlugin {
        try store.commitInstall(try store.prepareInstall(folder: folder.path))
    }

    private func refusal(_ folder: URL, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            let plan = try store.prepareInstall(folder: folder.path)
            store.discardInstall(plan)
            XCTFail("expected a refusal", file: file, line: line)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Install

    func testPlanShowsEveryCommandAndInstallsNothingUntilConfirmed() throws {
        let folder = try makePlugin("helper", files: [
            "hooks/hooks.json": #"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 ${PLUGIN_ROOT}/hooks/check.py"}]}], "Stop": [{"hooks": [{"type": "command", "command": "never-fired.sh"}]}]}}"#,
            ".mcp.json": #"{"mcpServers": {"docs": {"command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/server.js", "--stdio"], "cwd": "./bin"}, "off": {"command": "idle", "disabled": true}}}"#,
            "bin/.keep": "",
            "skills/greet/SKILL.md": "---\nname: greet\ndescription: Greet the user.\n---\nSay hi.",
        ])
        let plan = try store.prepareInstall(folder: folder.path)
        let installedRoot = store.root.appendingPathComponent("plugins/helper").path
        XCTAssertEqual(plan.hookCommands, ["PreToolUse（Bash）：python3 ${PLUGIN_ROOT}/hooks/check.py"],
                       "a Stop hook is listed in the contents, but nothing here runs it")
        XCTAssertEqual(plan.contents.hooks.count, 2)
        XCTAssertEqual(plan.mcpCommands, ["docs：node \(installedRoot)/server.js --stdio（工作目录 \(installedRoot)/bin）"],
                       "server commands show the path they will run from, not the staging copy; a disabled server starts nothing")
        XCTAssertEqual(plan.contents.skills.map(\.name), ["helper:greet"])
        XCTAssertTrue(plan.replacing == nil, "nothing installed yet to replace")
        XCTAssertTrue(store.installed().isEmpty, "a plan is not an install")

        store.discardInstall(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.stagingDirectory))
        XCTAssertTrue(store.installed().isEmpty)
    }

    func testConfirmedInstallIsACopyEnabledWithHooksUntrusted() throws {
        let folder = try makePlugin("helper", files: ["hooks/hooks.json": hooksJSON, "skills/greet/SKILL.md": "---\nname: greet\ndescription: Greet.\n---\n"])
        let plugin = try install(folder)
        try FileManager.default.removeItem(at: folder)

        XCTAssertEqual(plugin.id, "helper")
        XCTAssertEqual(plugin.manifest?.version, "1.0.0")
        XCTAssertTrue(plugin.enabled)
        XCTAssertNil(plugin.problem)
        XCTAssertEqual(plugin.source, .folder(path: folder.path))
        XCTAssertFalse(plugin.hooksTrusted)
        XCTAssertTrue(store.activeHooks().isEmpty, "installing never trusts hooks")
        XCTAssertEqual(store.skillRoots().map(\.scope), [.plugin("helper")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: (plugin.root as NSString).appendingPathComponent("skills/greet/SKILL.md")),
                      "the plugin keeps working after its source folder is gone")
    }

    func testReplacingKeepsSwitchesAndDropsTrustWhenHooksChange() throws {
        try install(try makePlugin("helper", files: ["hooks/hooks.json": hooksJSON]))
        try store.setEnabled(false, id: "helper")
        try store.setHooksTrusted(true, id: "helper")
        XCTAssertTrue(try XCTUnwrap(store.plugin(id: "helper")).hooksTrusted)

        try FileManager.default.removeItem(at: root.appendingPathComponent("src"))
        let same = try makePlugin("helper", manifest: #"{"name": "helper", "version": "1.1.0"}"#, files: ["hooks/hooks.json": hooksJSON])
        let plan = try store.prepareInstall(folder: same.path)
        XCTAssertEqual(plan.replacing, .some("1.0.0"))
        let replaced = try store.commitInstall(plan)
        XCTAssertFalse(replaced.enabled, "the user's switch survives an update")
        XCTAssertTrue(replaced.hooksTrusted, "unchanged hooks stay trusted")

        try FileManager.default.removeItem(at: root.appendingPathComponent("src"))
        let changed = try makePlugin("helper", files: ["hooks/hooks.json": hooksJSON.replacingOccurrences(of: "check.py", with: "other.py")])
        XCTAssertFalse(try store.commitInstall(try store.prepareInstall(folder: changed.path)).hooksTrusted, "changed hooks need trusting again")
    }

    // MARK: Refusals

    func testSymlinkOutOfThePluginIsRefused() throws {
        let secret = root.appendingPathComponent("secret.txt")
        try "token".write(to: secret, atomically: true, encoding: .utf8)
        let relativeOut = try makePlugin("leaky")
        try FileManager.default.createSymbolicLink(atPath: relativeOut.appendingPathComponent("skills").path, withDestinationPath: "../../secret.txt")
        XCTAssertEqual(refusal(relativeOut)?.contains("符号链接 skills → ../../secret.txt"), true)

        try FileManager.default.removeItem(at: root.appendingPathComponent("src"))
        let absolute = try makePlugin("absolute")
        try FileManager.default.createSymbolicLink(atPath: absolute.appendingPathComponent("data").path, withDestinationPath: absolute.appendingPathComponent(".codex-plugin").path)
        XCTAssertEqual(refusal(absolute)?.contains("绝对路径"), true, "an absolute link would point back at the source after the copy")
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("staging").path)) ?? [], [],
                       "a refused install leaves no staging copy")
    }

    func testManifestPathClimbingOutIsRefused() throws {
        let folder = try makePlugin("climber", manifest: #"{"name": "climber", "skills": "../other-plugin/skills"}"#)
        XCTAssertEqual(refusal(folder)?.contains("../other-plugin/skills"), true)
    }

    func testRelativeSymlinkInsideThePluginIsAllowed() throws {
        let folder = try makePlugin("linked", files: ["shared/greet/SKILL.md": "---\nname: greet\ndescription: Greet.\n---\n"])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("skills/greet").path, withDestinationPath: "../shared/greet")
        XCTAssertEqual(try install(folder).contents.skills.map(\.name), ["linked:greet"])
    }

    func testInstalledPluginTamperedWithLaterStopsLoading() throws {
        let plugin = try install(try makePlugin("helper", files: [".mcp.json": mcpJSON]))
        try FileManager.default.createSymbolicLink(atPath: (plugin.root as NSString).appendingPathComponent("escape"), withDestinationPath: "../../..")
        let reloaded = try XCTUnwrap(store.plugin(id: "helper"))
        XCTAssertNotNil(reloaded.problem)
        XCTAssertTrue(store.mcpServers().isEmpty, "a broken plugin contributes nothing")
    }

    func testMissingOrInvalidManifestIsRefused() throws {
        let bare = root.appendingPathComponent("src/bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        XCTAssertEqual(refusal(bare), PluginManifest.ParseError.missing.localizedDescription)
        let badName = try makePlugin("bad", manifest: #"{"name": "bad name"}"#)
        XCTAssertEqual(refusal(badName)?.contains("插件名不可用"), true)
        XCTAssertNotNil(refusal(root.appendingPathComponent("nowhere")))
    }

    // MARK: Switches and contributions

    func testSwitchesPersistAcrossStoreInstances() throws {
        try install(try makePlugin("helper", files: ["hooks/hooks.json": hooksJSON, ".mcp.json": mcpJSON]))
        try store.setHooksTrusted(true, id: "helper")
        try store.setMCPServerEnabled(false, server: "docs", pluginID: "helper")
        XCTAssertEqual(store.activeHooks().count, 1)

        let reopened = PluginStore(root: store.root)
        let plugin = try XCTUnwrap(reopened.plugin(id: "helper"))
        XCTAssertTrue(plugin.enabled)
        XCTAssertTrue(plugin.hooksTrusted)
        XCTAssertEqual(reopened.mcpServers().map(\.enabled), [false])

        try reopened.setEnabled(false, id: "helper")
        let third = PluginStore(root: store.root)
        XCTAssertFalse(try XCTUnwrap(third.plugin(id: "helper")).enabled)
        XCTAssertTrue(third.mcpServers().isEmpty, "a disabled plugin offers no servers")
        XCTAssertTrue(third.activeHooks().isEmpty, "nor hooks, trusted or not")
        XCTAssertTrue(third.skillRoots().isEmpty)
        XCTAssertTrue(third.readableRoots().isEmpty)
    }

    func testBundledServersGetCollisionFreeIdsAndPluginPaths() throws {
        let one = try install(try makePlugin("alpha", files: [".mcp.json": mcpJSON, "bin/.keep": ""]))
        try install(try makePlugin("beta", manifest: #"{"name": "beta", "mcpServers": {"mcp_servers": {"docs": {"url": "https://example.com/mcp"}}}}"#))

        let servers = store.mcpServers()
        XCTAssertEqual(servers.map(\.id), ["alpha-docs", "beta-docs"])
        XCTAssertEqual(servers.map(\.name), ["docs", "docs"])
        XCTAssertEqual(servers.map(\.origin), ["plugin:alpha", "plugin:beta"])
        let alpha = servers[0]
        XCTAssertEqual(alpha.args, ["\(one.root)/server.js", "--stdio"])
        XCTAssertEqual(alpha.cwd, "\(one.root)/bin")
        XCTAssertEqual(alpha.env["PLUGIN_ROOT"], one.root)
        XCTAssertEqual(alpha.env["PLUGIN_DATA"], one.dataDirectory)
        XCTAssertEqual(servers[1].url, "https://example.com/mcp")
    }

    func testServerCwdOutsideThePluginIsNotOffered() throws {
        let plugin = try install(try makePlugin("cwd", files: [".mcp.json": #"{"s": {"command": "x", "cwd": "../.."}}"#]))
        XCTAssertTrue(plugin.contents.mcpServers.isEmpty)
        XCTAssertEqual(plugin.contents.mcpProblems, ["s：cwd「../..」指向插件目录以外"])
    }

    func testUninstallRemovesFilesDataAndRecord() throws {
        let plugin = try install(try makePlugin("helper", files: ["hooks/hooks.json": hooksJSON]))
        try store.setHooksTrusted(true, id: "helper")
        XCTAssertEqual(store.activeHooks().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.dataDirectory), "the data folder exists once hooks can run")

        try store.uninstall(id: "helper")
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.dataDirectory))
        XCTAssertThrowsError(try store.setEnabled(true, id: "helper"))

        // Reinstalling starts over: enabled, hooks untrusted.
        let again = try install(try makePlugin("helper2", manifest: #"{"name": "helper"}"#, files: ["hooks/hooks.json": hooksJSON]))
        XCTAssertFalse(again.hooksTrusted)
    }

    func testFolderWithoutRecordIsListedDisabled() throws {
        let folder = try makePlugin("manual")
        let target = store.root.appendingPathComponent("plugins/manual")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: target)
        let plugin = try XCTUnwrap(store.plugin(id: "manual"))
        XCTAssertFalse(plugin.enabled, "a folder nobody confirmed does not run")
        XCTAssertEqual(plugin.source, .unknown)
    }
}
