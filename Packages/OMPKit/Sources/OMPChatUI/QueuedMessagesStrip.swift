import SwiftUI
import OMPCore
import OMPDesign

/// Follow-ups waiting for the running reply of the selected conversation
/// (Codex queued messages), as chips above the composer. 立即发送 interrupts
/// the reply and sends the message now, 编辑 moves it back into the draft,
/// 删除 drops it. Shared by the desktop and phone composers.
struct QueuedMessagesStrip: View {
    @Environment(ChatAppModel.self) private var model

    var body: some View {
        if let id = model.selectedConversationID {
            let queued = model.queuedMessages(for: id)
            if !queued.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(header(for: id, queued))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.ompTextTertiary)
                        .accessibilityIdentifier("composer.queued.header")
                    ForEach(queued) { item in
                        row(item, in: id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                .accessibilityIdentifier("composer.queued")
            }
        }
    }

    private func header(for id: UUID, _ queued: [QueuedMessage]) -> String {
        if model.isCompacting(id) { return ChatAppModel.queuedDuringCompactionText }
        if queued.allSatisfy(\.isHeld) { return "已停止 · 这些消息不会自动发出" }
        return "排队中 · 回复的下一步会带上"
    }

    private func row(_ item: QueuedMessage, in id: UUID) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.isHeld ? "pause.circle" : "clock")
                .font(.system(size: 11))
                .foregroundStyle(Color.ompTextTertiary)
            Text(item.preview)
                .font(.system(size: 12))
                .foregroundStyle(Color.ompText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(item.text)
            Spacer(minLength: 4)
            action("立即发送", id: "composer.queued.sendNow") {
                Task { await model.sendQueuedNow(item.id, in: id) }
            }
            action("编辑", id: "composer.queued.edit") {
                model.editQueued(item.id, in: id)
            }
            action("删除", id: "composer.queued.delete") {
                model.removeQueued(item.id, in: id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.queued.item")
    }

    private func action(_ title: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.ompTextSecondary)
            .accessibilityIdentifier(id)
    }
}
