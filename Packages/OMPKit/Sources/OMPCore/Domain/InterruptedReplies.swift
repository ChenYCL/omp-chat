import Foundation

public extension Conversation {
    /// Closes replies that were still streaming when the app last stopped
    /// (killed, crashed or quit mid-reply). Nothing can be running at launch,
    /// so a message left `streaming` or `pending` would otherwise show a
    /// thinking timer forever. Content that arrived is kept, as 停止 keeps it;
    /// an empty reply is marked failed. Follow-ups that were waiting for that
    /// reply are held, as 停止 holds them: only the user sends them now.
    /// Returns whether anything changed.
    mutating func closeInterruptedReplies() -> Bool {
        var changed = false
        for index in messages.indices where messages[index].status == .streaming || messages[index].status == .pending {
            let hasContent = !messages[index].parts.isEmpty
            messages[index].status = hasContent ? .complete : .failed
            if messages[index].errorText == nil {
                messages[index].errorText = hasContent
                    ? "应用退出时这条回复还没完成，内容可能不完整。"
                    : "应用退出时这条回复还没有内容。"
            }
            changed = true
        }
        for index in queuedMessages.indices where !queuedMessages[index].isHeld {
            queuedMessages[index].isHeld = true
            changed = true
        }
        return changed
    }
}
