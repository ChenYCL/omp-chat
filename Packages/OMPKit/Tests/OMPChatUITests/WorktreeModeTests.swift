import XCTest
@testable import OMPChatUI
import OMPCore

/// Managed worktree creation against real temporary repositories: detached
/// checkout, carried changes, include files, rollback, setup failure, the
/// registry, and the first-send path.
@MainActor
final class WorktreeModeTests: XCTestCase {
    private struct Fixture {
        var root: URL
        var repo: URL
        var model: ChatAppModel
        var id: UUID
    }

    /// The conversation under test: the model's accessor is private.
    private func talk(_ model: ChatAppModel, _ id: UUID) -> Conversation? {
        model.conversations.first { $0.id == id }
    }

    private func fixture(files: [String: String] = ["a.txt": "hello\n"]) async throws -> Fixture {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-wm-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for (name, contents) in files {
            let url = repo.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try git(repo, ["init", "-q", "-b", "main"])
        try git(repo, ["config", "user.email", "probe@example.com"])
        try git(repo, ["config", "user.name", "probe"])
        try git(repo, ["add", "-A"])
        try git(repo, ["commit", "-qm", "init"])

        let model = ChatAppModel(store: FileConversationStore(directoryURL: root.appendingPathComponent("store")))
        let conversation = model.newConversation()
        model.updateWorkingDirectory(conversation.id, repo.path)
        var settings = model.settings
        settings.worktreeBaseDirectory = root.appendingPathComponent("worktrees").path
        await model.saveSettings(settings)
        return Fixture(root: root, repo: repo, model: model, id: conversation.id)
    }

    private func git(_ repo: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(GitBinary.resolve()))
        process.arguments = args
        process.currentDirectoryURL = repo
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) 失败")
    }

    private func head(_ directory: String) throws -> String {
        let run = try gitOutput(directory, ["rev-parse", "HEAD"])
        return run.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitOutput(_ directory: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(GitBinary.resolve()))
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    override func tearDown() {
        // Fixtures clean themselves up; nothing shared to reset.
    }

    func testDetachedCreationAtTheChosenCommit() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try git(f.repo, ["checkout", "-qb", "feature"])
        try "feature".write(to: f.repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(f.repo, ["add", "-A"])
        try git(f.repo, ["commit", "-qm", "feature"])
        let featureHead = try head(f.repo.path)
        try git(f.repo, ["checkout", "-q", "main"])

        let failure = await f.model.createManagedWorktree(for: f.id, baseBranch: "feature")
        XCTAssertNil(failure, "创建应成功：\(failure ?? "")")

        let record = try XCTUnwrap(f.model.managedWorktree(for: f.id))
        XCTAssertEqual(record.baseCommit, featureHead, "应检出所选分支的 HEAD")
        XCTAssertNil(record.branch, "托管 worktree 以 detached HEAD 创建")
        XCTAssertEqual(record.baseBranch, "feature")
        let symbolic = try gitOutput(record.path, ["symbolic-ref", "--short", "-q", "HEAD"])
        XCTAssertEqual(symbolic.trimmingCharacters(in: .whitespacesAndNewlines), "", "HEAD 应是 detached")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + "/b.txt"))
        XCTAssertEqual(talk(f.model, f.id)?.workingDirectory, record.path, "对话应绑定到 worktree")
        XCTAssertTrue(record.path.contains("/worktrees/repo/"), "路径形如 <根目录>/<仓库名>/<slug>")
    }

    func testUncommittedChangesAreCarried() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Tracked edit plus a new untracked file, both on the current branch.
        try "hello\nworld\n".write(to: f.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "fresh".write(to: f.repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let failure = await f.model.createManagedWorktree(for: f.id, baseBranch: nil)
        XCTAssertNil(failure, "创建应成功：\(failure ?? "")")
        let path = try XCTUnwrap(f.model.managedWorktree(for: f.id)?.path)
        let tracked = try String(contentsOfFile: path + "/a.txt", encoding: .utf8)
        XCTAssertEqual(tracked, "hello\nworld\n", "已跟踪的未提交改动应带过去")
        XCTAssertEqual(try String(contentsOfFile: path + "/new.txt", encoding: .utf8), "fresh", "未跟踪文件应复制过去")
        // The source stays untouched.
        XCTAssertEqual(try String(contentsOfFile: f.repo.path + "/a.txt", encoding: .utf8), "hello\nworld\n")
    }

    func testOtherBranchDoesNotCarryLocalEdits() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try git(f.repo, ["branch", "other"])
        try "dirty".write(to: f.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let failure = await f.model.createManagedWorktree(for: f.id, baseBranch: "other")
        XCTAssertNil(failure, "创建应成功：\(failure ?? "")")
        let path = try XCTUnwrap(f.model.managedWorktree(for: f.id)?.path)
        XCTAssertEqual(try String(contentsOfFile: path + "/a.txt", encoding: .utf8), "hello\n",
                       "选了别的分支时不应带上当前检出的未提交改动")
    }

    func testIgnoredFilesOnlyViaWorktreeInclude() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try ".env\n*.log\nsecrets/\nAGENTS.override.md\n".write(
            to: f.repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
        )
        try ".env\n!secrets/keep.log\nsecrets/\n".write(
            to: f.repo.appendingPathComponent(".worktreeinclude"), atomically: true, encoding: .utf8
        )
        try git(f.repo, ["add", "-A"])
        try git(f.repo, ["commit", "-qm", "ignore rules"])
        try "token".write(to: f.repo.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.repo.appendingPathComponent("secrets"), withIntermediateDirectories: true)
        try "noise".write(to: f.repo.appendingPathComponent("secrets/keep.log"), atomically: true, encoding: .utf8)
        try "skip-me".write(to: f.repo.appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
        try "override".write(to: f.repo.appendingPathComponent("AGENTS.override.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: f.repo.appendingPathComponent(".env.link"),
            withDestinationURL: f.repo.appendingPathComponent(".env")
        )
        // Already tracked content the include must not clobber.
        try "tracked".write(to: f.repo.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try git(f.repo, ["add", "kept.txt"])
        try git(f.repo, ["commit", "-qm", "tracked"])

        let failure = await f.model.createManagedWorktree(for: f.id, baseBranch: nil)
        XCTAssertNil(failure, "创建应成功：\(failure ?? "")")
        let path = try XCTUnwrap(f.model.managedWorktree(for: f.id)?.path)
        XCTAssertEqual(try? String(contentsOfFile: path + "/.env", encoding: .utf8), "token")
        XCTAssertEqual(try? String(contentsOfFile: path + "/secrets/keep.log", encoding: .utf8), "noise",
                       "目录规则下被否定的文件仍应复制")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/debug.log"), "未列入 include 的忽略文件不复制")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/.env.link"), "符号链接不复制")
        XCTAssertEqual(try String(contentsOfFile: path + "/AGENTS.override.md", encoding: .utf8), "override",
                       "被忽略的 AGENTS.override.md 自动复制")
        XCTAssertEqual(try String(contentsOfFile: path + "/kept.txt", encoding: .utf8), "tracked", "已跟踪文件不被覆盖")
    }

    func testGitFailureRollsBack() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let failure = await f.model.createManagedWorktree(for: f.id, baseBranch: "no-such-branch")
        XCTAssertNotNil(failure, "不存在的分支应失败")
        XCTAssertNil(f.model.managedWorktree(for: f.id), "失败不应留下注册表记录")
        XCTAssertEqual(talk(f.model, f.id)?.workingDirectory, f.repo.path, "对话目录不变")
        let listed = try gitOutput(f.repo.path, ["worktree", "list", "--porcelain"])
        XCTAssertFalse(listed.contains("/worktrees/"), "失败不应留下 git worktree 条目")
        XCTAssertEqual(f.model.worktreeProgress?.phase, .failed)
    }

    func testFailureAfterCheckoutRemovesTheHalfMadeWorktree() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // An untracked file nobody can read: `worktree add` succeeds, then
        // carrying the untracked files fails, so there is a checkout to undo.
        let locked = f.repo.appendingPathComponent("locked.txt")
        try "secret".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let failure = await f.model.createManagedWorktree(for: f.id, baseBranch: nil)
        XCTAssertNotNil(failure, "复制未跟踪文件失败应报错")
        XCTAssertNil(f.model.managedWorktree(for: f.id), "失败不应留下注册表记录")
        XCTAssertEqual(talk(f.model, f.id)?.workingDirectory, f.repo.path, "对话目录不变")
        let listed = try gitOutput(f.repo.path, ["worktree", "list", "--porcelain"])
        XCTAssertFalse(listed.contains("/worktrees/"), "半成品的 git worktree 条目应被删除")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: f.root.appendingPathComponent("worktrees/repo").path
        )) ?? []
        XCTAssertEqual(leftovers, [], "半成品目录应被删除")
        XCTAssertEqual(f.model.worktreeProgress?.phase, .failed)
    }

    func testSetupFailureLeavesAUsableWorktree() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let environments = f.repo.appendingPathComponent(".codex/environments", isDirectory: true)
        try FileManager.default.createDirectory(at: environments, withIntermediateDirectories: true)
        // `false` exits 1; the checkout must survive with the output shown.
        try "version = 1\nname = \"local\"\n\n[setup]\nscript = \"echo setup-broke >&2; false\"\n".write(
            to: environments.appendingPathComponent("environment.toml"), atomically: true, encoding: .utf8
        )
        try git(f.repo, ["add", "-A"])
        try git(f.repo, ["commit", "-qm", "env"])

        let failure = await f.model.createManagedWorktree(for: f.id, baseBranch: nil)
        XCTAssertNil(failure, "脚本失败不算创建失败：\(failure ?? "")")
        let record = try XCTUnwrap(f.model.managedWorktree(for: f.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + "/a.txt"), "worktree 仍可用")
        XCTAssertEqual(talk(f.model, f.id)?.workingDirectory, record.path)
        XCTAssertEqual(f.model.worktreeProgress?.phase, .failed)
        XCTAssertTrue(f.model.worktreeProgress?.detail?.contains("setup-broke") ?? false, "应展示脚本输出")
        XCTAssertTrue(f.model.worktreeProgress?.detail?.contains(".codex/environments") ?? false)
    }

    func testRegistryPersistsAcrossBootstrap() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let created = await f.model.createManagedWorktree(for: f.id, baseBranch: nil)
        XCTAssertNil(created)
        let record = try XCTUnwrap(f.model.managedWorktree(for: f.id))

        // The save is a detached task; give it a moment, then reload.
        try await Task.sleep(nanoseconds: 300_000_000)
        let reloaded = ChatAppModel(store: FileConversationStore(directoryURL: f.root.appendingPathComponent("store")))
        await reloaded.bootstrap()
        let restored = try XCTUnwrap(reloaded.managedWorktree(for: f.id))
        XCTAssertEqual(restored.path, record.path)
        XCTAssertEqual(restored.baseCommit, record.baseCommit)
        XCTAssertNil(restored.branch)
    }

    func testForkUsesTheManagedPath() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let failure = await f.model.forkConversation(f.id, mode: .worktree)
        XCTAssertNil(failure, "分叉应成功：\(failure ?? "")")
        let copy = try XCTUnwrap(f.model.conversations.first { $0.id != f.id })
        let record = try XCTUnwrap(f.model.managedWorktree(for: copy.id))
        XCTAssertNil(record.branch, "分叉也是 detached")
        XCTAssertTrue(record.path.contains("/worktrees/repo/"), "分叉走托管路径而不是仓库旁边")
        XCTAssertEqual(copy.workingDirectory, record.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + "/a.txt"))
    }

    func testFirstSendCreatesTheWorktreeThenSends() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let scripted = ChatAppModel(
            store: FileConversationStore(directoryURL: f.root.appendingPathComponent("store")),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: f.root.appendingPathComponent("media")),
            transport: WorktreeScriptedTransport()
        )
        await scripted.bootstrap()
        await scripted.addProvider(
            ProviderProfile(name: "Mock", kind: .openAICompatible, baseURL: URL(string: "https://mock.test")!),
            apiKey: "sk-test"
        )
        var settings = scripted.settings
        settings.worktreeBaseDirectory = f.root.appendingPathComponent("worktrees").path
        await scripted.saveSettings(settings)
        let id = try XCTUnwrap(scripted.selectedConversationID)
        scripted.updateWorkingDirectory(id, f.repo.path)

        scripted.setWorktreeMode(true, for: id)
        scripted.draft = "hello worktree"
        scripted.send()

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if talk(scripted, id)?.messages.contains(where: { $0.role == .assistant }) == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let conversation = try XCTUnwrap(talk(scripted, id))
        let record = try XCTUnwrap(scripted.managedWorktree(for: id), "第一条消息应先创建 worktree")
        XCTAssertEqual(conversation.workingDirectory, record.path, "发送应发生在 worktree 里")
        XCTAssertFalse(scripted.worktreeMode(for: id), "创建后开关关闭")
        XCTAssertTrue(conversation.messages.contains { $0.role == .user && $0.writtenText.contains("hello worktree") })
        XCTAssertTrue(
            conversation.messages.contains { $0.role == .assistant },
            "脚本传输应给出回复（errorMessage=\(scripted.errorMessage ?? "无")，streaming=\(scripted.isStreaming)，last=\(conversation.messages.last.map { String(describing: $0.role) } ?? "无")）"
        )
    }

    func testFailedCreationKeepsTheDraft() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.setWorktreeMode(true, for: f.id)
        f.model.setWorktreeBaseBranch("missing", for: f.id)
        f.model.draft = "keep me"
        f.model.send()

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, f.model.worktreeProgress?.phase != .failed {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(f.model.draft, "keep me", "创建失败时草稿应留在输入框")
        XCTAssertNil(f.model.managedWorktree(for: f.id))
        XCTAssertTrue(talk(f.model, f.id)?.messages.isEmpty ?? false, "失败不应发出消息")
        XCTAssertNotNil(f.model.errorMessage)
    }
}

/// Answers the models list with one entry and every stream with one assistant
/// line. Never touches the network.
private final class WorktreeScriptedTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"object":"list","data":[{"id":"mock-model","object":"model"}]}"#.utf8)
        )
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let body = FollowUpSSE.answer("ok")
        return AsyncThrowingStream { continuation in
            continuation.yield(Data(body.utf8))
            continuation.finish()
        }
    }
}
