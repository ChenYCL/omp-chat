import XCTest
import OMPCore
@testable import OMPChatUI

/// Worktree management end to end against real temporary repositories:
/// policy execution (delete refused for pinned, deletes with snapshot on
/// archive), restore reproducing the working state, and the settings fields
/// decoding from old documents.
@MainActor
final class WorktreeManageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-manage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: helpers

    private func run(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitBinary.resolve()!)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args2(arguments)) failed")
    }

    private func args2(_ arguments: [String]) -> String { arguments.joined(separator: " ") }

    private func write(_ text: String, _ path: String, in directory: URL) throws {
        let target = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
    }

    /// One source repo with one commit.
    private func makeSource(name: String = "repo") throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
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

    /// Model + one conversation bound to the repo, with a registry row for a
    /// real worktree created by git.
    private func fixture(worktreeName: String = "wt") async throws -> (model: ChatAppModel, id: UUID, source: URL, worktree: URL, recordID: UUID) {
        let source = try makeSource()
        let worktree = root.appendingPathComponent(worktreeName, isDirectory: true)
        try run(["worktree", "add", "--detach", worktree.path, "HEAD"], in: source)

        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: root.appendingPathComponent("media")),
            transport: CannedOKTransport()
        )
        await model.bootstrap()
        let conversation = model.newConversation()
        model.updateWorkingDirectory(conversation.id, worktree.path)
        let record = ManagedWorktree(
            path: worktree.path,
            sourceRoot: source.path,
            baseCommit: try gitHead(source),
            conversationIDs: [conversation.id]
        )
        model.updateManagedWorktree(record)
        return (model, conversation.id, source, worktree, record.id)
    }

    private func gitHead(_ repo: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitBinary.resolve()!)
        process.arguments = ["rev-parse", "HEAD"]
        process.currentDirectoryURL = repo
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return String(decoding: (process.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Deletion

    func testDeleteRefusesPinnedChat() async throws {
        let f = try await fixture()
        f.model.togglePin(f.id)
        let refusal = await f.model.deleteManagedWorktree(f.recordID)
        XCTAssertEqual(refusal, "有置顶的对话在使用这个 Worktree。先取消置顶，或手动删除。")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.path), "拒绝时不删目录")
        XCTAssertTrue(f.model.managedWorktrees.first?.deletedAt == nil)
        // And the pane's pre-check reports the same reason.
        XCTAssertEqual(f.model.worktreeDeletionRefusal(for: f.recordID), refusal)
    }

    func testDeleteRefusesStreamingChat() async throws {
        let f = try await fixture()
        // Mark the chat as streaming without a network round trip.
        f.model.markStreamingForTest(f.id)
        let refusal = await f.model.deleteManagedWorktree(f.recordID)
        XCTAssertEqual(refusal, "这个 Worktree 的对话还在运行，等回复结束后再删。")
        f.model.markStreamingForTest(nil)
        let second = await f.model.deleteManagedWorktree(f.recordID)
        XCTAssertNil(second, "停流之后可以删")
    }

    func testDeleteSnapshotsThenRemovesAndMarks() async throws {
        let f = try await fixture()
        try write("let a = 2\n", "a.swift", in: f.worktree)      // uncommitted edit
        try write("new\n", "untracked.txt", in: f.worktree)       // untracked

        let failure = await f.model.deleteManagedWorktree(f.recordID)
        XCTAssertNil(failure, failure ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.path), "worktree 目录删除")
        let record = try XCTUnwrap(f.model.managedWorktrees.first)
        XCTAssertNotNil(record.deletedAt, "registry 标记删除")
        let snapshot = try XCTUnwrap(record.snapshot)
        // The snapshot commit keeps the uncommitted work reachable in the source.
        let show = Process()
        show.executableURL = URL(fileURLWithPath: GitBinary.resolve()!)
        show.arguments = ["show", "--name-only", "--format=", snapshot.commit]
        show.currentDirectoryURL = f.source
        show.standardOutput = Pipe()
        show.standardError = Pipe()
        show.standardInput = FileHandle.nullDevice
        try show.run()
        show.waitUntilExit()
        let names = String(decoding: (show.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(names.contains("untracked.txt"), "快照抓到未跟踪文件：\(names)")
        XCTAssertTrue(names.contains("a.swift"))
        XCTAssertEqual(f.model.worktreeDetails.first?.deleted, true, "详情缓存更新")
    }

    func testDeleteOfMissingDirectoryStillMarks() async throws {
        let f = try await fixture()
        try FileManager.default.removeItem(at: f.worktree)
        let failure = await f.model.deleteManagedWorktree(f.recordID)
        XCTAssertNil(failure, "目录已消失时静默 prune")
        XCTAssertNotNil(f.model.managedWorktrees.first?.deletedAt)
    }

    // MARK: Restore

    func testRestoreRecreatesWorktreeWithUncommittedWork() async throws {
        let f = try await fixture()
        try write("let a = 2\n", "a.swift", in: f.worktree)
        try write("carrier\n", "n.txt", in: f.worktree)
        _ = await f.model.deleteManagedWorktree(f.recordID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.path))
        XCTAssertEqual(f.model.deletedWorktree(forConversation: f.id)?.id, f.recordID, "删除后对话打开能看到恢复入口")

        let failure = await f.model.restoreManagedWorktree(for: f.id)
        XCTAssertNil(failure, failure ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.appendingPathComponent("a.swift").path), "worktree 重建")
        let restored = try String(contentsOf: f.worktree.appendingPathComponent("a.swift"), encoding: .utf8)
        XCTAssertEqual(restored, "let a = 2\n", "未提交改动跟快照回来")
        let untracked = try String(contentsOf: f.worktree.appendingPathComponent("n.txt"), encoding: .utf8)
        XCTAssertEqual(untracked, "carrier\n", "未跟踪文件回来")
        XCTAssertEqual(f.model.conversations.first { $0.id == f.id }?.workingDirectory, f.worktree.path, "对话重新绑定")
        XCTAssertNil(f.model.deletedWorktree(forConversation: f.id), "恢复后横幅消失")
        XCTAssertNil(f.model.managedWorktrees.first?.deletedAt)
    }

    // MARK: Deleting the chat

    func testDeletingTheChatOfALiveWorktreeKeepsTheCheckout() async throws {
        let f = try await fixture()
        try write("let a = 9\n", "a.swift", in: f.worktree)
        f.model.deleteConversation(f.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.appendingPathComponent("a.swift").path),
                      "删对话不删 worktree 里的工作")
        let record = try XCTUnwrap(f.model.managedWorktrees.first { $0.id == f.recordID }, "还在的 worktree 继续登记")
        XCTAssertTrue(record.conversationIDs.isEmpty, "不再指向已删除的对话")
        XCTAssertNil(f.model.managedWorktree(for: f.id))
    }

    func testDeletingTheChatOfADeletedWorktreeDropsTheRowButKeepsTheSnapshotRef() async throws {
        let f = try await fixture()
        try write("let a = 7\n", "a.swift", in: f.worktree)
        _ = await f.model.deleteManagedWorktree(f.recordID)
        let snapshot = try XCTUnwrap(f.model.managedWorktrees.first?.snapshot)
        f.model.deleteConversation(f.id)
        XCTAssertFalse(f.model.managedWorktrees.contains { $0.id == f.recordID }, "没有对话能恢复它了，登记去掉")
        // The work stays reachable in git.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: GitBinary.resolve()!)
        check.arguments = ["cat-file", "-e", snapshot.commit]
        check.currentDirectoryURL = f.source
        check.standardOutput = Pipe()
        check.standardError = Pipe()
        check.standardInput = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0, "快照提交还在仓库里")
    }

    func testDeletingOneOfTwoChatsKeepsTheOtherLinked() async throws {
        let f = try await fixture()
        let other = try XCTUnwrap(f.model.newChat(inManagedWorktree: f.recordID))
        _ = await f.model.deleteManagedWorktree(f.recordID)
        f.model.deleteConversation(f.id)
        let record = try XCTUnwrap(f.model.managedWorktrees.first { $0.id == f.recordID }, "另一个对话还能恢复它")
        XCTAssertEqual(record.conversationIDs, [other])
    }

    func testAChatDeletedWhileItsWorktreeIsBeingDeletedStaysUnlinked() async throws {
        let f = try await fixture()
        try write("let a = 5\n", "a.swift", in: f.worktree)
        let deletion = Task { await f.model.deleteManagedWorktree(f.recordID) }
        // The busy flag goes up before the first await, so the chat is
        // deleted while the snapshot and removal are still running.
        while !f.model.isWorktreeBusy(f.recordID) { await Task.yield() }
        f.model.deleteConversation(f.id)
        let failure = await deletion.value
        XCTAssertNil(failure, failure ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.path))
        XCTAssertFalse(f.model.managedWorktrees.contains { $0.id == f.recordID },
                       "删除收尾不能把已删除的对话写回登记表")
    }

    func testLaunchDropsLinksToChatsThatNoLongerExist() async throws {
        let store = InMemoryConversationStore()
        let source = try makeSource()
        let gone = UUID()
        let kept = Conversation(title: "还在")
        try await store.save(kept)
        try await store.saveManagedWorktrees([
            // Deleted, and its only chat is gone: nothing can restore it.
            ManagedWorktree(path: root.appendingPathComponent("old").path, sourceRoot: source.path,
                            baseCommit: try gitHead(source), conversationIDs: [gone], deletedAt: Date()),
            // Live: stays, just without the missing chat.
            ManagedWorktree(path: root.appendingPathComponent("live").path, sourceRoot: source.path,
                            baseCommit: try gitHead(source), conversationIDs: [gone, kept.id]),
        ])
        let model = ChatAppModel(
            store: store, secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: root.appendingPathComponent("media")),
            transport: CannedOKTransport()
        )
        await model.bootstrap()
        XCTAssertEqual(model.managedWorktrees.count, 1, "没有对话的已删除行去掉")
        XCTAssertEqual(model.managedWorktrees.first?.conversationIDs, [kept.id])
    }

    func testRestoreFallsBackToSuffixedPath() async throws {
        let f = try await fixture()
        try write("keep\n", "k.txt", in: f.worktree) // occupy the old path with junk
        _ = await f.model.deleteManagedWorktree(f.recordID)
        // Recreate junk at the old path after deletion.
        try write("keep\n", "k.txt", in: f.worktree)
        let failure = await f.model.restoreManagedWorktree(for: f.id)
        XCTAssertNil(failure, failure ?? "")
        let bound = f.model.conversations.first { $0.id == f.id }?.workingDirectory
        XCTAssertEqual(bound, f.worktree.path + "-2", "旧路径被占时落在 -2")
    }

    // MARK: Archive hook

    func testArchiveDeletesWorktreeUnlessPinned() async throws {
        let f = try await fixture()
        f.model.toggleArchive(f.id)
        // The archive hook runs on a Task; wait for the registry to flip.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, f.model.managedWorktrees.first?.deletedAt == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(f.model.managedWorktrees.first?.deletedAt, "归档触发快照删除")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.path))

        // Unarchiving does not auto-restore; the deleted row stays (its
        // snapshot remains the restore path when the chat is opened).
        f.model.toggleArchive(f.id)
        XCTAssertNotNil(f.model.managedWorktrees.first?.deletedAt, "取消归档不自动恢复")
    }

    func testArchiveKeepsPinnedChatWorktree() async throws {
        let f = try await fixture()
        f.model.togglePin(f.id)
        f.model.toggleArchive(f.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(f.model.managedWorktrees.first?.deletedAt, "置顶对话归档也不删")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.path))
    }

    func testSwitchOffStopsArchiveCleanup() async throws {
        let f = try await fixture()
        var settings = f.model.settings
        settings.worktreeAutoCleanup = false
        await f.model.saveSettings(settings)
        f.model.toggleArchive(f.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(f.model.managedWorktrees.first?.deletedAt, "自动删除关掉后归档不删")
    }

    // MARK: New chat in worktree

    func testNewChatInManagedWorktree() async throws {
        let f = try await fixture()
        let created = f.model.newChat(inManagedWorktree: f.recordID)
        let newID = try XCTUnwrap(created)
        XCTAssertEqual(f.model.conversations.first { $0.id == newID }?.workingDirectory, f.worktree.path)
        XCTAssertTrue(f.model.managedWorktrees.first?.conversationIDs.contains(newID) == true, "登记为新对话")
        // And a deleted worktree refuses: pin it (deletion refuses a pinned
        // chat), unpin so the delete goes through, then newChat must say no —
        // the directory is gone and the row is marked deleted.
        f.model.togglePin(f.id)
        f.model.togglePin(f.id) // unpin again; the pin state must not block
        let deleteRefusal = await f.model.deleteManagedWorktree(f.recordID)
        XCTAssertNil(deleteRefusal, deleteRefusal ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.path), "删除已生效")
        XCTAssertNil(f.model.newChat(inManagedWorktree: f.recordID))
    }

    // MARK: Settings decoding

    func testSettingsDecodeFromOldDocuments() throws {
        // A pre-worktree-settings document: no autoCleanup / keepCount keys.
        let old = #"{"version":1,"conversations":[],"providers":[],"models":[],"settings":{"sendOnReturn":true},"projects":[],"scheduledTasks":[]}"#
        let directory = root.appendingPathComponent("old-doc", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try old.write(to: directory.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        let store = FileConversationStore(directoryURL: directory)
        let model = ChatAppModel(store: store, secrets: InMemorySecretStore(), mediaLibrary: MediaLibrary(rootURL: directory.appendingPathComponent("m")), transport: CannedOKTransport())
        let ready = expectation(description: "bootstrap")
        Task { await model.bootstrap(); ready.fulfill() }
        wait(for: [ready], timeout: 10)
        XCTAssertTrue(model.settings.worktreeAutoCleanup, "旧文档得到官方默认 true")
        XCTAssertEqual(model.settings.worktreeKeepCount, 15, "旧文档得到官方默认 15")
    }

    func testSettingsRoundTripKeepsCleanupFields() async throws {
        let directory = root.appendingPathComponent("roundtrip", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileConversationStore(directoryURL: directory)
        var settings = AppSettings()
        settings.worktreeAutoCleanup = false
        settings.worktreeKeepCount = 7
        try await store.saveSettings(settings)
        let reloaded = try await store.loadSettings()
        XCTAssertFalse(reloaded.worktreeAutoCleanup)
        XCTAssertEqual(reloaded.worktreeKeepCount, 7)
    }
}

/// A transport that answers a model listing only; the tests here never send.
final class CannedOKTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"object":"list","data":[]}"#.utf8))
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
