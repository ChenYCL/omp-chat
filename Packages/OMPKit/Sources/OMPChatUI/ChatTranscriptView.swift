import SwiftUI
import OMPCore
import OMPDesign

public struct ChatTranscriptView: View {
    @Environment(ChatAppModel.self) private var model
    @State private var showingBatchDeleteConfirmation = false

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
                        ForEach(conversation.messages) { message in
                            MessageRow(
                                message: message,
                                mediaLibrary: model.mediaLibrary,
                                actions: actions(for: message)
                            )
                            .id(message.id)
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
            copy: { copyToPasteboard(message.concatenatedText) },
            edit: message.role == .user ? { (text: String) in
                model.editAndResend(message.id, newText: text)
            } : nil,
            branch: { _ = model.branch(from: message.id) },
            delete: { model.deleteMessage(message.id) },
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
                    .map(\.concatenatedText)
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
        // instead of once per token.
        let textCount = last.parts.reduce(0) { $0 + $1.plainText.count }
        return "\(conversation.id)-\(conversation.messages.count)-\(last.id)-\(textCount / 40)-\(last.status.rawValue)"
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        if model.needsSetup {
            setupPrompt
        } else {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.ompTextTertiary)
                (Text("今天想在 ")
                    + Text(model.activeProvider?.name ?? "OMP Chat").underline()
                    + Text(" 里聊些什么？"))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
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

/// Toast-style status line (model sync, export success, …).
public struct StatusToast: View {
    let message: String
    let onDismiss: () -> Void

    public init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
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
    }
}
