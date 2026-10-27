import Foundation

/// One status tag a conversation row can carry (Codex `codex.localTaskRow.*`).
/// Declared in precedence order: the first tag that applies is the row's
/// primary tag. Raw values are the official keys; they also travel to a
/// paired phone as `RelayConversation.status`.
public enum ConversationRowTag: String, CaseIterable, Codable, Sendable {
    /// An approval card waits in this thread (`awaitingApproval`).
    case awaitingApproval
    /// The thread waits on the user: follow-ups held after 停止, or a
    /// follow-up the reply ended without answering (`needsInput`).
    case needsInput
    /// The newest message is a reply that failed (`systemError`).
    case systemError
    /// A scheduled task run created this thread (`automation`).
    case automation
    /// A scheduled task sends its runs into this thread
    /// (`attachedHeartbeatAutomation`).
    case attachedAutomation = "attachedHeartbeatAutomation"

    /// The capsule text.
    public var title: String {
        switch self {
        case .awaitingApproval: "等待批准"
        case .needsInput: "需要你处理"
        case .systemError: "系统错误"
        case .automation: "定时任务运行"
        case .attachedAutomation: "已附加定时任务"
        }
    }

    /// The full sentence VoiceOver reads (official default messages).
    public var accessibilityLabel: String {
        switch self {
        case .awaitingApproval: "等待你批准工具调用"
        case .needsInput: "需要你处理排队或未回复的消息"
        case .systemError: "对话遇到系统错误"
        case .automation: "由定时任务运行创建"
        case .attachedAutomation: "已附加定时任务"
        }
    }

    public var systemImage: String {
        switch self {
        case .awaitingApproval: "exclamationmark.shield"
        case .needsInput: "hand.raised"
        case .systemError: "exclamationmark.triangle"
        case .automation: "clock"
        case .attachedAutomation: "clock.arrow.circlepath"
        }
    }

    /// Blocking tags ask the user to act; at most one shows (the highest).
    /// Task tags are provenance and accompany whatever else applies.
    public var isBlocking: Bool {
        switch self {
        case .awaitingApproval, .needsInput, .systemError: true
        case .automation, .attachedAutomation: false
        }
    }
}

/// What a sidebar row shows beside the title: one primary tag and the
/// provenance tags that may show with it.
///
/// Precedence: 等待批准 > 需要你处理 > 系统错误 > 定时任务运行 > 已附加定时任务.
/// Only the highest blocking tag is kept (an approval card hides an older
/// failure); both task tags are kept, after it.
public struct ConversationRowStatus: Equatable, Sendable {
    /// Live facts the model holds about one conversation; nothing here is
    /// persisted.
    public struct Facts: Equatable, Sendable {
        /// An approval card for this conversation is waiting.
        public var hasPendingApproval: Bool
        /// This conversation's reply is streaming or its context is being
        /// compacted: it is working, so it does not wait on the user.
        public var isBusy: Bool
        /// The task that created this conversation still exists.
        public var originTaskIsLive: Bool
        /// The first existing task whose target is this conversation.
        public var attachedTaskID: UUID?

        public init(hasPendingApproval: Bool = false, isBusy: Bool = false,
                    originTaskIsLive: Bool = false, attachedTaskID: UUID? = nil) {
            self.hasPendingApproval = hasPendingApproval
            self.isBusy = isBusy
            self.originTaskIsLive = originTaskIsLive
            self.attachedTaskID = attachedTaskID
        }
    }

    /// Note the reply loop puts on a follow-up it took in and then ended
    /// without answering (Codex `responseError.unansweredSteering`).
    public static let unansweredFollowUpNote = "你的追问没有收到回复，请重试"

    public static let none = ConversationRowStatus(tags: [], taskID: nil)

    /// Tags in precedence order; the first is the primary one.
    public let tags: [ConversationRowTag]
    /// The live scheduled task this row links to, for 「打开定时任务」: the
    /// task that created it when that task still exists, else the task
    /// attached to it. Nil once every linked task is deleted, while the
    /// 定时任务运行 tag stays (it is history).
    public let taskID: UUID?

    public init(tags: [ConversationRowTag], taskID: UUID?) {
        self.tags = tags
        self.taskID = taskID
    }

    public init(_ conversation: Conversation, facts: Facts) {
        var tags: [ConversationRowTag] = []
        if facts.hasPendingApproval {
            tags.append(.awaitingApproval)
        } else if !facts.isBusy, Self.needsInput(conversation) {
            tags.append(.needsInput)
        } else if !facts.isBusy, Self.endsInFailure(conversation) {
            tags.append(.systemError)
        }
        if conversation.scheduledTaskID != nil { tags.append(.automation) }
        if facts.attachedTaskID != nil { tags.append(.attachedAutomation) }
        self.tags = tags
        if let origin = conversation.scheduledTaskID, facts.originTaskIsLive {
            taskID = origin
        } else {
            taskID = facts.attachedTaskID
        }
    }

    public var primary: ConversationRowTag? { tags.first }
    public var secondary: ArraySlice<ConversationRowTag> { tags.dropFirst() }
    public var isBlocking: Bool { primary?.isBlocking ?? false }

    /// Follow-ups held after 停止 or a relaunch, or the newest user message
    /// carries the unanswered note.
    public static func needsInput(_ conversation: Conversation) -> Bool {
        if conversation.queuedMessages.contains(where: \.isHeld) { return true }
        guard let lastUser = conversation.messages.last(where: { $0.role == .user }) else { return false }
        return lastUser.errorText == unansweredFollowUpNote
    }

    /// The newest message is an assistant reply that failed; a newer reply
    /// or user message clears it.
    public static func endsInFailure(_ conversation: Conversation) -> Bool {
        guard let last = conversation.messages.last else { return false }
        return last.role == .assistant && last.status == .failed
    }
}
