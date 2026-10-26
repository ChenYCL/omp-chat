#if os(macOS)
import XCTest
import OMPCore
@testable import OMPChatUI

/// The built-in tools against real temporary files and a real zsh.
final class BuiltinToolTests: XCTestCase {
    private var root: URL!
    private var project: String!
    private var outside: String!
    private var provider: BuiltinToolProvider!
    private var context: AgentToolContext!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("builtin-tools-\(UUID().uuidString)")
        project = root.appendingPathComponent("proj").path
        outside = root.appendingPathComponent("outside").path
        try FileManager.default.createDirectory(atPath: project + "/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try write("README.md", "# Demo\nline 2\nline 3\n")
        try write("src/main.swift", "print(\"hi\")\n")
        provider = BuiltinToolProvider(home: root.path)
        context = AgentToolContext(conversationID: UUID(), workingDirectory: project)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: project + "/" + relative))
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOfFile: project + "/" + relative, encoding: .utf8)
    }

    private func call(_ name: String, _ arguments: [String: Any], context: AgentToolContext? = nil) async throws -> AgentToolOutput {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return try await provider.call(name, argumentsJSON: String(decoding: data, as: UTF8.self), context: context ?? self.context)
    }

    private func risk(_ name: String, _ arguments: [String: Any], roots: [String] = []) async throws -> ToolRisk {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let context = AgentToolContext(conversationID: UUID(), workingDirectory: project, readableRoots: roots)
        return await provider.risk(forCall: name, argumentsJSON: String(decoding: data, as: UTF8.self), context: context)
    }

    // MARK: Offer and risk

    func testOffersTheFiveToolsWithValidNames() async {
        let names = await provider.tools().map(\.name)
        XCTAssertEqual(Set(names), ["read_file", "list_dir", "write_file", "edit_file", "shell"])
        XCTAssertTrue(names.allSatisfy(AgentToolRegistry.isValidName))
        for spec in await provider.tools() {
            let schema = try? JSONSerialization.jsonObject(with: Data(spec.parametersJSON.utf8)) as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", spec.name)
        }
    }

    func testPerCallRisk() async throws {
        let readInside = try await risk("read_file", ["path": "README.md"])
        let readOutside = try await risk("read_file", ["path": "../outside/x"])
        let readRoot = try await risk("read_file", ["path": outside + "/x"], roots: [outside])
        let listInside = try await risk("list_dir", ["path": "src"])
        let writeInside = try await risk("write_file", ["path": "src/new.swift", "content": ""])
        let writeOutside = try await risk("write_file", ["path": "/etc/hosts", "content": ""])
        let editRoot = try await risk("edit_file", ["path": outside + "/x", "old_string": "a", "new_string": "b"], roots: [outside])
        let shell = try await risk("shell", ["command": "ls"])
        XCTAssertEqual(readInside, .read)
        XCTAssertEqual(readOutside, .execute)
        XCTAssertEqual(readRoot, .read)
        XCTAssertEqual(listInside, .read)
        XCTAssertEqual(writeInside, .write)
        XCTAssertEqual(writeOutside, .execute)
        XCTAssertEqual(editRoot, .execute, "可读根目录不放行写入")
        XCTAssertEqual(shell, .execute)
    }

    func testSymlinkOutOfTheProjectIsJudgedAndWrittenPhysically() async throws {
        let target = outside + "/target.txt"
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: project + "/link.txt", withDestinationPath: target)
        let linkRisk = try await risk("edit_file", ["path": "link.txt", "old_string": "alpha", "new_string": "beta"])
        XCTAssertEqual(linkRisk, .execute)
        let output = try await call("edit_file", ["path": "link.txt", "old_string": "alpha", "new_string": "beta"])
        XCTAssertFalse(output.isError, output.text)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "beta", "写入链接指向的真实文件")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: project + "/link.txt"), target, "链接本身保持不变")
    }

    func testSummariesAreChinese() {
        XCTAssertEqual(provider.summary(forCall: "shell", argumentsJSON: #"{"command":"git status\ngit diff"}"#), "运行命令：git status")
        XCTAssertEqual(provider.summary(forCall: "read_file", argumentsJSON: #"{"path":"README.md"}"#), "读取文件：README.md")
        XCTAssertEqual(provider.summary(forCall: "write_file", argumentsJSON: #"{"path":"a.txt","content":"你好"}"#), "写入文件：a.txt（6 字节）")
        XCTAssertEqual(provider.summary(forCall: "edit_file", argumentsJSON: #"{"path":"a.txt"}"#), "编辑文件：a.txt")
    }

    // MARK: read_file / list_dir

    func testReadFileWholeAndWindowed() async throws {
        let whole = try await call("read_file", ["path": "README.md"])
        XCTAssertEqual(whole.text, "# Demo\nline 2\nline 3")
        XCTAssertFalse(whole.isError)

        let window = try await call("read_file", ["path": project + "/README.md", "offset": 2, "limit": 1])
        XCTAssertTrue(window.text.hasPrefix("line 2\n"), window.text)
        XCTAssertTrue(window.text.contains("第 2–2 行，共 3 行"), window.text)

        let past = try await call("read_file", ["path": "README.md", "offset": 9])
        XCTAssertTrue(past.isError)
    }

    func testReadFileErrors() async throws {
        let missing = try await call("read_file", ["path": "nope.txt"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("不存在"))

        let directory = try await call("read_file", ["path": "src"])
        XCTAssertTrue(directory.isError)

        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: URL(fileURLWithPath: project + "/logo.png"))
        let binary = try await call("read_file", ["path": "logo.png"])
        XCTAssertTrue(binary.isError)
        XCTAssertTrue(binary.text.contains("二进制"))

        let unbound = AgentToolContext(conversationID: UUID(), workingDirectory: nil)
        let relative = try await call("read_file", ["path": "README.md"], context: unbound)
        XCTAssertTrue(relative.isError)
        XCTAssertTrue(relative.text.contains("工作目录"))
        let absolute = try await call("read_file", ["path": project + "/README.md"], context: unbound)
        XCTAssertFalse(absolute.isError)
    }

    func testTildeExpandsToHome() async throws {
        try Data("home note".utf8).write(to: root.appendingPathComponent("note.txt"))
        let output = try await call("read_file", ["path": "~/note.txt"])
        XCTAssertEqual(output.text, "home note")
    }

    func testListDirMarksDirectories() async throws {
        let output = try await call("list_dir", ["path": "."])
        XCTAssertEqual(output.text, "README.md\nsrc/")
        let missing = try await call("list_dir", ["path": "nope"])
        XCTAssertTrue(missing.isError)
    }

    // MARK: write_file / edit_file

    func testWriteFileCreatesParentsAndOverwrites() async throws {
        let created = try await call("write_file", ["path": "docs/deep/guide.md", "content": "新内容"])
        XCTAssertFalse(created.isError, created.text)
        XCTAssertEqual(try read("docs/deep/guide.md"), "新内容")
        let replaced = try await call("write_file", ["path": "README.md", "content": "short"])
        XCTAssertTrue(replaced.text.contains("覆盖"))
        XCTAssertEqual(try read("README.md"), "short")
        let directory = try await call("write_file", ["path": "src", "content": "x"])
        XCTAssertTrue(directory.isError)
    }

    func testEditFileReplacesExactlyOnce() async throws {
        let output = try await call("edit_file", ["path": "README.md", "old_string": "line 2", "new_string": "第二行"])
        XCTAssertFalse(output.isError, output.text)
        XCTAssertEqual(try read("README.md"), "# Demo\n第二行\nline 3\n")
        XCTAssertTrue(output.text.contains("\n-line 2\n+第二行"), output.text)
    }

    func testEditFileNotFoundLeavesFileUntouched() async throws {
        let before = try Data(contentsOf: URL(fileURLWithPath: project + "/README.md"))
        let output = try await call("edit_file", ["path": "README.md", "old_string": "line 9", "new_string": "x"])
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("没有找到"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: project + "/README.md")), before)
    }

    func testEditFileAmbiguousLeavesFileUntouchedUnlessReplaceAll() async throws {
        let before = try read("README.md")
        let ambiguous = try await call("edit_file", ["path": "README.md", "old_string": "line", "new_string": "row"])
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains("2 次"), ambiguous.text)
        XCTAssertEqual(try read("README.md"), before)

        let all = try await call("edit_file", ["path": "README.md", "old_string": "line", "new_string": "row", "replace_all": true])
        XCTAssertFalse(all.isError)
        XCTAssertEqual(try read("README.md"), "# Demo\nrow 2\nrow 3\n")
        XCTAssertTrue(all.text.contains("替换 2 处"))
    }

    func testEditFileMatchesLiterally() async throws {
        // "é" precomposed in the file, decomposed in the request: canonically
        // equal, but not the same text, so nothing is replaced.
        try write("accent.txt", "caf\u{E9}\n")
        let output = try await call("edit_file", ["path": "accent.txt", "old_string": "cafe\u{301}", "new_string": "tea"])
        XCTAssertTrue(output.isError)
        XCTAssertEqual(try read("accent.txt"), "caf\u{E9}\n")
    }

    func testEditFileRefusesEmptyOrUnchangedAndMissingFiles() async throws {
        let empty = try await call("edit_file", ["path": "README.md", "old_string": "", "new_string": "x"])
        XCTAssertTrue(empty.isError)
        let same = try await call("edit_file", ["path": "README.md", "old_string": "line 2", "new_string": "line 2"])
        XCTAssertTrue(same.isError)
        let missing = try await call("edit_file", ["path": "ghost.txt", "old_string": "a", "new_string": "b"])
        XCTAssertTrue(missing.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/ghost.txt"))
    }

    func testEditKeepsExecutableBit() async throws {
        try write("run.sh", "#!/bin/sh\necho old\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project + "/run.sh")
        _ = try await call("edit_file", ["path": "run.sh", "old_string": "old", "new_string": "new"])
        let permissions = try FileManager.default.attributesOfItem(atPath: project + "/run.sh")[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
    }

    // MARK: shell

    func testShellRunsInWorkingDirectoryWithExitCode() async throws {
        let output = try await call("shell", ["command": "pwd -P; echo out; echo err >&2; exit 3"])
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains(AgentPathPolicy.canonical(project)), output.text)
        XCTAssertTrue(output.text.contains("out"))
        XCTAssertTrue(output.text.contains("err"), "stderr 合并进输出")
        XCTAssertTrue(output.text.hasSuffix("退出码：3"), output.text)

        let ok = try await call("shell", ["command": "true"])
        XCTAssertFalse(ok.isError)
        XCTAssertTrue(ok.text.hasSuffix("退出码：0"))
    }

    func testShellSeesUserBinariesOnPath() async throws {
        let output = try await call("shell", ["command": "print -r -- $PATH"])
        XCTAssertTrue(output.text.contains("/opt/homebrew/bin") || output.text.contains("/usr/local/bin"), output.text)
    }

    func testShellTimeoutKillsTheProcessTree() async throws {
        let marker = "37.\(Int.random(in: 100...999))"
        let started = Date()
        let output = try await call("shell", ["command": "sleep \(marker) & sleep \(marker); echo never", "timeout_seconds": 1])
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("超时"), output.text)
        XCTAssertFalse(output.text.contains("never"))
        try await assertNoProcess(matching: "sleep \(marker)")
    }

    func testShellCancellationKillsTheProcessTree() async throws {
        let marker = "41.\(Int.random(in: 100...999))"
        let provider = self.provider!
        let context = self.context!
        let task = Task {
            try await provider.call("shell", argumentsJSON: #"{"command":"sleep \#(marker)"}"#, context: context)
        }
        try await Task.sleep(for: .milliseconds(800))
        let started = Date()
        task.cancel()
        let output = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("停止"), output.text)
        try await assertNoProcess(matching: "sleep \(marker)")
    }

    func testShellOutputKeepsHeadAndTail() async throws {
        let output = try await call("shell", ["command": "seq 1 100000"])
        XCTAssertTrue(output.text.hasPrefix("1\n2\n3\n"), String(output.text.prefix(40)))
        XCTAssertTrue(output.text.contains("100000\n退出码：0"), String(output.text.suffix(60)))
        XCTAssertTrue(output.text.contains("省略中间"))
        XCTAssertLessThan(output.text.utf8.count, BuiltinToolProvider.shellOutputCap + 512)
        XCTAssertFalse(output.isError)
    }

    func testShellDoesNotWaitForAnOrphanHoldingTheOutput() async throws {
        let marker = "43.\(Int.random(in: 100...999))"
        defer { _ = try? Self.run("/usr/bin/pkill", ["-f", "sleep \(marker)"]) }
        let started = Date()
        let output = try await call("shell", ["command": "sleep \(marker) & echo started"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertTrue(output.text.contains("started"))
    }

    func testCommandRunnerFeedsStdinAndKeepsStreamsApart() async throws {
        let run = await HostExecutor.runCommand(
            "read line; echo \"got:$line\"; echo \"dir:$(pwd -P)\"; echo \"var:$HOOK_VAR\"; echo oops >&2; exit 2",
            cwd: project, stdin: Data("{\"event\":\"PreToolUse\"}\n".utf8), timeout: 10,
            extraEnvironment: ["HOOK_VAR": "plugin"]
        )
        XCTAssertEqual(run.exitCode, 2)
        XCTAssertFalse(run.timedOut)
        XCTAssertFalse(run.cancelled)
        XCTAssertTrue(run.stdout.contains(#"got:{"event":"PreToolUse"}"#), run.stdout)
        XCTAssertTrue(run.stdout.contains("dir:" + AgentPathPolicy.canonical(project)), run.stdout)
        XCTAssertTrue(run.stdout.contains("var:plugin"))
        XCTAssertFalse(run.stdout.contains("oops"))
        XCTAssertEqual(run.stderr, "oops\n")

        // A child that never reads a large stdin must neither hang nor kill the app.
        let ignored = await HostExecutor.runCommand("exit 0", cwd: project, stdin: Data(count: 1 << 20), timeout: 10)
        XCTAssertEqual(ignored.exitCode, 0)
    }

    private func assertNoProcess(matching pattern: String) async throws {
        for _ in 0..<50 {
            if try Self.run("/usr/bin/pgrep", ["-f", pattern]) != 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("进程仍在运行：\(pattern)")
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
#endif
