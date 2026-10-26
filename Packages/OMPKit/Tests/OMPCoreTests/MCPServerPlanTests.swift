import XCTest
@testable import OMPCore

/// Which servers a settings change restarts, what environment a server gets,
/// how a missing runtime is told apart from a typo, and what a catalog
/// install writes. Mistakes here restart everything on a rename, leak a
/// secret into the workspace file, or start a server with the wrong folder.
final class MCPServerPlanTests: XCTestCase {
    private func key(_ config: MCPServerConfig, secrets: [String: String] = [:]) -> MCPLaunchKey {
        MCPLaunchKey(config: config, secrets: secrets)
    }

    // MARK: Diff

    func testOnlyLaunchChangesRestartAServer() {
        let base = MCPServerConfig(id: "fs", name: "FS", command: "npx", args: ["-y", "pkg@1"], env: ["A": "1"])
        var renamed = base
        renamed.name = "Files"
        renamed.risk = .read
        renamed.origin = "catalog"
        renamed.disabledTools = ["write_file"]
        XCTAssertEqual(key(base), key(renamed), "name, risk, origin and tool switches apply in place")

        var newArgs = base
        newArgs.args.append("/tmp")
        var newEnv = base
        newEnv.env["A"] = "2"
        var newCwd = base
        newCwd.cwd = "/tmp"
        for changed in [newArgs, newEnv, newCwd] {
            XCTAssertNotEqual(key(base), key(changed))
        }
        XCTAssertNotEqual(key(base, secrets: ["TOKEN": "a"]), key(base, secrets: ["TOKEN": "b"]), "a new secret value restarts")
    }

    func testDiffStartsStopsRestartsAndKeeps() {
        let a = MCPServerConfig(id: "a", name: "A", command: "x")
        let b = MCPServerConfig(id: "b", name: "B", command: "x")
        let c = MCPServerConfig(id: "c", name: "C", command: "x")
        var cChanged = c
        cChanged.args = ["--flag"]
        let d = MCPServerConfig(id: "d", name: "D", url: "https://example.com/mcp")

        let diff = MCPServerDiff.compute(
            running: ["a": key(a), "b": key(b), "c": key(c)],
            desired: ["a": key(a), "c": key(cChanged), "d": key(d)]
        )
        XCTAssertEqual(diff, MCPServerDiff(start: ["d"], stop: ["b"], restart: ["c"], keep: ["a"]))
        XCTAssertEqual(MCPServerDiff.compute(running: [:], desired: [:]), MCPServerDiff())
    }

    // MARK: Environment

    func testEnvironmentPrecedenceIsVaultThenConfigThenBase() {
        let config = MCPServerConfig(id: "gh", name: "GH", command: "npx", env: [
            "TOKEN": "",             // secret, stored in the vault
            "REGION": "eu",          // plain value
            "HOME": "/override",     // config beats the inherited value
            "PLACEHOLDER": "",       // secret never saved: inherited value stays
        ])
        let vault = ["TOKEN": "s3cret", "UNLISTED": "ignored"]
        let environment = MCPLaunchPlanner.environment(
            base: ["PATH": "/usr/bin", "HOME": "/Users/me", "PLACEHOLDER": "inherited"],
            config: config, secret: { vault[$0] }
        )
        XCTAssertEqual(environment, [
            "PATH": "/usr/bin", "HOME": "/override", "PLACEHOLDER": "inherited",
            "TOKEN": "s3cret", "REGION": "eu",
        ])

        var configured = config
        configured.env["TOKEN"] = "from-config"
        let vaultWins = MCPLaunchPlanner.environment(base: [:], config: configured, secret: { vault[$0] })
        XCTAssertEqual(vaultWins["TOKEN"], "s3cret", "the vault overrides a value typed into the config")
        XCTAssertEqual(MCPLaunchPlanner.secrets(for: config, secret: { vault[$0] }), ["TOKEN": "s3cret"],
                       "only variables the config names are read from the vault")
    }

    func testWorkingDirectoryDefaultsToHomeAndResolvesRelativePaths() {
        var config = MCPServerConfig(id: "p", name: "P", command: "node")
        XCTAssertEqual(MCPLaunchPlanner.workingDirectory(for: config, home: "/Users/me"), "/Users/me")
        config.cwd = "plugins/x"
        XCTAssertEqual(MCPLaunchPlanner.workingDirectory(for: config, home: "/Users/me"), "/Users/me/plugins/x")
        config.cwd = "~/work"
        XCTAssertEqual(MCPLaunchPlanner.workingDirectory(for: config, home: "/Users/me"), "/Users/me/work")
        config.cwd = "/opt/server"
        XCTAssertEqual(MCPLaunchPlanner.workingDirectory(for: config, home: "/Users/me"), "/opt/server")
    }

    // MARK: Runtime

    func testLocateFindsExecutablesOnPathAndSkipsNonExecutables() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-locate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        // A plain file and a directory named npx come first and must be skipped.
        FileManager.default.createFile(atPath: first.appendingPathComponent("npx").path, contents: Data("x".utf8))
        try FileManager.default.createDirectory(at: first.appendingPathComponent("uvx"), withIntermediateDirectories: true)
        let npx = second.appendingPathComponent("npx").path
        FileManager.default.createFile(atPath: npx, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        let path = "\(first.path)::\(second.path)"
        XCTAssertEqual(MCPLaunchPlanner.locate("npx", path: path, home: root.path), npx)
        XCTAssertNil(MCPLaunchPlanner.locate("uvx", path: path, home: root.path))
        XCTAssertEqual(MCPLaunchPlanner.locate(npx, path: "", home: "/nowhere"), npx, "an absolute path is used as is")
        XCTAssertEqual(MCPLaunchPlanner.locate("~/second/npx", path: "", home: root.path), npx)
        XCTAssertNil(MCPLaunchPlanner.locate("  ", path: path, home: root.path))

        XCTAssertEqual(MCPRuntime.required(byCommand: "npx"), .node)
        XCTAssertEqual(MCPRuntime.required(byCommand: "/opt/homebrew/bin/uvx"), .uv)
        XCTAssertNil(MCPRuntime.required(byCommand: "my-server"), "an unknown command is a typo, not a missing runtime")
    }

    // MARK: Catalog install

    func testCatalogInstallAppliesAnswersToArgumentsAndEnvironment() throws {
        let filesystem = try XCTUnwrap(MCPCatalog.entries.first { $0.id == "filesystem" })
        let installed = try filesystem.install(
            values: ["directories": ["/Users/me/Projects", " ", "~/Notes"]], existingIDs: [], home: "/Users/me"
        )
        XCTAssertEqual(installed.config.args, filesystem.template.args + ["/Users/me/Projects", "/Users/me/Notes"])
        XCTAssertEqual(installed.config.origin, "catalog")
        XCTAssertTrue(filesystem.matches(installed.config))
        XCTAssertThrowsError(try filesystem.install(values: [:], existingIDs: [], home: "/")) {
            XCTAssertEqual($0 as? MCPCatalogEntry.InstallError, .missing("允许访问的文件夹"))
        }

        let git = try XCTUnwrap(MCPCatalog.entries.first { $0.id == "git" })
        XCTAssertEqual(try git.install(values: [:], existingIDs: [], home: "/").config.args, git.template.args,
                       "an optional answer left blank adds nothing")
        XCTAssertEqual(try git.install(values: ["repository": ["/r"]], existingIDs: ["git", "git-2"], home: "/").config,
                       {
                           var expected = git.template
                           expected.id = "git-3"
                           expected.args += ["--repository", "/r"]
                           return expected
                       }(), "the flag is added and a taken id gets a suffix")

        let memory = try XCTUnwrap(MCPCatalog.entries.first { $0.id == "memory" })
        let memoryConfig = try memory.install(values: ["folder": ["/Users/me/Memory"]], existingIDs: [], home: "/Users/me").config
        XCTAssertEqual(memoryConfig.env["MEMORY_FILE_PATH"], "/Users/me/Memory/memory.jsonl")
    }

    func testSecretAnswersGoToTheVaultNotTheConfig() throws {
        let entry = MCPCatalogEntry(
            id: "search", name: "Search", summary: "搜索",
            template: MCPServerConfig(id: "search", name: "Search", command: "npx", args: ["-y", "search@1.0.0"]),
            runtime: .node,
            inputs: [
                .init(id: "key", label: "API Key", help: "", kind: .secret, target: .environment("API_KEY"), required: true),
                .init(id: "region", label: "区域", help: "", kind: .text, target: .environment("REGION"), required: false),
            ],
            homepage: "https://example.com", license: "MIT"
        )
        let installed = try entry.install(values: ["key": ["sk-123"], "region": ["eu"]], existingIDs: [], home: "/")
        XCTAssertEqual(installed.secrets, ["API_KEY": "sk-123"])
        XCTAssertEqual(installed.config.env, ["API_KEY": "", "REGION": "eu"], "the secret's name is kept, its value is not")
        let encoded = String(decoding: try JSONEncoder().encode(installed.config), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sk-123"), "the secret never reaches workspace.json")
    }
}
