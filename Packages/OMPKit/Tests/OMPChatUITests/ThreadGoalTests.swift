import XCTest
import OMPCore
@testable import OMPChatUI

/// The thread goal is trimmed, persisted and cleared by a blank value, and it
/// rides in the system prompt only while one is set.
@MainActor
final class ThreadGoalTests: XCTestCase {
    private func makeModel() async -> ChatAppModel {
        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: FileManager.default.temporaryDirectory),
            transport: URLSessionTransport()
        )
        await model.bootstrap()
        return model
    }

    func testGoalIsTrimmedAndPersisted() async throws {
        let store = InMemoryConversationStore()
        let model = ChatAppModel(
            store: store,
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: FileManager.default.temporaryDirectory),
            transport: URLSessionTransport()
        )
        await model.bootstrap()
        let id = try XCTUnwrap(model.selectedConversationID)

        model.setGoal(id, "  修好登录  ")
        XCTAssertEqual(model.selectedConversation?.goal, "修好登录")
        // persist() saves on a detached task; the store must see it.
        try await Task.sleep(for: .milliseconds(200))

        let reloaded = try await store.loadAll().first { $0.id == id }
        XCTAssertEqual(reloaded?.goal, "修好登录", "目标写入了工作区文档")
    }

    func testBlankGoalClearsIt() async throws {
        let model = await makeModel()
        let id = try XCTUnwrap(model.selectedConversationID)

        model.setGoal(id, "一个目标")
        model.setGoal(id, "   \n")
        XCTAssertNil(model.selectedConversation?.goal, "空白等于清除")
        model.setGoal(id, nil)
        XCTAssertNil(model.selectedConversation?.goal)
    }

    func testSystemPromptCarriesTheGoalOnlyWhenSet() async throws {
        let model = await makeModel()
        let conversation = try XCTUnwrap(model.selectedConversation)

        let without = try XCTUnwrap(model.debugSystemPrompt(for: conversation))
        XCTAssertFalse(without.contains("本对话的目标："), "没设目标时提示词里没有这一行")
        XCTAssertTrue(without.contains("【界面渲染】"), "omp-ui 说明仍在")

        var withGoal = conversation
        withGoal.goal = "修好登录"
        let prompt = try XCTUnwrap(model.debugSystemPrompt(for: withGoal))
        XCTAssertTrue(prompt.contains("本对话的目标：修好登录"))

        let goalRange = try XCTUnwrap(prompt.range(of: "本对话的目标：修好登录"))
        let guideRange = try XCTUnwrap(prompt.range(of: "【界面渲染】"))
        XCTAssertLessThan(goalRange.lowerBound, guideRange.lowerBound, "目标行在 omp-ui 说明之前")
    }

    func testOldDocumentWithoutGoalDecodes() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","title":"旧对话","messages":[]}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertNil(decoded.goal, "没有 goal 字段的旧文档仍能打开")
        XCTAssertEqual(decoded.title, "旧对话")
    }
}
