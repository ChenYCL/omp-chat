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
    /// Directory this thread works in (Official Codex `threadHeader.workingDirectory`).
    /// Nil means "wherever the app is", which is what older documents mean.
    public var workingDirectory: String?
    /// What this thread is trying to achieve (Official Codex
    /// `composer.threadGoal`). Nil means no goal; older documents have none.
    public var goal: String?
    /// `PermissionMode` raw value for this thread's tool calls; nil follows
    /// `AppSettings.defaultPermissionMode`.
    public var permissionMode: String? = nil
    /// Whether the model is offered tools here; nil means automatic: offered
    /// when the thread has a working directory.
    public var toolsEnabled: Bool? = nil
    /// A 「用 Codex 审查」 thread: its findings live only in this chat (official
    /// `codeReviewPlugin.manualReview.chatOnlyDisclosure`). Older documents
    /// have none.
    public var isCodeReview: Bool = false
    /// Follow-ups sent while a reply ran here, oldest first. Saved with the
    /// thread so a quit or crash does not lose what the user typed; nothing
    /// runs at launch, so they wait (held) until the user sends them.
    public var queuedMessages: [QueuedMessage] = []
    /// The summary requests send in place of the earlier messages; nil
    /// until the thread is compacted.
    public var compaction: ConversationCompaction? = nil
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
        hasUnread: Bool = false,
        workingDirectory: String? = nil,
        goal: String? = nil
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
        self.workingDirectory = workingDirectory
        self.goal = goal
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
        workingDirectory = try? container.decodeIfPresent(String.self, forKey: .workingDirectory)
        goal = try? container.decodeIfPresent(String.self, forKey: .goal)
        permissionMode = try? container.decodeIfPresent(String.self, forKey: .permissionMode)
        toolsEnabled = try? container.decodeIfPresent(Bool.self, forKey: .toolsEnabled)
        isCodeReview = (try? container.decodeIfPresent(Bool.self, forKey: .isCodeReview)) ?? false
        queuedMessages = (try? container.decodeIfPresent([QueuedMessage].self, forKey: .queuedMessages)) ?? []
        compaction = try? container.decodeIfPresent(ConversationCompaction.self, forKey: .compaction)
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

/// Which chats want attention. One definition for both sidebars: the 待处理
/// group lists these, and every other section hides them, so a chat cannot
/// appear twice.
public enum ConversationPriority {
    public static func wantsAttention(_ conversation: Conversation, streamingID: UUID?) -> Bool {
        guard !conversation.isArchived, !conversation.isLocked else { return false }
        return conversation.hasUnread
            || conversation.id == streamingID
            || conversation.needsReply
    }

    public static func ids(in conversations: [Conversation], streamingID: UUID?) -> Set<UUID> {
        Set(conversations.filter { wantsAttention($0, streamingID: streamingID) }.map(\.id))
    }
}
