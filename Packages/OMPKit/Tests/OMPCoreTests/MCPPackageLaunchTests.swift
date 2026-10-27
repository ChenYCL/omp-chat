import XCTest
@testable import OMPCore

/// `npx` / `uvx` servers are rewritten because their scripts cannot be exec'd
/// from the sandboxed app. A wrong reading here means a server runs the wrong
/// package, the wrong file, or is rewritten when it should have been left alone.
final class MCPPackageLaunchTests: XCTestCase {
    private typealias Launch = MCPPackageLaunch

    // MARK: plan

    func testTheCatalogShapesBecomeNpmPlans() throws {
        let plan = Launch.plan(command: "npx", arguments: ["-y", "chrome-devtools-mcp@1.12.0", "--no-usage-statistics"])
        guard case .npm(let spec, let rest) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(spec.name, "chrome-devtools-mcp")
        XCTAssertEqual(spec.version, "1.12.0")
        XCTAssertEqual(rest, ["--no-usage-statistics"], "包名后面的参数原样交给服务器")

        guard case .npm(let scoped, _) = Launch.plan(command: "/opt/homebrew/bin/npx", arguments: ["--yes", "-y", "@playwright/mcp@0.0.83"])
        else { return XCTFail("绝对路径的 npx、重复的 -y 也算") }
        XCTAssertEqual(scoped.name, "@playwright/mcp")
        XCTAssertEqual(scoped.version, "0.0.83")
    }

    func testUvxPlansKeepTheirArguments() {
        guard case .uv(let spec, let rest) = Launch.plan(command: "uvx", arguments: ["mcp-server-git==2026.10.19", "--repository", "/tmp/r"])
        else { return XCTFail() }
        XCTAssertEqual(spec.name, "mcp-server-git")
        XCTAssertEqual(spec.spec, "mcp-server-git==2026.10.19")
        XCTAssertEqual(rest, ["--repository", "/tmp/r"])
    }

    func testAnythingElseIsLeftAsConfigured() {
        let direct = Launch.Plan.direct
        XCTAssertEqual(Launch.plan(command: "node", arguments: ["server.js"]), direct)
        XCTAssertEqual(Launch.plan(command: "npx", arguments: []), direct, "没有包名")
        XCTAssertEqual(Launch.plan(command: "npx", arguments: ["-y"]), direct)
        XCTAssertEqual(Launch.plan(command: "npx", arguments: ["-p", "typescript", "tsc"]), direct, "-p 改变了 npx 的含义")
        XCTAssertEqual(Launch.plan(command: "npx", arguments: ["--package=x", "y"]), direct)
        XCTAssertEqual(Launch.plan(command: "npx", arguments: ["-y", "github:owner/repo"]), direct, "不是注册表里的包")
        XCTAssertEqual(Launch.plan(command: "npx", arguments: ["-y", "./local-pkg"]), direct)
        XCTAssertEqual(Launch.plan(command: "npx", arguments: ["-y", "https://x.test/a.tgz"]), direct)
        XCTAssertEqual(Launch.plan(command: "uvx", arguments: ["--from", "pkg", "cmd"]), direct)
        XCTAssertEqual(Launch.plan(command: "uvx", arguments: ["pkg[extra]==1"]), direct, "带 extras 的写法不改")
        XCTAssertEqual(Launch.plan(command: "uvx", arguments: ["git+https://x.test/r"]), direct)
    }

    // MARK: npm spec

    func testNpmSpecSplitsTheVersionAtTheLastAtSign() throws {
        let plain = try XCTUnwrap(Launch.NpmSpec("pkg"))
        XCTAssertEqual(plain.name, "pkg")
        XCTAssertNil(plain.version)
        let scopedBare = try XCTUnwrap(Launch.NpmSpec("@scope/pkg"))
        XCTAssertEqual(scopedBare.name, "@scope/pkg", "作用域前面的 @ 不是版本分隔符")
        XCTAssertNil(scopedBare.version)
        let scoped = try XCTUnwrap(Launch.NpmSpec("@scope/pkg@^1.2.0"))
        XCTAssertEqual(scoped.name, "@scope/pkg")
        XCTAssertEqual(scoped.version, "^1.2.0")
        XCTAssertNil(Launch.NpmSpec("pkg@"))
        XCTAssertNil(Launch.NpmSpec("@scope"), "只有作用域不是包名")
        XCTAssertNil(Launch.NpmSpec("a b"))
        XCTAssertNil(Launch.NpmSpec("../x"))
    }

    func testOnlyAnExactReleaseCountsAsPinned() throws {
        XCTAssertEqual(try XCTUnwrap(Launch.NpmSpec("p@1.2.3")).exactVersion, "1.2.3")
        XCTAssertEqual(try XCTUnwrap(Launch.NpmSpec("p@1.2.3-beta.1")).exactVersion, "1.2.3-beta.1")
        XCTAssertNil(try XCTUnwrap(Launch.NpmSpec("p@^1.2.3")).exactVersion)
        XCTAssertNil(try XCTUnwrap(Launch.NpmSpec("p@latest")).exactVersion, "标签会变，不能当成已装好")
        XCTAssertNil(try XCTUnwrap(Launch.NpmSpec("p")).exactVersion)
    }

    func testInstallFolderNamesAreFlatAndPerVersion() throws {
        let scoped = try XCTUnwrap(Launch.NpmSpec("@modelcontextprotocol/server-filesystem@2.0.1")).directoryName
        XCTAssertEqual(scoped, "npm-@modelcontextprotocol__server-filesystem@2.0.1")
        XCTAssertFalse(scoped.contains("/"))
        XCTAssertNotEqual(scoped, try XCTUnwrap(Launch.NpmSpec("@modelcontextprotocol/server-filesystem@2.0.2")).directoryName)
        let range = try XCTUnwrap(Launch.NpmSpec("p@>=1.0.0|<2")).directoryName
        XCTAssertFalse(range.contains(">") || range.contains("|") || range.contains("<"), "范围里的符号不能进文件名：\(range)")
    }

    // MARK: bin

    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testBinStringAndNamedTable() {
        XCTAssertEqual(Launch.binScript(packageJSON: json(#"{"bin":"cli.js"}"#), packageName: "p"), "cli.js")
        XCTAssertEqual(Launch.binScript(packageJSON: json(#"{"bin":"./dist/./cli.js"}"#), packageName: "p"), "dist/cli.js", "规整成相对路径")
        // Two commands: the one named like the package, as npm does it.
        let two = json(#"{"bin":{"ocu":"bin/ocu","open-computer-use":"bin/open-computer-use"}}"#)
        XCTAssertEqual(Launch.binScript(packageJSON: two, packageName: "@opensymph/open-computer-use"), "bin/open-computer-use")
    }

    func testASingleEntryNeedsNoNameMatch() {
        // @modelcontextprotocol/server-filesystem exposes mcp-server-filesystem.
        let single = json(#"{"bin":{"mcp-server-filesystem":"dist/index.js"}}"#)
        XCTAssertEqual(Launch.binScript(packageJSON: single, packageName: "@modelcontextprotocol/server-filesystem"), "dist/index.js")
    }

    func testAmbiguousOrUnsafeBinsAreRefused() {
        let ambiguous = json(#"{"bin":{"a":"a.js","b":"b.js"}}"#)
        XCTAssertNil(Launch.binScript(packageJSON: ambiguous, packageName: "p"), "两个命令又没有一个叫包名：不猜")
        XCTAssertNil(Launch.binScript(packageJSON: json(#"{"bin":"/usr/bin/evil"}"#), packageName: "p"))
        XCTAssertNil(Launch.binScript(packageJSON: json(#"{"bin":"../../outside.js"}"#), packageName: "p"), "不能走出包目录")
        XCTAssertNil(Launch.binScript(packageJSON: json(#"{"bin":{"p":"dist/../../x.js"}}"#), packageName: "p"))
        XCTAssertNil(Launch.binScript(packageJSON: json(#"{"name":"p"}"#), packageName: "p"))
        XCTAssertNil(Launch.binScript(packageJSON: json("not json"), packageName: "p"))
        XCTAssertNil(Launch.binScript(packageJSON: json(#"{"bin":""}"#), packageName: "p"))
    }

    func testOnlyNodeScriptsAreRunThroughNode() {
        XCTAssertTrue(Launch.isNodeScript(head: Data("#!/usr/bin/env node\nx".utf8), fileName: "cli"))
        XCTAssertTrue(Launch.isNodeScript(head: Data("#!/usr/bin/env -S node --no-warnings\n".utf8), fileName: "cli"))
        XCTAssertTrue(Launch.isNodeScript(head: Data("export {}".utf8), fileName: "index.mjs"), "没有 shebang 的 .mjs")
        XCTAssertFalse(Launch.isNodeScript(head: Data("#!/bin/sh\nexec x".utf8), fileName: "run"), "shell 脚本不是 node 能跑的")
        XCTAssertFalse(Launch.isNodeScript(head: Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0]), fileName: "bin"), "Mach-O")
        XCTAssertFalse(Launch.isNodeScript(head: Data("#!/usr/bin/env python3\n".utf8), fileName: "tool"))
    }

    // MARK: uv

    func testUvSpecNeedsAPlainRequirement() throws {
        XCTAssertEqual(try XCTUnwrap(Launch.UVSpec("mcp-server-fetch==2026.10.24")).name, "mcp-server-fetch")
        XCTAssertEqual(try XCTUnwrap(Launch.UVSpec("pkg>=1.0")).name, "pkg")
        XCTAssertEqual(try XCTUnwrap(Launch.UVSpec("pkg")).spec, "pkg")
        XCTAssertNil(Launch.UVSpec("pkg==1.0; python_version>'3'"))
        XCTAssertNil(Launch.UVSpec("pkg==")); XCTAssertNil(Launch.UVSpec("==1")); XCTAssertNil(Launch.UVSpec("a b"))
    }

    func testEntryPointIsReadFromTheProbeOutputOnly() {
        let noisy = "Installed 46 packages\nOMPENTRY mcp_server_fetch:main\n"
        let entry = Launch.uvEntry(fromProbeOutput: noisy)
        XCTAssertEqual(entry?.module, "mcp_server_fetch")
        XCTAssertEqual(entry?.attribute, "main")
        XCTAssertEqual(Launch.uvEntry(fromProbeOutput: "OMPENTRY pkg.cli:app.run [extra]")?.attribute, "app.run", "extras 之后的内容丢掉")
        XCTAssertNil(Launch.uvEntry(fromProbeOutput: "mcp_server_fetch:main"), "没有前缀的行不是探针输出")
        XCTAssertNil(Launch.uvEntry(fromProbeOutput: "OMPENTRY a;import os:main"), "分号会让生成的代码多出一句")
        XCTAssertNil(Launch.uvEntry(fromProbeOutput: "OMPENTRY a':main"))
        XCTAssertNil(Launch.uvEntry(fromProbeOutput: "OMPENTRY nocolon"))
        XCTAssertNil(Launch.uvEntry(fromProbeOutput: ""))
    }

    func testGeneratedPythonOnlyEverContainsValidatedNames() throws {
        let code = try XCTUnwrap(Launch.uvRunCode(module: "pkg.cli", attribute: "app.run"))
        XCTAssertTrue(code.contains("importlib.import_module('pkg.cli')"))
        XCTAssertTrue(code.contains("'app.run'.split('.')"))
        XCTAssertNil(Launch.uvRunCode(module: "pkg'); import os; ('", attribute: "main"))
        XCTAssertNil(Launch.uvRunCode(module: "pkg", attribute: "main()"))
        XCTAssertNil(Launch.uvRunCode(module: "", attribute: "main"))

        let probe = try XCTUnwrap(Launch.uvEntryProbe(scriptName: "mcp-server-fetch"))
        XCTAssertTrue(probe.contains("e.name == 'mcp-server-fetch'"))
        XCTAssertNil(Launch.uvEntryProbe(scriptName: "x'); import os; ('"))
        XCTAssertNil(Launch.uvEntryProbe(scriptName: ""))
    }
}
