import Foundation

/// How the sidebar, the phone drawer, the history sheet and the command palette
/// decide whether a conversation matches what was typed. Four copies of the same
/// two-field rule had drifted apart in casing handling; this is the one rule.
public enum ConversationSearch {
    /// True when the trimmed query is empty, or the title or last-message
    /// preview contains it case-insensitively.
    public static func matches(_ conversation: Conversation, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return conversation.title.range(of: trimmed, options: .caseInsensitive) != nil
            || conversation.lastMessagePreview.range(of: trimmed, options: .caseInsensitive) != nil
    }

    public static func filter(_ conversations: [Conversation], query: String) -> [Conversation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return conversations }
        return conversations.filter { matches($0, query: trimmed) }
    }
}
