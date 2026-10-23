import SwiftUI
import OMPCore
import OMPDesign

public struct ConversationSidebar: View {
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
    @State private var showArchived = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            list
            Divider().opacity(0.6)
            footer
        }
        .background(sidebarBackground)
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
        .alert("重命名项目", isPresented: Binding(
            get: { renamingProjectID != nil },
            set: { if !$0 { renamingProjectID = nil } }
        )) {
            TextField("项目名称", text: $newProjectName)
            Button("取消", role: .cancel) { renamingProjectID = nil }
            Button("保存") {
                if let id = renamingProjectID { model.renameProject(id, name: newProjectName) }
                renamingProjectID = nil
            }
        }
    }

    private var sidebarBackground: some ShapeStyle {
        #if os(macOS)
        return AnyShapeStyle(.regularMaterial)
        #else
        return AnyShapeStyle(Color.ompFill)
        #endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            OMPMark(size: 20)
            Text("OMP Chat")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ompText)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.ompTextTertiary)
            Spacer()
            Button {
                newProjectName = ""
                creatingProject = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 26, height: 26)
                    .background(Color.ompHover, in: Circle())
            }
            .buttonStyle(.plain)
            .help("新建项目")
            Button {
                _ = model.newTemporaryConversation()
            } label: {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 26, height: 26)
                    .background(Color.ompHover, in: Circle())
            }
            .buttonStyle(.plain)
            .help("临时对话（不保存）")
            Button {
                model.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 26, height: 26)
                    .background(Color.ompHover, in: Circle())
            }
            .buttonStyle(.plain)
            .help("新建对话 (⌘N)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.ompTextTertiary)
            TextField("搜索对话", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.ompTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if searching {
                    ForEach(filtered) { row($0) }
                    if filtered.isEmpty { emptyHint }
                } else {
                    projectSections
                    ungroupedSection
                    lockedSection
                    archivedSection
                    if model.conversations.isEmpty { emptyHint }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
    }

    private var searching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var projectSections: some View {
        ForEach(model.orderedProjects) { project in
            projectHeader(project)
            if !collapsedProjects.contains(project.id) {
                ForEach(model.conversations(in: project.id)) { row($0) }
            }
        }
    }

    private var ungroupedSection: some View {
        let items = model.conversations(in: nil)
        return Group {
            if !items.isEmpty {
                sectionHeader(model.projects.isEmpty ? "最近" : "未分组")
                ForEach(items) { row($0) }
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
                            .font(.system(size: 9))
                        Text("已归档")
                            .font(Theme.Typography.sectionHeader)
                        Text("\(model.archivedConversations.count)")
                            .font(.system(size: 9.5).monospacedDigit())
                    }
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
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
                    showLocked.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showLocked ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                        Text("已锁定")
                            .font(Theme.Typography.sectionHeader)
                        Text("\(model.lockedConversations.count)")
                            .font(.system(size: 9.5).monospacedDigit())
                    }
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                if showLocked {
                    ForEach(model.lockedConversations) { row($0) }
                }
            }
        }
    }

    private func projectHeader(_ project: Project) -> some View {
        let collapsed = collapsedProjects.contains(project.id)
        return HStack(spacing: 4) {
            Button {
                if collapsed { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(Color.ompTextSecondary)
            Text(project.name)
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(Color.ompTextSecondary)
                .lineLimit(1)
            Spacer()
            Button {
                _ = model.newConversation(in: project.id)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("在项目中新建对话")
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contextMenu {
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
            .font(Theme.Typography.sectionHeader)
            .tracking(0.4)
            .foregroundStyle(Color.ompTextTertiary)
            .padding(.horizontal, 8)
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

    private func row(_ conversation: Conversation) -> some View {
        ConversationRow(
            conversation: conversation,
            isSelected: model.selectedConversationID == conversation.id
        )
        .onTapGesture {
            model.selectedConversationID = conversation.id
        }
        .contextMenu { menu(for: conversation) }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                model.showSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11.5))
                    Text("设置")
                        .font(.system(size: 12.5))
                    Spacer()
                    if let provider = model.activeProvider {
                        Text(provider.name)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.ompTextTertiary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(Color.ompTextSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let descriptor = model.activeModel {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: 5, height: 5)
                    Text(descriptor.displayName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                    Spacer()
                    if let conversation = model.selectedConversation,
                       let usage = model.contextUsage(conversation) {
                        Text("\(TokenFormat.compact(usage.used))/\(TokenFormat.compact(usage.limit))")
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }

    private var filtered: [Conversation] {
        let sorted = model.sortedConversations
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.lastMessagePreview.localizedCaseInsensitiveContains(query)
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
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                    Text(conversation.title)
                        .font(Theme.Typography.sidebarTitle)
                        .foregroundStyle(Color.ompText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.relativeTime(conversation.updatedAt))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(Color.ompTextTertiary)
                }
                Text(conversation.lastMessagePreview)
                    .font(Theme.Typography.sidebarPreview)
                    .foregroundStyle(Color.ompTextSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous)
                .fill(isSelected ? Color.ompSelection : (hovering ? Color.ompHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
}
