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
    /// The composer mentions in `text`, resolved when it was sent: sent
    /// after the pastes, each marked on the message so the transcript shows
    /// it as a chip. 编辑 drops them and keeps the mentions, so the next
    /// send reads the files again.
    public var mentions: [MentionAttachment]
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
        mentions: [MentionAttachment] = [],
        replyToID: UUID? = nil,
        remote: Bool = false,
        isHeld: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.pastes = pastes
        self.mentions = mentions
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
        mentions = (try? container.decodeIfPresent([MentionAttachment].self, forKey: .mentions)) ?? []
        replyToID = try? container.decodeIfPresent(UUID.self, forKey: .replyToID)
        remote = (try? container.decodeIfPresent(Bool.self, forKey: .remote)) ?? false
        isHeld = (try? container.decodeIfPresent(Bool.self, forKey: .isHeld)) ?? false
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
    }

    /// One line for the chip above the composer.
    public var preview: String {
        let line = shownText.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !line.isEmpty { return line }
        if !pastes.isEmpty { return "粘贴的文本" }
        return attachments.isEmpty ? "空消息" : "附件消息"
    }

    /// `text` as the transcript shows it: mention tokens read as `@名称`.
    /// A phone's text is shown as typed; it never carries resolved mentions.
    public var shownText: String {
        remote ? text : ComposerMention.readable(text)
    }

    /// The user message it becomes when delivered: the text, each folded
    /// paste as a fenced block, the resolved mentions (marked), then the
    /// attachments.
    public var message: ChatMessage {
        let shown = shownText
        var parts: [ContentPart] = []
        if !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(shown)) }
        for paste in pastes {
            parts.append(.text("\n\n```\n\(paste)\n```"))
        }
        var marks: [MessageMention] = []
        for mention in mentions {
            marks.append(MessageMention(part: parts.count, attachment: mention))
            parts.append(.text(mention.text))
        }
        parts.append(contentsOf: attachments.map { .media($0) })
        return ChatMessage(role: .user, parts: parts, replyToID: replyToID, mentions: marks)
    }
}
