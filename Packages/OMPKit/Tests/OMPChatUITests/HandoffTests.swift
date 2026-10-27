import XCTest
import OMPCore
@testable import OMPChatUI

/// Handoff both directions against real repositories: changes move, nothing
/// is lost on a conflict, and the rollback leaves both sides as they were.
@MainActor
final class HandoffTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: helpers

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitBinary.resolve()!)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")): \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func write(_ text: String, _ path: String, in directory: URL) throws {
        let target = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
    }

    private func makeSource() throws -> URL {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"], in: repo)
        try run(["config", "user.email", "t@t"], in: repo)
        try run(["config", "user.name", "t"], in: repo)
        try run(["config", "commit.gpgsign", "false"], in: repo)
        try write("let a = 1\n", "a.swift", in: repo)
        try run(["add", "-A"], in: repo)
        try run(["commit", "-qm", "init"], in: repo)
        return repo
    }

    /// Model + chat bound to a real managed worktree (detached, as Codex
    /// creates them), registered like WorktreeMode's creation does.
    private func worktreeFixture() async throws -> (model: ChatAppModel, id: UUID, source: URL, worktree: URL, recordID: UUID) {
        let source = try makeSource()
        let worktree = root.appendingPathComponent("wt", isDirectory: true)
        try run(["worktree", "add", "--detach", worktree.path, "HEAD"], in: source)
        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: root.appendingPathComponent("m")),
            transport: CannedOKTransport()
        )
        await model.bootstrap()
        let conversation = model.newConversation()
        model.updateWorkingDirectory(conversation.id, worktree.path)
        let record = ManagedWorktree(
            path: worktree.path,
            sourceRoot: source.path,
            baseCommit: try run(["rev-parse", "HEAD"], in: source).trimmingCharacters(in: .whitespacesAndNewlines),
            conversationIDs: [conversation.id]
        )
        model.updateManagedWorktree(record)
        return (model, conversation.id, source, worktree, record.id)
    }

    // MARK: Worktree → Local

    func testHandoffWorktreeToLocalMovesUncommittedWork() async throws {
        let f = try await worktreeFixture()
        try write("let a = 2\n", "a.swift", in: f.worktree)
        try write("fresh\n", "n.txt", in: f.worktree)

        let failure = await f.model.handoff(f.id, to: .local)
        XCTAssertNil(failure, failure ?? "")
        XCTAssertEqual(try read("a.swift", in: f.source), "let a = 2\n", "改动到本地")
        XCTAssertEqual(try read("n.txt", in: f.source), "fresh\n", "未跟踪文件到本地")
        let status = try run(["status", "--porcelain"], in: f.worktree)
        XCTAssertTrue(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "worktree 交出后干净：\(status)")
        XCTAssertEqual(f.model.conversations.first { $0.id == f.id }?.workingDirectory, f.source.path, "对话重绑本地")
        // Registry link kept: handing back returns to the same worktree.
        XCTAssertEqual(f.model.managedWorktree(for: f.id)?.path, f.worktree.path)
        XCTAssertTrue(f.model.handoffProgress[f.id] == nil, "结束后清掉进度")
    }

    func testHandoffRefusesWhenLocalConflicts() async throws {
        let f = try await worktreeFixture()
        try write("let a = worktree-side\n", "a.swift", in: f.worktree)
        try write("let a = local-side\n", "a.swift", in: f.source)

        let failure = await f.model.handoff(f.id, to: .local)
        XCTAssertEqual(failure, "先把本地的这些改动暂存或提交：a.swift", "报出冲突文件")
        XCTAssertEqual(try read("a.swift", in: f.source), "let a = local-side\n", "本地未被改动")
        XCTAssertEqual(try read("a.swift", in: f.worktree), "let a = worktree-side\n", "worktree 未被动过")
        XCTAssertEqual(f.model.conversations.first { $0.id == f.id }?.workingDirectory, f.worktree.path, "绑定不变")
    }

    func testHandoffCommitsRideAlong() async throws {
        let f = try await worktreeFixture()
        try write("let a = 2\n", "a.swift", in: f.worktree)
        try run(["commit", "-aqm", "on detached head"], in: f.worktree)
        let failure = await f.model.handoff(f.id, to: .local)
        XCTAssertNil(failure, failure ?? "")
        XCTAssertEqual(try read("a.swift", in: f.source), "let a = 2\n", "worktree 提交的内容以未提交形式到本地")
        let status = try run(["status", "--porcelain"], in: f.source)
        XCTAssertTrue(status.contains("a.swift"))
    }

    // MARK: Local → Worktree

    func testHandoffLocalToWorktreeMovesAndCleansLocal() async throws {
        let f = try await worktreeFixture()
        // The chat works in Local now (simulating an earlier 交接到本地).
        f.model.updateWorkingDirectory(f.id, f.source.path)
        try write("let a = 3\n", "a.swift", in: f.source)
        try write("local-only\n", "l.txt", in: f.source)

        let failure = await f.model.handoff(f.id, to: .worktree)
        XCTAssertNil(failure, failure ?? "")
        // The registry row's path is where the changes must land; the
        // worktreeFixture's record keeps the real checkout directory.
        let recordPath = f.model.managedWorktree(for: f.id)?.path ?? f.worktree.path
        XCTAssertEqual(try read("a.swift", in: URL(fileURLWithPath: recordPath)), "let a = 3\n", "本地改动搬进 worktree")
        XCTAssertEqual(try read("l.txt", in: URL(fileURLWithPath: recordPath)), "local-only\n")
        let status = try run(["status", "--porcelain"], in: f.source)
        XCTAssertTrue(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "本地恢复干净：\(status)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("l.txt").path), "带走的未跟踪文件从本地删除")
        XCTAssertEqual(f.model.conversations.first { $0.id == f.id }?.workingDirectory, recordPath, "重绑 worktree")
    }

    func testHandoffToWorktreeRollsBackWhenLocalCleanFails() async throws {
        let f = try await worktreeFixture()
        f.model.updateWorkingDirectory(f.id, f.source.path)
        // An ignored file lives at a path the patch carries → the targeted
        // `clean -fq` leaves ignored files alone, so Local cannot be folded
        // back to clean and the move must roll back. (.gitignore itself is
        // force-added: an ignored .gitignore would make the commit fail.)
        try write(".gitignore\nd.txt\n", ".gitignore", in: f.source)
        try run(["add", "-f", ".gitignore"], in: f.source)
        try run(["commit", "-qm", "ignore d.txt", "--", ".gitignore"], in: f.source)
        try write("let a = 4\n", "a.swift", in: f.source)
        try write("ignored\n", "d.txt", in: f.source)

        let failure = await f.model.handoff(f.id, to: .worktree)
        XCTAssertNotNil(failure, "清理失败要报错并回滚")
        XCTAssertEqual(try read("a.swift", in: f.source), "let a = 4\n", "本地原样")
        XCTAssertEqual(try read("d.txt", in: f.source), "ignored\n")
        let status = try run(["status", "--porcelain"], in: f.worktree)
        XCTAssertFalse(status.contains("a.swift"), "worktree 已还原：\(status)")
        XCTAssertEqual(f.model.conversations.first { $0.id == f.id }?.workingDirectory, f.source.path, "绑定不变")
    }

    func testHandoffToLocalWithoutWorktreeIsRefused() async throws {
        let f = try await worktreeFixture()
        f.model.updateWorkingDirectory(f.id, f.source.path)
        let failure = await f.model.handoff(f.id, to: .local)
        XCTAssertEqual(failure, "这个对话不在它的 Worktree 里")
    }

    func testHandoffToWorktreeWithoutLocalRepoIsRefused() async throws {
        let f = try await worktreeFixture()
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        f.model.updateWorkingDirectory(f.id, plain.path)
        let failure = await f.model.handoff(f.id, to: .worktree)
        XCTAssertEqual(failure, "当前目录不在 git 仓库里")
    }

    func testHandoffCarriesSubdirectoryBinding() async throws {
        let f = try await worktreeFixture()
        try FileManager.default.createDirectory(at: f.worktree.appendingPathComponent("packages/app"), withIntermediateDirectories: true)
        f.model.updateWorkingDirectory(f.id, f.worktree.appendingPathComponent("packages/app").path)
        let failure = await f.model.handoff(f.id, to: .local)
        XCTAssertNil(failure, failure ?? "")
        // A chat inside packages/app of the worktree lands on the same
        // sub-path of Local when it exists, else on the repo root.
        let bound = f.model.conversations.first { $0.id == f.id }?.workingDirectory
        XCTAssertEqual(bound, f.source.path, "本地没有同子路径时落仓库根")
    }
}
