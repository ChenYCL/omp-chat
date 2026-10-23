import SwiftUI
import OMPCore
import OMPDesign

public struct MessageRow: View {
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

    private let message: ChatMessage
    private let mediaLibrary: MediaLibrary
    private let actions: Actions

    @Environment(ChatAppModel.self) private var model
    @State private var hovering = false
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

    public var body: some View {
        Group {
            if message.role == .user {
                userRow
            } else if message.role == .assistant {
                VStack(alignment: .leading, spacing: 4) {
                    if let duration = calculateDurationText() {
                        durationDivider(duration)
                    }
                    assistantRow
                }
            } else {
                systemRow
            }
        }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
    }

    // MARK: User

    private var userRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                if editing {
                    editor
                } else {
                    bubble
                }
                HStack(spacing: 8) {
                    if !message.alternativeVersions.isEmpty {
                        userVersionPicker
                    }
                    actionBar(alignment: .trailing)
                }
            }
        }
        .padding(.leading, 40)
    }

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
                    MediaAttachmentView(ref: ref, library: mediaLibrary)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
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
        .background(Color.ompFill.opacity(0.8), in: Capsule())
    }

    // MARK: Assistant

    @ViewBuilder
    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 10) {
            OMPMark(size: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                thinkingSection
                operationSection
                replyVersionPicker
                ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                    partView(part)
                }
                if message.status == .streaming {
                    StreamingCaret()
                }
                if let error = message.errorText, !error.isEmpty {
                    errorView(error)
                }
                metaRow
                actionBar(alignment: .leading)
            }
            Spacer(minLength: 24)
        }
        .padding(.trailing, 24)
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
        }
    }

    private func durationDivider(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.4)
            HStack(spacing: 4) {
                Text("用时 \(text)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ompTextTertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.ompTextTertiary)
            }
            .padding(.top, 2)
        }
        .padding(.bottom, 4)
    }

    private func calculateDurationText() -> String? {
        guard let conversation = model.selectedConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == message.id }),
              index > 0 else { return nil }
        let prev = conversation.messages[index - 1]
        guard prev.role == .user else { return nil }
        let diff = message.createdAt.timeIntervalSince(prev.createdAt)
        guard diff >= 2.0 else { return nil }
        if diff < 60 {
            return "\(Int(diff))秒"
        } else if diff < 3600 {
            let m = Int(diff) / 60
            let s = Int(diff) % 60
            return "\(m)分钟\(s)秒"
        } else {
            let h = Int(diff) / 3600
            let m = (Int(diff) % 3600) / 60
            return "\(h)小时\(m)分钟"
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

    @ViewBuilder
    private func partView(_ part: ContentPart) -> some View {
        switch part {
        case .text(let value):
            if !value.isEmpty {
                MarkdownText(value)
                    .font(.system(size: model.settings.fontSize))
                    .foregroundStyle(Color.ompText)
            }
        case .thinking:
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
        if let usage = message.usage, usage.totalTokens > 0 {
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
                            Text("思考 (Thinking):")
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
        HStack(spacing: 2) {
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

            if let select = actions.select {
                iconButton(model.selectedMessageIDs.contains(message.id) ? "checkmark.circle.fill" : "circle", help: "选择") { select() }
            }

            if let delete = actions.delete {
                iconButton("trash", help: "删除消息") { delete() }
            }

            if alignment == .leading { Spacer(minLength: 0) }
        }
        .opacity(hovering ? 1 : 0.001)
        .frame(height: 18)
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

/// Blinking caret shown while a reply streams.
public struct StreamingCaret: View {
    @State private var visible = true

    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 2, height: 15)
            .opacity(visible ? 1 : 0.15)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible.toggle() }
    }
}

public struct MediaAttachmentView: View {
    private let ref: MediaRef
    private let library: MediaLibrary
    @State private var showingLightbox = false

    public init(ref: MediaRef, library: MediaLibrary) {
        self.ref = ref
        self.library = library
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
                    ImageLightboxSheet(image: image, fileURL: library.url(for: ref))
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

/// Fullscreen zoomable lightbox for attachments matching ChatGPT Desktop
struct ImageLightboxSheet: View {
    let image: PlatformImageType
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var copied = false
    @State private var zoom: CGFloat = 1.0

    init(image: PlatformImageType, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()

                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoom)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in zoom = max(0.8, min(4.0, val)) }
                    )
                    .padding(24)
            }
            .navigationTitle(fileURL.lastPathComponent)
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
        #endif
    }

    private func saveImage() {
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

