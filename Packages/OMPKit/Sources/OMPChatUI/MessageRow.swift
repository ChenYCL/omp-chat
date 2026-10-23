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

        public init(
            copy: @escaping () -> Void,
            edit: ((String) -> Void)? = nil,
            branch: (() -> Void)? = nil,
            delete: (() -> Void)? = nil,
            regenerate: (() -> Void)? = nil,
            feedback: ((Int) -> Void)? = nil
        ) {
            self.copy = copy
            self.edit = edit
            self.branch = branch
            self.delete = delete
            self.regenerate = regenerate
            self.feedback = feedback
        }
    }

    private let message: ChatMessage
    private let mediaLibrary: MediaLibrary
    private let actions: Actions

    @State private var hovering = false
    @State private var editing = false
    @State private var editText = ""
    @State private var copied = false

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
                assistantRow
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
                actionBar(alignment: .trailing)
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

    // MARK: Assistant

    @ViewBuilder
    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 10) {
            OMPMark(size: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                thinkingSection
                operationSection
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
                iconButton("speaker.wave.2", help: "朗读") {
                    Speech.speak(message.concatenatedText)
                }
            }

            iconButton(copied ? "checkmark" : "doc.on.doc", help: "复制") {
                actions.copy()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
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
            Label("复制", systemImage: "doc.on.doc")
        }
        if actions.edit != nil {
            Button {
                editText = message.concatenatedText
                editing = true
            } label: {
                Label("编辑", systemImage: "pencil")
            }
        }
        if let branch = actions.branch {
            Button { branch() } label: {
                Label("从这里分支", systemImage: "arrow.triangle.branch")
            }
        }
        if let delete = actions.delete {
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

    public init(ref: MediaRef, library: MediaLibrary) {
        self.ref = ref
        self.library = library
    }

    public var body: some View {
        Group {
            if ref.kind == .image, let image = PlatformImage.load(at: library.url(for: ref)) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
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
