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

/// Truncates `value` to at most `maxBytes` UTF-8 bytes without splitting a
/// character: back off continuation bytes, then the lead byte of a cut sequence.
fileprivate func relayCappedUTF8(_ value: String, maxBytes: Int) -> String {
    guard value.utf8.count > maxBytes else { return value }
    var bytes = Array(value.utf8.prefix(maxBytes))
    while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
    if let last = bytes.last, last & 0xC0 == 0xC0 { bytes.removeLast() }
    return String(decoding: bytes, as: UTF8.self)
}

/// One tool operation mirrored inside a [`RelayMessage`], so the phone can
/// render moshi-style collapsible operation cards instead of plain text.
///
/// `summary` reuses the desktop 已读/已搜索/已运行/已编辑 parsing. `detail`
/// (full arguments + output) only rides on the most recent assistant replies
/// so the snapshot payload stays bounded over the hub and LAN.
public struct RelayActivity: Codable, Sendable, Equatable, Identifiable {
    /// Hard cap for `detail` (UTF-8 bytes).
    public static let maxDetailBytes = 4096
    /// Hard cap for activities per message.
    public static let maxPerMessage = 50

    /// Stable identifier; mirrors the originating `ToolCall.id` on the host.
    public var id: String
    /// Raw tool name (e.g. `edit_file`).
    public var name: String
    /// One-line description, identical parsing semantics to the desktop `ActivityLog`.
    public var summary: String
    /// `running` while awaiting the result, then `ok` or `error`.
    public var status: String
    /// Diffstat added lines from the tool output, `nil` when there is none.
    public var added: Int?
    /// Diffstat removed lines from the tool output, `nil` when there is none.
    public var removed: Int?
    /// Arguments + output, capped at `maxDetailBytes`; omitted for summary-only rows.
    public var detail: String?

    public init(
        id: String, name: String, summary: String, status: String,
        added: Int? = nil, removed: Int? = nil, detail: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.status = status
        self.added = added
        self.removed = removed
        self.detail = Self.capped(detail)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, status, added, removed, detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        added = try container.decodeIfPresent(Int.self, forKey: .added)
        removed = try container.decodeIfPresent(Int.self, forKey: .removed)
        detail = Self.capped(try container.decodeIfPresent(String.self, forKey: .detail))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(summary, forKey: .summary)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(added, forKey: .added)
        try container.encodeIfPresent(removed, forKey: .removed)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    /// Enforces the wire cap; empty input collapses to `nil` so it is omitted.
    static func capped(_ detail: String?) -> String? {
        guard var value = detail, !value.isEmpty else { return nil }
        value = relayCappedUTF8(value, maxBytes: Self.maxDetailBytes)
        return value.isEmpty ? nil : value
    }
}

/// Wire representation of one chat message mirrored to a remote controller.
public struct RelayMessage: Codable, Sendable, Equatable {
    /// Hard cap for the mirrored thinking text (UTF-8 bytes).
    public static let maxThinkingBytes = 8 * 1024

    /// Stable identifier; mirrors the originating `ChatMessage.id` on the host.
    public var id: String
    /// Lowercase `"user"` or `"assistant"`.
    public var role: String
    /// Message body text (thinking rides in `thinking`).
    public var text: String
    /// Message timestamp, encoded ISO8601.
    public var ts: Date
    /// True while this message is still being incrementally generated.
    public var streaming: Bool
    /// Model thinking transcript, capped at `maxThinkingBytes`; `nil` when empty.
    /// Optional and omitted on the wire when empty, so older clients keep working.
    public var thinking: String?
    /// Tool operations for collapsible activity cards, capped at
    /// `RelayActivity.maxPerMessage`; `nil` when the message has none.
    public var activity: [RelayActivity]?

    public init(
        id: String, role: String, text: String, ts: Date, streaming: Bool,
        thinking: String? = nil, activity: [RelayActivity]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.ts = ts
        self.streaming = streaming
        (self.thinking, self.activity) = Self.normalized(thinking: thinking, activity: activity)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, ts, streaming, thinking, activity
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
        (self.thinking, self.activity) = Self.normalized(
            thinking: try container.decodeIfPresent(String.self, forKey: .thinking),
            activity: try container.decodeIfPresent([RelayActivity].self, forKey: .activity)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(RelayDate.string(from: ts), forKey: .ts)
        try container.encode(streaming, forKey: .streaming)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(activity, forKey: .activity)
    }

    /// Applies the wire caps in one place; used by both initializers and the
    /// host snapshot builder in OMPChatUI.
    public static func normalized(
        thinking: String?, activity: [RelayActivity]?
    ) -> (String?, [RelayActivity]?) {
        let cappedThinking: String?
        if var value = thinking, !value.isEmpty {
            value = relayCappedUTF8(value, maxBytes: maxThinkingBytes)
            cappedThinking = value.isEmpty ? nil : value
        } else {
            cappedThinking = nil
        }
        let cappedActivity: [RelayActivity]?
        if let items = activity, !items.isEmpty {
            cappedActivity = Array(items.prefix(RelayActivity.maxPerMessage))
        } else {
            cappedActivity = nil
        }
        return (cappedThinking, cappedActivity)
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

/// What a phone may answer on an approval card. 始终允许 is deliberately
/// absent: a persistent grant stays a decision made at the Mac.
public enum RelayApprovalDecision: String, Codable, Sendable, CaseIterable {
    case allowOnce
    case deny
}

/// One tool call waiting for the user on the host, mirrored so a paired
/// phone can answer it. The host computes `canApprove` from its own policy;
/// the phone only renders it.
public struct RelayApproval: Codable, Sendable, Equatable, Identifiable {
    /// Hard cap for `argumentsJSON` (UTF-8 bytes, marker included).
    public static let maxArgumentsBytes = 4096
    /// Ends `argumentsJSON` when the cap cut it, so the phone shows it is partial.
    public static let truncationMarker = "\n…（参数过长，已截断）"

    /// Stable identifier; mirrors the host's `ToolApprovalRequest.id`.
    public var id: String
    public var conversationID: String
    /// The model's call id, so the phone can put the card beside its activity row.
    public var callID: String
    public var toolName: String
    /// Where the tool comes from: "内置", "MCP · playwright", "技能 · deploy".
    public var source: String
    /// `ToolRisk` raw value: `read`, `write`, `execute` or `control`.
    public var risk: String
    /// One human line, e.g. "运行命令：git status".
    public var summary: String
    /// The call's arguments, capped at `maxArgumentsBytes`.
    public var argumentsJSON: String
    /// Whether the host accepts 允许一次 from the phone. 拒绝 is always accepted.
    public var canApprove: Bool

    public init(
        id: String, conversationID: String, callID: String, toolName: String,
        source: String, risk: String, summary: String, argumentsJSON: String, canApprove: Bool
    ) {
        self.id = id
        self.conversationID = conversationID
        self.callID = callID
        self.toolName = toolName
        self.source = source
        self.risk = risk
        self.summary = summary
        self.argumentsJSON = Self.capped(argumentsJSON)
        self.canApprove = canApprove
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, callID, toolName, source, risk, summary, argumentsJSON, canApprove
    }

    // Every key is optional: one odd card must not fail the whole snapshot.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID) ?? ""
        callID = try container.decodeIfPresent(String.self, forKey: .callID) ?? ""
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        risk = try container.decodeIfPresent(String.self, forKey: .risk) ?? ToolRisk.execute.rawValue
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        argumentsJSON = Self.capped(try container.decodeIfPresent(String.self, forKey: .argumentsJSON) ?? "")
        canApprove = try container.decodeIfPresent(Bool.self, forKey: .canApprove) ?? false
    }

    /// Whether a phone may allow a call of `risk`: a read always; anything that
    /// writes, runs or drives the Mac only while 允许手机访问文件与终端 is on,
    /// the user's consent for the phone to touch this Mac's files and shell.
    public static func phoneMayAllow(_ risk: ToolRisk, allowShell: Bool) -> Bool {
        risk == .read || allowShell
    }

    /// Enforces the wire cap on a character boundary; a cut value ends with
    /// `truncationMarker` and still fits the cap.
    static func capped(_ arguments: String) -> String {
        guard arguments.utf8.count > maxArgumentsBytes else { return arguments }
        let budget = maxArgumentsBytes - truncationMarker.utf8.count
        return relayCappedUTF8(arguments, maxBytes: budget) + truncationMarker
    }
}

/// A phone command the host refused. Commands get no reply over the LAN
/// route or the hub, so the host echoes refusals in the snapshot and the
/// phone matches them to what it sent by `requestID`.
public struct RelayCommandFailure: Codable, Sendable, Equatable {
    /// How many refusals the host keeps; the oldest go first.
    public static let maxKept = 20

    /// The `requestID` the phone put on the command.
    public var requestID: String
    /// `not_found`: no such card on the phone's side of the mirror, or it was
    /// already answered. `shell_disabled`: allowing it needs 允许手机访问文件与终端.
    public var error: String

    public init(requestID: String, error: String) {
        self.requestID = requestID
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
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
    /// Approval cards waiting on the host, oldest first; `nil` when there are
    /// none. Optional and omitted on the wire when empty, so older clients keep working.
    public var approvals: [RelayApproval]?
    /// The host's latest refusals of phone commands, oldest first; `nil` when
    /// there are none. Omitted on the wire when empty.
    public var commandFailures: [RelayCommandFailure]?

    public init(
        rev: Int, host: String, selectedID: String?, conversations: [RelayConversation],
        approvals: [RelayApproval]? = nil, commandFailures: [RelayCommandFailure]? = nil
    ) {
        self.rev = rev
        self.host = host
        self.selectedID = selectedID
        self.conversations = conversations
        self.approvals = approvals.flatMap { $0.isEmpty ? nil : $0 }
        self.commandFailures = commandFailures.flatMap { $0.isEmpty ? nil : $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case rev, host, selectedID, conversations, approvals, commandFailures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rev = try container.decodeIfPresent(Int.self, forKey: .rev) ?? 0
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        selectedID = try container.decodeIfPresent(String.self, forKey: .selectedID)
        conversations = try container.decodeIfPresent([RelayConversation].self, forKey: .conversations) ?? []
        approvals = try container.decodeIfPresent([RelayApproval].self, forKey: .approvals)
            .flatMap { $0.isEmpty ? nil : $0 }
        commandFailures = try container.decodeIfPresent([RelayCommandFailure].self, forKey: .commandFailures)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rev, forKey: .rev)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(selectedID, forKey: .selectedID)
        try container.encode(conversations, forKey: .conversations)
        try container.encodeIfPresent(approvals.flatMap { $0.isEmpty ? nil : $0 }, forKey: .approvals)
        try container.encodeIfPresent(commandFailures.flatMap { $0.isEmpty ? nil : $0 }, forKey: .commandFailures)
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
    /// `approve`: the card's `RelayApproval.id`.
    public var approvalID: String?
    /// `approve`: a `RelayApprovalDecision` raw value; anything else is a bad command.
    public var decision: String?
    /// `approve`: chosen by the phone, echoed in `RelaySnapshot.commandFailures`
    /// when the host refuses the command.
    public var requestID: String?

    public init(
        kind: String,
        conversationID: String? = nil,
        messageID: String? = nil,
        text: String? = nil,
        title: String? = nil,
        value: Int? = nil,
        modelID: String? = nil,
        unread: Bool? = nil,
        approvalID: String? = nil,
        decision: String? = nil,
        requestID: String? = nil
    ) {
        self.kind = kind
        self.conversationID = conversationID
        self.messageID = messageID
        self.text = text
        self.title = title
        self.value = value
        self.modelID = modelID
        self.unread = unread
        self.approvalID = approvalID
        self.decision = decision
        self.requestID = requestID
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
        case .approve(let approvalID, let decision, let requestID):
            self.init(kind: "approve", approvalID: approvalID, decision: decision.rawValue, requestID: requestID)
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
        case "approve":
            // `allowAlways` lands here too: a phone may not grant it.
            guard let approvalID, !approvalID.isEmpty,
                  let decision = self.decision.flatMap(RelayApprovalDecision.init(rawValue:)) else { return nil }
            return .approve(approvalID: approvalID, decision: decision, requestID: requestID)
        default: return nil
        }
    }
}
