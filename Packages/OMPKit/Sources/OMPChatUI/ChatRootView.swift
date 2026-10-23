import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers
import OMPCore
import OMPDesign

public extension Notification.Name {
    static let ompQuickSwitch = Notification.Name("omp.quickSwitch")
    static let ompNewChat = Notification.Name("omp.newChat")
}

public struct ChatRootView: View {
    @Environment(ChatAppModel.self) private var model
    @State private var showSwitcher = false

    public init() {}

    public var body: some View {
        @Bindable var bindable = model
        #if os(iOS)
        iOSRootView()
            .sheet(isPresented: $bindable.showSettings) {
                ProviderSettingsView().environment(model)
            }
            .preferredColorScheme(colorScheme)
            .task { await model.bootstrap() }
        #else
        macOSRoot
            .sheet(isPresented: $bindable.showSettings) {
                ProviderSettingsView().environment(model)
            }
            .sheet(isPresented: $showSwitcher) {
                QuickSwitcherView().environment(model)
            }
            .preferredColorScheme(colorScheme)
            .task { await model.bootstrap() }
            .onReceive(NotificationCenter.default.publisher(for: .ompQuickSwitch)) { _ in showSwitcher = true }
            .onReceive(NotificationCenter.default.publisher(for: .ompNewChat)) { _ in model.newConversation() }
        #endif
    }

    private var colorScheme: ColorScheme? {
        switch model.settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: - macOS (Codex-style: icon rail + sidebar + detail)

    #if os(macOS)
    private var macOSRoot: some View {
        HStack(spacing: 0) {
            IconRail()
            Divider().opacity(0.6)
            ConversationSidebar()
                .frame(width: Theme.Layout.sidebarIdeal)
            Divider().opacity(0.6)
            ChatDetailView(onQuickSwitch: { showSwitcher = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.ompCanvas)
    }
    #endif
}

#if os(macOS)
/// Narrow icon rail like Codex/ChatGPT desktop.
struct IconRail: View {
    @Environment(ChatAppModel.self) private var model
    @State private var showSwitcher = false

    var body: some View {
        VStack(spacing: 6) {
            OMPMark(size: 22)
                .padding(.top, 30)
                .padding(.bottom, 8)

            railButton("square.and.pencil", help: "新聊天 (⌘N)", active: false) {
                NotificationCenter.default.post(name: .ompNewChat, object: nil)
            }
            railButton("clock", help: "最近对话") {
                NotificationCenter.default.post(name: .ompQuickSwitch, object: nil)
            }
            railButton("magnifyingglass", help: "搜索 (⌘K)") {
                NotificationCenter.default.post(name: .ompQuickSwitch, object: nil)
            }
            railButton("arrow.triangle.branch", help: "分支当前对话") {
                if let selected = model.selectedConversation, let last = selected.messages.last {
                    _ = model.branch(from: last.id)
                }
            }

            Spacer()

            railButton("gearshape", help: "设置 (⌘,)") {
                model.showSettings = true
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 52)
    }

    private func railButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        RailButton(symbol: symbol, help: help, active: active, action: action)
    }
}

/// Icon-rail button with a hover wash and an accent-tinted active state.
struct RailButton: View {
    let symbol: String
    let help: String
    var active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.ompTextSecondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.16) : (hovering ? Color.ompHover : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
    }
}
#endif

public struct ChatDetailView: View {
    @Environment(ChatAppModel.self) private var model
    let onQuickSwitch: () -> Void

    @State private var showExporter = false
    @State private var exportDocument: MarkdownDocument?
    @State private var showOptions = false

    public init(onQuickSwitch: @escaping () -> Void = {}) {
        self.onQuickSwitch = onQuickSwitch
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            header
            Divider().opacity(0.5)
            #endif

            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.dismissError() }
            }
            if let status = model.statusMessage {
                StatusToast(message: status) { model.dismissStatus() }
            }

            if model.selectedConversation?.messages.isEmpty == true, model.errorMessage == nil {
                // Codex-style empty state: the composer sits in the middle of
                // the canvas instead of pinned to the bottom.
                Spacer()
                ChatTranscriptView()
                ComposerBar()
                Spacer()
            } else {
                ChatTranscriptView()
                ComposerBar()
            }
        }
        .background(Color.ompCanvas)
        #if os(iOS)
        .navigationTitle(model.selectedConversation?.title ?? "OMP Chat")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showOptions) {
            ConversationOptionsSheet()
                .environment(model)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: (model.selectedConversation?.title ?? "conversation") + ".md"
        ) { _ in
            exportDocument = nil
        }
    }

    // MARK: macOS header

    #if os(macOS)
    private var header: some View {
        HStack(spacing: 10) {
            Text(model.selectedConversation?.title ?? "OMP Chat")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ompText)
                .lineLimit(1)
            if model.selectedConversation?.isTemporary == true {
                Text("临时")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }

            if let conversation = model.selectedConversation,
               let usage = model.contextUsage(conversation) {
                ContextBadge(used: usage.used, limit: usage.limit)
            }

            Spacer()

            if model.isStreaming {
                HStack(spacing: 4) {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    Text("生成中").font(.system(size: 10.5)).foregroundStyle(Color.ompTextSecondary)
                }
            }

            iconButton("magnifyingglass", help: "快速切换 (⌘K)", action: onQuickSwitch)
            iconButton("arrow.clockwise", help: "重新生成 (⇧⌘R)") {
                model.regenerateLast()
            }
            iconButton("square.and.arrow.up", help: "分享对话") {
                shareConversation()
            }
            iconButton("arrow.down.doc", help: "导出 Markdown") {
                prepareExport()
            }
            iconButton("slider.horizontal.3", help: "对话设置") {
                showOptions = true
            }
            iconButton("gearshape", help: "设置 (⌘,)") {
                model.showSettings = true
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .frame(height: 60)
        .background(Color.ompCanvas)
        .contentShape(Rectangle())
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ompTextSecondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }
    #endif

    private func shareConversation() {
        guard let conversation = model.selectedConversation else { return }
        let markdown = model.exportMarkdown(conversation)
        #if os(macOS)
        let picker = NSSharingServicePicker(items: [markdown])
        if let view = NSApp.keyWindow?.contentView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
        #else
        copyToPasteboard(markdown)
        #endif
    }

    private func prepareExport() {
        guard let conversation = model.selectedConversation else { return }
        exportDocument = MarkdownDocument(text: model.exportMarkdown(conversation))
        showExporter = true
    }
}

enum TokenFormat {
    static func compact(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        if value % 1000 == 0 { return "\(value / 1000)k" }
        return String(format: "%.1fk", Double(value) / 1000)
    }
}

struct ContextBadge: View {
    let used: Int
    let limit: Int

    private var ratio: Double {
        guard limit > 0 else { return 0 }
        return min(1, Double(used) / Double(limit))
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ompFill)
                Capsule()
                    .fill(ratio > 0.85 ? Color.red : Color.accentColor.opacity(0.7))
                    .frame(width: max(2, 34 * ratio))
            }
            .frame(width: 34, height: 3)
            Text("\(TokenFormat.compact(used))/\(TokenFormat.compact(limit))")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color.ompTextTertiary)
        }
        .help("上下文用量估算")
    }
}

struct MarkdownDocument: FileDocument {
    nonisolated static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Quick switcher

public struct QuickSwitcherView: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    public init() {}

    private var results: [Conversation] {
        let all = model.sortedConversations
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            $0.lastMessagePreview.localizedCaseInsensitiveContains(trimmed)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompTextTertiary)
                TextField("跳转到对话…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                Text("esc")
                    .font(.system(size: 9, weight: .medium).monospaced())
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider().opacity(0.6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(results) { conversation in
                        Button {
                            model.selectedConversationID = conversation.id
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left")
                                    .font(.system(size: 10))
                                    .foregroundStyle(conversation.isPinned ? .orange : Color.ompTextTertiary)
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(conversation.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.ompText)
                                        .lineLimit(1)
                                    Text(conversation.lastMessagePreview)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.ompTextSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if results.isEmpty {
                        Text("没有匹配的对话")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompTextSecondary)
                            .padding(.top, 24)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 520, height: 400)
        .background(Color.ompCard)
        .onAppear { focused = true }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
    }
}
