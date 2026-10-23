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
    static let ompFindInChat = Notification.Name("omp.findInChat")
    static let ompToggleSidebar = Notification.Name("omp.toggleSidebar")
}

public struct ChatRootView: View {
    @Environment(ChatAppModel.self) private var model
    @State private var showSwitcher = false
    @State private var sidebarVisible = true

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
            .onReceive(NotificationCenter.default.publisher(for: .ompToggleSidebar)) { _ in toggleSidebar() }
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
            if sidebarVisible {
                ConversationSidebar()
                    .frame(width: Theme.Layout.sidebarIdeal)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().opacity(0.6)
            }
            ChatDetailView(onQuickSwitch: { showSwitcher = true }, onToggleSidebar: toggleSidebar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.ompCanvas)
        .animation(Theme.Motion.quick, value: sidebarVisible)
    }

    private func toggleSidebar() {
        sidebarVisible.toggle()
    }
    #endif
}

#if os(macOS)
/// Narrow icon rail like Codex/ChatGPT desktop.
struct IconRail: View {
    @Environment(ChatAppModel.self) private var model
    @State private var activeSheet: ActiveSheet?

    enum ActiveSheet: Identifiable {
        case projects, history, schedules, usage
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 6) {
            OMPMark(size: 22)
                .padding(.top, 30)
                .padding(.bottom, 8)

            railButton("square.and.pencil", help: "新聊天 (⌘N)", active: false) {
                NotificationCenter.default.post(name: .ompNewChat, object: nil)
            }
            railButton("folder", help: "项目与工作区") {
                activeSheet = .projects
            }
            railButton("clock", help: "会话历史") {
                activeSheet = .history
            }
            railButton("calendar", help: "计划任务") {
                activeSheet = .schedules
            }
            railButton("chart.bar", help: "用量统计") {
                activeSheet = .usage
            }
            railButton("magnifyingglass", help: "快速搜索 (⌘K)") {
                NotificationCenter.default.post(name: .ompQuickSwitch, object: nil)
            }

            Spacer()

            railButton("gearshape", help: "设置 (⌘,)") {
                model.showSettings = true
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 52)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .projects:
                PaseoProjectsSheet().environment(model)
            case .history:
                PaseoSessionHistorySheet(onSelectConversation: { id in
                    model.selectedConversationID = id
                }).environment(model)
            case .schedules:
                PaseoScheduledTasksSheet()
            case .usage:
                PaseoUsageSheet().environment(model)
            }
        }
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
    let onToggleSidebar: () -> Void

    @State private var showExporter = false
    @State private var exportDocument: MarkdownDocument?
    @State private var showOptions = false
    @State private var inChatSearch = ""
    @State private var showInChatSearch = false

    public init(onQuickSwitch: @escaping () -> Void = {}, onToggleSidebar: @escaping () -> Void = {}) {
        self.onQuickSwitch = onQuickSwitch
        self.onToggleSidebar = onToggleSidebar
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            header
            Divider().opacity(0.5)
            #endif

            if showInChatSearch { inChatSearchBar }

            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.dismissError() }
            }
            if let status = model.statusMessage {
                StatusToast(message: status) { model.dismissStatus() }
            }

            if model.selectedConversation?.messages.isEmpty == true, model.errorMessage == nil {
                // Codex-style empty state: headline + composer vertically centered
                Spacer(minLength: 40)
                VStack(spacing: 18) {
                    ChatEmptyStateView()
                    ComposerBar()
                }
                .frame(maxWidth: Theme.Layout.transcriptMax + Theme.Layout.transcriptPadding * 2)
                Spacer(minLength: 40)
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
        .onReceive(NotificationCenter.default.publisher(for: .ompFindInChat)) { _ in
            showInChatSearch = true
        }
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
            iconButton("sidebar.left", help: "切换侧栏 (⌘B)") {
                onToggleSidebar()
            }
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
            if let conversation = model.selectedConversation, !conversation.messages.isEmpty {
                let tokens = conversation.messages.compactMap(\.usage).reduce(0) { $0 + $1.totalTokens }
                Text("\(conversation.messages.count) 条\(tokens > 0 ? " · \(TokenFormat.compact(tokens)) tok" : "")")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
            }


            Spacer()

            if model.isStreaming {
                HStack(spacing: 4) {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    Text("生成中").font(.system(size: 10.5)).foregroundStyle(Color.ompTextSecondary)
                }
            }

            // 查找按钮
            Button {
                showInChatSearch.toggle()
                if !showInChatSearch { inChatSearch = "" }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(showInChatSearch ? Color.accentColor : Color.ompTextSecondary)
                    .frame(width: 28, height: 28)
                    .background(showInChatSearch ? Color.accentColor.opacity(0.12) : Color.clear, in: Circle())
            }
            .buttonStyle(.plain)
            .help("在对话中查找 (⌘F)")

            // ChatGPT 风格分享胶囊按钮
            Button {
                shareConversation()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text("分享")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.ompText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.ompFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("分享对话")

            // ••• 溢出功能菜单 (ChatGPT 风格)
            Menu {
                Button {
                    model.regenerateLast()
                } label: {
                    Label("重新生成 (⇧⌘R)", systemImage: "arrow.clockwise")
                }
                .disabled(model.isStreaming || model.selectedConversation?.messages.isEmpty != false)

                Button {
                    showOptions = true
                } label: {
                    Label("对话设置 (自定义指令)", systemImage: "slider.horizontal.3")
                }

                Button {
                    prepareExport()
                } label: {
                    Label("导出 Markdown", systemImage: "arrow.down.doc")
                }

                Divider()

                Button {
                    model.showSettings = true
                } label: {
                    Label("偏好设置 (⌘,)", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.ompFill, in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
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


    @ViewBuilder
    private var inChatSearchBar: some View {
        if showInChatSearch {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ompTextTertiary)
                TextField("在此对话中查找", text: $inChatSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !inChatSearch.isEmpty {
                    Text("\(matchCount) 处")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color.ompTextTertiary)
                }
                Button {
                    showInChatSearch = false
                    inChatSearch = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.ompTextSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
        }
    }

    private var matchCount: Int {
        let query = inChatSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let conversation = model.selectedConversation else { return 0 }
        return conversation.messages.filter {
            $0.concatenatedText.localizedCaseInsensitiveContains(query)
        }.count
    }

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

/// Empty-state headline matching Codex/ChatGPT desktop reference
struct ChatEmptyStateView: View {
    @Environment(ChatAppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)

            (Text("你想让我们在 ")
                + Text(currentProjectName).underline()
                + Text(" 中构建什么？"))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.ompText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 4)
    }

    private var currentProjectName: String {
        if let id = model.selectedConversation?.projectID,
           let project = model.projects.first(where: { $0.id == id }) {
            return project.name
        }
        return "默认工作区"
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
