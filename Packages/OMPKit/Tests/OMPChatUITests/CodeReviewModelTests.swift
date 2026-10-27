import XCTest
import OMPCore
@testable import OMPChatUI

/// Answers every streamed request with one canned reply and keeps the
/// request bodies. Never touches the network.
private final class CannedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []

    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return bodies.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"object":"list","data":[{"id":"mock-model","object":"model"}]}"#.utf8))
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        bodies.append(request.httpBody ?? Data())
        lock.unlock()
        let event = ["choices": [["delta": ["content": "没有发现问题。\n结论：可以提交"], "finish_reason": "stop"]]]
        let data = try JSONSerialization.data(withJSONObject: event)
        let body = "data: \(String(decoding: data, as: UTF8.self))\n\ndata: [DONE]\n\n"
        return AsyncThrowingStream { continuation in
            continuation.yield(Data(body.utf8))
            continuation.finish()
        }
    }
}

/// 「用 Codex 审查」 end to end against a real temporary repository: the new
/// thread's fields, the request it sends, and when no thread is made.
@MainActor
final class CodeReviewModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-review-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func git(_ args: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(GitBinary.resolve()))
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }

    private func write(_ text: String, _ path: String, in repo: URL) throws {
        try text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    /// One commit; then `a.swift` staged, `b.swift` edited, `c.swift` new.
    private func makeRepo(dirty: Bool = true) throws -> URL {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "feature/review"], in: repo)
        try git(["config", "user.email", "a@b"], in: repo)
        try git(["config", "user.name", "a"], in: repo)
        try git(["config", "commit.gpgsign", "false"], in: repo)
        try write("let a = 1\n", "a.swift", in: repo)
        try write("let b = 1\n", "b.swift", in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        if dirty {
            try write("let a = 2\n", "a.swift", in: repo)
            try git(["add", "a.swift"], in: repo)
            try write("let b = 2\n", "b.swift", in: repo)
            try write("let c = 3\n", "c.swift", in: repo)
        }
        return repo
    }

    private func makeModel(_ transport: CannedTransport) async throws -> (ChatAppModel, UUID) {
        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: root.appendingPathComponent("media")),
            transport: transport
        )
        await model.bootstrap()
        await model.addProvider(ProviderProfile(name: "Mock", kind: .openAICompatible, baseURL: URL(string: "https://mock.test")!), apiKey: "sk-test")
        return (model, try XCTUnwrap(model.selectedConversationID))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }

    func testReviewStartsAReadOnlyThreadBoundToTheSameDirectory() async throws {
        let repo = try makeRepo()
        let transport = CannedTransport()
        let (model, source) = try await makeModel(transport)
        model.updateWorkingDirectory(source, repo.path)
        let before = model.conversations.count

        let failure = await model.startCodeReview(for: source)

        XCTAssertNil(failure)
        XCTAssertEqual(model.conversations.count, before + 1)
        let review = try XCTUnwrap(model.selectedConversation)
        XCTAssertNotEqual(review.id, source)
        XCTAssertEqual(review.title, "审查：feature/review")
        XCTAssertEqual(review.workingDirectory, repo.path)
        XCTAssertEqual(model.permissionMode(for: review.id), .readOnly)
        XCTAssertTrue(model.toolsEnabled(for: review.id))
        XCTAssertTrue(review.isCodeReview)
        XCTAssertEqual(model.conversations.first { $0.id == source }?.isCodeReview, false)

        let request = try XCTUnwrap(review.messages.first { $0.role == .user }?.concatenatedText)
        for piece in ["## 已暂存的改动", "### `a.swift`", "+let a = 2", "## 未暂存的改动", "### `b.swift`", "+let b = 2",
                      "## 未跟踪的文件", "### `c.swift`", "let c = 3"] {
            XCTAssertTrue(request.contains(piece), "请求里缺少 \(piece)")
        }

        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(model.codeReviewOutcome(review.id), .reported)
        XCTAssertNil(model.codeReviewOutcome(source))
        let sent = try XCTUnwrap(transport.requests.first)
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: sent), as: UTF8.self)
        XCTAssertTrue(wire.contains("let c = 3"), "审查请求真的发给了模型")
    }

    func testTheChangesTabCanReviewItsOwnDirectory() async throws {
        let repo = try makeRepo()
        let (model, source) = try await makeModel(CannedTransport())
        XCTAssertNil(model.selectedConversation?.workingDirectory)

        let failure = await model.startCodeReview(for: source, directory: repo.path)

        XCTAssertNil(failure)
        XCTAssertEqual(model.selectedConversation?.workingDirectory, repo.path)
        try await waitUntil { !model.isStreaming }
    }

    func testCleanTreeStartsNoReview() async throws {
        let repo = try makeRepo(dirty: false)
        let transport = CannedTransport()
        let (model, source) = try await makeModel(transport)
        model.updateWorkingDirectory(source, repo.path)
        let before = model.conversations.map(\.id)

        let failure = await model.startCodeReview(for: source)

        XCTAssertEqual(failure, "没有可审查的改动")
        XCTAssertEqual(model.conversations.map(\.id), before)
        XCTAssertEqual(model.selectedConversationID, source)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testThreadWithoutAGitDirectoryStartsNoReview() async throws {
        let (model, source) = try await makeModel(CannedTransport())
        let count = model.conversations.count

        let unbound = await model.startCodeReview(for: source)
        XCTAssertEqual(unbound, "这个对话没有绑定工作目录")

        model.updateWorkingDirectory(source, root.path)
        let notARepository = await model.startCodeReview(for: source)
        XCTAssertEqual(notARepository, GitWorkingTree.Failure.notARepository.message)
        XCTAssertEqual(model.conversations.count, count)
    }
}
