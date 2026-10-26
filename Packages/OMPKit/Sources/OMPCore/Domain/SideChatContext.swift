import Foundation

/// Codex `thread.sidePanel` Side chat: a question about a thread asked off to
/// the side, so neither the question nor the answer lands in the thread's own
/// history. The model sees the thread only through this system prompt.
public enum SideChatContext {
    /// Characters of thread transcript sent with a side question. The newest
    /// messages win; older ones are dropped whole and counted.
    public static let transcriptLimit = 24_000

    public static func systemPrompt(
        title: String,
        goal: String?,
        transcript: [ChatMessage],
        limit: Int = transcriptLimit
    ) -> String {
        var lines = [
            "你在一个「旁聊」里回答关于下面这段主对话的问题。旁聊的问答不会写进主对话。",
            "只根据主对话内容和常识回答；主对话里没有提到的事实，直接说没有提到，不要编造。",
            "",
            "主对话标题：\(title)",
        ]
        if let goal = goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            lines.append("主对话的目标：\(goal)")
        }
        lines.append("")

        let entries = transcript.compactMap(entry)
        guard !entries.isEmpty else {
            lines.append("主对话还没有内容。")
            return lines.joined(separator: "\n")
        }

        // Walk back from the newest message until the budget is spent.
        var kept: [String] = []
        var used = 0
        for entry in entries.reversed() {
            if used + entry.count <= limit {
                kept.append(entry)
                used += entry.count
            } else {
                if kept.isEmpty {
                    // The newest message alone is over the limit: keep its end,
                    // which is what the question is most likely about.
                    kept.append("…" + String(entry.suffix(max(0, limit - 1))))
                }
                break
            }
        }
        let omitted = entries.count - kept.count
        lines.append("主对话内容：")
        if omitted > 0 {
            lines.append("（更早的 \(omitted) 条消息已省略）")
        }
        lines.append(contentsOf: kept.reversed())
        return lines.joined(separator: "\n")
    }

    /// One labelled transcript line, or nil for messages with nothing to quote
    /// (system and tool messages, empty placeholders, image-only turns).
    private static func entry(_ message: ChatMessage) -> String? {
        let text = message.concatenatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch message.role {
        case .user: return "用户：\(text)"
        case .assistant: return "助手：\(text)"
        case .system, .tool: return nil
        }
    }
}
