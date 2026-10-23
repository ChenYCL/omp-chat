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
        projectID: UUID? = nil
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
    }

    public var lastMessagePreview: String {
        guard let last = messages.last else { return "开始新的对话" }
        let text = last.concatenatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "附件消息" : text
    }
}
