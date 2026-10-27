import SwiftUI
import OMPCore
import OMPDesign

public struct ChatTranscriptView: View {
    @Environment(ChatAppModel.self) private var model
    @State private var showingBatchDeleteConfirmation = false
    @State private var pendingMessageDelete: ChatMessage?

    public init() {}

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let conversation = model.selectedConversation {
                        if !model.selectedMessageIDs.isEmpty {
                            selectionBar
                        }
                        if conversation.messages.isEmpty {
                            emptyState
                        }
                        let compaction = model.compaction(for: conversation.id)
                        ForEach(conversation.messages) { message in
                            MessageRow(
                                message: message,
                                mediaLibrary: model.mediaLibrary,
                                actions: actions(for: message)
                            )
                            .id(message.id)
                            if let compaction, message.id == compaction.coveredThroughID {
                                CompactionDivider(compaction: compaction)
                            }
                        }
                        if model.isCompacting(conversation.id) {
                            CompactingIndicator()
                        }
                        if let progress = model.worktreeProgress, progress.conversationID == conversation.id {
                            WorktreeProgressCard(progress: progress)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                // Official MainContentFrame: thread content maxes at 768pt,
                // centered, with 24pt side padding.
                .padding(.horizontal, Theme.Layout.transcriptPadding)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: Theme.Layout.transcriptMax, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollSignature) { _, _ in
                withAnimation(Theme.Motion.quick) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: model.selectedConversationID) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .confirmationDialog(
                "删除这条消息？",
                isPresented: Binding(get: { pendingMessageDelete != nil },
                                     set: { if !$0 { pendingMessageDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingMessageDelete
            ) { message in
                Button("删除消息", role: .destructive) {
                    model.deleteMessage(message.id)
                    pendingMessageDelete = nil
                }
                Button("取消", role: .cancel) { pendingMessageDelete = nil }
            } message: { _ in
                Text("删除后无法撤销。")
            }
            .onReceive(NotificationCenter.default.publisher(for: .ompScrollToMessage)) { note in
                guard let id = note.userInfo?["messageID"] as? UUID else { return }
                withAnimation(Theme.Motion.quick) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ompScrollToBottom)) { _ in
                withAnimation(Theme.Motion.quick) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        .background(Color.ompCanvas)
    }

    private static let bottomAnchor = "transcript-bottom"

    private func actions(for message: ChatMessage) -> MessageRow.Actions {
        MessageRow.Actions(
            copy: { copyToPasteboard(message.writtenText) },
            edit: message.role == .user ? { (text: String) in
                model.editAndResend(message.id, newText: text)
            } : nil,
            branch: { _ = model.branch(from: message.id) },
            // Deleting one message asks first, like deleting a chat does.
            delete: { pendingMessageDelete = message },
            regenerate: message.role == .assistant ? { model.regenerateLast() } : nil,
            feedback: message.role == .assistant ? { value in
                model.setFeedback(message.id, value: value)
            } : nil,
            reply: { model.replyingTo = message },
            select: { model.toggleMessageSelection(message.id) }
        )
    }

    private var allSelected: Bool {
        guard let messages = model.selectedConversation?.messages, !messages.isEmpty else { return false }
        return model.selectedMessageIDs.count == messages.count
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("已选 \(model.selectedMessageIDs.count) 条")
                .font(.system(size: 12, weight: .medium))

            Button(allSelected ? "取消全选" : "全选") {
                if allSelected {
                    model.selectedMessageIDs = []
                } else if let messages = model.selectedConversation?.messages {
                    model.selectedMessageIDs = Set(messages.map(\.id))
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)

            Spacer()

            Button("复制") {
                let text = model.selectedConversation?.messages
                    .filter { model.selectedMessageIDs.contains($0.id) }
                    .map(\.writtenText)
                    .joined(separator: "\n\n") ?? ""
                copyToPasteboard(text)
                AudioFeedback.playSend(enabled: true)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))

            Button("删除", role: .destructive) {
                showingBatchDeleteConfirmation = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .confirmationDialog(
                "确定删除选中的 \(model.selectedMessageIDs.count) 条消息吗？",
                isPresented: $showingBatchDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除消息", role: .destructive) {
                    model.deleteSelectedMessages()
                }
                Button("取消", role: .cancel) {}
            }

            Button {
                model.selectedMessageIDs = []
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ompTextSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
    }


    private var scrollSignature: String {
        guard let conversation = model.selectedConversation, let last = conversation.messages.last else {
            return "empty-\(model.selectedConversationID?.uuidString ?? "-")"
        }
        // Bucket the growing text so streaming scrolls a few times a second
        // instead of once per token. Part count and waiting approvals are in
        // too: a tool result or an approval card adds no text, and the card's
        // buttons used to stay hidden under the composer.
        let textCount = last.parts.reduce(0) { $0 + $1.plainText.count }
        let waiting = model.pendingApprovals.filter { $0.conversationID == conversation.id }.map(\.id.uuidString)
        return "\(conversation.id)-\(conversation.messages.count)-\(last.id)-\(textCount / 40)-\(last.parts.count)"
            + "-\(last.status.rawValue)-\(waiting.joined(separator: ","))-\(model.isCompacting(conversation.id))"
    }

    // MARK: Empty state

    /// The transcript is only shown for an empty thread while no provider is
    /// set up; both platforms draw their own empty state otherwise.
    @ViewBuilder
    private var emptyState: some View {
        if model.needsSetup {
            setupPrompt
        }
    }

    private var setupPrompt: some View {
        VStack(spacing: 0) {
            OMPMark(size: 54, symbol: "gearshape.2")
                .padding(.bottom, 18)
            Text("还差一步")
                .font(Theme.Typography.title)
                .padding(.bottom, 6)
            Text("添加一个 OpenAI 兼容或 Anthropic 供应商，填入 API Key，然后同步模型列表。")
                .font(Theme.Typography.secondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.bottom, 22)
            Button {
                model.showSettings = true
            } label: {
                Label("打开设置", systemImage: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

public struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    public init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(3)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ompTextSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .frame(maxWidth: Theme.Layout.transcriptMax + 32, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// Toast-style status line (model sync, export done, compaction notices…).
/// Goes away on its own after a few seconds or on tap; it used to stay until
/// tapped, so a notice outlived what it described.
public struct StatusToast: View {
    let message: String
    let onDismiss: () -> Void

    static let lifetime: Duration = .seconds(5)

    public init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 6) {
            // Neutral: the lines are notices (「还没有足够早的内容可以压缩」,
            // 「压缩时不能插话…」) as often as successes.
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.ompTextSecondary)
            Text(message)
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .frame(maxWidth: Theme.Layout.transcriptMax + 32, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .onTapGesture(perform: onDismiss)
        // Keyed on the text: a newer message restarts the clock.
        .task(id: message) {
            try? await Task.sleep(for: Self.lifetime)
            if !Task.isCancelled { onDismiss() }
        }
        .accessibilityIdentifier("status.toast")
    }
}

/// Where a compaction's summary ends. Everything above stays in the
/// transcript; requests send the summary in its place. Tapping shows the
/// summary itself.
struct CompactionDivider: View {
    let compaction: ConversationCompaction
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Theme.Motion.quick) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    rule
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("以上内容已压缩为摘要")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("约 \(TokenFormat.compact(compaction.tokensBefore)) → \(TokenFormat.compact(compaction.tokensAfter))")
                        .font(.system(size: 10.5).monospacedDigit())
                    rule
                }
                .foregroundStyle(Color.ompTextTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("transcript.compaction.divider")
            .accessibilityHint(expanded ? "收起摘要" : "展开摘要")
            if expanded {
                Text(compaction.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextSecondary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                    .accessibilityIdentifier("transcript.compaction.summary")
            }
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.ompBorder)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// The transcript's last row while the earlier turns are being summarised.
struct CompactingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在压缩上下文…")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ompTextSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcript.compacting")
    }
}
