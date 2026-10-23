import SwiftUI
import OMPCore
import OMPDesign

public struct ChatTranscriptView: View {
    @Environment(ChatAppModel.self) private var model

    public init() {}

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Layout.messageSpacing) {
                    if let conversation = model.selectedConversation {
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
                .padding(.horizontal, Theme.Layout.transcriptPadding)
                .padding(.top, 20)
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
            regenerate: message.role == .assistant ? { model.regenerateLast() } : nil
        )
    }

    private var scrollSignature: String {
        guard let conversation = model.selectedConversation, let last = conversation.messages.last else {
            return "empty-\(model.selectedConversationID?.uuidString ?? "-")"
        }
        let textCount = last.parts.reduce(0) { $0 + $1.plainText.count }
        return "\(conversation.id)-\(conversation.messages.count)-\(last.id)-\(textCount)-\(last.status.rawValue)"
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        if model.needsSetup {
            setupPrompt
        } else {
            VStack(spacing: 0) {
                OMPMark(size: 54)
                    .padding(.bottom, 18)
                Text("今天想聊点什么？")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Color.ompText)
                    .padding(.bottom, 6)
                Text("当前模型 \(model.activeModel?.displayName ?? "未选择") · 输入 / 调用快捷模板")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.ompTextSecondary)
                    .padding(.bottom, 26)

                VStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button {
                            model.draft = suggestion
                        } label: {
                            HStack(spacing: 8) {
                                Text(suggestion)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.ompText)
                                Spacer()
                                Image(systemName: "arrow.up.left")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.ompTextTertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 64)
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
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    private static let suggestions = [
        "用三句话解释 Swift 的 actor 隔离",
        "把这段需求拆成可执行的开发任务",
        "帮我审查这段代码的并发安全风险",
    ]
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
        .padding(.horizontal, Theme.Layout.transcriptPadding)
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
        .padding(.horizontal, Theme.Layout.transcriptPadding)
        .padding(.top, 8)
        .onTapGesture(perform: onDismiss)
    }
}
