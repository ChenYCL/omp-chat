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
    static let ompVoiceMode = Notification.Name("omp.voiceMode")
    static let ompScrollToBottom = Notification.Name("omp.scrollToBottom")
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
/// Minimalist activity rail matching Codex desktop exactly (44pt).
struct IconRail: View {
    @Environment(ChatAppModel.self) private var model
    @State private var activeSheet: ActiveSheet?

    enum ActiveSheet: Identifiable {
        case history
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 16) {
            Button {
                // Home view
            } label: {
                Image(systemName: "house.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .padding(.top, 38)

            Button {
                activeSheet = .history
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("会话历史")

            Button {
                // Mentions
            } label: {
                Image(systemName: "at")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("提醒与提及")

            Menu {
                Button("项目与工作区") {
                    NotificationCenter.default.post(name: .ompQuickSwitch, object: nil)
                }
                Button("偏好设置 (⌘,)") {
                    model.showSettings = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多")

            Spacer()

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("偏好设置 (⌘,)")
            .padding(.bottom, 16)
        }
        .frame(width: 44)
        .background(Color.ompCanvas)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .history:
                PaseoSessionHistorySheet(onSelectConversation: { id in
                    model.selectedConversationID = id
                }).environment(model)
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
    @State private var exportFilename = "conversation.md"
    @State private var showOptions = false
    @State private var inChatSearch = ""
    @State private var showInChatSearch = false
    @State private var showRenameAlert = false
    @State private var renamingTitle = ""
    @ObservedObject private var network = NetworkMonitor.shared

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
            if !network.isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 11, weight: .bold))
                    Text("网络连接已断开，请检查网络设置")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.9), in: Capsule())
                .padding(.vertical, 4)
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
            defaultFilename: exportFilename
        ) { _ in
            exportDocument = nil
        }
        .alert("重命名对话", isPresented: $showRenameAlert) {
            TextField("对话标题", text: $renamingTitle)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let id = model.selectedConversationID {
                    model.renameConversation(id, title: renamingTitle)
                }
            }
        }
    }

    // MARK: macOS header

    #if os(macOS)
    private var header: some View {
        HStack(spacing: 8) {
            if let conversation = model.selectedConversation, !conversation.messages.isEmpty {
                Menu {
                    Button {
                        renamingTitle = conversation.title
                        showRenameAlert = true
                    } label: {
                        Label("重命名对话", systemImage: "pencil")
                    }

                    if !model.projects.isEmpty {
                        Menu("移动到项目") {
                            if conversation.projectID != nil {
                                Button("移出项目 (未分组)") {
                                    model.moveConversation(conversation.id, to: nil)
                                }
                                Divider()
                            }
                            ForEach(model.projects) { project in
                                Button {
                                    model.moveConversation(conversation.id, to: project.id)
                                } label: {
                                    if conversation.projectID == project.id {
                                        Label(project.name, systemImage: "checkmark")
                                    } else {
                                        Text(project.name)
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        model.togglePin(conversation.id)
                    } label: {
                        Label(conversation.isPinned ? "取消置顶" : "置顶对话", systemImage: "pin")
                    }

                    Button {
                        model.toggleLock(conversation.id)
                    } label: {
                        Label(conversation.isLocked ? "解锁对话" : "锁定对话", systemImage: "lock")
                    }

                    Button {
                        model.toggleArchive(conversation.id)
                    } label: {
                        Label(conversation.isArchived ? "取消归档" : "归档对话", systemImage: "archivebox")
                    }

                    Button {
                        model.duplicateConversation(conversation.id)
                    } label: {
                        Label("复制为新分支", systemImage: "arrow.triangle.branch")
                    }

                    Divider()

                    Button(role: .destructive) {
                        model.deleteConversation(conversation.id)
                    } label: {
                        Label("删除对话", systemImage: "trash")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(conversation.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ompText)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            Spacer()

            if let conversation = model.selectedConversation, !conversation.messages.isEmpty {
                Button {
                    shareConversation()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10))
                        Text("分享")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.ompText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.ompFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("分享对话")
            }
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

                Menu("导出对话") {
                    Button {
                        prepareExport(format: .markdown)
                    } label: {
                        Label("导出为 Markdown (.md)", systemImage: "doc.plaintext")
                    }
                    Button {
                        prepareExport(format: .html)
                    } label: {
                        Label("导出为 HTML 网页 (.html)", systemImage: "safari")
                    }
                    Button {
                        prepareExport(format: .json)
                    } label: {
                        Label("导出为 JSON 数据 (.json)", systemImage: "curlybraces")
                    }
                }

                Button {
                    if let conversation = model.selectedConversation {
                        copyToPasteboard(model.exportMarkdown(conversation))
                    }
                } label: {
                    Label("复制整篇对话内容", systemImage: "doc.on.doc")
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

    enum ExportFormat: String {
        case markdown = "md"
        case html = "html"
        case json = "json"
    }

    private func prepareExport(format: ExportFormat = .markdown) {
        guard let conversation = model.selectedConversation else { return }
        let text: String
        let ext = format.rawValue
        switch format {
        case .markdown:
            text = model.exportMarkdown(conversation)
        case .html:
            text = model.exportHTML(conversation)
        case .json:
            text = model.exportJSON(conversation)
        }
        exportDocument = MarkdownDocument(text: text)
        exportFilename = (conversation.title) + ".\(ext)"
        showExporter = true
    }
}

/// Empty-state headline matching Codex/ChatGPT desktop reference
struct ChatEmptyStateView: View {
    @Environment(ChatAppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.ompFill.opacity(0.6))
                    .frame(width: 62, height: 62)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.ompTextTertiary)
            }

            (Text("你想让我们在 ")
                + Text(currentProjectName).underline()
                + Text(" 中构建什么？"))
                .font(.system(size: 23, weight: .semibold))
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
    @State private var showPopover = false

    private var ratio: Double {
        guard limit > 0 else { return 0 }
        return min(1, Double(used) / Double(limit))
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
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
        }
        .buttonStyle(.plain)
        .help("点击查看上下文窗口占用详情")
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 6) {
                Text("上下文窗口占用 (Context Window)")
                    .font(.system(size: 12, weight: .semibold))
                Divider()
                HStack {
                    Text("当前对话已用:")
                    Spacer()
                    Text("\(used) tok")
                        .font(.system(size: 11.5).monospacedDigit())
                }
                HStack {
                    Text("模型上限:")
                    Spacer()
                    Text("\(limit) tok")
                        .font(.system(size: 11.5).monospacedDigit())
                }
                HStack {
                    Text("剩余可用空间:")
                    Spacer()
                    Text("\(max(0, limit - used)) tok")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(ratio > 0.85 ? .red : .green)
                }
                HStack {
                    Text("占用比例:")
                    Spacer()
                    Text(String(format: "%.1f%%", ratio * 100))
                        .font(.system(size: 11.5).monospacedDigit())
                }
            }
            .font(.system(size: 11.5))
            .padding(12)
            .frame(width: 220)
        }
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

    private struct QuickAction: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let shortcut: String?
        let action: (ChatAppModel, () -> Void) -> Void

        init(icon: String, title: String, shortcut: String? = nil, action: @escaping (ChatAppModel, () -> Void) -> Void) {
            self.icon = icon
            self.title = title
            self.shortcut = shortcut
            self.action = action
        }
    }

    private let allActions: [QuickAction] = [
        QuickAction(icon: "plus.circle.fill", title: "新建对话", shortcut: "⌘N") { model, dismiss in
            model.newConversation()
            dismiss()
        },
        QuickAction(icon: "eye.slash", title: "新建临时对话 (不保存)", shortcut: nil) { model, dismiss in
            _ = model.newTemporaryConversation()
            dismiss()
        },
        QuickAction(icon: "gearshape", title: "偏好设置", shortcut: "⌘,") { model, dismiss in
            model.showSettings = true
            dismiss()
        },
        QuickAction(icon: "folder", title: "新建项目", shortcut: nil) { model, dismiss in
            _ = model.createProject(name: "新项目")
            dismiss()
        },
        QuickAction(icon: "sun.max", title: "切换到亮色主题") { model, dismiss in
            var settings = model.settings
            settings.appearance = .light
            Task { await model.saveSettings(settings) }
            dismiss()
        },
        QuickAction(icon: "moon", title: "切换到暗色主题") { model, dismiss in
            var settings = model.settings
            settings.appearance = .dark
            Task { await model.saveSettings(settings) }
            dismiss()
        },
        QuickAction(icon: "circle.lefthalf.filled", title: "跟随系统主题") { model, dismiss in
            var settings = model.settings
            settings.appearance = .system
            Task { await model.saveSettings(settings) }
            dismiss()
        },
    ]

    private var matchingActions: [QuickAction] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allActions }
        return allActions.filter {
            $0.title.lowercased().contains(trimmed) || ($0.shortcut?.lowercased().contains(trimmed) ?? false)
        }
    }

    private var matchingProjects: [Project] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return model.projects }
        return model.projects.filter { $0.name.lowercased().contains(trimmed) }
    }

    private var matchingConversations: [Conversation] {
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
                LazyVStack(alignment: .leading, spacing: 1) {
                    // 快捷动作
                    if !matchingActions.isEmpty {
                        Text("快捷动作")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.ompTextTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 2)

                        ForEach(matchingActions) { item in
                            Button {
                                item.action(model, { dismiss() })
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 16)
                                    Text(item.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.ompText)
                                    Spacer()
                                    if let sc = item.shortcut {
                                        Text(sc)
                                            .font(.system(size: 10).monospaced())
                                            .foregroundStyle(Color.ompTextTertiary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.ompFill.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 项目
                    if !matchingProjects.isEmpty {
                        Text("项目与工作区")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.ompTextTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 2)

                        ForEach(matchingProjects) { project in
                            Button {
                                if let first = model.conversations(in: project.id).first {
                                    model.selectedConversationID = first.id
                                }
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 16)
                                    Text(project.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.ompText)
                                    Spacer()
                                    Text("\(model.conversations(in: project.id).count) 会话")
                                        .font(.system(size: 10.5).monospacedDigit())
                                        .foregroundStyle(Color.ompTextTertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.ompFill.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 对话历史
                    if !matchingConversations.isEmpty {
                        Text("对话历史")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.ompTextTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 2)

                        ForEach(matchingConversations) { conversation in
                            Button {
                                model.selectedConversationID = conversation.id
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left")
                                        .font(.system(size: 10))
                                        .foregroundStyle(conversation.isPinned ? .orange : Color.ompTextTertiary)
                                        .frame(width: 16)
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
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.ompFill.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if matchingActions.isEmpty && matchingProjects.isEmpty && matchingConversations.isEmpty {
                        Text("没有匹配的结果")
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
