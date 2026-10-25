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

/// Wire form of a [`RelayCommand`]: one flat JSON object so a hand-rolled
/// server, the Python hub and both apps can share a single encoding.
public struct RelayCommandWire: Codable, Sendable, Equatable {
    public var kind: String
    public var conversationID: String?
    public var messageID: String?
    public var text: String?
    public var title: String?
    public var value: Int?
    public var modelID: String?
    public var unread: Bool?

    public init(
        kind: String,
        conversationID: String? = nil,
        messageID: String? = nil,
        text: String? = nil,
        title: String? = nil,
        value: Int? = nil,
        modelID: String? = nil,
        unread: Bool? = nil
    ) {
        self.kind = kind
        self.conversationID = conversationID
        self.messageID = messageID
        self.text = text
        self.title = title
        self.value = value
        self.modelID = modelID
        self.unread = unread
    }

    public init(_ command: RelayCommand) {
        switch command {
        case .input(let conversationID, let text):
            self.init(kind: "input", conversationID: conversationID, text: text)
        case .stop(let conversationID):
            self.init(kind: "stop", conversationID: conversationID)
        case .select(let conversationID):
            self.init(kind: "select", conversationID: conversationID)
        case .newConversation:
            self.init(kind: "newConversation")
        case .rename(let conversationID, let title):
            self.init(kind: "rename", conversationID: conversationID, title: title)
        case .delete(let conversationID):
            self.init(kind: "delete", conversationID: conversationID)
        case .regenerate(let conversationID):
            self.init(kind: "regenerate", conversationID: conversationID)
        case .deleteMessage(let conversationID, let messageID):
            self.init(kind: "deleteMessage", conversationID: conversationID, messageID: messageID)
        case .editAndResend(let conversationID, let messageID, let text):
            self.init(kind: "editAndResend", conversationID: conversationID, messageID: messageID, text: text)
        case .branch(let conversationID, let messageID):
            self.init(kind: "branch", conversationID: conversationID, messageID: messageID)
        case .feedback(let conversationID, let messageID, let value):
            self.init(kind: "feedback", conversationID: conversationID, messageID: messageID, value: value)
        case .setModel(let conversationID, let modelID):
            self.init(kind: "setModel", conversationID: conversationID, modelID: modelID)
        case .togglePin(let conversationID):
            self.init(kind: "togglePin", conversationID: conversationID)
        case .toggleArchive(let conversationID):
            self.init(kind: "toggleArchive", conversationID: conversationID)
        case .toggleLock(let conversationID):
            self.init(kind: "toggleLock", conversationID: conversationID)
        case .setUnread(let conversationID, let unread):
            self.init(kind: "setUnread", conversationID: conversationID, unread: unread)
        }
    }

    /// The strongly-typed command, or `nil` for an unknown `kind`.
    public var command: RelayCommand? {
        switch kind {
        case "input": return .input(conversationID: conversationID, text: text ?? "")
        case "stop": return .stop(conversationID: conversationID ?? "")
        case "select": return conversationID.map { .select(conversationID: $0) }
        case "newConversation": return .newConversation
        case "rename":
            guard let conversationID, let title else { return nil }
            return .rename(conversationID: conversationID, title: title)
        case "delete": return conversationID.map { .delete(conversationID: $0) }
        case "regenerate": return conversationID.map { .regenerate(conversationID: $0) }
        case "deleteMessage":
            guard let conversationID, let messageID else { return nil }
            return .deleteMessage(conversationID: conversationID, messageID: messageID)
        case "editAndResend":
            guard let conversationID, let messageID, let text else { return nil }
            return .editAndResend(conversationID: conversationID, messageID: messageID, text: text)
        case "branch":
            guard let conversationID, let messageID else { return nil }
            return .branch(conversationID: conversationID, messageID: messageID)
        case "feedback":
            guard let conversationID, let messageID, let value else { return nil }
            return .feedback(conversationID: conversationID, messageID: messageID, value: value)
        case "setModel":
            guard let conversationID, let modelID else { return nil }
            return .setModel(conversationID: conversationID, modelID: modelID)
        case "togglePin": return conversationID.map { .togglePin(conversationID: $0) }
        case "toggleArchive": return conversationID.map { .toggleArchive(conversationID: $0) }
        case "toggleLock": return conversationID.map { .toggleLock(conversationID: $0) }
        case "setUnread":
            guard let conversationID, let unread else { return nil }
            return .setUnread(conversationID: conversationID, unread: unread)
        default: return nil
        }
    }
}
