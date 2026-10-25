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

    /// relaySnapshot must surface tool traffic as RelayActivity rows with the
    /// same summaries/diff stats the desktop ActivityLog derives, cap detail
    /// to the last 5 assistant messages, and skip user messages entirely.
    func testRelaySnapshotBuildsThinkingAndActivity() async throws {
        let store = InMemoryConversationStore()
        let model = try await makeModel(store: store, chunks: [
            "data: {\"choices\":[{\"delta\":{\"content\":\"完成\"}}]}\n\n",
            "data: [DONE]\n\n",
        ])
        var conversation = Conversation(title: "relay")
        let thinking = ChatMessage(role: .assistant, parts: [.thinking("先查再改")])
        let runningCall = ChatMessage(
            role: .assistant,
            parts: [.toolCall(ToolCall(id: "call_2", name: "Bash", argumentsJSON: #"{"command":"swift build"}"#))]
        )
        let finished = ChatMessage(
            role: .assistant,
            parts: [
                .thinking("先读文件"),
                .toolCall(ToolCall(id: "call_1", name: "Read", argumentsJSON: #"{"file_path":"/tmp/AppDelegate.swift"}"#)),
                .toolCall(ToolCall(id: "call_3", name: "edit_file", argumentsJSON: #"{"file_path":"/tmp/AppDelegate.swift"}"#)),
                .toolResult(ToolResult(callID: "call_1", name: "Read", outputText: "import Foundation")),
                .toolResult(ToolResult(callID: "call_3", name: "edit_file", outputText: "+let x = 1\n-let x = 0", isError: true)),
            ]
        )
        conversation.messages = [
            ChatMessage(role: .user, parts: [.text("改一下")]),
            thinking, runningCall, finished,
        ]
        conversation.updatedAt = Date()
        try await store.save(conversation)
        // A fresh model bootstraps from the store, which already holds the
        // seeded conversation (the first makeModel bootstrap only added its
        // default conversation to that same store).
        let relayModel = try await makeModel(store: store, chunks: [])

        let snapshot = relayModel.relaySnapshot()
        let relayed = try XCTUnwrap(snapshot.conversations.first { $0.id == conversation.id.uuidString })
        XCTAssertEqual(relayed.messages.count, 4)

        let user = relayed.messages[0]
        XCTAssertEqual(user.role, "user")
        XCTAssertNil(user.thinking)
        XCTAssertNil(user.activity)

        let thinkingOnly = relayed.messages[1]
        XCTAssertEqual(thinkingOnly.thinking, "先查再改")
        XCTAssertNil(thinkingOnly.activity)

        let runningMessage = relayed.messages[2]
        XCTAssertEqual(runningMessage.activity?.count, 1)
        XCTAssertEqual(runningMessage.activity?.first?.summary, "已运行 swift build")
        XCTAssertEqual(runningMessage.activity?.first?.status, "running")
        XCTAssertNil(runningMessage.activity?.first?.detail, "older assistant rows are summary-only")

        let full = relayed.messages[3]
        XCTAssertEqual(full.thinking, "先读文件")
        let activities = try XCTUnwrap(full.activity)
        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(activities[0].id, "call_1")
        XCTAssertEqual(activities[0].summary, "已读 AppDelegate.swift")
        XCTAssertEqual(activities[0].status, "ok")
        XCTAssertNil(activities[0].added)
        let edit = activities[1]
        XCTAssertEqual(edit.summary, "已编辑 AppDelegate.swift")
        XCTAssertEqual(edit.status, "error")
        XCTAssertEqual(edit.added, 1)
        XCTAssertEqual(edit.removed, 1)
        XCTAssertEqual(edit.detail, #"{"file_path":"/tmp/AppDelegate.swift"}"# + "\n" + "+let x = 1\n-let x = 0")
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
