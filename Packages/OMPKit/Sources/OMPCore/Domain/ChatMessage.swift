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

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        parts: [ContentPart],
        status: MessageStatus = .complete,
        createdAt: Date = Date(),
        errorText: String? = nil,
        usage: TokenUsage? = nil,
        feedback: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.parts = parts
        self.status = status
        self.createdAt = createdAt
        self.errorText = errorText
        self.usage = usage
        self.feedback = feedback
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
}
