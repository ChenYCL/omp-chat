#if os(macOS)
import OMPCore
import OMPDesign
import SwiftUI

/// 设置 → Worktree (official `settings.worktrees.*`): the auto-cleanup
/// switch and keep count, the fetch-before-create switch, the worktree root,
/// and the list of managed worktrees with their size, branch and chats.
/// Deletion and restore drive ChatAppModel; every row action does something
/// real, and a pinned chat blocks deletion with the official reason.
struct WorktreeSettingsPane: View {
    @Environment(ChatAppModel.self) private var model
    /// The settings window's `draft` worktree fields; its onChange saves.
    @Binding var autoCleanup: Bool
    @Binding var keepCount: Int
    @Binding var fetchUpstream: Bool
    @Binding var baseDirectory: String

    @State private var confirmingAutoCleanupOff = false
    @State private var deleting: ManagedWorktreeDetail?
    @State private var deletingReason: String?
    @State private var choosingRoot = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Worktree 让多个对话在同一仓库里互不干扰地工作。它们由应用管理：归档对话或超出数量上限时自动删除，删除前保存快照，打开对话时可以恢复。")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ompTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            card { settingsSection }
            card { worktreeList }
        }
        .accessibilityIdentifier("settings.worktree.pane")
        .task { await model.refreshWorktreeDetails() }
        .fileImporter(
            isPresented: $choosingRoot,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            baseDirectory = url.path
        }
        .confirmationDialog(
            "关闭自动删除？",
            isPresented: $confirmingAutoCleanupOff,
            titleVisibility: .visible
        ) {
            Button("关闭自动删除", role: .destructive) { autoCleanup = false }
            Button("取消", role: .cancel) { autoCleanup = true }
        } message: {
            Text("Worktree 会一直保留，磁盘占用由你自己管理；你仍可以随时在下面的列表里手动删除。")
        }
        .confirmationDialog(
            "删除「\(deleting?.path.split(separator: "/").last.map(String.init) ?? "Worktree")」？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = deleting {
                    Task {
                        if let failure = await model.deleteManagedWorktree(target.id) {
                            message = failure
                        }
                        await model.refreshWorktreeDetails()
                    }
                }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("删除前会保存快照；在对话里打开时可以恢复。")
        }
        .alert("无法删除", isPresented: Binding(get: { deletingReason != nil }, set: { if !$0 { deletingReason = nil } })) {
            Button("好", role: .cancel) { deletingReason = nil }
        } message: {
            Text(deletingReason ?? "")
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 60)
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section {
            Toggle("自动删除旧 Worktree", isOn: Binding(
                get: { autoCleanup },
                set: { newValue in
                    if newValue { autoCleanup = true } else { confirmingAutoCleanupOff = true }
                }
            ))
            .accessibilityIdentifier("settings.worktree.autoCleanup")

            if autoCleanup {
                Stepper(value: $keepCount, in: 1...50) {
                    Text("保留数量：\(keepCount)")
                        .accessibilityIdentifier("settings.worktree.keepCountValue")
                }
                .accessibilityIdentifier("settings.worktree.keepCount")
            }

            Toggle("创建前总是获取上游", isOn: $fetchUpstream)
                .accessibilityIdentifier("settings.worktree.fetchUpstream")

            HStack {
                Text("Worktree 根目录")
                Spacer()
                Text(GitInfo.tildified(model.resolvedWorktreeRoot()))
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Color.ompTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(model.resolvedWorktreeRoot())
                Button(baseDirectory.isEmpty ? "选择…" : "更改…") { choosingRoot = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.worktree.root")
                if !baseDirectory.isEmpty {
                    Button("默认") { baseDirectory = "" }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.worktree.rootReset")
                }
            }
        } footer: {
            Text("根目录为空时使用应用数据目录（OMPChat/worktrees）。归档对话、或超出保留数量时，最旧的 Worktree 会被自动删除；置顶或正在运行的对话不受影响。")
        }
    }

    // MARK: List

    @ViewBuilder
    private var worktreeList: some View {
        Section {
            if model.worktreeDetails.isEmpty {
                Text("还没有 Worktree。在对话头部选择「继续于 → 新建 Worktree」或「交接到 Worktree」时会创建。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextTertiary)
            }
            ForEach(model.worktreeDetails) { detail in
                row(detail)
            }
            HStack {
                Button {
                    Task { await model.refreshWorktreeDetails() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.worktree.refresh")
                Spacer()
                if let message {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextSecondary)
                        .lineLimit(2)
                }
            }
        } header: {
            Text("Worktree 列表")
        }
    }

    @ViewBuilder
    private func row(_ detail: ManagedWorktreeDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: detail.deleted ? "archivebox" : "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompTextTertiary)
                Text(GitInfo.tildified(detail.path))
                    .font(.system(size: 12.5).monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                if let size = detail.sizeOnDisk {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Color.ompTextTertiary)
                }
            }
            .accessibilityIdentifier("settings.worktree.row.\(detail.id)")

            HStack(spacing: 10) {
                Text(detail.branchLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ompTextSecondary)
                Text((detail.sourceRoot as NSString).lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ompTextTertiary)
                    .lineLimit(1)
                if let environment = detail.environmentPath {
                    Text("环境：\((environment as NSString).lastPathComponent)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                }
                if !detail.existsOnDisk, !detail.deleted {
                    Text("目录已不存在")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
            }

            if !detail.linkedConversationTitles.isEmpty {
                HStack(spacing: 6) {
                    ForEach(detail.linkedConversationTitles.prefix(4), id: \.self) { title in
                        Button(title) {
                            if let id = linkedConversationID(detail, title) {
                                model.selectedConversationID = id
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("在此 Worktree 新建对话") {
                    if model.newChat(inManagedWorktree: detail.id) == nil {
                        message = "这个 Worktree 已删除，不能新建对话。"
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(detail.deleted || !detail.existsOnDisk)
                .accessibilityIdentifier("settings.worktree.row.\(detail.id).newChat")

                Spacer()

                Button("删除") {
                    if let reason = model.worktreeDeletionRefusal(for: detail.id) {
                        deletingReason = reason
                    } else {
                        deleting = detail
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(detail.deleted)
                .accessibilityIdentifier("settings.worktree.row.\(detail.id).delete")
            }
        }
        .padding(.vertical, 2)
    }

    private func linkedConversationID(_ detail: ManagedWorktreeDetail, _ title: String) -> UUID? {
        let ids = model.managedWorktrees.first(where: { $0.id == detail.id })?.conversationIDs ?? []
        return model.conversations.first { ids.contains($0.id) && $0.title == title }?.id
    }
}
#endif

#if os(iOS)
import SwiftUI

/// Worktrees only exist on the Mac; the phone says so honestly.
struct WorktreeSettingsNote: View {
    var body: some View {
        Section {
            Text("Worktree 的创建、交接与删除都在 Mac 上进行。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } header: {
            Text("Worktree")
        }
        .accessibilityIdentifier("settings.worktree.iosNote")
    }
}
#endif
