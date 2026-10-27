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
    /// Approval cards the Mac is waiting on, read fresh on every render.
    let approvals: () -> [RelayApproval]
    /// The Mac's latest refusals of phone commands, read fresh on every render.
    let commandFailures: () -> [RelayCommandFailure]
    let onDismiss: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var draft = ""
    @State private var sending = false
    @State private var stopInFlight = false
    @State private var editingMessageID: String?
    @State private var editText = ""
    @State private var renaming = false
    @State private var renameText = ""
    @State private var feedbackFlash: String?
    @State private var approvalTracker = RemoteApprovalTracker()
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
                queuedStrip(for: conversation)
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
        .onChange(of: approvals()) { _, _ in reconcileApprovals() }
        .onChange(of: commandFailures()) { _, _ in reconcileApprovals() }
        // An answer that hears nothing back gives up, so its card works again.
        .task(id: approvalTracker.nextDeadline) {
            guard let deadline = approvalTracker.nextDeadline else { return }
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            reconcileApprovals()
        }
    }

    private var currentConversation: RelayConversation? {
        conversationProvider(conversationID)
    }

    /// The open conversation's approval cards, oldest first.
    private var openApprovals: [RelayApproval] {
        approvals().filter { $0.conversationID == conversationID }
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

    /// `omp-ui` buttons on the phone post into the same Mac conversation.
    private var remoteGenUISend: (@MainActor @Sendable (String) -> Void)? {
        guard let client else { return nil }
        let id = conversationID
        return { text in
            Task { try? await client.submit(.input(conversationID: id, text: text)) }
        }
    }

    // MARK: Transcript

    private func transcript(of conversation: RelayConversation) -> some View {
        let cards = openApprovals
        let placement = Self.place(cards, in: conversation.messages)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(conversation.messages, id: \.id) { message in
                        RemoteConsoleBubble(message: message)
                            .environment(\.genUISend, remoteGenUISend)
                            .id(message.id)
                            .contextMenu { menu(for: message) }
                        ForEach(placement.byMessage[message.id] ?? []) { approval in
                            approvalCard(approval)
                        }
                    }
                    ForEach(placement.unplaced) { approval in
                        approvalCard(approval)
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
            // A new card is what the agent waits on: bring it into view.
            .onChange(of: cards.map(\.id)) { old, new in
                guard let fresh = new.last(where: { !old.contains($0) }) else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.cardScrollID(fresh), anchor: .bottom)
                }
            }
        }
    }

    /// Each card goes under the assistant message whose activity holds its
    /// call; a card whose call is not in the mirrored messages goes last.
    private static func place(
        _ cards: [RelayApproval], in messages: [RelayMessage]
    ) -> (byMessage: [String: [RelayApproval]], unplaced: [RelayApproval]) {
        var owner: [String: String] = [:]
        for message in messages {
            for activity in message.activity ?? [] { owner[activity.id] = message.id }
        }
        var byMessage: [String: [RelayApproval]] = [:]
        var unplaced: [RelayApproval] = []
        for card in cards {
            if let messageID = owner[card.callID] {
                byMessage[messageID, default: []].append(card)
            } else {
                unplaced.append(card)
            }
        }
        return (byMessage, unplaced)
    }

    private static func cardScrollID(_ approvalID: String) -> String { "approval-\(approvalID)" }

    private func approvalCard(_ approval: RelayApproval) -> some View {
        RemoteApprovalCard(
            approval: approval,
            sending: approvalTracker.isSending(approval.id),
            error: approvalTracker.error(for: approval.id),
            onAnswer: { answer(approval, $0) }
        )
        .id(Self.cardScrollID(approval.id))
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

    // MARK: Queued follow-ups

    /// The Mac's queued follow-ups for this conversation, as chips above the
    /// composer: 立即发送 and 删除 go to the Mac; 编辑 brings the text back
    /// into this composer and drops it there.
    @ViewBuilder
    private func queuedStrip(for conversation: RelayConversation) -> some View {
        if !conversation.queued.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(queuedHeader(conversation))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
                ForEach(conversation.queued) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.held ? "pause.circle" : "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ompTextTertiary)
                        Text(item.text.isEmpty ? "附件消息" : item.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ompText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        queuedAction("立即发送", id: "remote.console.queued.sendNow") {
                            submit(.sendQueuedNow(conversationID: conversationID, queuedID: item.id))
                        }
                        if !item.hasAttachments {
                            queuedAction("编辑", id: "remote.console.queued.edit") {
                                draft = draft.isEmpty ? item.text : draft + "\n" + item.text
                                submit(.removeQueued(conversationID: conversationID, queuedID: item.id))
                                inputFocused = true
                            }
                        }
                        queuedAction("删除", id: "remote.console.queued.delete") {
                            submit(.removeQueued(conversationID: conversationID, queuedID: item.id))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.ompCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.ompBorder, lineWidth: 0.5)
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("remote.console.queued.item")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityIdentifier("remote.console.queued")
        }
    }

    private func queuedHeader(_ conversation: RelayConversation) -> String {
        if conversation.isCompacting { return "压缩时不能插话，消息会在压缩完成后发送" }
        if conversation.queued.allSatisfy(\.held) { return "已停止 · 这些消息不会自动发出" }
        return "排队中 · 回复的下一步会带上"
    }

    private func queuedAction(_ title: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.ompTextSecondary)
            .accessibilityIdentifier(id)
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
            }
            // While the Mac replies, a typed message joins its queue as a
            // follow-up, so send shows beside stop.
            if !conversation.isStreaming || canSend {
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

    /// Sends 允许一次 / 拒绝 for one card. The card waits for the Mac's next
    /// snapshot to drop it (applied) or to name the request (refused).
    private func answer(_ approval: RelayApproval, _ decision: RelayApprovalDecision) {
        guard let client, let requestID = approvalTracker.begin(approval.id) else { return }
        Task {
            do {
                try await client.submit(.approve(approvalID: approval.id, decision: decision, requestID: requestID))
            } catch {
                approvalTracker.sendFailed(approval.id, message: RemoteApprovalTracker.sendFailureMessage(error))
            }
        }
    }

    private func reconcileApprovals() {
        for notice in approvalTracker.update(approvals: approvals(), failures: commandFailures()) {
            flash(notice)
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
                    if !message.thinking.isNilOrEmpty {
                        RemoteThinkingRow(text: message.thinking ?? "")
                    }
                    if let activities = message.activity, !activities.isEmpty {
                        RemoteOperationGroup(activities: activities)
                    }
                    // Same renderer as the Mac: code blocks, tables, math and
                    // omp-ui interfaces instead of raw markdown source.
                    if !message.text.isEmpty {
                        MarkdownText(message.text)
                            .foregroundStyle(Color.ompText)
                    }
                    if message.streaming {
                        Text("▍")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.ompTextTertiary)
                            .opacity(caretOn ? 1 : 0.15)
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

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

/// Collapsible "思考过程" row above an assistant reply, mirroring the
/// desktop `MessageRow.thinkingSection` at phone scale.
struct RemoteThinkingRow: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Theme.Motion.quick) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 10, weight: .medium))
                    Text("思考过程")
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.ompTextTertiary)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.ompTextSecondary)
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("remote.console.thinking")
            if expanded {
                Text(text)
                    .font(.system(size: 12.5))
                    .lineSpacing(4)
                    .foregroundStyle(Color.ompTextSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Collapsed "<N> 个操作" strip: one 26pt header with a total diff chip,
/// expanding into 13pt activity rows. Tap a row to unfold its capped
/// arguments + output detail. Official diff colours, OMPDesign tokens.
struct RemoteOperationGroup: View {
    let activities: [RelayActivity]
    @State private var expanded = false
    @State private var detailedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(Theme.Motion.quick) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.ompTextTertiary)
                    statusIcon
                    Text("\(activities.count) 个操作")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompTextSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let summary = diffSummary {
                        DiffChip(added: summary.added, removed: summary.removed)
                    }
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("remote.console.operations")
            if expanded {
                ForEach(activities) { activity in
                    RemoteActivityRow(
                        activity: activity,
                        showsDetail: detailedID == activity.id,
                        onToggleDetail: {
                            withAnimation(Theme.Motion.quick) {
                                detailedID = detailedID == activity.id ? nil : activity.id
                            }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if activities.contains(where: { $0.status == "running" }) {
            ProgressView()
                .controlSize(.mini)
                .tint(Color.ompDynamic(light: 0xAB1616, dark: 0xFDB9AB))
        } else if activities.contains(where: { $0.status == "error" }) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ompFlat(rgb: 0xDE4A43))
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ompDynamic(light: 0x055F51, dark: 0x42DEC2))
        }
    }

    private var diffSummary: (added: Int, removed: Int)? {
        let added = activities.reduce(0) { $0 + ($1.added ?? 0) }
        let removed = activities.reduce(0) { $0 + ($1.removed ?? 0) }
        return (added == 0 && removed == 0) ? nil : (added, removed)
    }
}

/// One 26pt activity row: status icon + summary + per-row diff chip, tapping
/// expands the capped detail panel (arguments + output, mono 12.5pt).
struct RemoteActivityRow: View {
    let activity: RelayActivity
    let showsDetail: Bool
    let onToggleDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggleDetail) {
                HStack(spacing: 6) {
                    RemoteToolStatusIcon(status: activity.status)
                    Text(activity.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if activity.added != nil || activity.removed != nil {
                        DiffChip(added: activity.added ?? 0, removed: activity.removed ?? 0)
                    }
                    Image(systemName: showsDetail ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.ompTextTertiary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("remote.console.activity.\(activity.id)")
            if showsDetail, let detail = activity.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(activity.status == "error" ? Color.ompFlat(rgb: 0xDE4A43) : Color.ompTextSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous))
            }
        }
    }
}

/// Remote twin of `ToolStatusIcon` driven by the wire status string.
struct RemoteToolStatusIcon: View {
    let status: String

    var body: some View {
        switch status {
        case "running":
            ProgressView()
                .controlSize(.mini)
                .tint(Color.ompDynamic(light: 0xAB1616, dark: 0xFDB9AB))
        case "error":
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ompFlat(rgb: 0xDE4A43))
        default:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ompDynamic(light: 0x055F51, dark: 0x42DEC2))
        }
    }
}

// MARK: - Approval card

/// Phone twin of the Mac's `ToolApprovalCard`: one tool call the Mac's agent
/// is suspended on. Only 允许一次 / 拒绝 — 始终允许 stays a Mac decision. When
/// the Mac does not let the phone allow this call, 允许一次 is off and the
/// card says why; 拒绝 always works.
struct RemoteApprovalCard: View {
    let approval: RelayApproval
    /// An answer is on its way; both buttons wait for the Mac.
    let sending: Bool
    /// Why the last answer did not apply.
    let error: String?
    let onAnswer: (RelayApprovalDecision) -> Void
    @State private var showArguments = false

    private var risk: ToolRisk? { ToolRisk(rawValue: approval.risk) }

    private var riskColor: Color {
        switch risk {
        case .read?: Color.ompTextSecondary
        case .control?: Color.red
        default: Color.orange
        }
    }

    /// The refusal text when it would only repeat the notice under the card.
    private var shownError: String? {
        guard let error else { return nil }
        return !approval.canApprove && error == RemoteApprovalTracker.shellDisabledMessage ? nil : error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: risk == .control ? "cursorarrow.click.2" : "exclamationmark.shield")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(riskColor)
                Text("需要你的批准 · \(risk?.title ?? approval.risk)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                Spacer(minLength: 0)
                Text(approval.source)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
                    .lineLimit(1)
            }
            Text(approval.summary.isEmpty ? approval.toolName : approval.summary)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.ompText)
                .textSelection(.enabled)
                .lineLimit(6)
                .accessibilityIdentifier("remote.approval.summary")
            if !approval.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup(isExpanded: $showArguments) {
                    ScrollView {
                        Text(approval.argumentsJSON)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.ompTextSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                } label: {
                    Text("参数")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextSecondary)
                }
                .accessibilityIdentifier("remote.approval.arguments")
            }
            if !approval.canApprove {
                Text(RemoteApprovalTracker.shellDisabledMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ompTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("remote.approval.notice")
            }
            if let shownError {
                Label(shownError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("remote.approval.error")
            }
            HStack(spacing: 8) {
                Button("允许一次") { onAnswer(.allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || !approval.canApprove)
                    .accessibilityIdentifier("remote.approval.allowOnce")
                Button("拒绝", role: .destructive) { onAnswer(.deny) }
                    .buttonStyle(.bordered)
                    .disabled(sending)
                    .accessibilityIdentifier("remote.approval.deny")
                if sending {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.ompCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(riskColor.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.approval.card")
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
