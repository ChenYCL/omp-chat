import SwiftUI
import OMPCore
import OMPDesign
import LocalAuthentication

// Official ChatGPT desktop single-column sidebar (no 52pt icon rail):
// header row (new chat + search + overflow "···"), scrollable middle, footer
// (usage alert + settings + active model pill). All rows 36pt on ompSidebar.

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

// MARK: - Sidebar

/// Official single-column sidebar, ChatGPT desktop parity.
public struct MacShellSidebar: View {
    @Environment(ChatAppModel.self) private var model
    @State private var search = ""
    @State private var showSearch = false
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
    @State private var creatingCustomSection = false
    @State private var customSectionName = ""
    @State private var renamingSectionID: UUID?
    @State private var collapsedCustomSections: Set<UUID> = []
    @State private var hoverNewChat = false
    @State private var hoverMore = false
    @State private var hoverSettings = false
    @State private var showContextPopover = false
    @State private var showModelPicker = false

    public init() {}

    /// 13–14pt sidebar icons (official sidebar nav size).
    private static let rowIconSize: CGFloat = 13.5
    /// 11pt semibold group titles (official sidebar heading).
    private static let sectionTitle = Font.system(size: 11, weight: .semibold)

    public var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .background(Color.ompSidebar)
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

    /// Official --color-ghost-hover equivalent: light #0000000d, dark #ffffff1a.
    private var ghostHover: Color {
        Color.ompDynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)
    }

    // MARK: Header: new chat (primary) + search + overflow

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    model.newConversation()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: Self.rowIconSize, weight: .medium))
                        Text("新聊天")
                            .font(Theme.Typography.sidebarTitle)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.ompText)
                    .frame(height: Theme.Layout.rowHeight)
                    .padding(.horizontal, 10)
                    .background(hoverNewChat ? ghostHover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverNewChat = $0 }
                .help("新建聊天 (⌘N)")

                Button {
                    withAnimation(Theme.Motion.quick) { showSearch.toggle() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: Self.rowIconSize))
                        .foregroundStyle(showSearch ? Color.accentColor : Color.ompTextTertiary)
                        .frame(width: Theme.Layout.rowHeight, height: Theme.Layout.rowHeight)
                        .background(showSearch ? ghostHover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("搜索对话")

                Menu {
                    Button("新建临时对话") {
                        _ = model.newTemporaryConversation()
                    }
                    Button("新建项目") {
                        newProjectName = ""
                        creatingProject = true
                    }
                    Button("新建自定义分区") {
                        customSectionName = ""
                        creatingCustomSection = true
                    }
                    Divider()
                    Button("项目与工作区 (⌘K)") {
                        NotificationCenter.default.post(name: .ompQuickSwitch, object: nil)
                    }
                    Divider()
                    Button("折叠全部分组") {
                        let ids = model.orderedProjects.map(\.id) + model.orderedCustomSections.map(\.id)
                        collapsedProjects.formUnion(ids)
                        collapsedCustomSections.formUnion(ids)
                    }
                    Button("展开全部分组") {
                        collapsedProjects.removeAll()
                        collapsedCustomSections.removeAll()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: Self.rowIconSize))
                        .foregroundStyle(Color.ompTextTertiary)
                        .frame(width: Theme.Layout.rowHeight, height: Theme.Layout.rowHeight)
                        .background(hoverMore ? ghostHover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .onHover { hoverMore = $0 }
                .help("更多")
            }
            if showSearch {
                searchField
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 38)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextTertiary)
            TextField("搜索对话", text: $search)
                .textFieldStyle(.plain)
                .font(Theme.Typography.sm)
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
        .frame(height: 28)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
    }

    // MARK: Scroll region

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if searching {
                    ForEach(filtered) { row($0) }
                    if filtered.isEmpty { emptyHint }
                } else {
                    pinnedSection
                    customSections
                    projectSections
                    ungroupedSection
                    lockedSection
                    archivedSection
                    if model.conversations.isEmpty { emptyHint }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
    }

    private var searching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filtered: [Conversation] {
        let sorted = model.sortedConversations
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.lastMessagePreview.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: Sections

    private var pinnedSection: some View {
        let pinned = model.sortedConversations.filter { $0.isPinned && !$0.isArchived && !$0.isLocked }
        return Group {
            if !pinned.isEmpty {
                sectionHeader("置顶")
                ForEach(pinned) { row($0) }
            }
        }
    }

    private var customSections: some View {
        ForEach(model.orderedCustomSections) { custom in
            let collapsed = collapsedCustomSections.contains(custom.id)
            Button {
                if collapsed { collapsedCustomSections.remove(custom.id) } else { collapsedCustomSections.insert(custom.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: Self.rowIconSize))
                        .foregroundStyle(Color.ompTextSecondary)
                    Text(custom.name)
                        .font(Theme.Typography.sidebarTitle)
                        .foregroundStyle(Color.ompText)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.ompTextTertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                .padding(.horizontal, 10)
                .frame(height: Theme.Layout.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { customSectionMenu(custom) }
            if !collapsed {
                ForEach(model.conversations(inCustomSection: custom.id).filter { !$0.isPinned }) { row($0) }
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
        ForEach(model.orderedProjects) { project in
            projectHeader(project)
            if !collapsedProjects.contains(project.id) {
                ForEach(model.conversations(in: project.id).filter { !$0.isPinned }) { row($0) }
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
        let items = model.conversations(in: nil).filter { !$0.isPinned && !$0.isArchived && !$0.isLocked }
        var groups: [DateBucket: [Conversation]] = [:]
        for c in items {
            let b = Self.bucket(for: c.updatedAt)
            groups[b, default: []].append(c)
        }

        return Group {
            if !items.isEmpty {
                if model.projects.isEmpty {
                    ForEach(DateBucket.allCases, id: \.self) { b in
                        if let bucketItems = groups[b], !bucketItems.isEmpty {
                            sectionHeader(b.rawValue)
                            ForEach(bucketItems) { row($0) }
                        }
                    }
                } else {
                    sectionHeader("未分组")
                    ForEach(items) { row($0) }
                }
            }
        }
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
                            .font(.system(size: Self.rowIconSize))
                        Text("已归档")
                            .font(Self.sectionTitle)
                        Text("\(model.archivedConversations.count)")
                            .font(.system(size: 9.5).monospacedDigit())
                    }
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: Theme.Layout.rowHeight)
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
                            .font(.system(size: Self.rowIconSize))
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
                    .frame(height: Theme.Layout.rowHeight)
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
                    .font(.system(size: Self.rowIconSize))
                    .foregroundStyle(Color.ompTextSecondary)
                Text(project.name)
                    .font(Theme.Typography.sidebarTitle)
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.ompTextTertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.Layout.rowHeight)
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
            .padding(.bottom, 4)
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: search.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(Color.ompTextTertiary)
            Text(search.isEmpty ? "还没有对话" : "没有匹配的对话")
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

    // MARK: Footer: usage alert + settings + context + model pill

    private var footer: some View {
        VStack(spacing: 0) {
            usageAlert
            HStack(spacing: 6) {
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: Self.rowIconSize))
                        .foregroundStyle(Color.ompTextTertiary)
                        .frame(width: 28, height: 28)
                        .background(hoverSettings ? ghostHover : Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hoverSettings = $0 }
                .help("偏好设置 (⌘,)")

                Spacer(minLength: 0)
                modelPill
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func contextBadge(used: Int, limit: Int) -> some View {
        let ratio = min(1, Double(used) / Double(max(1, limit)))
        Button {
            showContextPopover.toggle()
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
        .popover(isPresented: $showContextPopover) {
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

    /// Sidebar usage alert strip (official `sidebarElectron.usageAlert`):
    /// progress bar + window remaining, shown once context passes 85%.
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

    private var modelPill: some View {
        Group {
            if model.availableModels.count > 12 {
                Button {
                    showModelPicker = true
                } label: {
                    modelPillLabel
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    if model.availableModels.isEmpty {
                        Text("先在设置中同步模型")
                    } else {
                        ForEach(model.availableModels) { descriptor in
                            Button {
                                model.setModel(descriptor)
                            } label: {
                                let tag = [
                                    descriptor.capabilities.thinking ? "🧠 思考" : nil,
                                    descriptor.capabilities.vision ? "👁 视觉" : nil,
                                    descriptor.limits.contextWindow.map { TokenFormat.compact($0) }
                                ].compactMap { $0 }.joined(separator: " · ")
                                let suffix = tag.isEmpty ? "" : " (\(tag))"
                                if descriptor.id == model.activeModel?.id {
                                    Label(descriptor.displayName + suffix, systemImage: "checkmark")
                                } else {
                                    Text(descriptor.displayName + suffix)
                                }
                            }
                        }
                    }
                } label: {
                    modelPillLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .fixedSize()
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet()
                .environment(model)
        }
    }

    private var modelPillLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: model.activeModel?.capabilities.thinking == true ? "sparkles" : "cpu")
                .font(.system(size: 9.5))
                .foregroundStyle(model.activeModel?.capabilities.thinking == true ? Color.purple : Color.ompTextSecondary)
            Text(model.activeModel?.displayName ?? "选择模型")
                .font(Theme.Typography.pill)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(Color.ompTextSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.ompFill, in: Capsule())
    }
}

// MARK: - Conversation row

/// Single-line sidebar conversation row: 36pt tall, selected = ompFill +
/// officialMD radius, trailing `···` revealed on hover only.
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
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
            Text(title)
                .font(Theme.Typography.sidebarTitle)
                .foregroundStyle(Color.ompText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isStreamingThis {
                ProgressView()
                    .controlSize(.mini)
            } else if hasUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
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
        .frame(height: Theme.Layout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous)
                .fill(isSelected ? Color.ompFill : (hovering ? hoverColor : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
    }

    /// ghost-hover equivalent: light #0000000d, dark #ffffff1a.
    private var hoverColor: Color {
        Color.ompDynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)
    }
}
