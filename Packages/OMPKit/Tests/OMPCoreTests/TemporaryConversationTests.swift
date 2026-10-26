import XCTest
@testable import OMPCore

/// Temporary chats are not persisted and are not part of history; they need
/// their own list or they vanish from the UI as soon as they are deselected.
final class TemporaryConversationTests: XCTestCase {
    func testTemporaryFlagIsDecodedWithADefault() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","title":"x","parts":[]}
        """
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertFalse(conversation.isTemporary, "旧文档没有这个字段时按非临时处理")
    }

    func testTemporaryChatsAreHiddenFromHistoryAndSearch() {
        var temporary = Conversation(title: "临时")
        temporary.isTemporary = true
        temporary.messages = [ChatMessage(role: .user, parts: [.text("秘密")])]
        XCTAssertFalse(ConversationPriority.wantsAttention(temporary, streamingID: nil), "临时对话不进待处理")
    }
}
