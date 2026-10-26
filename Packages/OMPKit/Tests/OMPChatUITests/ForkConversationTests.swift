import XCTest
@testable import OMPChatUI
import OMPCore

/// Official Codex forkActions: local / sameWorktree / worktree. The first two
/// only copy state; the third must really create a git worktree or report why.
@MainActor
final class ForkConversationTests: XCTestCase {
    /// `newConversation()` rather than relying on bootstrap, which needs a
    /// store round trip.
    private func model() -> (ChatAppModel, UUID) {
        let m = ChatAppModel(store: FileConversationStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-fork-\(UUID().uuidString)", isDirectory: true)))
        let conversation = m.newConversation()
        return (m, conversation.id)
    }

    func testLocalForkDropsTheDirectory() async {
        let (m, id) = model()
        m.updateWorkingDirectory(id, "/tmp/somewhere")
        let failure = await m.forkConversation(id, mode: .local)
        XCTAssertNil(failure, "本地副本不应失败")
        let forked = m.conversations.first { $0.id != id && $0.title.hasSuffix("(副本)") }
        XCTAssertNil(forked?.workingDirectory, "本地副本不绑定目录")
    }

    func testSameWorktreeKeepsTheDirectory() async {
        let (m, id) = model()
        m.updateWorkingDirectory(id, "/tmp/somewhere")
        _ = await m.forkConversation(id, mode: .sameWorktree)
        let forked = m.conversations.first { $0.id != id && $0.title.hasSuffix("(副本)") }
        XCTAssertEqual(forked?.workingDirectory, "/tmp/somewhere", "同一工作目录副本保留路径")
    }

    func testWorktreeForkReportsWhyGitRefused() async throws {
        let (m, id) = model()
        // A directory that is not a repository: git worktree add must fail and
        // the failure must be surfaced, not swallowed.
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-notarepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        m.updateWorkingDirectory(id, plain.path)
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        let failure = await m.forkConversation(id, mode: .worktree)
        XCTAssertNotNil(failure, "不在仓库里时 worktree 分叉应报错")
        XCTAssertFalse(failure?.isEmpty ?? true)
    }

    func testWorktreeForkCreatesARealCheckout() async throws {
        guard let git = GitBinary.resolve() else { throw XCTSkip("no git") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-wt-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func run(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = args
            process.currentDirectoryURL = repo
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) 失败")
        }
        try run(["init", "-q"])
        try run(["config", "user.email", "probe@example.com"])
        try run(["config", "user.name", "probe"])
        try "hello".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "-A"])
        try run(["commit", "-qm", "init"])

        let (m, id) = model()
        m.updateWorkingDirectory(id, repo.path)
        let failure = await m.forkConversation(id, mode: .worktree)
        XCTAssertNil(failure, "worktree 分叉应成功：\(failure ?? "")")

        let forked = m.conversations.first { $0.id != id && $0.title.hasSuffix("(副本)") }
        let path = try XCTUnwrap(forked?.workingDirectory, "副本应绑定新目录")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/a.txt"), "新 worktree 应有仓库内容")
        XCTAssertTrue(path.hasPrefix(root.path), "新 worktree 应在仓库旁边")
    }
}
