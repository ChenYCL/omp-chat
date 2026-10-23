import XCTest
import OMPCore
@testable import OMPChatUI

private struct FakeTransport: HTTPTransport {
    var modelsBody: Data
    var streamChunks: [String]
    var streamFailure: Error?

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: modelsBody)
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        if let streamFailure {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: streamFailure)
            }
        }
        return AsyncThrowingStream { continuation in
            for chunk in streamChunks {
                continuation.yield(Data(chunk.utf8))
            }
            continuation.finish()
        }
    }
}

@MainActor
final class ChatAppModelTests: XCTestCase {
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("omp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    private func makeModel(
        store: InMemoryConversationStore = InMemoryConversationStore(),
        secrets: InMemorySecretStore = InMemorySecretStore(),
        chunks: [String]
    ) async throws -> ChatAppModel {
        let modelsBody = Data(#"{"object":"list","data":[{"id":"mock-model","object":"model"}]}"#.utf8)
        let transport = FakeTransport(modelsBody: modelsBody, streamChunks: chunks)
        let model = ChatAppModel(
            store: store,
            secrets: secrets,
            mediaLibrary: MediaLibrary(rootURL: libraryRoot),
            transport: transport
        )
        await model.bootstrap()
        let profile = ProviderProfile(name: "Mock", kind: .openAICompatible, baseURL: URL(string: "https://mock.test")!)
        await model.addProvider(profile, apiKey: "sk-test")
        return model
    }

    func testStreamingCompletesAndPersists() async throws {
        let store = InMemoryConversationStore()
        let model = try await makeModel(store: store, chunks: [
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"！\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n",
        ])
        XCTAssertEqual(model.availableModels.first?.id, "mock-model")

        await model.sendNow(text: "hi", attachments: [])
        try await waitUntilIdle(model)

        let conversation = try XCTUnwrap(model.selectedConversation)
        XCTAssertEqual(conversation.messages.count, 2)
        let assistant = conversation.messages[1]
        XCTAssertEqual(assistant.concatenatedText, "你好！")
        XCTAssertEqual(assistant.status, .complete)
        XCTAssertEqual(conversation.title, "hi")

        let persisted = try await store.loadAll()
        XCTAssertEqual(persisted.first?.messages.count, 2)
        XCTAssertEqual(persisted.first?.modelID, "mock-model")
    }

    func testStreamFailureMarksMessageFailed() async throws {
        let model = try await makeFailingModel()
        await model.sendNow(text: "hi", attachments: [])
        try await waitUntilIdle(model)

        let assistant = try XCTUnwrap(model.selectedConversation?.messages.last)
        XCTAssertEqual(assistant.status, .failed)
        XCTAssertFalse(assistant.errorText?.isEmpty ?? true)
        XCTAssertNotNil(model.errorMessage)

        await model.sendNow(text: "second", attachments: [])
        try await waitUntilIdle(model)
        XCTAssertEqual(model.selectedConversation?.messages.count, 4)
    }

    func waitUntilIdle(_ model: ChatAppModel) async throws {
        for _ in 0..<300 {
            if !model.isStreaming { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("streaming never finished")
    }
}

extension ChatAppModelTests {
    fileprivate func makeFailingModel() async throws -> ChatAppModel {
        let modelsBody = Data(#"{"object":"list","data":[{"id":"mock-model","object":"model"}]}"#.utf8)
        let transport = FakeTransport(
            modelsBody: modelsBody,
            streamChunks: [],
            streamFailure: ProviderError.http(status: 502, body: "bad gateway")
        )
        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: libraryRoot),
            transport: transport
        )
        await model.bootstrap()
        let profile = ProviderProfile(name: "Mock", kind: .openAICompatible, baseURL: URL(string: "https://mock.test")!)
        await model.addProvider(profile, apiKey: "sk-test")
        return model
    }
}
