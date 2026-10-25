import Foundation

/// ISO8601 date codec shared by all relay wire types.
enum RelayDate {
    static let encoder = ISO8601DateFormatter()

    static let decoder = ISO8601DateFormatter()
    static let fractionalDecoder: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(from date: Date) -> String { encoder.string(from: date) }

    static func date(from raw: String) -> Date? {
        decoder.date(from: raw) ?? fractionalDecoder.date(from: raw)
    }
}

/// Wire representation of one chat message mirrored to a remote controller.
public struct RelayMessage: Codable, Sendable, Equatable {
    /// Stable identifier; mirrors the originating `ChatMessage.id` on the host.
    public var id: String
    /// Lowercase `"user"` or `"assistant"`.
    public var role: String
    /// Message body text (thinking content never included).
    public var text: String
    /// Message timestamp, encoded ISO8601.
    public var ts: Date
    /// True while this message is still being incrementally generated.
    public var streaming: Bool

    public init(id: String, role: String, text: String, ts: Date, streaming: Bool) {
        self.id = id
        self.role = role
        self.text = text
        self.ts = ts
        self.streaming = streaming
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, ts, streaming
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        if let raw = try container.decodeIfPresent(String.self, forKey: .ts),
           let date = RelayDate.date(from: raw) {
            ts = date
        } else {
            ts = Date()
        }
        streaming = try container.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(RelayDate.string(from: ts), forKey: .ts)
        try container.encode(streaming, forKey: .streaming)
    }
}

/// Wire representation of one conversation mirrored to a remote controller.
public struct RelayConversation: Codable, Sendable, Equatable {
    /// Stable identifier; mirrors the originating `Conversation.id`.
    public var id: String
    public var title: String
    /// Last activity time, encoded ISO8601.
    public var updatedAt: Date
    /// Project name, or `nil` when unassigned.
    public var project: String?
    /// True while the conversation is generating on the host.
    public var isStreaming: Bool
    /// Most recent messages (host caps at the latest 100 per conversation).
    public var messages: [RelayMessage]

    public init(
        id: String, title: String, updatedAt: Date, project: String?,
        isStreaming: Bool, messages: [RelayMessage]
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.project = project
        self.isStreaming = isStreaming
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, updatedAt, project, isStreaming, messages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        if let raw = try container.decodeIfPresent(String.self, forKey: .updatedAt),
           let date = RelayDate.date(from: raw) {
            updatedAt = date
        } else {
            updatedAt = Date()
        }
        project = try container.decodeIfPresent(String.self, forKey: .project)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        messages = try container.decodeIfPresent([RelayMessage].self, forKey: .messages) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(RelayDate.string(from: updatedAt), forKey: .updatedAt)
        try container.encodeIfPresent(project, forKey: .project)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(messages, forKey: .messages)
    }
}

/// Full structured mirror of the host chat state.
///
/// The remote controller pulls this on pair/snapshot and replaces its local
/// copy whenever a `rev` SSE `rev` event reports a newer revision.
public struct RelaySnapshot: Codable, Sendable, Equatable {
    /// Monotonic revision; the host bumps it on every state change.
    public var rev: Int
    /// Human-readable host name shown in the pairing UI.
    public var host: String
    /// Selected conversation on the host, or `nil`.
    public var selectedID: String?
    public var conversations: [RelayConversation]

    public init(rev: Int, host: String, selectedID: String?, conversations: [RelayConversation]) {
        self.rev = rev
        self.host = host
        self.selectedID = selectedID
        self.conversations = conversations
    }

    private enum CodingKeys: String, CodingKey {
        case rev, host, selectedID, conversations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rev = try container.decodeIfPresent(Int.self, forKey: .rev) ?? 0
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        selectedID = try container.decodeIfPresent(String.self, forKey: .selectedID)
        conversations = try container.decodeIfPresent([RelayConversation].self, forKey: .conversations) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rev, forKey: .rev)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(selectedID, forKey: .selectedID)
        try container.encode(conversations, forKey: .conversations)
    }
}
