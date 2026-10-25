import XCTest
import OMPCore
@testable import OMPChatUI

final class HostExecutorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-executor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func executor(allowed: Bool) -> HostExecutor {
        HostExecutor(shellAllowed: allowed, homeDirectory: root.path)
    }

    func testGateOffRejectsShellButAllowsInfo() async {
        let executor = executor(allowed: false)

        let blocked = await executor.handle(HostRPCRequest(id: "1", op: "exec", command: "echo hi"))
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(blocked.error, "shell_disabled")

        let listed = await executor.handle(HostRPCRequest(id: "2", op: "fs.list"))
        XCTAssertEqual(listed.error, "shell_disabled")

        let info = await executor.handle(HostRPCRequest(id: "3", op: "info"))
        XCTAssertTrue(info.ok)
        XCTAssertEqual(info.info?.cwd, root.path)
        XCTAssertEqual(info.info?.home, root.path)
        XCTAssertNil(info.info?.gitBranch)
    }

    func testExecTracksDirectoryChanges() async throws {
        let sub = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let executor = executor(allowed: true)

        let response = await executor.handle(HostRPCRequest(
            id: "cd", op: "exec", command: "cd work && pwd", cwd: root.path, timeout: 10
        ))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.exitCode, 0)
        let expected = sub.resolvingSymlinksInPath().path
        XCTAssertEqual(response.cwd, expected)
        let printed = response.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(
            URL(fileURLWithPath: printed).resolvingSymlinksInPath().path,
            expected
        )

        let back = await executor.handle(HostRPCRequest(
            id: "back", op: "exec", command: "pwd", cwd: response.cwd, timeout: 10
        ))
        XCTAssertEqual(back.cwd, expected)
    }
    func testRealHomeComesFromPasswdNotContainer() async {
        let real = HostExecutor.realHomeDirectory()
        XCTAssertFalse(real.contains("/Library/Containers/"), "home must not be the sandbox container")
        XCTAssertTrue(FileManager.default.fileExists(atPath: real))

        let executor = HostExecutor(shellAllowed: false)
        let info = await executor.handle(HostRPCRequest(id: "home", op: "info"))
        XCTAssertEqual(info.info?.home, real)
        XCTAssertEqual(executor.resolve("~/Documents", base: "/tmp"), real + "/Documents")
    }

    func testExecHomeFollowsTheInjectedHome() async {
        let real = HostExecutor.realHomeDirectory()
        let executor = HostExecutor(shellAllowed: true, homeDirectory: real)
        let response = await executor.handle(HostRPCRequest(
            id: "home", op: "exec", command: "printf %s \"$HOME\"", cwd: root.path, timeout: 10
        ))
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.stdout, real)
        XCTAssertFalse(response.stdout?.contains("/Library/Containers/") ?? true)
    }

    func testExecTimesOut() async {
        let executor = executor(allowed: true)
        let response = await executor.handle(HostRPCRequest(
            id: "slow", op: "exec", command: "sleep 30", cwd: root.path, timeout: 0.4
        ))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "timeout")
    }

    func testExecTruncatesLargeOutput() async {
        let executor = executor(allowed: true)
        let response = await executor.handle(HostRPCRequest(
            id: "big", op: "exec",
            command: "python3 -c 'print(\"x\" * 400000, end=\"\")'",
            cwd: root.path, timeout: 20
        ))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.truncated, true)
        XCTAssertEqual(response.stdout?.count, HostExecutor.outputCap)
    }

    func testReadTruncatesAndKeepsLossyText() async throws {
        let file = root.appendingPathComponent("note.txt")
        var bytes = Data(repeating: 0x61, count: 300)
        bytes.append(0xff)
        try bytes.write(to: file)
        let executor = executor(allowed: true)

        let response = await executor.handle(HostRPCRequest(
            id: "read", op: "fs.read", path: "note.txt", maxBytes: 100
        ))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.truncated, true)
        XCTAssertEqual(response.text?.count, 100)

        let missing = await executor.handle(HostRPCRequest(id: "miss", op: "fs.read", path: "nope.txt"))
        XCTAssertEqual(missing.error, "not_found")
    }

    func testListSortsDirectoriesFirstIncludingHidden() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent(".hidden"))
        try Data("y".utf8).write(to: root.appendingPathComponent("beta.txt"))
        let executor = executor(allowed: true)

        let response = await executor.handle(HostRPCRequest(id: "ls", op: "fs.list", path: root.path))
        let names = try XCTUnwrap(response.entries).map(\.name)
        XCTAssertEqual(names, ["alpha", "zeta", ".hidden", "beta.txt"])
        XCTAssertEqual(response.entries?.first?.isDirectory, true)
        XCTAssertEqual(response.entries?.last?.isDirectory, false)
    }

    func testTildeAndRelativePathsResolve() {
        let executor = executor(allowed: true)
        XCTAssertEqual(executor.resolve("~", base: "/tmp"), root.path)
        XCTAssertEqual(executor.resolve("~/alpha", base: "/tmp"), root.appendingPathComponent("alpha").path)
        XCTAssertEqual(executor.resolve("beta", base: root.path), root.appendingPathComponent("beta").path)
        XCTAssertEqual(executor.resolve("/abs", base: root.path), "/abs")
        XCTAssertEqual(executor.resolve(nil, base: root.path), root.path)
    }

    func testGitStatusReportsBranchAndDirtyCount() async throws {
        try Data("seed".utf8).write(to: root.appendingPathComponent("note.txt"))
        for arguments in [
            ["init", "-q"],
            ["symbolic-ref", "HEAD", "refs/heads/feature"],
            ["add", "note.txt"],
            ["-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-qm", "init"],
        ] {
            let prep = Process()
            prep.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            prep.arguments = arguments
            prep.currentDirectoryURL = root
            try prep.run()
            prep.waitUntilExit()
            XCTAssertEqual(prep.terminationStatus, 0, arguments.joined(separator: " "))
        }
        try Data("changed".utf8).write(to: root.appendingPathComponent("note.txt"))
        try Data("new".utf8).write(to: root.appendingPathComponent("extra.txt"))
        let executor = executor(allowed: false)

        let info = await executor.handle(HostRPCRequest(id: "git", op: "info", cwd: root.path))
        XCTAssertEqual(info.info?.gitBranch, "feature")
        XCTAssertEqual(info.info?.gitDirty, 2)
    }

    func testUnknownOpAndEmptyCommandAreBadRequests() async {
        let executor = executor(allowed: true)
        let unknown = await executor.handle(HostRPCRequest(id: "u", op: "fs.delete"))
        XCTAssertEqual(unknown.error, "bad_request")
        let empty = await executor.handle(HostRPCRequest(id: "e", op: "exec", command: "   "))
        XCTAssertEqual(empty.error, "bad_request")
    }

    func testOperationLogKeepsLastTwenty() async {
        let log = RemoteOperationLog()
        let executor = HostExecutor(shellAllowed: false, homeDirectory: root.path, log: log)
        for index in 0..<25 {
            _ = await executor.handle(HostRPCRequest(id: "\(index)", op: "exec", command: "echo \(index)"))
        }
        let records = log.snapshot()
        XCTAssertEqual(records.count, RemoteOperationLog.capacity)
        XCTAssertTrue(records.first?.summary.contains("5") ?? false)
        XCTAssertTrue(records.last?.summary.contains("24") ?? false)
    }

    func testMarkerStripping() {
        let (text, cwd) = HostExecutor.stripCWDMarker("hello\nOMPHOST_CWD_x/some/dir\n", marker: "OMPHOST_CWD_x")
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(cwd, "/some/dir")
        let (plain, none) = HostExecutor.stripCWDMarker("untouched", marker: "OMPHOST_CWD_x")
        XCTAssertEqual(plain, "untouched")
        XCTAssertNil(none)
    }
    // MARK: - exec.cancel

    func testCancelKillsSleepAndReportsCancelled() async throws {
        let executor = executor(allowed: true)
        let started = Date()
        let pending = Task { await executor.handle(HostRPCRequest(
            id: "cancel-me", op: "exec", command: "echo before && sleep 30", cwd: root.path, timeout: 120
        )) }
        // Give zsh time to spawn so the process tree exists.
        try await Task.sleep(for: .milliseconds(600))

        let ack = await executor.handle(HostRPCRequest(
            id: "c1", op: "exec.cancel", requestID: "cancel-me"
        ))
        XCTAssertTrue(ack.ok, ack.error ?? "")
        let response = await pending.value
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "cancelled")
        XCTAssertEqual(response.exitCode, 130)
        XCTAssertEqual(response.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), "before")
        XCTAssertLessThan(elapsed, 5, "cancel must not wait for the 30s sleep")

        // The wrapper and its sleep child are really gone.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try Self.pgrep("sleep 30"), [])
    }

    func testCancelIsIdempotent() async throws {
        let executor = executor(allowed: true)
        let pending = Task { await executor.handle(HostRPCRequest(
            id: "twice", op: "exec", command: "sleep 30", cwd: root.path, timeout: 120
        )) }
        try await Task.sleep(for: .milliseconds(600))

        let first = await executor.handle(HostRPCRequest(id: "k1", op: "exec.cancel", requestID: "twice"))
        XCTAssertTrue(first.ok)
        // Wait for the exec to unwind, so the retry exercises the
        // already-finished case, not the still-dying one.
        let response = await pending.value
        XCTAssertEqual(response.error, "cancelled")
        XCTAssertEqual(response.exitCode, 130)
        let second = await executor.handle(HostRPCRequest(id: "k2", op: "exec.cancel", requestID: "twice"))
        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.text, "not_running")

        // Unknown ids are not_running too, before and after any exec.
        let ghost = await executor.handle(HostRPCRequest(id: "k3", op: "exec.cancel", requestID: "ghost"))
        XCTAssertTrue(ghost.ok)
        XCTAssertEqual(ghost.text, "not_running")
    }

    func testCancelRequiresShellGate() async {
        let executor = executor(allowed: false)
        let blocked = await executor.handle(HostRPCRequest(id: "g", op: "exec.cancel", requestID: "x"))
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(blocked.error, "shell_disabled")
    }

    func testCancelWithoutRequestIDIsBadRequest() async {
        let executor = executor(allowed: true)
        let response = await executor.handle(HostRPCRequest(id: "b", op: "exec.cancel"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "bad_request")
    }

    /// `pgrep -f` as an array of pids, so tests can prove processes died.
    static func pgrep(_ pattern: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }
}
