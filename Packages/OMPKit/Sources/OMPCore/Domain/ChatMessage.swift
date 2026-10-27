import Foundation

public enum MessageRole: String, Codable, Hashable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public enum MessageStatus: String, Codable, Hashable, Sendable {
    case pending
    case streaming
    case complete
    case failed
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var parts: [ContentPart]
    public var status: MessageStatus
    public var createdAt: Date
    public var errorText: String?
    public var usage: TokenUsage?
    /// User feedback on an assistant reply: +1 like, -1 dislike, nil none.
    public var feedback: Int?
    /// The message this one quotes, when sent as a reply.
    public var replyToID: UUID?
    /// Earlier versions of this prompt if it was edited.
    public var alternativeVersions: [String] = []
    public var currentVersionIndex: Int = 0
    public init(
        id: UUID = UUID(),
        role: MessageRole,
        parts: [ContentPart],
        status: MessageStatus = .complete,
        createdAt: Date = Date(),
        errorText: String? = nil,
        usage: TokenUsage? = nil,
        feedback: Int? = nil,
        replyToID: UUID? = nil,
        alternativeVersions: [String] = [],
        currentVersionIndex: Int = 0
    ) {
        self.id = id
        self.role = role
        self.parts = parts
        self.status = status
        self.createdAt = createdAt
        self.errorText = errorText
        self.usage = usage
        self.feedback = feedback
        self.replyToID = replyToID
        self.alternativeVersions = alternativeVersions
        self.currentVersionIndex = currentVersionIndex
    }

    enum CodingKeys: String, CodingKey {
        case id, role, parts, status, createdAt, errorText, usage, feedback, replyToID
        case alternativeVersions, currentVersionIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(MessageRole.self, forKey: .role)
        self.parts = try container.decode([ContentPart].self, forKey: .parts)
        self.status = (try? container.decodeIfPresent(MessageStatus.self, forKey: .status)) ?? .complete
        self.createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        self.errorText = try container.decodeIfPresent(String.self, forKey: .errorText)
        self.usage = try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
        self.feedback = try container.decodeIfPresent(Int.self, forKey: .feedback)
        self.replyToID = try container.decodeIfPresent(UUID.self, forKey: .replyToID)
        self.alternativeVersions = (try? container.decodeIfPresent([String].self, forKey: .alternativeVersions)) ?? []
        self.currentVersionIndex = (try? container.decodeIfPresent(Int.self, forKey: .currentVersionIndex)) ?? 0
    }

    /// Visible answer text only. Thinking lives in `thinkingText`.
    public var concatenatedText: String {
        parts.compactMap { part in
            if case .text(let value) = part { value } else { nil }
        }.joined()
    }

    public var thinkingText: String {
        parts.compactMap { part in
            if case .thinking(let value) = part { value } else { nil }
        }.joined()
    }

    /// Replaces the running text payload while streaming, preserving part order.
    public func appendingText(_ delta: String) -> ChatMessage {
        guard !delta.isEmpty else { return self }
        var copy = self
        if case .text(let existing)? = copy.parts.last {
            copy.parts[copy.parts.count - 1] = .text(existing + delta)
        } else {
            copy.parts.append(.text(delta))
        }
        return copy
    }

    public func appendingThinking(_ delta: String) -> ChatMessage {
        guard !delta.isEmpty else { return self }
        var copy = self
        if let index = copy.parts.lastIndex(where: { part in
            if case .thinking = part { true } else { false }
        }), case .thinking(let existing) = copy.parts[index], index == copy.parts.count - 1 {
            copy.parts[index] = .thinking(existing + delta)
        } else {
            copy.parts.append(.thinking(delta))
        }
        return copy
    }

    /// The message minus its thinking seals. Seals only go back to the
    /// provider inside the tool loop that produced them; anywhere else they
    /// are opaque, often kilobytes long, and useless.
    public var withoutThinkingSeals: ChatMessage {
        var copy = self
        copy.parts.removeAll { part in
            if case .thinkingSeal = part { true } else { false }
        }
        return copy
    }
}

public extension Conversation {
    /// For a conversation leaving this device (JSON export / import): the
    /// readable thinking stays, the seals do not.
    var withoutThinkingSeals: Conversation {
        var copy = self
        copy.messages = messages.map(\.withoutThinkingSeals)
        copy.alternativeReplies = alternativeReplies.map(\.withoutThinkingSeals)
        return copy
    }
}
