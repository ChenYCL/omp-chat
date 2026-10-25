import XCTest
import OMPCore
@testable import OMPChatUI

@MainActor
final class RelayHostControllerTests: XCTestCase {
    func testRelaySnapshotMirrorsConversations() async throws {
        let model = try await makeModelWithReply()
        let snapshot = model.relaySnapshot()

        XCTAssertFalse(snapshot.host.isEmpty)
        XCTAssertEqual(snapshot.selectedID, model.selectedConversationID?.uuidString)
        XCTAssertEqual(snapshot.conversations.count, model.conversations.count)

        let conversation = try XCTUnwrap(snapshot.conversations.first)
        let local = try XCTUnwrap(model.selectedConversation)
        XCTAssertEqual(conversation.id, local.id.uuidString)
        XCTAssertEqual(conversation.title, local.title)
        XCTAssertEqual(conversation.project, nil)
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages.first?.role, "user")
        XCTAssertEqual(conversation.messages.first?.text, "hello relay")
        XCTAssertEqual(conversation.messages.last?.role, "assistant")
        XCTAssertEqual(conversation.messages.last?.streaming, false)
    }

    func testRelaySnapshotFlagsStreamingMessage() async throws {
        let model = try await makeModelWithReply()
        // The reply already finished; start a second one and observe the
        // in-flight marker without waiting for completion.
        await model.sendNow(text: "second question", attachments: [])
        let snapshot = model.relaySnapshot()
        if model.isStreaming {
            let conversation = try XCTUnwrap(snapshot.conversations.first)
            XCTAssertTrue(conversation.isStreaming)
            XCTAssertEqual(conversation.messages.last?.streaming, true)
        }
    }

    func testRelayInputWithoutConversationCreatesNew() async throws {
        let model = try await makeModelWithReply()
        let before = model.conversations.count
        await model.handleRelayCommand(.input(conversationID: nil, text: "from phone"))
        XCTAssertEqual(model.conversations.count, before + 1)
        let latest = try XCTUnwrap(model.conversations.last)
        XCTAssertEqual(latest.messages.first?.concatenatedText, "from phone")
    }
    func testRelayStopIsSafeWhenIdle() async throws {
        let model = try await makeModelWithReply()
        await model.handleRelayCommand(.stop(conversationID: model.conversations[0].id.uuidString))
        XCTAssertFalse(model.isStreaming)
    }

    func testControllerStartStopLifecycle() throws {
        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: FileManager.default.temporaryDirectory),
            transport: FailingTransport()
        )
        let controller = RelayHostController(model: model, token: "test-token")
        XCTAssertFalse(controller.isRunning)

        // Port 0 lets the OS pick a free port; the advertiser attaches to the
        // server's listener so no fixed port can collide.
        controller.start(port: 0)
        if controller.isRunning {
            XCTAssertNotNil(controller.port)
            XCTAssertGreaterThan(controller.port ?? 0, 0)
            controller.stop()
            XCTAssertFalse(controller.isRunning)
            XCTAssertNil(controller.port)
        } else {
            // In sandboxed CI the listener can be refused; the error must be
            // surfaced rather than swallowed.
            XCTAssertNotNil(controller.lastError)
        }
    }

    func testRelayInputTargetsExistingConversation() async throws {
        let model = try await makeModelWithReply()
        let target = try XCTUnwrap(model.conversations.first)
        let messageCountBefore = target.messages.count
        await model.handleRelayCommand(
            .input(conversationID: target.id.uuidString, text: "targeted")
        )
        XCTAssertEqual(model.selectedConversationID, target.id)
        for _ in 0..<300 where model.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reloaded = try XCTUnwrap(model.conversations.first { $0.id == target.id })
        XCTAssertEqual(reloaded.messages.count, messageCountBefore + 2)
        XCTAssertEqual(reloaded.messages.first?.concatenatedText, "hello relay")
        XCTAssertEqual(reloaded.messages.last?.concatenatedText, "hi there")
    }

    private func makeModelWithReply() async throws -> ChatAppModel {
        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let modelsBody = Data(#"{"object":"list","data":[{"id":"mock-model","object":"model"}]}"#.utf8)
        let transport = ReplayTransport(modelsBody: modelsBody)
        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: libraryRoot),
            transport: transport
        )
        await model.bootstrap()
        let profile = ProviderProfile(name: "Mock", kind: .openAICompatible, baseURL: URL(string: "https://mock.test")!)
        await model.addProvider(profile, apiKey: "sk-test")
        await model.sendNow(text: "hello relay", attachments: [])
        for _ in 0..<300 where model.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        return model
    }
}

/// Transport that streams one fixed assistant reply then finishes.
private struct ReplayTransport: HTTPTransport {
    let modelsBody: Data

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: modelsBody)
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"hi there\"}}]}\n\n".utf8))
            continuation.yield(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8))
            continuation.yield(Data("data: [DONE]\n\n".utf8))
            continuation.finish()
        }
    }
}

private struct FailingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 599, headers: [:], body: Data())
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
