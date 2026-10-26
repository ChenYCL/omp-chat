import Foundation

/// Token usage aggregated over the workspace for the 用量 pages.
///
/// A request is one assistant message that carries `usage`, including earlier
/// replies kept in `alternativeReplies` after regenerating (they were billed
/// too). Reasoning tokens are a breakdown of output: OpenAI-compatible
/// `completion_tokens` already include `reasoning_tokens`, and Anthropic's
/// `output_tokens` include thinking, so the total is input + output.
public struct UsageSummary: Equatable, Sendable {
    public struct Totals: Equatable, Sendable {
        public var inputTokens = 0
        public var outputTokens = 0
        /// Part of `outputTokens`, not in addition to it.
        public var reasoningTokens = 0
        public var requests = 0

        public init() {}

        public var totalTokens: Int { inputTokens + outputTokens }

        mutating func add(_ usage: TokenUsage) {
            inputTokens += usage.inputTokens
            outputTokens += usage.outputTokens
            reasoningTokens += usage.reasoningTokens
            requests += 1
        }
    }

    public struct Day: Identifiable, Equatable, Sendable {
        /// Start of the local calendar day.
        public var date: Date
        public var totalTokens: Int
        public var id: Date { date }
    }

    public struct ConversationUsage: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var modelID: String?
        public var totals: Totals
    }

    /// Usage grouped by the conversation's current model; messages do not
    /// record which model produced them.
    public struct ModelUsage: Identifiable, Equatable, Sendable {
        /// nil when the conversation uses the default model.
        public var modelID: String?
        public var conversations: Int
        public var totals: Totals
        public var id: String { modelID ?? "" }
    }

    public static let dailyDays = 14

    public var all = Totals()
    /// Today and the six days before it, by message `createdAt`.
    public var last7Days = Totals()
    /// Today and the 29 days before it.
    public var last30Days = Totals()
    /// The last `dailyDays` local days, oldest first, zero-filled.
    public var daily: [Day] = []
    /// Conversations with usage, most tokens first.
    public var topConversations: [ConversationUsage] = []
    /// Models with usage, most tokens first.
    public var byModel: [ModelUsage] = []

    public init(conversations: [Conversation], now: Date = Date(), calendar: Calendar = .current, topLimit: Int = 5) {
        let today = calendar.startOfDay(for: now)
        func dayOffset(_ date: Date) -> Int? {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day
        }

        var dailyTokens = [Int](repeating: 0, count: Self.dailyDays)
        var perConversation: [ConversationUsage] = []
        var perModel: [String?: ModelUsage] = [:]

        for conversation in conversations {
            var totals = Totals()
            for message in conversation.messages + conversation.alternativeReplies {
                guard message.role == .assistant, let usage = message.usage else { continue }
                totals.add(usage)
                // Future-dated messages (clock skew) count toward all-time only.
                guard let offset = dayOffset(message.createdAt), offset >= 0 else { continue }
                if offset < 7 { last7Days.add(usage) }
                if offset < 30 { last30Days.add(usage) }
                if offset < Self.dailyDays { dailyTokens[Self.dailyDays - 1 - offset] += usage.inputTokens + usage.outputTokens }
            }
            guard totals.requests > 0 else { continue }
            all.inputTokens += totals.inputTokens
            all.outputTokens += totals.outputTokens
            all.reasoningTokens += totals.reasoningTokens
            all.requests += totals.requests
            perConversation.append(ConversationUsage(id: conversation.id, title: conversation.title, modelID: conversation.modelID, totals: totals))

            var group = perModel[conversation.modelID] ?? ModelUsage(modelID: conversation.modelID, conversations: 0, totals: Totals())
            group.conversations += 1
            group.totals.inputTokens += totals.inputTokens
            group.totals.outputTokens += totals.outputTokens
            group.totals.reasoningTokens += totals.reasoningTokens
            group.totals.requests += totals.requests
            perModel[conversation.modelID] = group
        }

        daily = dailyTokens.enumerated().map { index, tokens in
            let date = calendar.date(byAdding: .day, value: index - (Self.dailyDays - 1), to: today) ?? today
            return Day(date: date, totalTokens: tokens)
        }
        topConversations = Array(perConversation.sorted {
            $0.totals.totalTokens != $1.totals.totalTokens ? $0.totals.totalTokens > $1.totals.totalTokens : $0.title < $1.title
        }.prefix(max(0, topLimit)))
        byModel = perModel.values.sorted {
            $0.totals.totalTokens != $1.totals.totalTokens ? $0.totals.totalTokens > $1.totals.totalTokens : ($0.modelID ?? "") < ($1.modelID ?? "")
        }
    }
}
