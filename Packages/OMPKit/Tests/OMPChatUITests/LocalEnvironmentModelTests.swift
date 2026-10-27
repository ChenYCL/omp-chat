import XCTest
import OMPCore
@testable import OMPChatUI

/// A stand-in transport; the environment slice never sends requests, but
/// `ChatAppModel` wants one at init.
private struct EnvFakeTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"object":"list","data":[]}"#.utf8))
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// The local-environment members on `ChatAppModel`: discovery caching,
/// selection fallback, save with conflict detection, delete, and how an
/// environment action reaches the side panel terminal.
@MainActor
final class LocalEnvironmentModelTests: XCTestCase {
    private var root: URL!
    private var model: ChatAppModel!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-env-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: root.appendingPathComponent("media")),
            transport: EnvFakeTransport()
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func makeRepo(named name: String) throws -> String {
        let repo = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        return repo
    }

    private func writeEnvironment(_ text: String, repo: String, fileName: String) throws -> String {
        let directory = repo + "/.codex/environments"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/" + fileName
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        model.invalidateLocalEnvironmentCache()
        return path
    }

    private func makeBoundConversation(to repo: String) throws -> UUID {
        let conversation = model.newConversation()
        model.updateWorkingDirectory(conversation.id, repo)
        return conversation.id
    }

    private func environmentText(_ name: String, actions: String = "") -> String {
        """
        version = 1
        name = "\(name)"

        [setup]
        script = "make"

        [cleanup]
        script = "make clean"

        \(actions)
        """
    }

    private let actionBlock = """
        [[actions]]
        name = "Run"
        icon = "run"
        command = "npm start"

        [[actions]]
        name = "Linux only"
        icon = "test"
        command = "make test"
        platform = "linux"

        """

    // MARK: Discovery and selection

    func testDiscoveryAndSelectionFallback() throws {
        let repo = try makeRepo(named: "repo")
        let only = try writeEnvironment(environmentText("only"), repo: repo, fileName: "only.toml")
        _ = try makeBoundConversation(to: repo)

        let files = model.localEnvironments(forProject: repo)
        XCTAssertEqual(files.map(\.fileName), ["only.toml"])
        XCTAssertEqual(model.selectedLocalEnvironmentPath(forProject: repo), only)

        // An explicit choice of the second file sticks...
        let second = try writeEnvironment(environmentText("second"), repo: repo, fileName: "second.toml")
        model.selectLocalEnvironment(second, forProject: repo)
        XCTAssertEqual(model.selectedLocalEnvironmentPath(forProject: repo), second)

        // ...and clearing it falls back to "no choice", because two files no
        // longer have an unambiguous default.
        model.selectLocalEnvironment(nil, forProject: repo)
        XCTAssertNil(model.selectedLocalEnvironmentPath(forProject: repo))
    }

    func testInheritedFilesAreListed() throws {
        let repo = try makeRepo(named: "repo")
        try writeEnvironment(environmentText("root"), repo: repo, fileName: "root.toml")
        // A deeper folder of the same repository: no .git of its own, so the
        // walk continues up to the repo root and labels those files inherited.
        let nested = repo + "/packages/app"
        try writeEnvironment(environmentText("own"), repo: nested, fileName: "own.toml")

        let files = model.localEnvironments(forProject: nested)
        XCTAssertEqual(files.map(\.fileName), ["own.toml", "root.toml"])
        XCTAssertEqual(files[0].inherited, false)
        XCTAssertEqual(files[1].inherited, true)
        XCTAssertEqual(files[1].sourceFolderName, "repo", "the label is the folder's name, like the official 从 {folder}")
    }

    // MARK: Saving

    func testSaveCreatesSelectsAndDetectsConflicts() throws {
        let repo = try makeRepo(named: "repo")
        try makeBoundConversation(to: repo)

        let environment = LocalEnvironment(name: "made", setup: LocalEnvironmentScript(script: "echo hi"))
        XCTAssertNil(model.saveLocalEnvironment(environment, toProject: repo, fileName: "made"))

        let destination = repo + "/.codex/environments/made.toml"
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
        model.invalidateLocalEnvironmentCache()
        XCTAssertEqual(
            model.selectedLocalEnvironmentPath(forProject: repo),
            LocalEnvironmentDiscovery.standardize(destination),
            "a saved environment becomes the selection"
        )
        let listed = model.localEnvironments(forProject: repo)
        XCTAssertEqual(listed.first?.environment?.name, "made")

        // Changed on disk since listing → the save is refused with the
        // official conflict text.
        try "name = \"tampered\"\n\n[setup]\nscript = \"\"\n"
            .write(toFile: destination, atomically: true, encoding: .utf8)
        let failure = model.saveLocalEnvironment(environment, toProject: repo, fileName: "made")
        XCTAssertEqual(failure, LocalEnvironmentConflict.message)

        // After the change is observed, saving the same content works.
        model.invalidateLocalEnvironmentCache()
        _ = model.localEnvironments(forProject: repo)
        XCTAssertNil(model.saveLocalEnvironment(environment, toProject: repo, fileName: "made"))
    }

    func testSaveRejectsInvalidEnvironment() throws {
        let repo = try makeRepo(named: "repo")
        try makeBoundConversation(to: repo)
        var environment = LocalEnvironment(name: "  ")
        environment.actions = [LocalEnvironmentAction(name: "", icon: nil, command: "x")]
        let failure = model.saveLocalEnvironment(environment, toProject: repo, fileName: "bad")
        XCTAssertNotNil(failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.codex/environments/bad.toml"))
    }

    // MARK: Deleting

    func testDeleteRemovesFileAndClearsSelectionEffect() throws {
        let repo = try makeRepo(named: "repo")
        let path = try writeEnvironment(environmentText("gone"), repo: repo, fileName: "gone.toml")
        try makeBoundConversation(to: repo)
        XCTAssertEqual(model.selectedLocalEnvironmentPath(forProject: repo), path)

        XCTAssertNil(model.deleteLocalEnvironment(at: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(model.localEnvironments(forProject: repo).isEmpty)
        XCTAssertNil(model.selectedLocalEnvironmentPath(forProject: repo))

        // Only `.codex/environments` members may go.
        XCTAssertNotNil(model.deleteLocalEnvironment(at: repo + "/.git/config"))
    }

    // MARK: Actions

    func testEnvironmentActionRunsThroughTerminal() throws {
        let repo = try makeRepo(named: "repo")
        try writeEnvironment(environmentText("actions", actions: actionBlock), repo: repo, fileName: "actions.toml")
        let conversationID = try makeBoundConversation(to: repo)

        let failure = model.runEnvironmentAction(index: 0, in: conversationID)
        XCTAssertNil(failure)
        XCTAssertTrue(model.sidePanelOpen)
        XCTAssertEqual(model.sidePanelTab, .terminal)
        let request = try XCTUnwrap(model.sidePanelTerminalRequest)
        XCTAssertEqual(request.command, "npm start")
        XCTAssertEqual(request.directory, repo)
        model.finishSidePanelTerminalRequest(request.id)
        XCTAssertNil(model.sidePanelTerminalRequest)

        // Only the actions for this platform count, so index 1 is the Linux
        // action and is out of range on a Mac.
        XCTAssertEqual(model.runEnvironmentAction(index: 9, in: conversationID), "没有这个环境动作")
        XCTAssertEqual(model.runEnvironmentAction(index: -1, in: conversationID), "没有这个环境动作")
        XCTAssertEqual(model.runEnvironmentAction(index: 0, in: UUID()), "找不到这个对话")
    }

    func testEnvironmentActionWithoutSelectionReportsIt() throws {
        let repo = try makeRepo(named: "empty")
        let conversationID = try makeBoundConversation(to: repo)
        XCTAssertEqual(model.runEnvironmentAction(index: 0, in: conversationID), "这个项目还没有选择环境")
    }

    // MARK: Running

    func testModelRunWritesWorktreeFileAndRecordsDiagnostics() async throws {
        let repo = try makeRepo(named: "runrepo")
        let worktree = root.appendingPathComponent("runwt").path
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let config = try writeEnvironment(
            """
            version = 1
            name = "runner"

            [setup]
            script = "printf '%s\\n' $CODEX_SOURCE_TREE_PATH $CODEX_WORKTREE_PATH > made.txt"

            """,
            repo: repo,
            fileName: "runner.toml"
        )

        let result = await model.runLocalEnvironmentScript(.setup, configPath: config, sourceRoot: repo, worktreeRoot: worktree)
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertFalse(result.skipped)
        let made = try String(contentsOfFile: worktree + "/made.txt", encoding: .utf8)
        XCTAssertTrue(made.contains(LocalEnvironmentDiscovery.standardize(repo)), "made: \(made)")
        XCTAssertTrue(made.contains(LocalEnvironmentDiscovery.standardize(worktree)))

        // One diagnostics event per run.
        let events = DiagnosticsCenter.shared.recent(10)
        XCTAssertTrue(events.contains { $0.category == "environment" && $0.message.contains("setup") })
    }

    func testMissingConfigIsSkippedNotFailed() async {
        // A missing config is "nothing to run", never a fake success or an
        // error: cleanup on a worktree without the file must proceed.
        let result = await model.runLocalEnvironmentScript(
            .cleanup,
            configPath: root.appendingPathComponent("absent.toml").path,
            sourceRoot: root.path,
            worktreeRoot: root.path
        )
        XCTAssertTrue(result.skipped)
        XCTAssertEqual(result.exitCode, 0)
    }
}
