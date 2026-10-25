import SwiftUI
import OMPCore
import OMPDesign

#if os(iOS)
/// Full remote control surface for one Mac conversation.
///
/// The phone is not a read-only mirror: every action a user can take on the
/// desktop is available here (send, stop, regenerate, edit-and-resend, branch,
/// delete, feedback, rename, pin/archive/lock/unread, model switch). All of it
/// is expressed as [`RelayCommand`]s the Mac executes against its own model, so
/// there is exactly one source of truth and no divergent local state.
///
/// Interaction mirrors moshi / Paseo / collie conventions:
/// - assistant replies are plain text on the canvas, user turns are bubbles
/// - a floating status chip row above the composer (diff / usage / tools)
/// - long-press a message for the full action sheet
/// - the composer is a single-line pill that grows to six lines
struct RemoteConsoleScreen: View {
    let conversationID: String
    let client: (any RelayCommandSink)?
    let hostName: String
    let conversationProvider: (String) -> RelayConversation?
    let onDismiss: () -> Void

    @State private var draft = ""
    @State private var sending = false
    @State private var stopInFlight = false
    @State private var editingMessageID: String?
    @State private var editText = ""
    @State private var renaming = false
    @State private var renameText = ""
    @State private var feedbackFlash: String?
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if let conversation = currentConversation {
                transcript(of: conversation)
                chips(for: conversation)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在同步会话…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ompTextTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let conversation = currentConversation {
                composer(for: conversation)
            }
        }
        .background(Color.ompCanvas)
        .alert("重命名对话", isPresented: $renaming) {
            TextField("对话标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { submit(.rename(conversationID: conversationID, title: renameText)) }
        }
        .alert("编辑并重发", isPresented: Binding(
            get: { editingMessageID != nil },
            set: { if !$0 { editingMessageID = nil } }
        )) {
            TextField("新内容", text: $editText, axis: .vertical)
            Button("取消", role: .cancel) { editingMessageID = nil }
            Button("发送") {
                if let id = editingMessageID {
                    submit(.editAndResend(conversationID: conversationID, messageID: id, text: editText))
                }
                editingMessageID = nil
            }
        }
        .overlay(alignment: .top) {
            if let feedbackFlash {
                Text(feedbackFlash)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ompInverseText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.ompPrimarySolid, in: Capsule())
                    .padding(.top, 56)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: feedbackFlash)
    }

    private var currentConversation: RelayConversation? {
        conversationProvider(conversationID)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
                onDismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            VStack(spacing: 1) {
                Text(currentConversation?.title ?? "远程会话")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                Text(hostName.isEmpty ? "已连接" : hostName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ompTextTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Menu {
                Button { renameText = currentConversation?.title ?? ""; renaming = true } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button { submit(.regenerate(conversationID: conversationID)) } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
                Button { submit(.togglePin(conversationID: conversationID)) } label: {
                    Label("置顶 / 取消置顶", systemImage: "pin")
                }
                Button { submit(.toggleArchive(conversationID: conversationID)) } label: {
                    Label("归档", systemImage: "archivebox")
                }
                Button { submit(.setUnread(conversationID: conversationID, unread: true)) } label: {
                    Label("标记为未读", systemImage: "envelope.badge")
                }
                Divider()
                Button(role: .destructive) {
                    submit(.delete(conversationID: conversationID))
                    dismiss()
                } label: {
                    Label("删除对话", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 32, height: 32)
            }
            .accessibilityIdentifier("remote.console.menu")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    // MARK: Transcript

    private func transcript(of conversation: RelayConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(conversation.messages, id: \.id) { message in
                        RemoteConsoleBubble(message: message)
                            .id(message.id)
                            .contextMenu { menu(for: message) }
                    }
                    if let error = nil as String? {
                        Text(error).font(.system(size: 12))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: conversation.messages.last?.text) { _, _ in
                if let last = conversation.messages.last {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for message: RelayMessage) -> some View {
        Button {
            UIPasteboard.general.string = message.text
            flash("已复制")
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        if message.role == "user" {
            Button {
                editText = message.text
                editingMessageID = message.id
            } label: {
                Label("编辑并重发", systemImage: "pencil")
            }
        }
        Button {
            submit(.branch(conversationID: conversationID, messageID: message.id))
            flash("已从该消息分支")
        } label: {
            Label("从这里分支", systemImage: "arrow.triangle.branch")
        }
        if message.role == "assistant" {
            Button {
                submit(.feedback(conversationID: conversationID, messageID: message.id, value: 1))
                flash("已赞")
            } label: {
                Label("赞", systemImage: "hand.thumbsup")
            }
            Button {
                submit(.feedback(conversationID: conversationID, messageID: message.id, value: -1))
                flash("已踩")
            } label: {
                Label("踩", systemImage: "hand.thumbsdown")
            }
        }
        Divider()
        Button(role: .destructive) {
            submit(.deleteMessage(conversationID: conversationID, messageID: message.id))
        } label: {
            Label("删除这条消息", systemImage: "trash")
        }
    }

    // MARK: Chips

    @ViewBuilder
    private func chips(for conversation: RelayConversation) -> some View {
        let lastAssistant = conversation.messages.last { $0.role == "assistant" }
        HStack(spacing: 6) {
            if conversation.isStreaming {
                chip {
                    ProgressView().controlSize(.mini)
                    Text("生成中")
                }
            }
            chip {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.ompTextTertiary)
                Text("\(conversation.messages.count) 条")
            }
            if let lastAssistant, !lastAssistant.text.isEmpty {
                chip {
                    Image(systemName: "text.word.spacing")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.ompTextTertiary)
                    Text("\(lastAssistant.text.count) 字")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func chip(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 4) { content() }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.ompTextSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.ompCard, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.ompBorder, lineWidth: 0.5))
    }

    // MARK: Composer

    private func composer(for conversation: RelayConversation) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发送消息", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($inputFocused)
                .accessibilityIdentifier("remote.console.input")
                .onSubmit(send)

            if conversation.isStreaming {
                Button {
                    guard let client, !stopInFlight else { return }
                    stopInFlight = true
                    Task {
                        try? await client.submit(.stop(conversationID: conversationID))
                        stopInFlight = false
                    }
                } label: {
                    ZStack {
                        Circle().fill(Color.ompPrimarySolid).frame(width: 32, height: 32)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.ompInverseText)
                            .frame(width: 11, height: 11)
                    }
                }
                .buttonStyle(.plain)
                .disabled(stopInFlight)
                .accessibilityIdentifier("remote.console.stop")
                .accessibilityLabel("停止生成")
            } else {
                Button(action: send) {
                    Circle()
                        .fill(canSend ? Color.ompPrimarySolid : Color.ompFill)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(canSend ? Color.ompInverseText : Color.ompTextTertiary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityIdentifier("remote.console.send")
                .accessibilityLabel("发送消息")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.ompCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.ompBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending && client != nil
    }

    // MARK: Actions

    private func send() {
        guard canSend, let client else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        Task {
            defer { sending = false }
            do {
                try await client.submit(.input(conversationID: conversationID, text: text))
                draft = ""
            } catch {
                flash("发送失败，稍后重试")
            }
        }
    }

    private func submit(_ command: RelayCommand) {
        guard let client else { return }
        Task {
            do {
                try await client.submit(command)
            } catch {
                flash("操作失败")
            }
        }
    }

    private func flash(_ text: String) {
        feedbackFlash = text
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if feedbackFlash == text { feedbackFlash = nil }
        }
    }
}

// MARK: - Bubble

/// moshi convention: the assistant speaks on the canvas, the user speaks from a
/// bubble. Streaming shows a blinking caret instead of a spinner.
struct RemoteConsoleBubble: View {
    let message: RelayMessage
    @State private var caretOn = true

    var body: some View {
        Group {
            if message.role == "user" {
                HStack(spacing: 0) {
                    Spacer(minLength: 48)
                    Text(message.text)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.ompText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Color.ompUserBubble,
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                        )
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(message.text)
                            .font(.system(size: 16))
                            .lineSpacing(10)
                            .foregroundStyle(Color.ompText)
                            .textSelection(.enabled)
                        if message.streaming {
                            Text("▍")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.ompTextTertiary)
                                .opacity(caretOn ? 1 : 0.15)
                        }
                    }
                    Text(RelativeDateTimeFormatter.ompRelay.string(for: message.ts) ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.ompTextTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            guard message.streaming else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                caretOn = false
            }
        }
    }
}

// MARK: - Helpers

private extension RelativeDateTimeFormatter {
    static let ompRelay: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
#endif
