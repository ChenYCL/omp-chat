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
        isTemporary: Bool = false
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
