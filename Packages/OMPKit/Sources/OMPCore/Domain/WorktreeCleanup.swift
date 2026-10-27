import Foundation

/// Where a handoff moves a chat: the source checkout ("Local") or the chat's
/// associated managed worktree (official Codex `localConversation.moveTo*`).
public enum HandoffDestination: String, Sendable, CaseIterable {
    case local
    case worktree

    public var title: String {
        switch self {
        case .local: return "交接到本地"
        case .worktree: return "交接到 Worktree"
        }
    }
}

/// Which managed worktrees to delete, decided purely from state (official
/// Codex `settings.worktrees.*`, "Worktree cleanup" in the docs).
///
/// Codex-managed worktrees are deleted automatically when
/// - their chat is archived (a worktree several chats share only once all of
///   those chats are archived), or
/// - the oldest ones have to go to stay within the keep count.
/// A worktree tied to a pinned chat or a chat whose reply is running is never
/// deleted. Order is deterministic: archived-first (oldest creation date
/// first), then the rest oldest first; equal creation dates fall back to the
/// id, so the decision never depends on dictionary or file order.
public enum WorktreeCleanup {

    /// One registry entry reduced to what the decision reads. `ManagedWorktree`
    /// maps into this; keeping it separate makes the policy testable without
    /// persistence and immune to registry field additions.
    public struct Item: Sendable, Equatable {
        public var id: UUID
        public var createdAt: Date
        /// Chats bound to the worktree, any order.
        public var conversationIDs: Set<UUID>

        public init(id: UUID, createdAt: Date, conversationIDs: Set<UUID>) {
            self.id = id
            self.createdAt = createdAt
            self.conversationIDs = conversationIDs
        }
    }

    /// One chat's state, reduced the same way.
    public struct Chat: Sendable, Equatable {
        public var id: UUID
        public var isPinned: Bool
        public var isArchived: Bool

        public init(id: UUID, isPinned: Bool = false, isArchived: Bool = false) {
            self.id = id
            self.isPinned = isPinned
            self.isArchived = isArchived
        }
    }

    /// A worktree may be deleted at all: every linked chat exists, none is
    /// pinned and none is streaming. Missing chats (deleted from history)
    /// release the worktree.
    public static func isProtected(
        _ item: Item,
        conversations: [Chat],
        streamingConversationID: UUID?
    ) -> Bool {
        for id in item.conversationIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            if id == streamingConversationID { return true }
            guard let chat = conversations.first(where: { $0.id == id }) else { continue }
            if chat.isPinned { return true }
        }
        return false
    }

    /// Every live worktree the automatic cleanup may delete right now, in the
    /// order they should go. `autoCleanup == false` stops everything: the
    /// settings switch means "manage disk usage myself", so neither the keep
    /// count nor the archive hook acts.
    ///
    /// `keepCount` counts live worktrees, protected ones included — Codex
    /// keeps *the most recent 15*; protection delays an old worktree's
    /// deletion without making room for a newer one.
    public static func orderedDeletions(
        items: [Item],
        conversations: [Chat],
        streamingConversationID: UUID?,
        autoCleanup: Bool,
        keepCount: Int
    ) -> [UUID] {
        guard autoCleanup, !items.isEmpty else { return [] }
        let sorted = items.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        // Archived chats first: their worktree is done serving anything (an
        // empty conversation list counts as released — nothing is left to
        // serve). These go whether or not the keep count is exceeded.
        var deletable: [Item] = []
        var kept: [Item] = []
        for item in sorted {
            if isProtected(item, conversations: conversations, streamingConversationID: streamingConversationID) {
                kept.append(item)
                continue
            }
            if !item.conversationIDs.isEmpty, !item.conversationIDs.allSatisfy({ id in
                // A chat missing from history has released the worktree, so
                // only a chat that exists AND is not archived keeps it.
                let chat = conversations.first(where: { $0.id == id })
                return chat == nil || chat?.isArchived == true
            }) {
                kept.append(item)
                continue
            }
            deletable.append(item)
        }
        // Then the keep count caps the deletions — BUT an archived chat's
        // worktree is deleted eagerly (official: "Codex-managed worktrees are
        // deleted automatically when you archive the associated chat"),
        // regardless of the limit. Protected worktrees never entered
        // `deletable`. Order stays oldest-first across both reasons.
        let overflow = max(0, sorted.count - max(0, keepCount))
        guard overflow > 0 else {
            // Archive reason only: every worktree whose chats are all
            // archived — or whose chats have all left the history — goes,
            // even under the limit. A worktree with no chat at all is kept
            // until the limit takes it.
            return deletable.filter { item in
                !item.conversationIDs.isEmpty && item.conversationIDs.allSatisfy { id in
                    let chat = conversations.first(where: { $0.id == id })
                    return chat == nil || chat?.isArchived == true
                }
            }.map(\.id)
        }
        return Array(deletable.prefix(min(overflow, deletable.count))).map(\.id)
    }
}
