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

    /// Points managed worktrees at a temporary root before any is created.
    private func useWorktreeRoot(_ m: ChatAppModel, _ root: URL) async {
        var settings = m.settings
        settings.worktreeBaseDirectory = root.path
        await m.saveSettings(settings)
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

        let worktrees = root.appendingPathComponent("worktrees", isDirectory: true)
        let (m, id) = model()
        await useWorktreeRoot(m, worktrees)
        m.updateWorkingDirectory(id, repo.path)
        let failure = await m.forkConversation(id, mode: .worktree)
        XCTAssertNil(failure, "worktree 分叉应成功：\(failure ?? "")")

        let forked = m.conversations.first { $0.id != id && $0.title.hasSuffix("(副本)") }
        let path = try XCTUnwrap(forked?.workingDirectory, "副本应绑定新目录")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/a.txt"), "新 worktree 应有仓库内容")
        XCTAssertTrue(path.hasPrefix(worktrees.appendingPathComponent("repo").path + "/"),
                      "分叉走托管路径 <根目录>/<仓库名>/<slug>，而不是仓库旁边")
        // Managed: detached HEAD at the source HEAD, registered, bound.
        XCTAssertEqual(try gitSymbolicRef(path), "", "托管 worktree 应是 detached HEAD")
        let forkedID = try XCTUnwrap(forked?.id, "副本应存在")
        let record = try XCTUnwrap(m.managedWorktree(for: forkedID), "分叉应登记注册表")
        XCTAssertNil(record.branch)
        XCTAssertEqual(record.path, path)
    }

    /// Empty output means HEAD is detached.
    private func gitSymbolicRef(_ directory: String) throws -> String {
        let git = try XCTUnwrap(GitBinary.resolve())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["symbolic-ref", "--short", "-q", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// 继续于 新建 Worktree moves the same conversation instead of copying it.
    func testContinueInWorktreeRebindsTheSameConversation() async throws {
        guard let git = GitBinary.resolve() else { throw XCTSkip("no git") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-cont-\(UUID().uuidString)", isDirectory: true)
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
        await useWorktreeRoot(m, root.appendingPathComponent("worktrees", isDirectory: true))
        m.updateWorkingDirectory(id, repo.path)
        let before = m.conversations.count
        let failure = await m.continueInNewWorktree(id)
        XCTAssertNil(failure, "继续于新建 Worktree 应成功：\(failure ?? "")")

        XCTAssertEqual(m.conversations.count, before, "继续于不复制对话")
        let rebound = m.conversations.first { $0.id == id }
        let path = try XCTUnwrap(rebound?.workingDirectory, "原对话应改绑到新目录")
        XCTAssertNotEqual(path, repo.path, "应离开原来的目录")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/a.txt"), "新 worktree 应有仓库内容")
        XCTAssertTrue(path.hasPrefix(root.path + "/worktrees/"), "新 worktree 在托管根目录下")
        XCTAssertEqual(try gitSymbolicRef(path), "", "托管 worktree 应是 detached HEAD")
    }
}
