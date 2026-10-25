import XCTest
@testable import OMPCore

/// One definition of "wants attention" for both sidebars: the 待处理 group
/// lists these, and every other section hides them.
final class ConversationPrioritySetTests: XCTestCase {
    private func conversation(_ title: String, unread: Bool = false,
                             archived: Bool = false, locked: Bool = false) -> Conversation {
        var conversation = Conversation(title: title)
        conversation.hasUnread = unread
        conversation.isArchived = archived
        conversation.isLocked = locked
        return conversation
    }

    func testUnreadAndAwaitingReplyWantAttention() {
        var waiting = conversation("等回复")
        waiting.messages = [ChatMessage(role: .user, parts: [.text("问")])]
        let plain = conversation("普通")
        let ids = ConversationPriority.ids(in: [conversation("未读", unread: true), waiting, plain], streamingID: nil)
        XCTAssertEqual(ids.count, 2, "未读和待回复都在待处理里")
        XCTAssertFalse(ids.contains(plain.id), "普通会话不在")
    }

    func testArchivedAndLockedStayOut() {
        let ids = ConversationPriority.ids(in: [
            conversation("归档未读", unread: true, archived: true),
            conversation("锁定未读", unread: true, locked: true),
        ], streamingID: nil)
        XCTAssertTrue(ids.isEmpty)
    }

    func testStreamingChatWantsAttention() {
        let streaming = conversation("正在生成")
        var other = conversation("未读", unread: true)
        let ids = ConversationPriority.ids(in: [streaming], streamingID: streaming.id)
        XCTAssertEqual(ids, [streaming.id])
        XCTAssertTrue(ConversationPriority.ids(in: [other], streamingID: nil).contains(other.id))
        other.hasUnread = false
        XCTAssertFalse(ConversationPriority.ids(in: [other], streamingID: nil).contains(other.id))
    }
}
