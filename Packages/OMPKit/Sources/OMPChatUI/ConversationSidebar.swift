import SwiftUI
import OMPCore
import OMPDesign

public struct ConversationSidebar: View {
    @Environment(ChatAppModel.self) private var model
    @State private var search = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var deletingID: UUID?

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
                let pinned = filtered.filter(\.isPinned)
                let recent = filtered.filter { !$0.isPinned }
                if !pinned.isEmpty {
                    sectionHeader("置顶")
                    ForEach(pinned) { row($0) }
                }
                if !recent.isEmpty {
                    sectionHeader(pinned.isEmpty ? "最近" : "全部")
                    ForEach(recent) { row($0) }
                }
                if filtered.isEmpty {
                    emptyHint
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
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
            renameText = conversation.title
            renamingID = conversation.id
        } label: {
            Label("重命名", systemImage: "pencil")
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
