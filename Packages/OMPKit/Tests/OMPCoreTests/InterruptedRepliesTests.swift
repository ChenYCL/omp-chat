import XCTest
@testable import OMPCore

/// A reply saved mid-stream and then cut off by a kill or crash used to keep
/// its 正在思考 timer running after every relaunch.
final class InterruptedRepliesTests: XCTestCase {
    private func conversation(_ messages: [ChatMessage]) -> Conversation {
        var conversation = Conversation(title: "t")
        conversation.messages = messages
        return conversation
    }

    func testPartialReplyIsKeptAndMarkedIncomplete() {
        var c = conversation([
            ChatMessage(role: .user, parts: [.text("问")]),
            ChatMessage(role: .assistant, parts: [.text("答了一半")], status: .streaming),
        ])
        XCTAssertTrue(c.closeInterruptedReplies())
        XCTAssertEqual(c.messages[1].status, .complete, "已经收到的内容保留，和停止一样")
        XCTAssertEqual(c.messages[1].parts, [.text("答了一半")])
        XCTAssertEqual(c.messages[1].errorText, "应用退出时这条回复还没完成，内容可能不完整。")
    }

    func testEmptyReplyFails() {
        var c = conversation([ChatMessage(role: .assistant, parts: [], status: .pending)])
        XCTAssertTrue(c.closeInterruptedReplies())
        XCTAssertEqual(c.messages[0].status, .failed, "什么都没收到的回复算失败，才能重新生成")
        XCTAssertEqual(c.messages[0].errorText, "应用退出时这条回复还没有内容。")
    }

    func testFinishedMessagesAreUntouched() {
        let done = ChatMessage(role: .assistant, parts: [.text("好")])
        let failed = ChatMessage(role: .assistant, parts: [], status: .failed, errorText: "网关 502")
        var c = conversation([done, failed])
        XCTAssertFalse(c.closeInterruptedReplies(), "没有中断的回复就不该重写这份会话")
        XCTAssertEqual(c.messages, [done, failed])
    }

    func testAnExistingNoteIsKept() {
        var c = conversation([ChatMessage(role: .assistant, parts: [.text("x")], status: .streaming, errorText: "已达到上限")])
        XCTAssertTrue(c.closeInterruptedReplies())
        XCTAssertEqual(c.messages[0].errorText, "已达到上限")
    }
}
