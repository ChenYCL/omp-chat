import XCTest
@testable import OMPCore

/// The side chat's model sees the thread only through this prompt, so what it
/// keeps, labels and drops decides whether the answer is about the right thing.
final class SideChatContextTests: XCTestCase {
    private func message(_ role: MessageRole, _ text: String) -> ChatMessage {
        ChatMessage(role: role, parts: text.isEmpty ? [] : [.text(text)])
    }

    func testLabelsRolesInOrder() {
        let prompt = SideChatContext.systemPrompt(title: "部署", goal: nil, transcript: [
            message(.user, "先跑测试"),
            message(.assistant, "测试通过"),
        ])
        let user = prompt.range(of: "用户：先跑测试")
        let assistant = prompt.range(of: "助手：测试通过")
        XCTAssertNotNil(user)
        XCTAssertNotNil(assistant)
        XCTAssertLessThan(user!.lowerBound, assistant!.lowerBound, "保持原来的顺序")
        XCTAssertTrue(prompt.contains("主对话标题：部署"))
    }

    func testSkipsMessagesWithNothingToQuote() {
        let prompt = SideChatContext.systemPrompt(title: "t", goal: nil, transcript: [
            message(.system, "系统提示"),
            message(.tool, "工具输出"),
            message(.assistant, ""),
            message(.user, "真问题"),
        ])
        XCTAssertFalse(prompt.contains("系统提示"))
        XCTAssertFalse(prompt.contains("工具输出"))
        XCTAssertFalse(prompt.contains("助手：\n"), "空的占位回复不该变成一行空助手")
        XCTAssertTrue(prompt.contains("用户：真问题"))
    }

    func testGoalIsIncludedOnlyWhenSet() {
        let withGoal = SideChatContext.systemPrompt(title: "t", goal: " 发布 ", transcript: [message(.user, "x")])
        XCTAssertTrue(withGoal.contains("主对话的目标：发布"))
        let blank = SideChatContext.systemPrompt(title: "t", goal: "  ", transcript: [message(.user, "x")])
        XCTAssertFalse(blank.contains("主对话的目标"))
    }

    func testEmptyThreadSaysSo() {
        let prompt = SideChatContext.systemPrompt(title: "t", goal: nil, transcript: [message(.assistant, "")])
        XCTAssertTrue(prompt.contains("主对话还没有内容"))
        XCTAssertFalse(prompt.contains("主对话内容："))
    }

    func testOverLimitKeepsNewestAndCountsTheRest() {
        let transcript = (1...5).map { message(.user, "第\($0)条" + String(repeating: "字", count: 10)) }
        // Each entry is "用户：第N条" + 10 chars = 16 characters; room for two.
        let prompt = SideChatContext.systemPrompt(title: "t", goal: nil, transcript: transcript, limit: 35)
        XCTAssertTrue(prompt.contains("第5条"))
        XCTAssertTrue(prompt.contains("第4条"))
        XCTAssertFalse(prompt.contains("第3条"), "超出预算的旧消息整条丢掉")
        XCTAssertTrue(prompt.contains("（更早的 3 条消息已省略）"))
    }

    func testNewestMessageAloneOverLimitKeepsItsEnd() {
        let long = "开头" + String(repeating: "中", count: 50) + "结尾问题"
        let prompt = SideChatContext.systemPrompt(title: "t", goal: nil, transcript: [
            message(.user, "更早的"),
            message(.assistant, long),
        ], limit: 20)
        XCTAssertTrue(prompt.contains("结尾问题"), "保留最后一段")
        XCTAssertFalse(prompt.contains("开头"))
        XCTAssertTrue(prompt.contains("（更早的 1 条消息已省略）"))
    }
}
