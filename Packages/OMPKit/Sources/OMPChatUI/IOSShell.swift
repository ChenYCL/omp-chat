import SwiftUI
import UniformTypeIdentifiers
import OMPCore
import OMPDesign

#if os(iOS)
// MARK: - IOSShell
//
// Unified iOS information architecture (three legacy variants merged):
// - One bottom TabBar (49pt + safe area, 22pt icons, 10pt labels): 聊天 / 主机 / 远程.
// - 左侧抽屉只放二级入口（项目 / 会话历史 / 计划任务 / 用量 / 设备 / 子代理）。
// - 聊天页 = 44pt 顶栏 + 白底消息区 + 悬浮 chips + 胶囊输入条 + 文件|终端|配置 工具条。
// - 主机页 = 四态 pane（文件 / 终端 / 脚本 / 配置）。
// - 远程页 = 配对表单 或 主机会话列表（原 RemotePairSheet 内容提升为整页）。

/// Sheet titles → shell routes. The drawer opens these as full-screen sheets.
enum IOSShellRoute: String, Identifiable {
    case projects, history, archived, locked, usage, devices, subagents, diagnostics
    var id: Self { self }
}

public struct IOSShell: View {
    @Environment(ChatAppModel.self) private var model
    @State private var tab: ShellTab = .chat
    @State private var drawerOpen = false
    @State private var route: IOSShellRoute?
    @State private var hostPane: HostPane = .files
    /// The single shared link to the paired Mac; the 远程 tab publishes into it
    /// and every 主机 pane reads through it.
    @State private var remoteSession = RemoteSession()

    public init() {}

    public enum ShellTab: String, CaseIterable {
        case chat = "聊天"
        case host = "主机"
        case remote = "远程"
    }

    /// Host pane kinds; the chat composer toolbar jumps into matching panes.
    public enum HostPane: String, CaseIterable {
        case files = "文件"
        case terminal = "终端"
        case scripts = "脚本"
        case config = "配置"
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            TabView(selection: $tab) {
                ChatScreen(onOpenDrawer: openDrawer, onOpenHostPane: jump(to:))
                    .toolbarBackground(.hidden, for: .tabBar)
                    .tabItem { Label(ShellTab.chat.rawValue, systemImage: "bubble.left") }
                    .tag(ShellTab.chat)

                HostScreen(pane: $hostPane, onOpenDrawer: openDrawer, onOpenRemote: { tab = .remote })
                    .toolbarBackground(.hidden, for: .tabBar)
                    .tabItem { Label(ShellTab.host.rawValue, systemImage: "desktopcomputer") }
                    .tag(ShellTab.host)

                RemoteScreen()
                    .tabItem { Label(ShellTab.remote.rawValue, systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(ShellTab.remote)
            }
            .tint(.accentColor)
            .environment(remoteSession)

            if drawerOpen {
                Color.black.opacity(0.25)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .offset(x: IOSShellMetrics.drawerWidth)
                    .onTapGesture { closeDrawer() }
            }

            if drawerOpen {
                ShellDrawer(route: $route, onClose: closeDrawer, onSelectConversation: { id in
                    model.selectedConversationID = id
                    tab = .chat
                    closeDrawer()
                })
                .frame(width: IOSShellMetrics.drawerWidth)
                .transition(.move(edge: .leading))
            }
        }
        .animation(Theme.Motion.quick, value: drawerOpen)
        // Picking a Mac in 可控设备 closes the sheet and lands on 远程, where
        // the reconnect runs and its progress or error is visible.
        .onChange(of: remoteSession.requestedDevice) { _, device in
            guard device != nil else { return }
            route = nil
            closeDrawer()
            tab = .remote
        }
        .sheet(item: $route) { item in
            // Sheets do not inherit the TabView's environment: without
            // RemoteSession here, any route that reads it (设备, CLI 会话)
            // traps on open.
            NavigationStack { routeDestination(item) }
                .environment(model)
                .environment(remoteSession)
                .presentationDetents([.large])
        }
    }

    @ViewBuilder
    private func routeDestination(_ item: IOSShellRoute) -> some View {
        switch item {
        case .projects: PaseoProjectsSheet()
        case .history: PaseoSessionHistorySheet { id in
                model.selectedConversationID = id
                tab = .chat
                route = nil
            }
        case .archived: PaseoArchivedSheet { id in
                model.selectedConversationID = id
                tab = .chat
                route = nil
            }
        case .locked: PaseoLockedSheet { id in
                model.selectedConversationID = id
                tab = .chat
                route = nil
            }
        case .usage: PaseoUsageSheet()
        case .devices: PaseoDevicesSheet()
        case .subagents: CLISessionsSheet()
        case .diagnostics: DiagnosticsView()
        }
    }

    private func openDrawer() {
        withAnimation(Theme.Motion.quick) { drawerOpen = true }
    }

    private func closeDrawer() {
        withAnimation(Theme.Motion.quick) { drawerOpen = false }
    }

    private func jump(to pane: HostPane) {
        hostPane = pane
        tab = .host
    }
}

// MARK: - Shell metrics (official iOS values)

enum IOSShellMetrics {
    static let drawerWidth: CGFloat = 290
    static let topBarHeight: CGFloat = 44
    static let tabBarHeight: CGFloat = 49            // official UITabBar height
    static let tabIconSize: CGFloat = 22             // official tab icon point size
    static let tabLabelSize: CGFloat = 10            // official tab label point size
    static let composerMinHeight: CGFloat = 40       // single line
    static let composerMaxHeight: CGFloat = 132      // multi-line cap
    static let composerRadius: CGFloat = 22
    static let sendButtonSize: CGFloat = 32
    /// Official iOS tab bar tracks the surface token, not a fixed white:
    /// light #f9f9f9, dark #212121 (the earlier fixed colour left white bands
    /// under the composer in dark mode).
    static let tabBarBackground = Color.ompDynamic(light: 0xF9F9F9, dark: 0x212121)
}

// MARK: - Chat Screen

/// 聊天 tab: 44pt top bar + transcript + floating chips + pill composer + tool strip.
struct ChatScreen: View {
    @Environment(ChatAppModel.self) private var model
    let onOpenDrawer: () -> Void
    let onOpenHostPane: (IOSShell.HostPane) -> Void

    @State private var showingSubagents = false
    @State private var showingHistory = false
    @State private var renaming = false
    @State private var renameText = ""
    /// In-chat search on the phone. The desktop's ⌘F posted a notification that
    /// only ChatDetailView listened to, so the phone's menu item did nothing.
    @State private var findQuery = ""
    @State private var finding = false
    @State private var findCursor: UUID?

    init(
        onOpenDrawer: @escaping () -> Void = {},
        onOpenHostPane: @escaping (IOSShell.HostPane) -> Void = { _ in }
    ) {
        self.onOpenDrawer = onOpenDrawer
        self.onOpenHostPane = onOpenHostPane
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.6)
            if finding { findBar }
            ZStack(alignment: .bottom) {
                if showsEmptyState {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ChatTranscriptView()
                    VStack(spacing: 8) {
                        scrollChevron
                        IOSStatusChips(showingSubagents: $showingSubagents)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color.ompCanvas)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                ComposerToolBar(onOpenHostPane: onOpenHostPane)
                Rectangle()
                    .fill(Color.ompBorder)
                    .frame(height: 0.5)
                PaseoComposerBar()
            }
            .background(IOSShellMetrics.tabBarBackground)
        }
        .environment(\.ompSearchHighlight, finding && !findQuery.trimmingCharacters(in: .whitespaces).isEmpty
                     ? findQuery.trimmingCharacters(in: .whitespaces) : nil)
        .onChange(of: findQuery) { _, _ in findCursor = nil }
        .alert("重命名对话", isPresented: $renaming) {
            TextField("标题", text: $renameText)
            Button("保存") {
                if let id = model.selectedConversationID { model.renameConversation(id, title: renameText) }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showingHistory) {
            PaseoSessionHistorySheet { id in
                model.selectedConversationID = id
            }
            .environment(model)
        }
        .sheet(isPresented: $showingSubagents) {
            NavigationStack { CLISessionsSheet() }
                .environment(model)
        }
    }

    // MARK: 44pt top bar: ☰ | title (pull-down menu) | •••

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onOpenDrawer) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shell.drawer")
            .accessibilityLabel("打开抽屉")

            Spacer()

            conversationTitleMenu

            Spacer()

            Menu {
                Button { showingHistory = true } label: {
                    Label("搜索会话", systemImage: "magnifyingglass")
                }
                Button {
                    // The phone has its own bar in ChatScreen; the desktop's
                    // ⌘F notification never reached IOSShell.
                    finding = true
                } label: {
                    Label("在对话中查找", systemImage: "text.magnifyingglass")
                }
                Button {
                    model.showSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                if let conversation = model.selectedConversation {
                    ShareLink(item: model.exportMarkdown(conversation)) {
                        Label("导出 Markdown", systemImage: "doc.badge.arrow.up")
                    }
                    ShareLink(item: model.exportHTML(conversation)) {
                        Label("分享会话", systemImage: "square.and.arrow.up")
                    }
                    // JSON is the backup format the desktop exports, and the one
                    // 导入 reads back; the phone could not produce it.
                    ShareLink(
                        item: model.exportJSON(conversation),
                        preview: SharePreview("\(conversation.title).json")
                    ) {
                        Label("导出 JSON 备份", systemImage: "curlybraces")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 36, height: 36)
            }
            .accessibilityIdentifier("shell.overflow")
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 8)
        .frame(height: IOSShellMetrics.topBarHeight)
        .background(Color.ompCanvas)
    }

    /// Center title, tappable to reveal conversation actions (official pull-down).
    private var conversationTitleMenu: some View {
        Menu {
            Button {
                _ = model.newConversation()
            } label: {
                Label("新建对话", systemImage: "square.and.pencil")
            }
            Button {
                _ = model.newTemporaryConversation()
            } label: {
                Label("临时对话", systemImage: "eye.slash")
            }
            Divider()
            Button { model.selectPreviousConversation() } label: {
                Label("上一个对话", systemImage: "chevron.up")
            }
            Button { model.selectNextConversation() } label: {
                Label("下一个对话", systemImage: "chevron.down")
            }
            if let conversation = model.selectedConversation {
                Divider()
                Button {
                    renameText = conversation.title
                    renaming = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button { model.togglePin(conversation.id) } label: {
                    Label(conversation.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                }
                Button { model.toggleArchive(conversation.id) } label: {
                    Label(conversation.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
                }
                Button { model.duplicateConversation(conversation.id) } label: {
                    Label("复制为新分支", systemImage: "arrow.triangle.branch")
                }
            }
            Button {
                model.showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 5) {
                Text(displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ompTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.ompFill.opacity(0.6), in: Capsule())
        }
        .accessibilityIdentifier("shell.title")
    }

    /// In-chat search bar: query, hit count, and ↑/↓ to move between matches.
    private var findBar: some View {
        let hits = findHits
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.ompTextTertiary)
            TextField("在此对话中查找", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityIdentifier("chat.find")
            if !findQuery.isEmpty {
                Text(findLabel(hits))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
                    .accessibilityIdentifier("chat.find.count")
                Button { moveFind(by: -1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hits.count < 2 ? Color.ompTextTertiary : Color.ompTextSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(hits.count < 2)
                .accessibilityLabel("上一处")
                Button { moveFind(by: 1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hits.count < 2 ? Color.ompTextTertiary : Color.ompTextSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(hits.count < 2)
                .accessibilityLabel("下一处")
            }
            Button {
                finding = false
                findQuery = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭查找")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// "2 处" before the first jump, "1/2" once walking, so the two buttons have
    /// something to show for their work.
    private func findLabel(_ hits: [UUID]) -> String {
        guard !hits.isEmpty else { return "无匹配" }
        if let cursor = findCursor, let index = hits.firstIndex(of: cursor) {
            return "\(index + 1)/\(hits.count)"
        }
        return "\(hits.count) 处"
    }

    private var findHits: [UUID] {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let conversation = model.selectedConversation else { return [] }
        return conversation.messages
            .filter { $0.concatenatedText.localizedCaseInsensitiveContains(query) }
            .map(\.id)
    }

    /// Walks forward through hits, wrapping, and scrolls each into view.
    private func moveFind(by step: Int) {
        let hits = findHits
        guard let next = SearchCursor.step(from: findCursor.flatMap { hits.firstIndex(of: $0) }, by: step, count: hits.count)
        else { return }
        findCursor = hits[next]
        NotificationCenter.default.post(
            name: .ompScrollToMessage, object: nil, userInfo: ["messageID": hits[next]]
        )
    }

    private var scrollChevron: some View {
        Button {
            NotificationCenter.default.post(name: .ompScrollToBottom, object: nil)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.ompTextSecondary)
                .frame(width: 32, height: 32)
                .background(Color.ompCard, in: Circle())
                .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    /// True while the transcript has nothing to show (fresh conversation).
    private var showsEmptyState: Bool {
        guard let conversation = model.selectedConversation else { return true }
        return conversation.messages.isEmpty && !model.needsSetup
    }

    /// Official empty state: 62pt circle on ompFill + neutral sparkle,
    /// 23pt semibold title, 14pt secondary subtitle.
    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.ompFill)
                    .frame(width: 62, height: 62)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            VStack(spacing: 6) {
                (Text("今天想在 ")
                    + Text(model.activeProvider?.name ?? "OMP Chat").underline()
                    + Text(" 里聊些什么？"))
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                    .multilineTextAlignment(.center)
                Text(model.activeModel?.id ?? "选择一个模型开始")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            .padding(.horizontal, 24)
        }
    }

    /// Top-bar title; falls back to 新对话 when unset or blank.
    private var displayTitle: String {
        let title = model.selectedConversation?.title.trimmingCharacters(in: .whitespaces) ?? ""
        return title.isEmpty ? "新对话" : title
    }

}


// MARK: - Composer Tool Strip (Moshi: 文件 | 终端 | 配置)

/// Slim tool strip above the composer; jumps to the matching host pane.
struct ComposerToolBar: View {
    let onOpenHostPane: (IOSShell.HostPane) -> Void

    var body: some View {
        HStack(spacing: 0) {
            toolItem(IOSShell.HostPane.files, icon: "folder", title: "文件")
            divider
            toolItem(IOSShell.HostPane.terminal, icon: "terminal", title: "终端")
            divider
            toolItem(IOSShell.HostPane.config, icon: "slider.horizontal.3", title: "配置")
        }
        .frame(height: 30)
        .background(IOSShellMetrics.tabBarBackground)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.ompBorder)
            .frame(width: 0.5, height: 14)
    }

    private func toolItem(_ pane: IOSShell.HostPane, icon: String, title: String) -> some View {
        Button {
            onOpenHostPane(pane)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.ompTextSecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Host Screen

/// 主机 tab: four panes (文件 / 终端 / 脚本 / 配置) with a 44pt top bar.
struct HostScreen: View {
    @Environment(RemoteSession.self) private var session
    @Binding var pane: IOSShell.HostPane
    let onOpenDrawer: () -> Void
    /// Switches the shell to the 远程 tab so the user can pair.
    let onOpenRemote: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            hostTopBar
            Divider().opacity(0.6)
            HStack(spacing: 3) {
                ForEach(IOSShell.HostPane.allCases, id: \.self) { item in
                    Button {
                        withAnimation(Theme.Motion.quick) { pane = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12.5, weight: pane == item ? .semibold : .medium))
                            .foregroundStyle(pane == item ? Color.ompText : Color.ompTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(pane == item ? Color.ompCard : Color.clear)
                            )
                            .shadow(color: pane == item ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch pane {
            case .files: PaseoFilesPane(onOpenRemote: onOpenRemote)
            case .terminal: PaseoTerminalPane(onOpenRemote: onOpenRemote)
            case .scripts: PaseoScriptsPane(onOpenRemote: onOpenRemote)
            case .config: PaseoConfigPane(onOpenRemote: onOpenRemote)
            }
        }
        .background(Color.ompCanvas)
    }

    private var hostTopBar: some View {
        HStack(spacing: 8) {
            Button(action: onOpenDrawer) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shell.drawer")
            .accessibilityLabel("打开抽屉")

            Spacer()

            VStack(spacing: 0) {
                Text("主机")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                if session.isConnected, !session.hostName.isEmpty {
                    Text(session.hostName)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 8)
        .frame(height: IOSShellMetrics.topBarHeight)
        .background(Color.ompCanvas)
    }
}

// MARK: - Drawer (secondary entries only)

/// 左侧抽屉: only second-level entries (项目 / 会话历史 / 计划任务 / 用量 / 设备 / 子代理).
struct ShellDrawer: View {
    @Environment(ChatAppModel.self) private var model
    @Binding var route: IOSShellRoute?
    let onClose: () -> Void
    let onSelectConversation: (UUID) -> Void

    @State private var search = ""
    /// Deleting a chat asks first, like the desktop's row menu.
    @State private var pendingDelete: Conversation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OMP Chat")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ompText)
                Spacer()
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.ompText)
                        .frame(width: 32, height: 32)
                        .background(Color.ompFill, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 54)
            .padding(.bottom, 14)
            .accessibilityIdentifier("shell.drawer.panel")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompTextTertiary)
                TextField("搜索会话…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            VStack(spacing: 2) {
                Button { route = .projects } label: {
                    drawerItem(icon: "folder", title: "项目", badge: "\(model.projects.count)")
                }.buttonStyle(.plain)

                Button {
                    _ = model.newTemporaryConversation()
                    // Clearing the route dismisses the drawer; closeDrawer()
                    // belongs to IOSShell and is not in scope here.
                    route = nil
                } label: {
                    drawerItem(icon: "timer", title: "临时对话")
                }.buttonStyle(.plain)

                Button { route = .history } label: {
                    drawerItem(icon: "clock", title: "会话历史", badge: "\(model.sortedConversations.count)")
                }.buttonStyle(.plain)

                Button { route = .archived } label: {
                    drawerItem(icon: "archivebox", title: "已归档",
                               badge: model.archivedConversations.isEmpty ? nil : "\(model.archivedConversations.count)")
                }.buttonStyle(.plain)

                Button { route = .locked } label: {
                    drawerItem(icon: "lock", title: "已锁定",
                               badge: model.lockedConversations.isEmpty ? nil : "\(model.lockedConversations.count)")
                }.buttonStyle(.plain)

                Button { route = .usage } label: {
                    drawerItem(icon: "chart.bar", title: "用量")
                }.buttonStyle(.plain)

                Button { route = .devices } label: {
                    drawerItem(icon: "desktopcomputer", title: "设备")
                }.buttonStyle(.plain)

                Button { route = .subagents } label: {
                    drawerItem(icon: "person.2", title: "CLI 会话")
                }.buttonStyle(.plain)
                Button { route = .diagnostics } label: {
                    drawerItem(icon: "stethoscope", title: "诊断")
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10)

            Divider().padding(.vertical, 12)

            HStack {
                Text("最近会话")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ompTextTertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !priorityConversations.isEmpty {
                        Text("待处理")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.ompTextTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 2)
                            .padding(.bottom, 4)
                        ForEach(priorityConversations) { conv in
                            conversationRow(conv)
                        }
                        Divider().padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    ForEach(filteredConversations) { conv in
                        conversationRow(conv)
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)

            Divider()
            userChip
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ompCard)
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 8, y: 0)
    }


    /// Unread replies and whichever conversation is still generating — the
    /// phone's counterpart to the desktop sidebar's 待处理 section.
    private var priorityConversations: [Conversation] {
        let ids = model.priorityConversationIDs()
        return model.sortedConversations.filter { ids.contains($0.id) }
    }

    /// Reorders within the visible list and persists the new indexes.
    private func moveRow(_ conv: Conversation, by step: Int) {
        var order = model.sortedConversations
        guard let from = order.firstIndex(where: { $0.id == conv.id }) else { return }
        let to = from + step
        guard order.indices.contains(to) else { return }
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        model.reorderConversations(order)
    }

    private func setManualOrder() {
        var settings = model.settings
        settings.conversationSort = "manual"
        // Persisted through the model so the desktop sidebar agrees.
        Task { await model.saveSettings(settings) }
    }

    private func conversationRow(_ conv: Conversation) -> some View {
            Button {
                onSelectConversation(conv.id)
            } label: {
                HStack(spacing: 8) {
                    Text(conv.title)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.ompText)
                        .lineLimit(1)
                    Spacer()
                    Text(conv.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompTextTertiary)
                    if model.streamingConversationID == conv.id {
                        ProgressView().controlSize(.mini)
                    } else if conv.hasUnread {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    } else if conv.id == model.selectedConversationID {
                        Circle().fill(Color.ompText).frame(width: 5, height: 5)
                    } else if conv.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(
                    conv.id == model.selectedConversationID ? Color.ompFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            // Rows live in a ScrollView, not a List, so swipeActions does not
            // apply; a context menu is the phone's equivalent for the desktop
            // row's pin / archive / delete menu.
            .contextMenu {
                Button { model.togglePin(conv.id) } label: {
                    Label(conv.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                }
                Button { model.setUnread(conv.id, unread: !conv.hasUnread) } label: {
                    Label(conv.hasUnread ? "标记已读" : "标记未读", systemImage: "envelope.badge")
                }
                Button { model.toggleArchive(conv.id) } label: {
                    Label(conv.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
                }
                Divider()
                // Moving rows is only meaningful in manual order; offering it
                // under a date sort would change nothing on screen.
                if model.settings.conversationSort == "manual" {
                    Button { moveRow(conv, by: -1) } label: {
                        Label("上移", systemImage: "arrow.up")
                    }
                    Button { moveRow(conv, by: 1) } label: {
                        Label("下移", systemImage: "arrow.down")
                    }
                } else {
                    Button { setManualOrder() } label: {
                        Label("切换为手动排序", systemImage: "arrow.up.arrow.down")
                    }
                }
                Divider()
                Button(role: .destructive) { pendingDelete = conv } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .confirmationDialog(
                "删除这个对话？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { conv in
                Button("删除", role: .destructive) {
                    model.deleteConversation(conv.id)
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { conv in
                Text("「\(conv.title)」及其消息将被永久删除，无法撤销。")
            }
    }

    private var filteredConversations: [Conversation] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // While the 待处理 group is shown, its rows are not repeated below.
        let shown = Set(search.isEmpty ? priorityConversations.map(\.id) : [])
        if q.isEmpty {
            return Array(model.sortedConversations.filter { !shown.contains($0.id) }.prefix(20))
        }
        return model.sortedConversations.filter {
            !shown.contains($0.id)
                && ($0.title.lowercased().contains(q) || $0.lastMessagePreview.lowercased().contains(q))
        }
    }

    private func drawerItem(icon: String, title: String, badge: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.ompText)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ompText)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    /// Bottom user chip: real provider/model state, no fake account.
    private var userChip: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.ompPrimarySolid)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompInverseText)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(model.activeProvider?.name ?? "未配置供应商")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                Text(model.activeModel?.id ?? "默认模型")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(height: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Composer (official iOS pill)

/// 贴底胶囊输入条: 40pt single-line / ≤132pt multi-line, radius 22,
/// ompSurface fill + 0.5pt border; left `+` menu, right 32pt circular send key.
struct PaseoComposerBar: View {
    @Environment(ChatAppModel.self) private var model
    @State private var showVoiceSheet = false
    @State private var showImageSheet = false
    @State private var importingFile = false

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                if !model.imageModels.isEmpty {
                    Button {
                        showImageSheet = true
                    } label: {
                        Label("生成图片", systemImage: "photo.badge.plus")
                    }
                }
                Menu("语音模式") {
                    Button {
                        showVoiceSheet = true
                    } label: {
                        Label("打开语音输入", systemImage: "mic")
                    }
                }
                Button {
                    importingFile = true
                } label: {
                    Label("添加附件", systemImage: "paperclip")
                }
                Menu("提示词模板") {
                    Button("代码审查") {
                        model.draft = "请全面审查以下代码，指出潜在 bug、边界条件、性能瓶颈与六个月可维护性风险：\n\n```\n\n```"
                    }
                    Button("错误排查") {
                        model.draft = "这段代码在运行时报错，请分析根本原因并给出最小改动的修复方案：\n\n```\n\n```"
                    }
                    Button("单元测试") {
                        model.draft = "请为以下模块编写严谨的单元测试，覆盖正常路径、边界值与错误分支：\n\n```\n\n```"
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .frame(width: IOSShellMetrics.composerMinHeight, height: IOSShellMetrics.composerMinHeight)
            }

            TextField("发送消息", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("composer.input")
                .accessibilityLabel("消息输入框")
                .font(.system(size: 15))
                .lineLimit(1...6)
                // A vertical-axis TextField inside an HStack expands to the
                // tallest sibling; `.fixedSize` keeps it at its intrinsic
                // height so an empty composer stays one line (40pt).
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, (IOSShellMetrics.composerMinHeight - 20) / 2)

            sendButton
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .background(Color.ompCard, in: RoundedRectangle(cornerRadius: IOSShellMetrics.composerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IOSShellMetrics.composerRadius, style: .continuous)
                .strokeBorder(Color.ompBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .sheet(isPresented: $showVoiceSheet) {
            VoiceModeSheet().environment(model)
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                do { try model.attach(url: url, removeSandboxScope: scoped) }
                catch { model.dismissError() }
            }
        }
        .sheet(isPresented: $showImageSheet) {
            ImageGenerationSheet().environment(model)
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isStreaming {
            Button {
                model.stop()
            } label: {
                ZStack {
                    Circle().fill(Color.ompPrimarySolid)
                        .frame(width: IOSShellMetrics.sendButtonSize, height: IOSShellMetrics.sendButtonSize)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.ompInverseText)
                        .frame(width: 11, height: 11)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.stop")
            .accessibilityLabel("停止生成")
        } else {
            Button {
                model.send()
            } label: {
                Circle()
                    .fill(Color.ompPrimarySolid)
                    .frame(width: IOSShellMetrics.sendButtonSize, height: IOSShellMetrics.sendButtonSize)
                    .opacity(canSend ? 1 : 0.3)
                    .overlay(
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.ompInverseText)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityIdentifier("composer.send")
            .accessibilityLabel("发送消息")
        }
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftAttachments.isEmpty
    }
}
#endif
