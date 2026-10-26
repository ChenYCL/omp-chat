#if os(macOS)
import SwiftUI
import OMPCore

/// The side panel's 旁聊 tab (Codex `thread.sidePanel` Side chat): questions
/// about the selected thread, answered with the thread as context but kept out
/// of it. An answer reaches the thread only through 插入输入框.
struct SideChatPane: View {
    @Environment(ChatAppModel.self) private var model
    @State private var question = ""
    @State private var failure: String?

    private var threadID: UUID? { model.selectedConversationID }
    private var messages: [ChatMessage] { threadID.map(model.sideChat(for:)) ?? [] }
    private var streaming: Bool { threadID != nil && model.sideChatStreamingID == threadID }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            Text("就当前对话提问，比如「刚才定下的方案是什么」。回答不会写进对话。")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ompTextTertiary)
                                .padding(.top, 8)
                        }
                        ForEach(messages) { message in
                            row(message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.last?.concatenatedText) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            inputBar
        }
        .onChange(of: threadID) { _, _ in failure = nil }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 11))
            Text(model.selectedConversation?.title ?? "没有选中的对话")
                .font(.system(size: 11.5))
                .lineLimit(1)
            Spacer()
            Button("清空") {
                if let threadID { model.clearSideChat(threadID) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .disabled(messages.isEmpty)
            .accessibilityIdentifier("sideChat.clear")
        }
        .foregroundStyle(Color.ompTextSecondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder
    private func row(_ message: ChatMessage) -> some View {
        if message.role == .user {
            Text(message.concatenatedText)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ompText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if message.concatenatedText.isEmpty, message.status == .streaming {
                    ProgressView().controlSize(.small)
                } else {
                    MarkdownText(message.concatenatedText)
                        .textSelection(.enabled)
                }
                if let error = message.errorText {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.red)
                }
                if message.status == .complete, !message.concatenatedText.isEmpty, let threadID {
                    Button {
                        model.insertSideChatAnswer(message.id, from: threadID)
                    } label: {
                        Label("插入输入框", systemImage: "arrow.down.to.line")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.ompTextSecondary)
                    .help("把这条回答放进主对话的输入框，由你决定要不要发送")
                    .accessibilityIdentifier("sideChat.insert")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
            }
            HStack(spacing: 6) {
                TextField("问一个关于这个对话的问题", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit(send)
                    .disabled(threadID == nil)
                    .accessibilityIdentifier("sideChat.input")
                if streaming {
                    Button {
                        model.stopSideChat()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .help("停止")
                    .accessibilityIdentifier("sideChat.stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || threadID == nil)
                    .help("发送")
                    .accessibilityIdentifier("sideChat.send")
                }
            }
        }
        .padding(10)
    }

    private func send() {
        // Commit any IME composition first so the last word is not dropped.
        GenUIButton.endTextEditing()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            failure = model.sendSideChat(question)
            if failure == nil { question = "" }
        }
    }
}
#endif
