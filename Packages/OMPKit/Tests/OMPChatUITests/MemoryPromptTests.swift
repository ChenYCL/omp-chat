import XCTest
@testable import OMPChatUI
import OMPCore

/// 记忆上下文 used to be a switch that controlled nothing. It now feeds the
/// system prompt, one memory per line, and only when switched on.
@MainActor
final class MemoryPromptTests: XCTestCase {
    private func model(memories: String, enabled: Bool) async -> ChatAppModel {
        let store = FileConversationStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-mem-\(UUID().uuidString)", isDirectory: true))
        let m = ChatAppModel(store: store)
        var settings = m.settings
        settings.memories = memories
        settings.enableMemories = enabled
        await m.saveSettings(settings)
        return m
    }

    private func prompt(_ m: ChatAppModel, _ text: String) -> String {
        // A fresh conversation is already selected after init; the prompt only
        // depends on its own system prompt, which is empty here.
        let conversation = m.selectedConversation ?? Conversation(title: "t")
        return m.debugSystemPrompt(for: conversation) ?? ""
    }

    func testMemoriesReachThePromptWhenEnabled() async {
        let m = await model(memories: "我在用 Swift\n回复用中文", enabled: true)
        let text = prompt(m, "hi")
        XCTAssertTrue(text.contains("我在用 Swift"), "开启后记忆应进入提示词")
        XCTAssertTrue(text.contains("回复用中文"), "每行一条都要带上")
        XCTAssertTrue(text.contains("用户希望你在对话中记住"), "应有一段说明，模型才知道这是什么")
    }

    func testMemoriesStayOutWhenDisabled() async {
        let m = await model(memories: "我在用 Swift", enabled: false)
        XCTAssertFalse(prompt(m, "hi").contains("我在用 Swift"), "关闭时不应发送记忆")
    }

    func testBlankLinesAndPaddingAreDropped() async {
        let m = await model(memories: "\n  我在用 Swift  \n\n", enabled: true)
        let text = prompt(m, "hi")
        XCTAssertTrue(text.contains("我在用 Swift"))
        XCTAssertFalse(text.contains("\n\n\n"), "空行不该留下多余的换行")
    }
}
