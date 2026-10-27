import XCTest
@testable import OMPCore

/// The pure deletion decision: archived chats first, then the keep count,
/// never a pinned or streaming chat's worktree, always deterministic.
final class WorktreeCleanupTests: XCTestCase {
    private func item(_ id: String, minutesAgo: Int, conversations: UUID...) -> WorktreeCleanup.Item {
        WorktreeCleanup.Item(
            id: UUID(uuidString: id)!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_000_000 - minutesAgo * 60)),
            conversationIDs: Set(conversations)
        )
    }

    private var a: UUID { UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")! }
    private var b: UUID { UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")! }

    func testArchivedWorktreesGoFirstOldestFirst() {
        let chat1 = UUID()
        let chat2 = UUID()
        let old = item("AAAAAAAA-0000-0000-0000-000000000001", minutesAgo: 100, conversations: chat1)
        let new = item("AAAAAAAA-0000-0000-0000-000000000002", minutesAgo: 10, conversations: chat2)
        let chats = [
            WorktreeCleanup.Chat(id: chat1, isArchived: true),
            WorktreeCleanup.Chat(id: chat2, isArchived: true),
        ]
        // Archived chats delete eagerly (official: worktrees go when the
        // associated chat is archived), oldest first, whatever the limit.
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: [new, old], conversations: chats, streamingConversationID: nil, autoCleanup: true, keepCount: 15),
            [old.id, new.id]
        )
        // Over the limit, the archived ones (oldest first) are exactly what
        // the overflow takes.
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: [new, old], conversations: chats, streamingConversationID: nil, autoCleanup: true, keepCount: 1),
            [old.id]
        )
    }

    func testLimitOnlyBeyondCount() {
        let ids = (1...3).map { UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000\($0)")! }
        let items = ids.enumerated().map { index, id in
            WorktreeCleanup.Item(id: id, createdAt: Date(timeIntervalSince1970: TimeInterval(1_000_000 + index * 60)), conversationIDs: [])
        }
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: items, conversations: [], streamingConversationID: nil, autoCleanup: true, keepCount: 2),
            [ids[0]],
            "3 个里只删最老的 1 个"
        )
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: items, conversations: [], streamingConversationID: nil, autoCleanup: true, keepCount: 3),
            [],
            "没有超出就不删"
        )
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: items, conversations: [], streamingConversationID: nil, autoCleanup: true, keepCount: 0),
            ids,
            "保留数量 0 时全删，最老的在前"
        )
    }

    func testPinnedChatProtectsItsWorktree() {
        let pinned = UUID()
        let item = WorktreeCleanup.Item(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), conversationIDs: [pinned])
        let chats = [WorktreeCleanup.Chat(id: pinned, isPinned: true, isArchived: true)]
        XCTAssertTrue(WorktreeCleanup.isProtected(item, conversations: chats, streamingConversationID: nil))
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: [item], conversations: chats, streamingConversationID: nil, autoCleanup: true, keepCount: 0),
            [],
            "置顶对话的 worktree 即使归档了也不删"
        )
    }

    func testStreamingChatProtectsItsWorktree() {
        let running = UUID()
        let item = WorktreeCleanup.Item(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), conversationIDs: [running])
        XCTAssertTrue(WorktreeCleanup.isProtected(item, conversations: [], streamingConversationID: running))
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: [item], conversations: [], streamingConversationID: running, autoCleanup: true, keepCount: 0),
            []
        )
    }

    func testSharedWorktreeNeedsEveryChatArchived() {
        let archived = UUID()
        let active = UUID()
        let item = WorktreeCleanup.Item(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), conversationIDs: [archived, active])
        let chats = [
            WorktreeCleanup.Chat(id: archived, isArchived: true),
            WorktreeCleanup.Chat(id: active),
        ]
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: [item], conversations: chats, streamingConversationID: nil, autoCleanup: true, keepCount: 0),
            [],
            "还有一个活跃对话共用时不删"
        )
    }

    func testDeletedChatsReleaseTheWorktree() {
        let gone = UUID()
        let item = WorktreeCleanup.Item(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), conversationIDs: [gone])
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: [item], conversations: [], streamingConversationID: nil, autoCleanup: true, keepCount: 0),
            [item.id],
            "对话已从历史删除时不拦着清理"
        )
    }

    func testSwitchOffStopsEverything() {
        let items = [item("AAAAAAAA-0000-0000-0000-000000000009", minutesAgo: 5)]
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: items, conversations: [], streamingConversationID: nil, autoCleanup: false, keepCount: 0),
            [],
            "自动删除关掉后归档与超限都不删"
        )
    }

    func testProtectedWorktreesDoNotMakeRoom() {
        // 20 个 worktree，19 个挂着置顶对话：上限 15 也不能删第 20 个之外的。
        let pinned = UUID()
        var items: [WorktreeCleanup.Item] = []
        for index in 1...19 {
            items.append(item(
                String(format: "AAAAAAAA-0000-0000-0000-%012d", index),
                minutesAgo: 200 - index,
                conversations: pinned
            ))
        }
        items.append(item("AAAAAAAA-0000-0000-0000-000000000020", minutesAgo: 5))
        let chats = [WorktreeCleanup.Chat(id: pinned, isPinned: true)]
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: items, conversations: chats, streamingConversationID: nil, autoCleanup: true, keepCount: 15),
            [items[19].id],
            "受保护的不给新的腾位置，只删能删的"
        )
    }

    func testEqualDatesBreakTiesByID() {
        let when = Date(timeIntervalSince1970: 500)
        let first = WorktreeCleanup.Item(id: a, createdAt: when, conversationIDs: [])
        let second = WorktreeCleanup.Item(id: b, createdAt: when, conversationIDs: [])
        XCTAssertEqual(
            WorktreeCleanup.orderedDeletions(items: [second, first], conversations: [], streamingConversationID: nil, autoCleanup: true, keepCount: 1),
            [a],
            "创建时间相同按 id 定序，不依赖传入顺序"
        )
    }
}
