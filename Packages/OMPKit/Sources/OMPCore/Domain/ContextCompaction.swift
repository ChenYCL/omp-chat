import Foundation

/// A summary standing in for a thread's earlier messages (Codex context
/// compaction). Requests send the summary instead of every message up to and
/// including `coveredThroughID`; the transcript still shows them all.
public struct ConversationCompaction: Codable, Hashable, Sendable {
    public var id: UUID
    public var summary: String
    /// The last message the summary covers.
    public var coveredThroughID: UUID
    public var createdAt: Date
    /// Estimated request size before and after this compaction.
    public var tokensBefore: Int
    public var tokensAfter: Int

    /// Whether sending the summary instead of the turns it covers makes the
    /// request smaller; one that does not is not worth applying.
    public var shrinksRequest: Bool { tokensAfter < tokensBefore }

    public init(
        id: UUID = UUID(),
        summary: String,
        coveredThroughID: UUID,
        createdAt: Date = Date(),
        tokensBefore: Int = 0,
        tokensAfter: Int = 0
    ) {
        self.id = id
        self.summary = summary
        self.coveredThroughID = coveredThroughID
        self.createdAt = createdAt
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        coveredThroughID = try container.decode(UUID.self, forKey: .coveredThroughID)
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        tokensBefore = (try? container.decodeIfPresent(Int.self, forKey: .tokensBefore)) ?? 0
        tokensAfter = (try? container.decodeIfPresent(Int.self, forKey: .tokensAfter)) ?? 0
    }
}

/// Where a thread may be compacted, what a compacted thread sends, and the
/// summarisation request. Pure: the app model runs the request and stores
/// the result.
public enum ContextCompaction {
    /// Compaction starts on its own before a request once the estimate
    /// reaches this share of the model's context window.
    public static let autoThreshold = 0.85
    /// The newest turns (a user message and everything after it) always
    /// go verbatim.
    public static let keptTurns = 2
    /// Opens the message that carries the summary.
    public static let summaryLead = "以下是此前对话的摘要："
    /// Longest summary asked for.
    public static let summaryOutputTokens = 4_096
    /// Per-call caps in the transcript the summariser reads; tool traffic is
    /// most of a long agent thread.
    static let argumentsCap = 1_000
    static let outputCap = 2_000

    public static let instructions = """
    你负责压缩一段很长的对话。把用户给出的对话记录整理成一份摘要，之后它会代替这些原始消息，交给同一个助手继续工作，所以要让助手不看原文也能接着做下去。
    必须保留：用户的目标和要求、已经做出的决定及理由、已完成和未完成的工作、提到的文件路径、命令、关键代码片段和数值、遇到的错误和处理方式、还没回答的问题。
    省略寒暄和重复内容。记录里如果有此前的摘要，把它和新内容合成一份完整的摘要。
    只输出摘要正文，用对话所用的语言，不要加开场白。
    """

    // MARK: Estimates

    /// Rough token estimate: CJK ≈ 1 token per character, other text ≈ 1
    /// token per 4 characters.
    public static func estimatedTokens(_ text: String) -> Int {
        var counter = Counter()
        counter.add(text)
        return counter.tokens
    }

    /// What a message costs in a request: its text, tool calls and tool
    /// results. Thinking is left out; earlier turns' thinking is not resent.
    public static func estimatedTokens(_ message: ChatMessage) -> Int {
        var counter = Counter()
        for part in message.parts {
            switch part {
            case .text(let value):
                counter.add(value)
            case .toolCall(let call):
                counter.add(call.name)
                counter.add(call.argumentsJSON)
            case .toolResult(let result):
                counter.add(result.outputText)
            case .thinking, .thinkingSeal, .media:
                break
            }
        }
        return counter.tokens
    }

    public static func estimatedTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimatedTokens($1) }
    }

    /// The estimate of what the next request of this thread sends.
    public static func estimatedTokens(of conversation: Conversation) -> Int {
        estimatedTokens(requestMessages(conversation.messages, compaction: conversation.compaction))
    }

    /// One pass over the scalars, no grapheme breaking: the context meter
    /// re-reads every tool output on each render.
    private struct Counter {
        var wide = 0
        var scalars = 0

        mutating func add(_ text: String) {
            for scalar in text.unicodeScalars {
                scalars += 1
                if scalar.value > 0x2E80 { wide += 1 }
            }
        }

        var tokens: Int { wide + (scalars - wide) / 4 }
    }

    // MARK: Requests

    /// Index of the compaction's last covered message, or nil when it no
    /// longer applies: that message was deleted, or an edit cut it off.
    public static func coveredIndex(of compaction: ConversationCompaction?, in messages: [ChatMessage]) -> Int? {
        guard let compaction else { return nil }
        return messages.lastIndex { $0.id == compaction.coveredThroughID }
    }

    /// The history a request sends: the summary message, then the messages
    /// after the covered one. Without an applicable compaction, everything.
    public static func requestMessages(_ history: [ChatMessage], compaction: ConversationCompaction?) -> [ChatMessage] {
        guard let compaction, let covered = coveredIndex(of: compaction, in: history) else { return history }
        return [summaryMessage(compaction)] + history[(covered + 1)...]
    }

    /// The user message carrying the summary.
    public static func summaryMessage(_ compaction: ConversationCompaction) -> ChatMessage {
        ChatMessage(
            id: compaction.id,
            role: .user,
            parts: [.text(summaryLead + "\n\n" + compaction.summary)],
            createdAt: compaction.createdAt
        )
    }

    // MARK: Boundary

    /// Index of the first message a new compaction keeps verbatim, or nil
    /// when nothing is old enough. The cut is always at a user message, at
    /// least `keepingTurns` turns from the end and after what `previous`
    /// already covers, and never where it would leave a kept tool result
    /// without its call.
    public static func boundary(
        in messages: [ChatMessage],
        after previous: ConversationCompaction?,
        keepingTurns: Int = keptTurns
    ) -> Int? {
        let floor = coveredIndex(of: previous, in: messages).map { $0 + 1 } ?? 0
        let starts = messages.indices.filter { messages[$0].role == .user }
        var candidate = starts.count - max(1, keepingTurns)
        // Walks to earlier turns only; ends at the first turn or the floor.
        while candidate >= 0 {
            let cut = starts[candidate]
            guard cut > floor else { return nil }
            if !orphansToolResult(messages, at: cut) { return cut }
            candidate -= 1
        }
        return nil
    }

    /// Whether cutting before `cut` leaves a kept tool result whose call
    /// would be summarised away. Matching is within the kept part first, so
    /// providers that reuse call ids across turns still compact.
    static func orphansToolResult(_ messages: [ChatMessage], at cut: Int) -> Bool {
        var keptCalls: Set<String> = []
        var keptResults: Set<String> = []
        for message in messages[cut...] {
            for part in message.parts {
                switch part {
                case .toolCall(let call): keptCalls.insert(call.id)
                case .toolResult(let result): keptResults.insert(result.callID)
                default: break
                }
            }
        }
        let loose = keptResults.subtracting(keptCalls)
        guard !loose.isEmpty else { return false }
        return messages[..<cut].contains { message in
            message.parts.contains { part in
                if case .toolCall(let call) = part { loose.contains(call.id) } else { false }
            }
        }
    }

    /// Whether to compact before the next request: the estimate has reached
    /// `autoThreshold` of the window and something is old enough.
    public static func shouldAutoCompact(
        _ messages: [ChatMessage],
        compaction: ConversationCompaction?,
        contextWindow: Int?
    ) -> Bool {
        guard let window = contextWindow, window > 0 else { return false }
        let used = estimatedTokens(requestMessages(messages, compaction: compaction))
        guard Double(used) >= Double(window) * autoThreshold else { return false }
        return boundary(in: messages, after: compaction) != nil
    }

    // MARK: Summarising

    /// The one request that writes the summary: no tools, no thinking. It
    /// reads the earlier summary (when it still applies) plus the messages
    /// from there up to `boundary`, as a plain transcript, so no provider
    /// sees tool blocks without tools or thinking it cannot verify.
    public static func summaryRequest(
        modelID: String,
        messages: [ChatMessage],
        boundary: Int,
        previous: ConversationCompaction?,
        contextWindow: Int?,
        maxOutputTokens: Int?
    ) -> GenerationRequest {
        let covered = coveredIndex(of: previous, in: messages)
        let floor = covered.map { $0 + 1 } ?? 0
        let output = min(maxOutputTokens ?? summaryOutputTokens, summaryOutputTokens)
        // Leave the summariser room for its answer even when the thread
        // already fills most of the window.
        let budget = contextWindow.map { max(1_000, Int(Double($0) * 0.7) - output) }
        let text = transcript(
            Array(messages[floor..<max(floor, boundary)]),
            previousSummary: covered == nil ? nil : previous?.summary,
            budgetTokens: budget
        )
        return GenerationRequest(
            modelID: modelID,
            messages: [ChatMessage(role: .user, parts: [.text(text)])],
            systemPrompt: instructions,
            maxOutputTokens: output
        )
    }

    /// The compaction a finished summary makes, with its estimates.
    /// `boundary` comes from `boundary(in:after:)` over the same messages.
    public static func compaction(
        summary: String,
        messages: [ChatMessage],
        boundary: Int,
        previous: ConversationCompaction?,
        createdAt: Date = Date()
    ) -> ConversationCompaction {
        let before = estimatedTokens(requestMessages(messages, compaction: previous))
        var made = ConversationCompaction(
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            coveredThroughID: messages[boundary - 1].id,
            createdAt: createdAt,
            tokensBefore: before
        )
        made.tokensAfter = estimatedTokens(requestMessages(messages, compaction: made))
        return made
    }

    /// The summariser's input. Over `budgetTokens` the oldest messages drop
    /// out first; the earlier summary and the newest message always stay.
    static func transcript(_ messages: [ChatMessage], previousSummary: String?, budgetTokens: Int?) -> String {
        let entries = messages.compactMap(entry)
        let costs = entries.map(estimatedTokens)
        var start = 0
        if let budgetTokens {
            var total = costs.reduce(0, +) + (previousSummary.map(estimatedTokens) ?? 0)
            while start < entries.count - 1, total > budgetTokens {
                total -= costs[start]
                start += 1
            }
        }
        var sections: [String] = []
        if let previousSummary, !previousSummary.isEmpty {
            sections.append("【此前的摘要】\n\(previousSummary)")
        }
        if start > 0 {
            sections.append("（更早的 \(start) 条消息太长，已省略）")
        }
        sections.append(contentsOf: entries[start...])
        return "以下是需要压缩的对话记录：\n\n" + sections.joined(separator: "\n\n") + "\n\n请输出摘要。"
    }

    private static func entry(_ message: ChatMessage) -> String? {
        var lines: [String] = []
        var text = ""
        func flushText() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append((message.role == .user ? "【用户】" : "【助手】") + trimmed) }
            text = ""
        }
        for part in message.parts {
            switch part {
            case .text(let value):
                text += value
            case .media(let ref):
                text += "[附件：\(ref.originalName ?? ref.kind.rawValue)]"
            case .toolCall(let call):
                flushText()
                lines.append("【调用工具 \(call.name)】\(capped(call.argumentsJSON, argumentsCap))")
            case .toolResult(let result):
                flushText()
                let mark = result.isError ? "（出错）" : ""
                lines.append("【工具结果 \(result.name)】\(mark)\(capped(result.outputText, outputCap))")
            case .thinking, .thinkingSeal:
                break
            }
        }
        flushText()
        guard message.role != .system, !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func capped(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…（已截断）"
    }
}
