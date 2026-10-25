import XCTest
@testable import OMPCore

/// The sidebar's 待处理 group is driven by these two flags; both are computed
/// from stored state, so the rules are checked here rather than in the UI.
final class ConversationPriorityTests: XCTestCase {
    private func conversation(_ roles: [(MessageRole, MessageStatus)]) -> Conversation {
        var conversation = Conversation(title: "t")
        conversation.messages = roles.map { role, status in
            ChatMessage(role: role, parts: [.text("x")], status: status)
        }
        return conversation
    }

    func testUserTailNeedsAReply() {
        XCTAssertTrue(conversation([(.user, .complete), (.assistant, .complete), (.user, .complete)]).needsReply,
                      "最后一条是用户发言，说明还在等回复")
    }

    func testFinishedReplyDoesNotNeedOne() {
        XCTAssertFalse(conversation([(.user, .complete), (.assistant, .complete)]).needsReply)
        XCTAssertFalse(conversation([]).needsReply, "空会话不算待回复")
    }

    func testFailedReplyNeedsAReply() {
        XCTAssertTrue(conversation([(.user, .complete), (.assistant, .failed)]).needsReply,
                      "回复失败要让人看到")
    }

    func testTemporaryConversationsStayOutOfTheQueue() {
        var temporary = conversation([(.user, .complete)])
        temporary.isTemporary = true
        XCTAssertFalse(temporary.needsReply, "临时对话不进待处理")
    }
}
