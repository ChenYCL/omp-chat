import XCTest
import OMPCore
@testable import OMPChatUI

@MainActor
final class MarkAllReadTests: XCTestCase {
    private func conversation(_ title: String, unread: Bool, archived: Bool = false) -> Conversation {
        var conversation = Conversation(title: title)
        conversation.hasUnread = unread
        conversation.isArchived = archived
        return conversation
    }

    func testMarkAllReadClearsUnreadAndPersists() async throws {
        let store = InMemoryConversationStore()
        let open = conversation("未读", unread: true)
        let read = conversation("已读", unread: false)
        try await store.save(open)
        try await store.save(read)
        let model = ChatAppModel(store: store, secrets: InMemorySecretStore())
        await model.bootstrap()

        model.markAllRead()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(model.conversations.map(\.hasUnread), [false, false])
        let persisted = try await store.loadAll()
        XCTAssertTrue(persisted.allSatisfy { !$0.hasUnread }, "清掉的未读要写回存储")
        XCTAssertEqual(Set(persisted.map(\.title)), ["未读", "已读"])
    }

    func testMarkAllReadLeavesArchivedUntouched() async throws {
        let store = InMemoryConversationStore()
        let archived = conversation("归档未读", unread: true, archived: true)
        let open = conversation("普通未读", unread: true)
        try await store.save(archived)
        try await store.save(open)
        let model = ChatAppModel(store: store, secrets: InMemorySecretStore())
        await model.bootstrap()

        model.markAllRead()
        try await Task.sleep(nanoseconds: 200_000_000)

        let archivedNow = model.conversations.first { $0.title == "归档未读" }
        XCTAssertEqual(archivedNow?.hasUnread, true, "归档的未读不动")
        XCTAssertEqual(model.conversations.first { $0.title == "普通未读" }?.hasUnread, false)
        let persisted = try await store.loadAll()
        XCTAssertEqual(persisted.first { $0.title == "归档未读" }?.hasUnread, true)
    }
}
