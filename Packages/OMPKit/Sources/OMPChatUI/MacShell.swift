import SwiftUI
import OMPCore
import OMPDesign
import LocalAuthentication

// Codex desktop single-column sidebar: header row (`◧ Code` + 28pt ghost icon
// buttons), always-visible search field, nav rows (新聊天 / 搜索 / 自定义 / 更多),
// scrollable groups (Recents + 置顶 / 自定义分区 / 项目 / 时间分桶 / 已锁定 / 已归档),
// footer (usage alert + user bar). Nav rows 30pt, conversation rows 32pt.

/// Official `--color-ghost-hover`: light #0000000d, dark #ffffff1a.
var ompGhostHover: Color {
    Color.ompDynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)
}

// MARK: - Sidebar resizer

/// Vertical drag handle between sidebar and main content; 220–320pt clamp.
struct SidebarResizer: View {
    @Binding var width: CGFloat

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.ompBorder.opacity(hovering || dragging ? 1 : 0))
                    .frame(width: 1)
            }
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        width = min(320, max(220, width + value.translation.width - (dragBase ?? 0)))
                        dragBase = value.translation.width
                    }
                    .onEnded { _ in
                        dragging = false
                        dragBase = nil
                    }
            )
            .animation(Theme.Motion.fade, value: hovering)
    }

    @State private var dragBase: CGFloat?
}

// MARK: - Top fade

/// Official `MainContentTopFade`: 24pt gradient ompCanvas → clear so scrolling
/// content dissolves as it reaches the top of the viewport.
struct MainContentTopFade: View {
    var body: some View {
        LinearGradient(
            colors: [.ompCanvas, .ompCanvas.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
        .frame(height: 24)
    }
}

// MARK: - Ghost icon button

/// 28pt rounded ghost-hover icon button (sidebar header + user bar).
private struct GhostIconButton: View {
    let systemImage: String
    var iconSize: CGFloat = 13
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Color.ompTextSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous)
                        .fill(hovering ? ompGhostHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Nav row

/// Codex nav row content: 30pt tall, 13pt secondary icon + 13pt label, radius 6.
private struct NavRowLabel: View {
    let icon: String
    let title: String

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompTextSecondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.officialSM, style: .continuous)
                .fill(hovering ? ompGhostHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
    }
}

/// 30pt sidebar nav row (新聊天 / 搜索 / 自定义).
private struct NavRow: View {
    let icon: String
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NavRowLabel(icon: icon, title: title)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Sidebar

/// Codex desktop single-column sidebar.
public struct MacShellSidebar: View {
    @Environment(ChatAppModel.self) private var model
    @State private var search = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var deletingID: UUID?
    @State private var collapsedProjects: Set<UUID> = []
    @State private var creatingProject = false
    @State private var newProjectName = ""
    @State private var renamingProjectID: UUID?
    @State private var showLocked = false
    @State private var isLockedUnlocked = false
    @State private var showArchived = false
    @State private var showCLISessions = false
    @State private var showMoreMenu = false
    @State private var creatingCustomSection = false
    @State private var customSectionName = ""
    @State private var renamingSectionID: UUID?
    @State private var collapsedCustomSections: Set<UUID> = []
    @State private var showProjectsSheet = false
    @FocusState private var searchFocused: Bool

    public init() {}

    /// 11.5pt medium group titles (Codex sidebar heading).
    private static let sectionTitle = Font.system(size: 11.5, weight: .medium)
    /// Conversation row height (Codex sidebar row).
    private static let conversationRowHeight: CGFloat = 32

    public var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .background(Color.ompSidebar)
        .sheet(isPresented: $showProjectsSheet) {
            PaseoProjectsSheet()
                .environment(model)
        }
        .sheet(isPresented: $showCLISessions) {
            CLISessionsSheet(source: .thisMac)
                .environment(model)
                .environment(RemoteSession())
        }
        .scheduledTaskEditorHost()
        .alert("重命名对话", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) { renamingID = nil }
            Button("保存") {
                if let id = renamingID { model.renameConversation(id, title: renameText) }
                renamingID = nil
            }
        }
        .confirmationDialog(
            "删除这个对话？",
            isPresented: Binding(
                get: { deletingID != nil },
                set: { if !$0 { deletingID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let id = deletingID { model.deleteConversation(id) }
                deletingID = nil
            }
            Button("取消", role: .cancel) { deletingID = nil }
        } message: {
            Text("此操作不可撤销。")
        }
        .alert("新建项目", isPresented: $creatingProject) {
            TextField("项目名称", text: $newProjectName)
            Button("取消", role: .cancel) { newProjectName = "" }
            Button("创建") {
                _ = model.createProject(name: newProjectName)
                newProjectName = ""
            }
        }
        .alert("新建自定义分区", isPresented: $creatingCustomSection) {
            TextField("分区名称", text: $customSectionName)
            Button("取消", role: .cancel) { customSectionName = "" }
            Button("创建") {
                _ = model.createCustomSection(name: customSectionName)
                customSectionName = ""
            }
        }
        .alert("重命名分区", isPresented: Binding(
            get: { renamingSectionID != nil },
            set: { if !$0 { renamingSectionID = nil } }
        )) {
            TextField("分区名称", text: $customSectionName)
            Button("取消", role: .cancel) { renamingSectionID = nil }
            Button("保存") {
                if let id = renamingSectionID { model.renameCustomSection(id, name: customSectionName) }
                renamingSectionID = nil
            }
        }
    }

    // MARK: Header: `◧ Code` + ghost buttons + search

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.lefthalf.filled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ompText)
                    // The app's own name; this said "Code", which is the app
                    // this layout was modelled on, not this one.
                    Text("OMP Chat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ompText)
                }
                Spacer(minLength: 0)
                GhostIconButton(systemImage: "square.and.pencil", help: "新建聊天 (⌘N)") {
                    model.newConversation()
                }
                GhostIconButton(systemImage: "command", help: "命令面板 (⌘K)") {
                    NotificationCenter.default.post(name: .ompQuickSwitch, object: nil)
                }
            }
            searchField
        }
        .padding(.horizontal, 12)
        .padding(.top, 38)
        .padding(.bottom, 6)
    }

    /// Always-visible search field: 30pt, radius 8, ompFill, 11pt magnifier.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.ompTextTertiary)
            TextField("搜索", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous))
    }

    // MARK: Scroll region

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                navRows
                if searching {
                    ForEach(filtered) { row($0) }
                    if filtered.isEmpty { emptyHint }
                } else {
                    prioritySection
                    temporarySection
                    pinnedSection
                    ScheduledTasksSidebarSection()
                    customSections
                    projectSections
                    ungroupedSection
                    lockedSection
                    archivedSection
                    if model.conversations.isEmpty || sidebarHiddenEverything { emptyHint }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
    }

    /// Nav rows: 新聊天 / 搜索 / 自定义 / 更多. Every legacy rail & header entry
    /// stays reachable from here.
    private var navRows: some View {
        VStack(spacing: 1) {
            NavRow(icon: "plus", title: "新聊天", help: "新建聊天 (⌘N)") {
                model.newConversation()
            }
            NavRow(icon: "magnifyingglass", title: "搜索", help: "搜索对话") {
                searchFocused = true
            }
            NavRow(icon: "folder", title: "自定义", help: "项目与自定义分区管理") {
                showProjectsSheet = true
            }
            Button {
                showMoreMenu = true
            } label: {
                NavRowLabel(icon: "ellipsis", title: "更多")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showMoreMenu, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    moreMenuItem("新建临时对话") { _ = model.newTemporaryConversation() }
                    moreMenuItem("新建项目") {
                        newProjectName = ""
                        creatingProject = true
                    }
                    moreMenuItem("新建自定义分区") {
                        customSectionName = ""
                        creatingCustomSection = true
                    }
                    moreMenuItem("添加定时任务…") { NotificationCenter.default.post(name: .ompAddScheduledTask, object: nil) }
                    Divider()
                    moreMenuItem("折叠全部分组") {
                        let ids = model.orderedProjects.map(\.id) + model.orderedCustomSections.map(\.id)
                        collapsedProjects.formUnion(ids)
                        collapsedCustomSections.formUnion(ids)
                    }
                    moreMenuItem("展开全部分组") {
                        collapsedProjects.removeAll()
                        collapsedCustomSections.removeAll()
                    }
                    Divider()
                    moreMenuItem("已归档") { showArchived = true }
                    moreMenuItem(isLockedUnlocked ? "已锁定 (已解锁)" : "已锁定 (解锁查看)") {
                        toggleLockedSection()
                    }
                    Divider()
                    // The phone could see the Mac's Claude sessions; the Mac
                    // itself could not, though it is the machine running them.
                    moreMenuItem("CLI 会话") { showCLISessions = true }
                }
                .padding(8)
                .frame(width: 220)
            }
            .help("更多")
        }
        .padding(.bottom, 4)
    }

    /// Popover menu row: 28pt, ghost hover, matching the nav rows.
    private func moreMenuItem(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            showMoreMenu = false
            action()
        } label: {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompText)
                .padding(.horizontal, 10)
                .frame(height: 28, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filtered: [Conversation] {
        ConversationSearch.filter(model.sortedConversations, query: search)
    }

    // MARK: Sections

    /// Official `priorityThreads` idea: what wants attention right now —
    /// unread replies and whichever conversation is still generating. Hidden
    /// when there is nothing waiting, so it never takes space for nothing.
    private var priorityItems: [Conversation] {
        let ids = model.priorityConversationIDs()
        return model.sortedConversations.filter { ids.contains($0.id) }
    }

    /// Temporary chats: no icon clutter, just the list, and a hint that they are
    /// dropped when the app closes. Without this section a temporary chat
    /// disappeared from the sidebar the moment it stopped being selected.
    private var temporarySection: some View {
        let items = model.temporaryConversations
        return Group {
            if !items.isEmpty {
                sectionHeader("临时")
                ForEach(items) { conversation in
                    row(conversation)
                }
            }
        }
    }

    /// Conversations the 整理侧栏 filter lets through, applied to every list.
    private var filterAllowed: (Conversation) -> Bool {
        let rule = SidebarFilter(stored: model.settings.sidebarFilter)
        return { rule.includes($0) }
    }

    @ViewBuilder
    private var prioritySection: some View {
        let items = priorityItems.filter(filterAllowed)
        if !items.isEmpty {
            sectionHeader("待处理")
            ForEach(items) { row($0) }
            markAllReadButton
        }
    }

    /// 全部标为已读 under the 待处理 header: one click clears every unread flag.
    private var markAllReadButton: some View {
        Button {
            model.markAllRead()
        } label: {
            Label("全部标为已读", systemImage: "envelope.open")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ompTextSecondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .accessibilityLabel("全部标为已读")
        .accessibilityIdentifier("sidebar.markAllRead")
        .help("全部标为已读")
    }

    /// True when the filter hides every conversation the sidebar could list,
    /// so the empty state explains why instead of a bare sidebar.
    private var sidebarHiddenEverything: Bool {
        !model.conversations.isEmpty
            && SidebarOrganization.filter(model.sortedConversations, by: SidebarFilter(stored: model.settings.sidebarFilter)).isEmpty
    }

    private var pinnedSection: some View {
        let pinned = model.sortedConversations.filter { $0.isPinned && !$0.isArchived && !$0.isLocked }.filter(filterAllowed)
        return Group {
            if !pinned.isEmpty {
                sectionHeader("置顶")
                ForEach(pinned) { row($0) }
            }
        }
    }

    private var customSections: some View {
        let handled = model.priorityConversationIDs()
        return ForEach(model.orderedCustomSections) { custom in
            let collapsed = collapsedCustomSections.contains(custom.id)
            Button {
                if collapsed { collapsedCustomSections.remove(custom.id) } else { collapsedCustomSections.insert(custom.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompTextSecondary)
                    Text(custom.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompText)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.ompTextTertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { customSectionMenu(custom) }
            if !collapsed {
                ForEach(model.conversations(inCustomSection: custom.id).filter { !$0.isPinned && !handled.contains($0.id) }.filter(filterAllowed)) { row($0) }
            }
        }
    }

    @ViewBuilder
    private func customSectionMenu(_ custom: Project) -> some View {
        Button {
            customSectionName = custom.name
            renamingSectionID = custom.id
        } label: {
            Label("重命名分区", systemImage: "pencil")
        }
        Divider()
        Button {
            model.archiveConversations(inCustomSection: custom.id)
        } label: {
            Label("归档分区全部会话", systemImage: "archivebox")
        }
        Button {
            model.markCustomSectionRead(custom.id)
        } label: {
            Label("标记分区已读", systemImage: "envelope.open")
        }
        Divider()
        Button(role: .destructive) {
            model.deleteCustomSection(custom.id)
        } label: {
            Label("删除分区", systemImage: "trash")
        }
    }

    private var projectSections: some View {
        let handled = model.priorityConversationIDs()
        return ForEach(model.orderedProjects) { project in
            projectHeader(project)
            if !collapsedProjects.contains(project.id) {
                ForEach(model.conversations(in: project.id).filter { !$0.isPinned && !handled.contains($0.id) }.filter(filterAllowed)) { row($0) }
            }
        }
    }

    enum DateBucket: String, CaseIterable {
        case today = "今天"
        case yesterday = "昨天"
        case previous7Days = "前 7 天"
        case previous30Days = "前 30 天"
        case earlier = "更早"
    }

    private static func bucket(for date: Date) -> DateBucket {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return .previous7Days }
        if days < 30 { return .previous30Days }
        return .earlier
    }

    private var ungroupedSection: some View {
        // 待处理 already lists unread / streaming / awaiting-reply chats, so
        // they are not repeated here (the phone drawer does the same).
        let handled = model.priorityConversationIDs()
        let items = model.conversations(in: nil).filter {
            !$0.isPinned && !$0.isArchived && !$0.isLocked && !handled.contains($0.id)
        }.filter(filterAllowed)
        var groups: [DateBucket: [Conversation]] = [:]
        for c in items {
            let b = Self.bucket(for: c.updatedAt)
            groups[b, default: []].append(c)
        }

        return Group {
            if !items.isEmpty {
                recentsHeader
                if SidebarGrouping(stored: model.settings.sidebarGrouping) == .connection {
                    connectionGroups(items)
                } else if model.projects.isEmpty {
                    ForEach(DateBucket.allCases, id: \.self) { b in
                        if let bucketItems = groups[b], !bucketItems.isEmpty {
                            sectionHeader(b.rawValue)
                            ForEach(bucketItems) { row($0) }
                        }
                    }
                } else {
                    ForEach(items) { row($0) }
                }
            }
        }
    }

    /// 按连接: one collapsible group per provider (Codex
    /// `sidebarElectron.groupByMenu` connection mode), most recent first.
    @ViewBuilder
    private func connectionGroups(_ items: [Conversation]) -> some View {
        let groups = SidebarOrganization.connectionGroups(items, providers: model.providers)
        ForEach(Array(groups.enumerated()), id: \.element.name) { _, group in
            ConnectionGroupHeader(name: group.name, count: group.conversations.count)
            ForEach(group.conversations) { row($0) }
        }
    }

    /// Codex `Recents` group heading: 11.5pt medium tertiary + sort menu
    /// (最后更新 / 创建时间 / 手动, backed by real `settings.conversationSort`).
    private var recentsHeader: some View {
        HStack(spacing: 4) {
            Text("Recents")
                .font(Self.sectionTitle)
                .tracking(0.2)
                .foregroundStyle(Color.ompTextTertiary)
            Spacer(minLength: 0)
            organizeMenu
            Menu {
                sortItem("updated", "最后更新")
                sortItem("created", "创建时间")
                sortItem("manual", "手动")
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("排序方式")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func sortItem(_ value: String, _ title: String) -> some View {
        Button {
            var settings = model.settings
            settings.conversationSort = value
            Task { await model.saveSettings(settings) }
        } label: {
            if model.settings.conversationSort == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Codex `sidebarElectron.groupByMenu`: 分组 (按项目 / 按连接) and 显示
    /// (全部 / 聊天 / 工作), both persisted through `saveSettings`.
    private var organizeMenu: some View {
        Menu {
            Section("分组") {
                organizeItem(SidebarGrouping.project.rawValue, "按项目") { $0.sidebarGrouping = SidebarGrouping.project.rawValue }
                organizeItem(SidebarGrouping.connection.rawValue, "按连接") { $0.sidebarGrouping = SidebarGrouping.connection.rawValue }
            }
            Section("显示") {
                organizeItem(SidebarFilter.all.rawValue, "全部") { $0.sidebarFilter = SidebarFilter.all.rawValue }
                organizeItem(SidebarFilter.chat.rawValue, "聊天") { $0.sidebarFilter = SidebarFilter.chat.rawValue }
                organizeItem(SidebarFilter.work.rawValue, "工作") { $0.sidebarFilter = SidebarFilter.work.rawValue }
            }
        } label: {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("整理侧栏")
        .accessibilityIdentifier("sidebar.organize")
        .help("整理侧栏")
    }

    private func organizeItem(_ value: String, _ title: String, apply: @escaping (inout AppSettings) -> Void) -> some View {
        Button {
            var settings = model.settings
            apply(&settings)
            Task { await model.saveSettings(settings) }
        } label: {
            if isSelected(value) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Ticked when this grouping or filter value is the stored one.
    private func isSelected(_ value: String) -> Bool {
        model.settings.sidebarGrouping == value || model.settings.sidebarFilter == value
    }

    private var archivedSection: some View {
        Group {
            if !model.archivedConversations.isEmpty {
                Button {
                    showArchived.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Image(systemName: "archivebox")
                            .font(.system(size: 13))
                        Text("已归档")
                            .font(Self.sectionTitle)
                        Text("\(model.archivedConversations.count)")
                            .font(.system(size: 9.5).monospacedDigit())
                    }
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showArchived {
                    ForEach(model.archivedConversations) { row($0) }
                }
            }
        }
    }

    private var lockedSection: some View {
        Group {
            if !model.lockedConversations.isEmpty {
                Button {
                    toggleLockedSection()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: (showLocked && isLockedUnlocked) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Image(systemName: isLockedUnlocked ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(isLockedUnlocked ? Color.accentColor : Color.ompTextTertiary)
                        Text("已锁定")
                            .font(Self.sectionTitle)
                        Text("\(model.lockedConversations.count)")
                            .font(.system(size: 9.5).monospacedDigit())
                        if isLockedUnlocked {
                            Text("已解锁")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isLockedUnlocked ? "点击重新锁定" : "点击验证 Touch ID 或密码解锁")
                if showLocked && isLockedUnlocked {
                    ForEach(model.lockedConversations) { row($0) }
                }
            }
        }
    }

    private func toggleLockedSection() {
        if isLockedUnlocked {
            withAnimation(Theme.Motion.quick) {
                isLockedUnlocked = false
                showLocked = false
            }
        } else {
            let context = LAContext()
            var error: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "验证以访问已锁定的私密对话") { success, _ in
                    Task { @MainActor in
                        if success {
                            withAnimation(Theme.Motion.quick) {
                                isLockedUnlocked = true
                                showLocked = true
                            }
                        }
                    }
                }
            } else {
                withAnimation(Theme.Motion.quick) {
                    isLockedUnlocked = true
                    showLocked = true
                }
            }
        }
    }

    private func projectHeader(_ project: Project) -> some View {
        let collapsed = collapsedProjects.contains(project.id)
        return Button {
            if collapsed { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ompTextSecondary)
                Text(project.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.ompTextTertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                _ = model.newConversation(in: project.id)
            } label: {
                Label("在项目中新建对话", systemImage: "plus")
            }
            Button {
                newProjectName = project.name
                renamingProjectID = project.id
            } label: {
                Label("重命名项目", systemImage: "pencil")
            }
            Button(role: .destructive) {
                model.deleteProject(project.id)
            } label: {
                Label("删除项目", systemImage: "trash")
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Self.sectionTitle)
            .tracking(0.2)
            .foregroundStyle(Color.ompTextTertiary)
            .padding(.leading, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: search.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(Color.ompTextTertiary)
            Text(search.isEmpty ? (sidebarHiddenEverything ? "没有符合的对话" : "还没有对话") : "没有匹配的对话")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Rows

    private func row(_ conversation: Conversation) -> some View {
        MacShellConversationRow(
            title: conversation.title,
            isPinned: conversation.isPinned,
            relativeTime: Self.relativeTime(conversation.updatedAt),
            isSelected: model.selectedConversationID == conversation.id,
            isStreamingThis: model.streamingConversationID == conversation.id,
            hasUnread: conversation.hasUnread,
            menuContent: { AnyView(menu(for: conversation)) }
        )
        .onTapGesture {
            model.selectedConversationID = conversation.id
        }
        .contextMenu { menu(for: conversation) }
        .draggable(conversation.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = UUID(uuidString: raw), dragged != conversation.id else { return false }
            var order = model.sortedConversations
            guard let from = order.firstIndex(where: { $0.id == dragged }),
                  let to = order.firstIndex(where: { $0.id == conversation.id }) else { return false }
            let moved = order.remove(at: from)
            order.insert(moved, at: to)
            model.reorderConversations(order)
            return true
        }
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "刚刚"
        case ..<3600: return "\(Int(seconds / 60)) 分钟前"
        case ..<86400: return "\(Int(seconds / 3600)) 小时前"
        case ..<604800: return "\(Int(seconds / 86400)) 天前"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
    }

    @ViewBuilder
    private func menu(for conversation: Conversation) -> some View {
        Button {
            model.togglePin(conversation.id)
        } label: {
            Label(conversation.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
        }
        Button {
            model.setUnread(conversation.id, unread: !conversation.hasUnread)
        } label: {
            Label(conversation.hasUnread ? "标记为已读" : "标记为未读", systemImage: conversation.hasUnread ? "envelope.open" : "envelope.badge")
        }
        Button {
            model.toggleArchive(conversation.id)
        } label: {
            Label(conversation.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
        }
        Button {
            model.toggleLock(conversation.id)
        } label: {
            Label(conversation.isLocked ? "解锁对话" : "锁定对话", systemImage: conversation.isLocked ? "lock.open" : "lock")
        }
        Button {
            renameText = conversation.title
            renamingID = conversation.id
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            model.duplicateConversation(conversation.id)
        } label: {
            Label("复制为新分支", systemImage: "arrow.triangle.branch")
        }
        if !model.projects.isEmpty {
            Menu("移动到项目") {
                if conversation.projectID != nil {
                    Button("移出项目") {
                        model.moveConversation(conversation.id, to: nil)
                    }
                }
                ForEach(model.orderedProjects) { project in
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
        Divider()
        Button(role: .destructive) {
            deletingID = conversation.id
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: Footer: usage alert + user bar

    private var footer: some View {
        VStack(spacing: 0) {
            contextFooter
            usageAlert
            userBar
        }
    }

    /// Context-window meter with the detail popover. `ContextBadge` existed
    /// unwired, so the capacity readout the PRD calls delivered was reachable
    /// from nowhere.
    @ViewBuilder
    private var contextFooter: some View {
        if let conversation = model.selectedConversation,
           let usage = model.contextUsage(conversation), usage.limit > 0 {
            HStack(spacing: 6) {
                ContextBadge(used: usage.used, limit: usage.limit)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    /// Codex user bar: 44pt, 18pt gradient avatar, name, `Pro` capsule, gear.
    private var userBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.ompMarkGradient)
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                )
            Text("本地")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.ompText)
            Text("Pro")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.ompTextTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .overlay(Capsule().strokeBorder(Color.ompBorder, lineWidth: 1))
            Spacer(minLength: 0)
            GhostIconButton(systemImage: "gearshape", iconSize: 14, help: "偏好设置 (⌘,)") {
                model.showSettings = true
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    /// Sidebar usage alert strip: progress bar + window remaining, shown once
    /// context passes 85%.
    @ViewBuilder
    private var usageAlert: some View {
        if let conversation = model.selectedConversation,
           let usage = model.contextUsage(conversation),
           usage.limit > 0 {
            let ratio = Double(usage.used) / Double(usage.limit)
            if ratio >= 0.85 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(ratio >= 0.95 ? .red : .orange)
                        Text(ratio >= 0.95 ? "上下文即将用尽" : "上下文空间偏低")
                            .font(.system(size: 10.5, weight: .semibold))
                        Spacer()
                        Text("剩余 \(TokenFormat.compact(max(0, usage.limit - usage.used)))")
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.ompFill)
                            Capsule()
                                .fill(ratio >= 0.95 ? Color.red : Color.orange)
                                .frame(width: max(3, proxy.size.width * min(1, ratio)))
                        }
                    }
                    .frame(height: 3)
                    Text("新对话以获得完整上下文窗口")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.ompTextSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.ompFill.opacity(0.6))
            }
        }
    }
}

// MARK: - Conversation row

/// Codex sidebar conversation row: 32pt tall, 5pt leading status dot (unread =
/// solid ompText, else stroked ompBorder), 13pt title, selected = ompFill
/// radius 6, trailing `···` revealed on hover only.
private struct MacShellConversationRow: View {
    let title: String
    let isPinned: Bool
    let relativeTime: String
    let isSelected: Bool
    var isStreamingThis: Bool = false
    var hasUnread: Bool = false
    var menuContent: (() -> AnyView)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isStreamingThis {
                ProgressView()
                    .controlSize(.mini)
            } else if hovering, let menuContent {
                Menu {
                    menuContent()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.ompFill, in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else if hovering {
                Text(relativeTime)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.officialSM, style: .continuous)
                .fill(isSelected ? Color.ompFill : (hovering ? ompGhostHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
    }

    /// 5pt status dot; pinned conversations show the orange pin instead.
    @ViewBuilder
    private var statusDot: some View {
        if isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
                .frame(width: 5, height: 5)
        } else if hasUnread {
            Circle()
                .fill(Color.ompText)
                .frame(width: 5, height: 5)
        } else {
            Circle()
                .strokeBorder(Color.ompBorder, lineWidth: 1)
                .frame(width: 5, height: 5)
        }
    }
}

// MARK: - Connection group header

/// Collapsible 按连接 group header: provider name + conversation count,
/// styled like the locked section's disclosure row.
private struct ConnectionGroupHeader: View {
    let name: String
    let count: Int
    @State private var collapsed = false

    var body: some View {
        Button {
            collapsed.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                Text(name)
                    .font(Self.sectionTitle)
                Text("\(count)")
                    .font(.system(size: 9.5).monospacedDigit())
            }
            .foregroundStyle(Color.ompTextTertiary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("连接分组 \(name)")
        .accessibilityIdentifier("sidebar.connectionGroup.\(name)")
    }

    private static let sectionTitle = Font.system(size: 11.5, weight: .medium)
}
