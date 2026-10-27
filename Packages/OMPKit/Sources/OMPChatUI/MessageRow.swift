import SwiftUI
import OMPCore
import OMPDesign

public struct MessageRow: View {
    private let message: ChatMessage
    private let mediaLibrary: MediaLibrary
    private let actions: Actions

    @Environment(ChatAppModel.self) private var model
    @State private var hovering = false
    @State private var hoverTimer: Timer?
    @State private var editing = false
    @State private var editText = ""
    @State private var copied = false
    @State private var showUsagePopover = false
    @ObservedObject private var speech = SpeechManager.shared

    public init(message: ChatMessage, mediaLibrary: MediaLibrary, actions: Actions) {
        self.message = message
        self.mediaLibrary = mediaLibrary
        self.actions = actions
    }

    public struct Actions {
        public var copy: () -> Void
        public var edit: ((String) -> Void)?
        public var branch: (() -> Void)?
        public var delete: (() -> Void)?
        public var regenerate: (() -> Void)?
        public var feedback: ((Int) -> Void)?
        public var reply: (() -> Void)?
        public var select: (() -> Void)?

        public init(
            copy: @escaping () -> Void,
            edit: ((String) -> Void)? = nil,
            branch: (() -> Void)? = nil,
            delete: (() -> Void)? = nil,
            regenerate: (() -> Void)? = nil,
            feedback: ((Int) -> Void)? = nil,
            reply: (() -> Void)? = nil,
            select: (() -> Void)? = nil
        ) {
            self.copy = copy
            self.edit = edit
            self.branch = branch
            self.delete = delete
            self.regenerate = regenerate
            self.feedback = feedback
            self.reply = reply
            self.select = select
        }
    }
    /// All image refs in this message, for lightbox paging.
    private var galleryRefs: [MediaRef] {
        message.parts.compactMap {
            if case .media(let ref) = $0, ref.kind == .image { return ref }
            return nil
        }
    }

    /// A turn with no text, media or tool traffic has nothing to draw. Rendering
    /// it produced empty capsules / residual pills in the transcript.
    private var hasRenderableContent: Bool {
        if message.status == .streaming { return true }
        if !message.concatenatedText.isEmpty { return true }
        if !message.thinkingText.isEmpty { return true }
        if !(message.errorText ?? "").isEmpty { return true }
        return message.parts.contains { part in
            switch part {
            case .media, .toolCall, .toolResult: return true
            default: return false
            }
        }
    }

    public var body: some View {
        Group {
            if !hasRenderableContent {
                EmptyView()
            } else if message.role == .user {
                userRow
            } else if message.role == .assistant {
                assistantRow
            } else {
                systemRow
            }
        }
        #if os(macOS)
        .onHover { enter in
            hoverTimer?.invalidate()
            withAnimation(Theme.Motion.fade) { hovering = enter }
        }
        #else
        // `onLongPressGesture` on the whole row wins over the buttons inside it:
        // every child button (action bar copy/reply, omp-ui tabs/buttons) became
        // unhittable. A simultaneous gesture reveals the action bar on long
        // press and still lets those buttons receive taps.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                hoverTimer?.invalidate()
                withAnimation(Theme.Motion.fade) { hovering = true }
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
                    withAnimation(Theme.Motion.fade) { hovering = false }
                }
            }
        )
        .onDisappear { hoverTimer?.invalidate() }
        #endif
    }


    // MARK: User

    private var userRow: some View {
        // Official user message: no avatar column, bubble right-aligned and
        // capped at ~78% of the 768pt transcript column.
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                if editing {
                    editor
                } else {
                    bubble
                }
                // A follow-up the reply took in but ended without answering.
                if let note = message.errorText, !note.isEmpty {
                    errorView(note)
                }
                HStack(spacing: 8) {
                    if !message.alternativeVersions.isEmpty {
                        userVersionPicker
                    }
                    actionBar(alignment: .trailing)
                }
            }
        }
    }
    /// Official user bubble: ompUserBubble fill, radius 22, padding 10×14,
    /// max width 78% of the transcript column, right aligned.
    private var bubble: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let value):
                    if !value.isEmpty {
                        MarkdownText(value)
                            .foregroundStyle(Color.ompText)
                    }
                case .media(let ref):
                    MediaAttachmentView(ref: ref, library: mediaLibrary, gallery: galleryRefs)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.ompUserBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .contextMenu { menuItems }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.s) {
            TextField("编辑消息", text: $editText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...12)
                .padding(10)
                .background(Color.ompCard, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
            HStack(spacing: Theme.Spacing.s) {
                Button("取消") {
                    editing = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button("发送") {
                    editing = false
                    actions.edit?(editText)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var userVersionPicker: some View {
        let allVersions = message.alternativeVersions + [message.concatenatedText]
        let total = allVersions.count
        let current = message.currentVersionIndex + 1
        return HStack(spacing: 4) {
            Button {
                model.switchUserPromptVersion(message.id, delta: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(current <= 1)

            Text("\(current)/\(total)")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ompTextTertiary)

            Button {
                model.switchUserPromptVersion(message.id, delta: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(current >= total)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            hovering ? Color.ompFill.opacity(0.8) : Color.clear,
            in: Capsule()
        )
        // Hidden until the row is hovered: a permanent pill on every user turn
        // reads as an unexplained grey blob in the transcript.
        .opacity(hovering ? 1 : 0)
    }

    // MARK: Assistant

    @ViewBuilder
    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Reasoning models stream thinking for seconds before the first
            // answer token (measured 9.2s on deepseek-v4.1-flash). A lone caret
            // reads as "stuck", so show a live status + thinking tail instead.
            if isAwaitingAnswer {
                StreamingThinkingStatus(startedAt: message.createdAt, thinking: message.thinkingText)
            } else {
                thinkingSection
            }
            operationSection
            replyVersionPicker
            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                partView(part)
            }
            if message.status == .streaming, !isAwaitingAnswer {
                StreamingCaret()
            }
            if let error = message.errorText, !error.isEmpty {
                errorView(error)
            }
            fileChangeSection
            actionBar(alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tool traffic folds into one collapsible card instead of loose pills.
    @ViewBuilder
    private var operationSection: some View {
        let calls = message.parts.compactMap { part -> ToolCall? in
            if case .toolCall(let call) = part { call } else { nil }
        }

        let results = message.parts.compactMap { part -> ToolResult? in
            if case .toolResult(let result) = part { result } else { nil }
        }
        if !calls.isEmpty {
            OperationCard(calls: calls, results: results)
        }
        // Calls of this message the agent loop is waiting on.
        let callIDs = Set(calls.map(\.id))
        let pending = model.pendingApprovals.filter {
            $0.conversationID == model.selectedConversationID && callIDs.contains($0.callID)
        }
        ForEach(pending) { request in
            ToolApprovalCard(request: request)
        }
    }

    /// Edit-like tool calls that carry a file path render as bordered cards.
    @ViewBuilder
    private var fileChangeSection: some View {
        let changes: [FileChange] = message.parts.compactMap { part in
            if case .toolCall(let call) = part,
               ActivityLog.editedFilePath(in: call) != nil {
                FileChange(
                    id: call.id,
                    call: call,
                    result: message.parts.compactMap { part -> ToolResult? in
                        if case .toolResult(let result) = part, result.callID == call.id { result } else { nil }
                    }.first
                )
            } else {
                nil
            }
        }
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(changes) { change in
                    FileChangeCard(change: change)
                }
            }
        }
    }

    /// Shows `< n/n >` when the last reply has regenerated alternatives.
    @ViewBuilder
    private var replyVersionPicker: some View {
        if message.role == .assistant,
           let conversation = model.selectedConversation,
           conversation.messages.last?.id == message.id,
           !conversation.alternativeReplies.isEmpty {
            let total = conversation.alternativeReplies.count + 1
            HStack(spacing: 4) {
                Button {
                    model.cycleReply(forward: false)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                Text("\(total)/\(total)")
                    .font(.system(size: 10).monospacedDigit())
                Button {
                    model.cycleReply(forward: true)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Color.ompTextSecondary)
            .opacity(hovering ? 1 : 0)
        }
    }

    private var systemRow: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "info.circle")
            Text(message.concatenatedText)
                .font(Theme.Typography.secondary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(Theme.Spacing.s)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }

    /// Streaming and no visible answer text yet.
    private var isAwaitingAnswer: Bool {
        message.status == .streaming && message.concatenatedText.isEmpty
    }

    @ViewBuilder
    private var thinkingSection: some View {
        let thinking = message.thinkingText
        if !thinking.isEmpty {
            DisclosureGroup {
                Text(thinking)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 10, weight: .medium))
                    Text("思考过程")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)
        }
    }

    /// `omp-ui` buttons post their text as the next user turn. Ignored while a
    /// reply is still streaming, same as the composer.
    private var genUISend: @MainActor @Sendable (String) -> Void {
        { [model] text in
            guard !model.isStreaming else { return }
            Task { await model.sendNow(text: text, attachments: []) }
        }
    }

    @ViewBuilder
    private func partView(_ part: ContentPart) -> some View {
        switch part {
        case .text(let value):
            if !value.isEmpty {
                MarkdownText(value)
                    .foregroundStyle(Color.ompText)
                    .environment(\.genUISend, genUISend)
                    .environment(\.ompFileReferencesEnabled, true)
            }
        case .thinking, .thinkingSeal:
            EmptyView()
        case .media(let ref):
            MediaAttachmentView(ref: ref, library: mediaLibrary)
        case .toolCall:
            EmptyView()
        case .toolResult:
            EmptyView()
        }
    }

    private func errorView(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(error)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }

    @ViewBuilder
    private var metaRow: some View {
        if hovering, let usage = message.usage, usage.totalTokens > 0 {
            Button {
                showUsagePopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Label(TokenFormat.compact(usage.inputTokens), systemImage: "arrow.up")
                        .foregroundStyle(Color.green)
                    Label(TokenFormat.compact(usage.outputTokens), systemImage: "arrow.down")
                        .foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.ompFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("点击查看 Token 详细用量")
            .popover(isPresented: $showUsagePopover) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Token 用量明细")
                        .font(.system(size: 12, weight: .semibold))
                    Divider()
                    HStack {
                        Text("输入 (Prompt):")
                        Spacer()
                        Text("\(usage.inputTokens)")
                            .font(.system(size: 11.5).monospacedDigit())
                    }
                    HStack {
                        Text("输出 (Completion):")
                        Spacer()
                        Text("\(usage.outputTokens)")
                            .font(.system(size: 11.5).monospacedDigit())
                    }
                    if usage.reasoningTokens > 0 {
                        HStack {
                            Text("其中思考 (Thinking):")
                            Spacer()
                            Text("\(usage.reasoningTokens)")
                                .font(.system(size: 11.5).monospacedDigit())
                        }
                    }
                    Divider()
                    HStack {
                        Text("总计:")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(usage.totalTokens)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                }
                .font(.system(size: 11.5))
                .padding(12)
                .frame(width: 200)
            }
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color.ompTextTertiary)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actionBar(alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 4) {
            if alignment == .trailing { Spacer(minLength: 0) }

            if message.role == .assistant, !message.concatenatedText.isEmpty {
                let speaking = speech.speakingMessageID == message.id
                iconButton(
                    speaking ? "stop.circle.fill" : "speaker.wave.2",
                    help: speaking ? "停止朗读" : "朗读"
                ) {
                    Speech.speak(
                        message.concatenatedText,
                        messageID: message.id,
                        rateMultiplier: model.settings.speechRateMultiplier,
                        language: model.settings.speechVoiceLanguage
                    )
                }
                .foregroundStyle(speaking ? Color.accentColor : Color.secondary)
            }
            iconButton(copied ? "checkmark" : "doc.on.doc", help: "复制") {
                actions.copy()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            }

            if let reply = actions.reply {
                iconButton("arrowshape.turn.up.left", help: "引用回复") { reply() }
            }

            if message.role == .user, actions.edit != nil {
                iconButton("pencil", help: "编辑并重新发送") {
                    editText = message.concatenatedText
                    editing = true
                }
            }

            if let branch = actions.branch {
                iconButton("arrow.triangle.branch", help: "从这里分支") { branch() }
            }

            if message.role == .assistant, let feedback = actions.feedback {
                iconButton(message.feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup", help: "赞") {
                    feedback(1)
                }
                iconButton(message.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown", help: "踩") {
                    feedback(-1)
                }
            }

            if message.role == .assistant, let regenerate = actions.regenerate {
                iconButton("arrow.clockwise", help: "重新生成") { regenerate() }
            }

            if message.role == .assistant {
                metaRow
            }

            if let select = actions.select {
                iconButton(model.selectedMessageIDs.contains(message.id) ? "checkmark.circle.fill" : "circle", help: "选择") { select() }
            }

            if let delete = actions.delete {
                iconButton("trash", help: "删除消息") { delete() }
            }

            if alignment == .leading { Spacer(minLength: 0) }
        }
        // Reserving 18pt for a hidden action bar left a dead band under every
        // turn (turns read ~34pt apart instead of 16pt). Collapse it instead.
        .frame(height: hovering ? 18 : 0)
        .opacity(hovering ? 1 : 0)
        .clipped()
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ompTextSecondary)
        .help(help)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            actions.copy()
        } label: {
            Label("复制内容", systemImage: "doc.on.doc")
        }
        if let reply = actions.reply {
            Button { reply() } label: {
                Label("引用此条", systemImage: "arrowshape.turn.up.left")
            }
        }
        if message.role == .assistant, !message.concatenatedText.isEmpty {
            let speaking = speech.speakingMessageID == message.id
            Button {
                Speech.speak(
                    message.concatenatedText,
                    messageID: message.id,
                    rateMultiplier: model.settings.speechRateMultiplier,
                    language: model.settings.speechVoiceLanguage
                )
            } label: {
                Label(speaking ? "停止朗读" : "朗读此条", systemImage: speaking ? "stop.circle" : "speaker.wave.2")
            }
        }
        if actions.edit != nil {
            Button {
                editText = message.concatenatedText
                editing = true
            } label: {
                Label("编辑重发", systemImage: "pencil")
            }
        }
        if let branch = actions.branch {
            Button { branch() } label: {
                Label("从这里分支", systemImage: "arrow.triangle.branch")
            }
        }
        if let delete = actions.delete {
            Divider()
            Button(role: .destructive) { delete() } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

/// Pulsing dot at the end of a streaming answer (official ChatGPT cursor).
public struct StreamingCaret: View {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Circle()
            .fill(Color.ompText)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel("正在生成")
    }
}

/// Pre-answer state of a streaming reply: shimmering "正在思考", elapsed
/// seconds, and the tail of the reasoning as it arrives.
struct StreamingThinkingStatus: View {
    let startedAt: Date
    let thinking: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ShimmerText(text: "正在思考", font: .system(size: 14, weight: .medium))
                    Text(Self.elapsed(from: startedAt, to: context.date))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.ompTextTertiary)
                }
                if !tail.isEmpty {
                    Text(tail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompTextSecondary)
                        .lineSpacing(3)
                        .lineLimit(4, reservesSpace: false)
                        .truncationMode(.head)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.ompBorder).frame(width: 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在思考，\(Self.elapsed(from: startedAt, to: context.date))")
        }
    }

    /// Last four non-empty lines of the reasoning stream.
    private var tail: String {
        thinking
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(4)
            .joined(separator: "\n")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}

/// Text with a highlight sweeping left to right; static under Reduce Motion.
struct ShimmerText: View {
    let text: String
    let font: Font
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Color.ompTextTertiary)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.ompText, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width * 1.6 - geo.size.width * 0.6)
                }
                .mask(Text(text).font(font))
                .opacity(reduceMotion ? 0 : 1)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

public struct MediaAttachmentView: View {
    private let ref: MediaRef
    private let library: MediaLibrary
    private let gallery: [MediaRef]
    @State private var showingLightbox = false

    public init(ref: MediaRef, library: MediaLibrary, gallery: [MediaRef] = []) {
        self.ref = ref
        self.library = library
        self.gallery = gallery.isEmpty ? [ref] : gallery
    }

    public var body: some View {
        Group {
            if ref.kind == .image, let image = PlatformImage.load(at: library.url(for: ref)) {
                Button {
                    showingLightbox = true
                } label: {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                                .strokeBorder(Color.ompBorder.opacity(0.8), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.06), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showingLightbox) {
                    let startIndex = gallery.firstIndex(where: { $0.id == ref.id }) ?? 0
                    ImageLightboxSheet(gallery: gallery, library: library, startIndex: startIndex)
                }
            } else {
                Label(ref.originalName ?? ref.relativePath, systemImage: icon)
                    .font(Theme.Typography.caption)
                    .padding(8)
                    .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            }
        }
    }

    private var icon: String {
        switch ref.kind {
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .file: "doc"
        }
    }
}

#if os(macOS)
import AppKit
typealias PlatformImageType = NSImage
#else
import UIKit
typealias PlatformImageType = UIImage
#endif

enum PlatformImage {
    static func load(at url: URL) -> PlatformImageType? {
        #if os(macOS)
        NSImage(contentsOf: url)
        #else
        UIImage(contentsOfFile: url.path)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImageType) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Fullscreen zoomable lightbox for attachments matching ChatGPT Desktop.
/// Holds a gallery of image refs so multi-image messages can page through
/// (imagePreviewDialog.nextImage / previousImage).
struct ImageLightboxSheet: View {
    let gallery: [MediaRef]
    let library: MediaLibrary
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var copied = false
    @State private var zoom: CGFloat = 1.0
    @State private var index: Int = 0
    @State private var current: PlatformImageType?

    init(gallery: [MediaRef], library: MediaLibrary, startIndex: Int) {
        self.gallery = gallery
        self.library = library
        self.startIndex = startIndex
    }

    private var fileURL: URL { library.url(for: gallery[index]) }

    private var canPage: Bool { gallery.count > 1 }

    private func goTo(_ delta: Int) {
        let next = index + delta
        guard gallery.indices.contains(next) else { return }
        index = next
        zoom = 1.0
        loadImage()
    }

    private func loadImage() {
        current = PlatformImage.load(at: fileURL)
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()

                if let image = current {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .id(index)
                        .scaleEffect(zoom)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { val in zoom = max(0.8, min(4.0, val)) }
                        )
                        .padding(24)
                }

                if canPage {
                    Button {
                        goTo(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(index == 0 ? 0.25 : 0.9))
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)

                    Button {
                        goTo(1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(index == gallery.count - 1 ? 0.25 : 0.9))
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index == gallery.count - 1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 18)
                }
            }
            .navigationTitle(fileURL.lastPathComponent)
            .overlay(alignment: .bottom) {
                if canPage {
                    Text("\(index + 1) / \(gallery.count)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 14)
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            zoom = max(0.5, zoom - 0.25)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .help("缩小")
                        Text("\(Int(zoom * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .frame(width: 42)
                        Button {
                            zoom = min(4.0, zoom + 0.25)
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .help("放大")
                        Button("适应") { zoom = 1.0 }
                            .help("恢复原始大小")

                        Button {
                            guard let image = current else { return }
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([image])
                            #else
                            UIPasteboard.general.image = image
                            #endif
                            copied = true
                            AudioFeedback.playSend(enabled: true)
                            Task {
                                try? await Task.sleep(for: .seconds(1.2))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "已复制" : "复制图片", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }

                        Button {
                            saveImage()
                        } label: {
                            Label(saved ? "已保存" : "保存到本地", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                        }
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 780, minHeight: 560)
        .onKeyPress(phases: .down) { press in
            guard canPage else { return .ignored }
            if press.key == .leftArrow { goTo(-1); return .handled }
            if press.key == .rightArrow { goTo(1); return .handled }
            return .ignored
        }
        #endif
        .onAppear {
            index = min(max(0, startIndex), max(0, gallery.count - 1))
            loadImage()
        }
    }

    private func saveImage() {
        guard let image = current else { return }
        #if os(macOS)
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            let target = downloads.appendingPathComponent(fileURL.lastPathComponent)
            try? FileManager.default.copyItem(at: fileURL, to: target)
            saved = true
            AudioFeedback.playComplete(enabled: true)
        }
        #else
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        saved = true
        AudioFeedback.playComplete(enabled: true)
        #endif
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
        }
    }
}

