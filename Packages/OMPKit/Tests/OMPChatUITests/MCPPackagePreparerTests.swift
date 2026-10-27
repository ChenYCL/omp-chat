#if os(macOS)
import XCTest
import OMPCore
@testable import OMPChatUI

/// The preparer is what makes a freshly downloaded `npx` / `uvx` server start
/// inside the sandbox: it installs once and returns an interpreter launch.
/// Nothing here touches the network; a fake runner plays npm and uvx.
final class MCPPackagePreparerTests: XCTestCase {
    private var temp: URL!
    private var bin: URL!
    private var root: URL!

    /// Records every command the preparer runs and answers with `reply`.
    private final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var delay: Duration = .zero
        var reply: @Sendable ([String]) -> MCPPackagePreparer.Outcome = { _ in .init(exitCode: 0, output: "") }

        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }

        var runner: MCPPackagePreparer.Runner {
            { [self] argv, _ in
                lock.withLock { recorded.append(argv) }
                if delay > .zero { try? await Task.sleep(for: delay) }
                return reply(argv)
            }
        }
    }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-prep-\(UUID().uuidString)")
        bin = temp.appendingPathComponent("bin")
        root = temp.appendingPathComponent("packages")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["node", "npm", "uvx"] { try makeExecutable(bin.appendingPathComponent(name)) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func makeExecutable(_ url: URL) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func preparer(_ runner: Runner) -> MCPPackagePreparer {
        MCPPackagePreparer(root: root, run: runner.runner)
    }

    /// What `npm install --prefix <dir> <spec>` leaves behind.
    private func fakeNpmInstall(name: String, version: String, bin binField: String = #""bin":{"cli":"dist/cli.js"}"#,
                                script: String = "#!/usr/bin/env node\nconsole.log(1)\n", scriptPath: String = "dist/cli.js") -> @Sendable ([String]) -> MCPPackagePreparer.Outcome {
        { argv in
            guard let prefix = argv.firstIndex(of: "--prefix").map({ argv[$0 + 1] }) else { return .init(exitCode: 2, output: "no prefix") }
            let package = URL(fileURLWithPath: prefix).appendingPathComponent("node_modules/\(name)")
            let file = package.appendingPathComponent(scriptPath)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(script.utf8).write(to: file)
            try? Data(#"{"name":"\#(name)","version":"\#(version)",\#(binField)}"#.utf8).write(to: package.appendingPathComponent("package.json"))
            return .init(exitCode: 0, output: "added 1 package")
        }
    }

    private func npmPlan(_ spec: String, rest: [String] = []) throws -> MCPPackageLaunch.Plan {
        .npm(try XCTUnwrap(MCPPackageLaunch.NpmSpec(spec)), arguments: rest)
    }

    private func installedScript(_ name: String) -> String {
        root.appendingPathComponent("npm-\(name.replacingOccurrences(of: "/", with: "__"))@1.2.3/node_modules/\(name)/dist/cli.js").standardizedFileURL.path
    }

    // MARK: npm

    func testFirstStartInstallsThenRunsTheScriptThroughNode() async throws {
        let runner = Runner()
        runner.reply = fakeNpmInstall(name: "@acme/tool", version: "1.2.3")
        let prepared = await preparer(runner).prepare(try npmPlan("@acme/tool@1.2.3", rest: ["--flag"]), path: bin.path, home: temp.path)

        XCTAssertEqual(prepared, .launch(executable: bin.appendingPathComponent("node").path,
                                         arguments: [installedScript("@acme/tool"), "--flag"]),
                       "不是 npx，也不是 .bin 里的垫片：node 加包里的脚本，参数照传")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(call.first, bin.appendingPathComponent("npm").path)
        XCTAssertEqual(Array(call.dropFirst().prefix(1)), ["install"])
        XCTAssertEqual(call.last, "@acme/tool@1.2.3", "装的是配置里固定的版本")
        XCTAssertTrue(call.contains("--prefix") && call.contains("--no-audit"))
    }

    func testAnExactVersionAlreadyInstalledIsNotInstalledAgain() async throws {
        let runner = Runner()
        runner.reply = fakeNpmInstall(name: "@acme/tool", version: "1.2.3")
        let sut = preparer(runner)
        _ = await sut.prepare(try npmPlan("@acme/tool@1.2.3"), path: bin.path, home: temp.path)
        let second = await sut.prepare(try npmPlan("@acme/tool@1.2.3", rest: ["x"]), path: bin.path, home: temp.path)
        XCTAssertEqual(runner.calls.count, 1, "第二次启动直接用装好的包")
        if case .launch(_, let arguments) = second { XCTAssertEqual(arguments.last, "x") } else { XCTFail("\(second)") }
    }

    func testAFolderWithAnotherVersionIsInstalledOver() async throws {
        let runner = Runner()
        // The folder is named for 1.2.3 but holds 1.0.0, e.g. an interrupted upgrade.
        runner.reply = fakeNpmInstall(name: "@acme/tool", version: "1.0.0")
        let sut = preparer(runner)
        _ = await sut.prepare(try npmPlan("@acme/tool@1.2.3"), path: bin.path, home: temp.path)
        runner.reply = fakeNpmInstall(name: "@acme/tool", version: "1.2.3")
        _ = await sut.prepare(try npmPlan("@acme/tool@1.2.3"), path: bin.path, home: temp.path)
        XCTAssertEqual(runner.calls.count, 2, "清单里的版本和要求的不同，要重装")
    }

    func testATagIsInstalledOnceAndKept() async throws {
        let runner = Runner()
        runner.reply = fakeNpmInstall(name: "tool", version: "9.9.9")
        let sut = preparer(runner)
        _ = await sut.prepare(try npmPlan("tool@latest"), path: bin.path, home: temp.path)
        _ = await sut.prepare(try npmPlan("tool@latest"), path: bin.path, home: temp.path)
        XCTAssertEqual(runner.calls.count, 1, "latest 解析出来的版本无从对比，装过就不再动")
    }

    func testAFailedInstallSaysWhatHappened() async throws {
        let runner = Runner()
        runner.reply = { _ in .init(exitCode: 1, output: "npm error code E404\nnpm error 404 Not Found - GET https://registry/none\n") }
        let prepared = await preparer(runner).prepare(try npmPlan("none@1.0.0"), path: bin.path, home: temp.path)
        guard case .failure(let reason, let log) = prepared else { return XCTFail("\(prepared)") }
        XCTAssertTrue(reason.contains("none@1.0.0") && reason.contains("1"), reason)
        XCTAssertEqual(log.last, "npm error 404 Not Found - GET https://registry/none", "npm 自己的报错要带出来")
    }

    func testAPackageWithoutAUsableBinFailsClearly() async throws {
        let runner = Runner()
        runner.reply = fakeNpmInstall(name: "lib", version: "1.0.0", bin: #""main":"index.js""#)
        let prepared = await preparer(runner).prepare(try npmPlan("lib@1.0.0"), path: bin.path, home: temp.path)
        guard case .failure(let reason, _) = prepared else { return XCTFail("\(prepared)") }
        XCTAssertTrue(reason.contains("lib"), reason)
    }

    func testABinThatEscapesThePackageIsNeverRun() async throws {
        let runner = Runner()
        runner.reply = fakeNpmInstall(name: "evil", version: "1.0.0", bin: #""bin":"../../../outside.js""#)
        let prepared = await preparer(runner).prepare(try npmPlan("evil@1.0.0"), path: bin.path, home: temp.path)
        guard case .failure = prepared else { return XCTFail("\(prepared)") }
    }

    func testANativeBinIsLeftAsConfigured() async throws {
        let runner = Runner()
        runner.reply = fakeNpmInstall(name: "native", version: "1.0.0", bin: #""bin":"bin/tool""#,
                                      script: "\u{CF}\u{FA}\u{ED}\u{FE}binary", scriptPath: "bin/tool")
        let prepared = await preparer(runner).prepare(try npmPlan("native@1.0.0"), path: bin.path, home: temp.path)
        XCTAssertEqual(prepared, .unchanged, "node 跑不了二进制：不改写，由原命令去试")
    }

    func testSimultaneousStartsOfOnePackageInstallItOnce() async throws {
        let runner = Runner()
        runner.delay = .milliseconds(150)
        runner.reply = fakeNpmInstall(name: "@acme/tool", version: "1.2.3")
        let sut = preparer(runner)
        let plan = try npmPlan("@acme/tool@1.2.3")
        async let one = sut.prepare(plan, path: bin.path, home: temp.path)
        async let two = sut.prepare(plan, path: bin.path, home: temp.path)
        let (first, second) = await (one, two)
        XCTAssertEqual(runner.calls.count, 1, "两个服务器用同一个包，同时启动时只装一次")
        XCTAssertEqual(first, second)
    }

    func testMissingRuntimesAreReportedAsRuntimes() async throws {
        let empty = temp.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let runner = Runner()
        let sut = preparer(runner)
        let npm = await sut.prepare(try npmPlan("p@1.0.0"), path: empty.path, home: temp.path)
        XCTAssertEqual(npm, .needsRuntime(.node))
        let uv = await sut.prepare(.uv(try XCTUnwrap(MCPPackageLaunch.UVSpec("p==1")), arguments: []), path: empty.path, home: temp.path)
        XCTAssertEqual(uv, .needsRuntime(.uv))
        XCTAssertTrue(runner.calls.isEmpty, "没有运行时就什么都不跑")
    }

    func testDirectPlansRunNothing() async {
        let runner = Runner()
        let prepared = await preparer(runner).prepare(.direct, path: bin.path, home: temp.path)
        XCTAssertEqual(prepared, .unchanged)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: uv

    private func uvPlan(_ spec: String, rest: [String] = []) throws -> MCPPackageLaunch.Plan {
        .uv(try XCTUnwrap(MCPPackageLaunch.UVSpec(spec)), arguments: rest)
    }

    func testUvServersRunTheirEntryPointThroughPython() async throws {
        let runner = Runner()
        runner.reply = { _ in .init(exitCode: 0, output: "Installed 46 packages\nOMPENTRY mcp_server_fetch:main\n") }
        let prepared = await preparer(runner).prepare(try uvPlan("mcp-server-fetch==2026.10.24", rest: ["--ignore-robots-txt"]),
                                                      path: bin.path, home: temp.path)
        let uvx = bin.appendingPathComponent("uvx").path
        guard case .launch(let executable, let arguments) = prepared else { return XCTFail("\(prepared)") }
        XCTAssertEqual(executable, uvx)
        XCTAssertEqual(Array(arguments.prefix(4)), ["--from", "mcp-server-fetch==2026.10.24", "python", "-c"])
        XCTAssertTrue(arguments[4].contains("importlib.import_module('mcp_server_fetch')"), "入口来自包自己的元数据")
        XCTAssertEqual(arguments.last, "--ignore-robots-txt")
        let probe = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(Array(probe.prefix(5)), [uvx, "--from", "mcp-server-fetch==2026.10.24", "python", "-c"])
    }

    func testAPinnedUvEntryIsReadOnce() async throws {
        let runner = Runner()
        runner.reply = { _ in .init(exitCode: 0, output: "OMPENTRY mod:main") }
        let sut = preparer(runner)
        _ = await sut.prepare(try uvPlan("p==1.0"), path: bin.path, home: temp.path)
        _ = await sut.prepare(try uvPlan("p==1.0"), path: bin.path, home: temp.path)
        XCTAssertEqual(runner.calls.count, 1, "固定版本的入口不会变，不必每次启动都起一遍 uv")

        let other = Runner()
        other.reply = { _ in .init(exitCode: 0, output: "OMPENTRY mod:main") }
        let unpinned = preparer(other)
        _ = await unpinned.prepare(try uvPlan("q"), path: bin.path, home: temp.path)
        _ = await unpinned.prepare(try uvPlan("q"), path: bin.path, home: temp.path)
        XCTAssertEqual(other.calls.count, 2, "没固定版本时每次重新读")
    }

    func testUvFailuresExplainThemselves() async throws {
        let failing = Runner()
        failing.reply = { _ in .init(exitCode: 1, output: "error: No solution found\n") }
        let installFailed = await preparer(failing).prepare(try uvPlan("nope==1"), path: bin.path, home: temp.path)
        guard case .failure(let reason, let log) = installFailed else { return XCTFail("\(installFailed)") }
        XCTAssertTrue(reason.contains("nope==1"), reason)
        XCTAssertEqual(log, ["error: No solution found"])

        let silent = Runner()
        silent.reply = { _ in .init(exitCode: 0, output: "nothing printed\n") }
        let noEntry = await preparer(silent).prepare(try uvPlan("lib==1"), path: bin.path, home: temp.path)
        guard case .failure(let message, _) = noEntry else { return XCTFail("\(noEntry)") }
        XCTAssertTrue(message.contains("lib"), message)
    }
}
#endif
