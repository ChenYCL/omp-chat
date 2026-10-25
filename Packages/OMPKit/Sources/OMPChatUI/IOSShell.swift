import SwiftUI
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
    case projects, history, schedules, usage, devices, subagents
    var id: Self { self }
}

public struct IOSShell: View {
    @Environment(ChatAppModel.self) private var model
    @State private var tab: ShellTab = .chat
    @State private var drawerOpen = false
    @State private var route: IOSShellRoute?
    @State private var hostPane: HostPane = .files
    @State private var selectedHost = "Mac mini"

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

                HostScreen(pane: $hostPane, selectedHost: $selectedHost, onOpenDrawer: openDrawer)
                    .toolbarBackground(.hidden, for: .tabBar)
                    .tabItem { Label(ShellTab.host.rawValue, systemImage: "desktopcomputer") }
                    .tag(ShellTab.host)

                RemoteScreen()
                    .tabItem { Label(ShellTab.remote.rawValue, systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(ShellTab.remote)
            }
            .tint(.accentColor)

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
        .sheet(item: $route) { item in
            NavigationStack { routeDestination(item) }
                .environment(model)
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
        case .schedules: PaseoScheduledTasksSheet()
        case .usage: PaseoUsageSheet()
        case .devices: PaseoDevicesSheet(selectedDeviceName: $selectedHost)
        case .subagents: PaseoSubagentsSheet()
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
    /// Official iOS colors; no token exists for hairline-over-white tab bar.
    static let tabBarBackground = Color.ompFlat(rgb: 0xF9F9F9)
}

// MARK: - Chat Screen

/// 聊天 tab: 44pt top bar + transcript + floating chips + pill composer + tool strip.
struct ChatScreen: View {
    @Environment(ChatAppModel.self) private var model
    let onOpenDrawer: () -> Void
    let onOpenHostPane: (IOSShell.HostPane) -> Void

    @State private var showingSubagents = false

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
            ZStack(alignment: .bottom) {
                ChatTranscriptView()
                VStack(spacing: 8) {
                    scrollChevron
                    StatusChipsRow(showingSubagents: $showingSubagents)
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color.ompCanvas)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                ComposerToolBar(onOpenHostPane: onOpenHostPane)
                PaseoComposerBar()
            }
            .background(IOSShellMetrics.tabBarBackground)
        }
        .sheet(isPresented: $showingSubagents) {
            NavigationStack { PaseoSubagentsSheet() }
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
            .accessibilityIdentifier("shell.drawer")
            .accessibilityLabel("打开抽屉")

            Spacer()

            conversationTitleMenu

            Spacer()

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
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
            Button {
                model.showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.selectedConversation?.title ?? "OMP Chat")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.ompTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.ompFill.opacity(0.6), in: Capsule())
        }
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
}

// MARK: - Status Chips (Moshi floating row)

/// Floating chips above the transcript tail: `∠ +932 -288` / `Ω 子代理 · 25` / tool time.
struct StatusChipsRow: View {
    @Environment(ChatAppModel.self) private var model
    @Binding var showingSubagents: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let diff = totalDiff {
                chip {
                    Image(systemName: "angle")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.ompTextTertiary)
                    Text("+\(diff.added)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.ompFlat(rgb: 0x1F7A34))
                    Text("-\(diff.removed)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.red)
                }
            } else if let usage = model.selectedConversation?.messages.compactMap(\.usage).last {
                chip {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.ompFlat(rgb: 0x1F7A34))
                    Text(TokenFormat.compact(usage.inputTokens))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.accentColor)
                    Text(TokenFormat.compact(usage.outputTokens))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                }
            }


            Button {
                showingSubagents = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.ompTextTertiary)
                    Text(toolCount > 0 ? "操作 · \(toolCount)" : "子代理 · \(model.sortedConversations.count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.ompTextSecondary)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private func chip(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 5) { content() }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.ompCard, in: Capsule())
            .shadow(color: Color.black.opacity(0.05), radius: 4, y: 1)
    }

    private var totalDiff: (added: Int, removed: Int)? {
        guard let conversation = model.selectedConversation else { return nil }
        var added = 0
        var removed = 0
        for msg in conversation.messages {
            for part in msg.parts {
                if case .toolResult(let result) = part {
                    for line in result.outputText.split(separator: "\n", omittingEmptySubsequences: false) {
                        if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
                        else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
                    }
                }
            }
        }
        return (added == 0 && removed == 0) ? nil : (added, removed)
    }

    private var toolCount: Int {
        guard let conversation = model.selectedConversation else { return 0 }
        return conversation.messages.reduce(0) { count, msg in
            count + msg.parts.filter {
                if case .toolCall = $0 { return true }
                return false
            }.count
        }
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
        .frame(height: 36)
        .background(IOSShellMetrics.tabBarBackground)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.ompBorder)
            .frame(width: 0.5, height: 16)
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
    @Environment(ChatAppModel.self) private var model
    @Binding var pane: IOSShell.HostPane
    @Binding var selectedHost: String
    let onOpenDrawer: () -> Void

    @State private var directory: URL = URL(fileURLWithPath: "/")

    var body: some View {
        VStack(spacing: 0) {
            hostTopBar
            Divider().opacity(0.6)
            // Pane pills (four-state switch), directly under the top bar.
            HStack(spacing: 4) {
                ForEach(IOSShell.HostPane.allCases, id: \.self) { item in
                    Button {
                        withAnimation(Theme.Motion.quick) { pane = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12.5, weight: pane == item ? .semibold : .medium))
                            .foregroundStyle(pane == item ? Color.ompText : Color.ompTextSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(pane == item ? Color.ompCard : Color.clear)
                            )
                            .shadow(color: pane == item ? Color.black.opacity(0.05) : .clear, radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch pane {
            case .files: PaseoFilesPane(directory: $directory)
            case .terminal: PaseoTerminalPane(directory: directory)
            case .scripts: PaseoScriptsPane(selectedHost: selectedHost)
            case .config: ProviderSettingsEmbedded()
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
            .accessibilityIdentifier("shell.drawer")
            .accessibilityLabel("打开抽屉")

            Spacer()

            Text("主机")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ompText)

            Spacer()

            Button {
                _ = model.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
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
    @State private var showSearch = false

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

            if showSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompTextTertiary)
                    TextField("搜索会话…", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.ompTextTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            } else {
                Button {
                    withAnimation(Theme.Motion.quick) { showSearch = true }
                } label: {
                    drawerItem(icon: "magnifyingglass", title: "搜索")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
            }

            VStack(spacing: 2) {
                Button { route = .projects } label: {
                    drawerItem(icon: "folder", title: "项目", badge: "\(model.projects.count)")
                }.buttonStyle(.plain)

                Button { route = .history } label: {
                    drawerItem(icon: "clock", title: "会话历史", badge: "\(model.sortedConversations.count)")
                }.buttonStyle(.plain)

                Button { route = .schedules } label: {
                    drawerItem(icon: "calendar", title: "计划任务")
                }.buttonStyle(.plain)

                Button { route = .usage } label: {
                    drawerItem(icon: "chart.bar", title: "用量")
                }.buttonStyle(.plain)

                Button { route = .devices } label: {
                    drawerItem(icon: "desktopcomputer", title: "设备")
                }.buttonStyle(.plain)

                Button { route = .subagents } label: {
                    drawerItem(icon: "person.2", title: "子代理")
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
                    ForEach(filteredConversations) { conv in
                        Button {
                            onSelectConversation(conv.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(conv.title)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Color.ompText)
                                    .lineLimit(1)
                                Spacer()
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                conv.id == model.selectedConversationID
                                    ? Color.ompFill
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ompCard)
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 8, y: 0)
    }

    private var filteredConversations: [Conversation] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(model.sortedConversations.prefix(20)) }
        return model.sortedConversations.filter {
            $0.title.lowercased().contains(q) || $0.lastMessagePreview.lowercased().contains(q)
        }
    }

    private func drawerItem(icon: String, title: String, badge: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompText)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.ompText)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                .padding(.vertical, (IOSShellMetrics.composerMinHeight - 20) / 2)
                // Grows with content up to 6 lines; explicit caps make the
                // vertical-axis field jump straight to its maximum.

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
                    .fill(canSend ? Color.ompPrimarySolid : Color.ompFill)
                    .frame(width: IOSShellMetrics.sendButtonSize, height: IOSShellMetrics.sendButtonSize)
                    .overlay(
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(canSend ? Color.ompInverseText : Color.ompTextTertiary)
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
