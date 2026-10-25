import Foundation

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var providerID: UUID?
    public var modelID: String?
    public var systemPrompt: String?
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    /// Project this conversation belongs to; nil means ungrouped.
    public var projectID: UUID?
    /// Locked chats stay in the account but are hidden from history, pinned
    /// lists and search until unlocked (ChatGPT locked chats, Oct 2026).
    public var isLocked: Bool
    /// Temporary chats are not saved to history and vanish on close.
    public var isTemporary: Bool
    /// Per-conversation reasoning effort override: low / medium / high.
    public var reasoningEffort: String?
    /// Earlier assistant replies kept when regenerating the last answer.
    public var alternativeReplies: [ChatMessage] = []
    /// Manual order within a sidebar section; nil keeps the date ordering.
    public var sortIndex: Int? = nil
    /// Whether this conversation has an unread response from a background stream.
    public var hasUnread: Bool = false
    public init(
        id: UUID = UUID(),
        title: String = "新对话",
        providerID: UUID? = nil,
        modelID: String? = nil,
        systemPrompt: String? = nil,
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        isArchived: Bool = false,
        projectID: UUID? = nil,
        isLocked: Bool = false,
        isTemporary: Bool = false,
        reasoningEffort: String? = nil,
        hasUnread: Bool = false
    ) {
        self.id = id
        self.title = title
        self.providerID = providerID
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.projectID = projectID
        self.isLocked = isLocked
        self.isTemporary = isTemporary
        self.reasoningEffort = reasoningEffort
        self.hasUnread = hasUnread
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "新对话"
        providerID = try container.decodeIfPresent(UUID.self, forKey: .providerID)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isTemporary = try container.decodeIfPresent(Bool.self, forKey: .isTemporary) ?? false
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        alternativeReplies = try container.decodeIfPresent([ChatMessage].self, forKey: .alternativeReplies) ?? []
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex)
        hasUnread = (try? container.decodeIfPresent(Bool.self, forKey: .hasUnread)) ?? false
    }


    /// True when the conversation is waiting on an answer: the newest message
    /// is the user's, or the reply failed. Drives the sidebar's 待处理 group.
    public var needsReply: Bool {
        guard let last = messages.last, !isTemporary else { return false }
        if last.role == .user { return true }
        return last.role == .assistant && last.status == .failed
    }

    public var lastMessagePreview: String {
        guard let last = messages.last else { return "开始新的对话" }
        let text = last.concatenatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "附件消息" }
        let stripped = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        return stripped
    }
}
