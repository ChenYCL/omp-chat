import Foundation

/// A follow-up sent while a reply was running in its conversation (Codex
/// queued messages / steering). It waits in `Conversation.queuedMessages`
/// until the running reply reaches a point where the model can read it:
/// between two model turns, or the reply's end.
public struct QueuedMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var attachments: [MediaRef]
    /// Long pastes that were chips in the composer, kept apart from `text`
    /// so 编辑 can put them back as chips.
    public var pastes: [String]
    /// The message it quotes (the composer's 引用).
    public var replyToID: UUID?
    /// Sent from a paired phone: the reply it reaches is held to the phone's
    /// permission limit from then on.
    public var remote: Bool
    /// Set by 停止 and by a relaunch: the reply it was waiting for is gone,
    /// so only the user sends it (立即发送). Held messages are never
    /// delivered on their own.
    public var isHeld: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        attachments: [MediaRef] = [],
        pastes: [String] = [],
        replyToID: UUID? = nil,
        remote: Bool = false,
        isHeld: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.pastes = pastes
        self.replyToID = replyToID
        self.remote = remote
        self.isHeld = isHeld
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = (try? container.decodeIfPresent([MediaRef].self, forKey: .attachments)) ?? []
        pastes = (try? container.decodeIfPresent([String].self, forKey: .pastes)) ?? []
        replyToID = try? container.decodeIfPresent(UUID.self, forKey: .replyToID)
        remote = (try? container.decodeIfPresent(Bool.self, forKey: .remote)) ?? false
        isHeld = (try? container.decodeIfPresent(Bool.self, forKey: .isHeld)) ?? false
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
    }

    /// One line for the chip above the composer.
    public var preview: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !line.isEmpty { return line }
        if !pastes.isEmpty { return "粘贴的文本" }
        return attachments.isEmpty ? "空消息" : "附件消息"
    }

    /// The user message it becomes when delivered.
    public var message: ChatMessage {
        ChatMessage(
            role: .user,
            parts: Self.userParts(text: text, pastes: pastes, attachments: attachments),
            replyToID: replyToID
        )
    }

    /// A user message's parts as the composer sends them: the text, each
    /// folded paste as a fenced block, then the attachments.
    public static func userParts(text: String, pastes: [String], attachments: [MediaRef]) -> [ContentPart] {
        var parts: [ContentPart] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(text)) }
        for paste in pastes {
            parts.append(.text("\n\n```\n\(paste)\n```"))
        }
        parts.append(contentsOf: attachments.map { .media($0) })
        return parts
    }
}
