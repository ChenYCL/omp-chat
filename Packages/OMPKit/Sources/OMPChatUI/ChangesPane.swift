#if os(macOS)
import AppKit
import SwiftUI
import OMPCore
import OMPDesign

/// The side panel's 改动 tab, Codex's changes panel against the real working
/// tree: 已暂存 / 未暂存 split by git's XY columns, each row's diff for its own
/// side, stage / unstage / discard, then commit and push. Every git write goes
/// through `ChatAppModel.changeWorkingTree`, whose revision bump re-reads
/// status here — also when a debug action made the write.
struct ChangesPane: View {
    /// Where git runs; anywhere inside the checkout.
    let directory: String
    /// Bumped by the panel's refresh button.
    let reload: Int

    @Environment(ChatAppModel.self) private var model
    @State private var phase: Phase = .loading
    @State private var status = GitWorkingTree.Status(staged: [], unstaged: [])
    @State private var root: String?
    @State private var branch: GitWorkingTree.BranchInfo?
    @State private var branchError: String?
    @State private var diff: Diff?
    @State private var message = ""
    @State private var busy = false
    @State private var outcome: Outcome?
    @State private var pendingDiscard: GitWorkingTree.Change?

    private enum Phase: Equatable {
        case loading, ready, notARepo, gitMissing
        case failed(String)
    }

    private enum Outcome: Equatable {
        case success(String)
        case failure(String)
    }

    private struct ReloadKey: Hashable {
        var directory: String
        var revision: Int
        var reload: Int
    }

    private enum Loaded: Sendable {
        case ready(GitWorkingTree.Status, root: String, branch: Result<GitWorkingTree.BranchInfo, GitWorkingTree.Failure>)
        case failed(GitWorkingTree.Failure)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .gitMissing:
                note("这台 Mac 上没有可用的 git，改动列表不可用。")
            case .notARepo:
                note("当前目录不在 git 仓库里。")
            case .failed(let text):
                note(text)
            case .loading, .ready:
                header
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        groups
                    }
                    .padding(.vertical, 4)
                }
                Divider()
                commitBar
            }
        }
        .task(id: ReloadKey(directory: directory, revision: model.workingTreeRevision, reload: reload)) {
            await load()
        }
        // Another directory is another repository: nothing of the last one stays.
        .onChange(of: directory) { _, _ in
            phase = .loading
            status = .init(staged: [], unstaged: [])
            branch = nil
            branchError = nil
            diff = nil
            outcome = nil
        }
        .confirmationDialog(
            pendingDiscard.map { "丢弃“\(label($0))”的改动？" } ?? "",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDiscard
        ) { change in
            Button("丢弃改动", role: .destructive) { discard(change) }
                .accessibilityIdentifier("changes.discard.confirm")
            Button("取消", role: .cancel) {}
        } message: { change in
            Text(change.isUntracked
                 ? "这个未跟踪的文件会被删除，无法撤销。"
                 : "暂存和未暂存的改动都会还原到最近一次提交，无法撤销。")
        }
    }

    private func note(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(Color.ompTextTertiary)
            if let branch {
                Text(verbatim: branch.detached ? "分离于 \(branch.name)" : branch.name)
                    .font(.system(size: 11.5, weight: .semibold).monospaced())
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let upstream = branch.upstream {
                    Text(verbatim: "↑\(branch.ahead) ↓\(branch.behind)")
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(Color.ompTextSecondary)
                        .help("比 \(upstream) 多 \(branch.ahead) 个提交，少 \(branch.behind) 个")
                    Text(verbatim: upstream)
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if let branchError {
                Text(verbatim: branchError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ompTextTertiary)
                    .lineLimit(1)
                    .help(branchError)
            }
            Spacer(minLength: 0)
            if busy || phase == .loading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("changes.branch")
    }

    // MARK: Groups

    @ViewBuilder
    private var groups: some View {
        if status.staged.isEmpty, status.unstaged.isEmpty {
            Text(phase == .loading ? "读取中…" : "没有未提交的改动。")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextTertiary)
                .padding(12)
        }
        if !status.staged.isEmpty {
            groupHeader(
                "已暂存", count: status.staged.count,
                action: "全部取消暂存", identifier: "changes.unstageAll"
            ) {
                let dir = directory
                Task { await perform { try GitWorkingTree.unstageAll(in: dir); return nil } }
            }
            ForEach(status.staged) { row($0) }
        }
        if !status.unstaged.isEmpty {
            groupHeader(
                "未暂存", count: status.unstaged.count,
                action: "全部暂存", identifier: "changes.stageAll"
            ) {
                let dir = directory
                Task { await perform { try GitWorkingTree.stageAll(in: dir); return nil } }
            }
            ForEach(status.unstaged) { row($0) }
        }
    }

    private func groupHeader(
        _ title: String, count: Int, action: String, identifier: String,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ompTextSecondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ompTextTertiary)
                .padding(.horizontal, 5)
                .background(Color.ompFill, in: Capsule())
            Spacer(minLength: 0)
            Button(action: perform) {
                Text(action)
                    .font(.system(size: 10.5))
                    .foregroundStyle(busy ? Color.ompTextTertiary : Color.ompTextSecondary)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(_ change: GitWorkingTree.Change) -> some View {
        let side = change.staged ? "staged" : "unstaged"
        let open = diff?.id == change.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Toggle("", isOn: Binding(
                    get: { change.staged },
                    set: { stage in toggleStaged(change, to: stage) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .disabled(busy)
                .help(change.staged ? "取消暂存" : "暂存")
                .accessibilityIdentifier("changes.toggle.\(side).\(change.path)")
                Button {
                    toggleDiff(change)
                } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: change.code)
                            .font(.system(size: 10, weight: .semibold).monospaced())
                            .foregroundStyle(color(for: change.code))
                            .frame(minWidth: 16, alignment: .leading)
                        Text(verbatim: label(change))
                            .font(.system(size: 12).monospaced())
                            .foregroundStyle(open ? Color.ompText : Color.ompTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(label(change))
                .accessibilityIdentifier("changes.row.\(side).\(change.path)")
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .contextMenu { menu(change) }
            if open, let diff {
                diffView(diff)
            }
        }
    }

    @ViewBuilder
    private func menu(_ change: GitWorkingTree.Change) -> some View {
        if change.staged {
            Button("取消暂存") { toggleStaged(change, to: false) }
        } else {
            Button("暂存") { toggleStaged(change, to: true) }
        }
        Button("丢弃改动…", role: .destructive) { pendingDiscard = change }
        Divider()
        Button("在访达中显示") { reveal(change) }
            .disabled(fileURL(change).map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
    }

    /// The path as git reports it; a rename shows where it came from.
    private func label(_ change: GitWorkingTree.Change) -> String {
        guard let original = change.originalPath else { return change.path }
        return "\(original) → \(change.path)"
    }

    private func color(for code: String) -> Color {
        if code.contains("D") || code.contains("U") { return Color.ompFlat(rgb: 0xDE4A43) }
        if code.contains("A") || code.contains("?") { return Color.ompFlat(rgb: 0x2F9E5E) }
        return Color.ompFlat(rgb: 0xC98A1B)
    }

    // MARK: Commit and push

    private var canCommit: Bool {
        !busy && !status.staged.isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commitBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("提交信息", text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .padding(8)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier("changes.commitMessage")
            HStack(spacing: 8) {
                Button(action: commit) {
                    Text("提交")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ompInverseText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Color.ompPrimarySolid, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .opacity(canCommit ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .keyboardShortcut(.return, modifiers: .command)
                .help("提交已暂存的改动 (⌘↩)")
                .accessibilityIdentifier("changes.commit")
                if let branch, let upstream = branch.upstream, branch.ahead > 0 {
                    Button(action: push) {
                        Label("推送 ↑\(branch.ahead)", systemImage: "arrow.up")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .opacity(busy ? 0.35 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .help("推送到 \(upstream)")
                    .accessibilityIdentifier("changes.push")
                }
                Spacer(minLength: 0)
                // Official codeReview.menu.review: a read-only thread reviews
                // everything listed here.
                Button(action: review) {
                    Label("用 Codex 审查", systemImage: "checklist")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .opacity(canReview ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!canReview)
                .help("在新对话里只读审查这些改动")
                .accessibilityIdentifier("changes.review")
            }
            if let outcome {
                switch outcome {
                case .success(let text):
                    Text(verbatim: text)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Color.ompFlat(rgb: 0x2F9E5E))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("changes.result")
                case .failure(let text):
                    // git's own words in full: "Please tell me who you are" is
                    // only useful with the commands printed under it.
                    Text(verbatim: text)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Color.ompFlat(rgb: 0xDE4A43))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("changes.result")
                }
            }
        }
        .padding(10)
    }

    // MARK: Actions

    private func load() async {
        let dir = directory
        let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded in
            do {
                let root = try GitWorkingTree.repositoryRoot(of: dir)
                let status = try GitWorkingTree.status(in: dir)
                let branch: Result<GitWorkingTree.BranchInfo, GitWorkingTree.Failure>
                do {
                    branch = .success(try GitWorkingTree.branchInfo(in: dir))
                } catch {
                    branch = .failure(error as? GitWorkingTree.Failure ?? .git(error.localizedDescription))
                }
                return .ready(status, root: root, branch: branch)
            } catch {
                return .failed(error as? GitWorkingTree.Failure ?? .git(error.localizedDescription))
            }
        }.value
        guard !Task.isCancelled else { return }
        switch loaded {
        case .ready(let status, let root, let branch):
            self.status = status
            self.root = root
            switch branch {
            case .success(let info): self.branch = info; branchError = nil
            case .failure(let failure): self.branch = nil; branchError = failure.message
            }
            phase = .ready
            refreshOpenDiff()
        case .failed(let failure):
            status = .init(staged: [], unstaged: [])
            branch = nil
            diff = nil
            switch failure {
            case .gitMissing, .unsupported: phase = .gitMissing
            case .notARepository: phase = .notARepo
            default: phase = .failed(failure.message)
            }
        }
    }

    /// Runs one git write through the model, which re-reads status after it,
    /// and shows git's answer under the commit button.
    @discardableResult
    private func perform(_ operation: @escaping @Sendable () throws -> String?) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let text = try await model.changeWorkingTree(operation)
            outcome = text.map(Outcome.success)
            return true
        } catch {
            outcome = .failure(error.localizedDescription)
            return false
        }
    }

    private func toggleStaged(_ change: GitWorkingTree.Change, to stage: Bool) {
        guard stage != change.staged, !busy else { return }
        let dir = directory
        let paths = change.paths
        Task {
            await perform {
                if stage {
                    try GitWorkingTree.stage(paths, in: dir)
                } else {
                    try GitWorkingTree.unstage(paths, in: dir)
                }
                return nil
            }
        }
    }

    private func discard(_ change: GitWorkingTree.Change) {
        pendingDiscard = nil
        let dir = directory
        let paths = change.paths
        Task {
            await perform {
                for path in paths {
                    try GitWorkingTree.discard(path, in: dir)
                }
                return nil
            }
        }
    }

    private func commit() {
        // Commit any IME composition first; SwiftUI copies it into `message`
        // on a later run-loop turn, so read the field only after that.
        GenUIButton.endTextEditing()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard canCommit else { return }
            let dir = directory
            let text = message
            let committed = await perform {
                let hash = try GitWorkingTree.commit(message: text, in: dir)
                return "已提交 \(hash)"
            }
            if committed { message = "" }
        }
    }

    private func push() {
        guard !busy else { return }
        let dir = directory
        Task {
            await perform { "已推送到 \(try GitWorkingTree.push(in: dir))" }
        }
    }

    /// Something to review, and no git write or reply in the way.
    private var canReview: Bool {
        !busy && !status.isClean && !model.isStreaming && model.selectedConversationID != nil
    }

    /// Starts a read-only review thread over this checkout's changes; why it
    /// could not start shows under the buttons.
    private func review() {
        guard canReview, let id = model.selectedConversationID else { return }
        let dir = directory
        busy = true
        outcome = nil
        Task {
            defer { busy = false }
            if let failure = await model.startCodeReview(for: id, directory: dir) {
                outcome = .failure(failure)
            }
        }
    }

    private func fileURL(_ change: GitWorkingTree.Change) -> URL? {
        guard let root else { return nil }
        return URL(fileURLWithPath: (root as NSString).appendingPathComponent(change.path))
    }

    private func reveal(_ change: GitWorkingTree.Change) {
        guard let url = fileURL(change) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Diff

    /// The open row's diff: the staged one for a 已暂存 row, the working
    /// tree's for a 未暂存 row.
    private struct Diff {
        var id: String
        var lines: [Line]
        struct Line {
            var text: String
            var kind: Kind
        }
        enum Kind { case context, added, removed, note }
    }

    nonisolated private static let diffLineCap = 400

    private func toggleDiff(_ change: GitWorkingTree.Change) {
        if diff?.id == change.id {
            diff = nil
            return
        }
        diff = Diff(id: change.id, lines: [.init(text: "读取中…", kind: .note)])
        readDiff(change)
    }

    /// After a refresh the open row may have moved groups or gone; otherwise
    /// its diff is read again so it matches the new state.
    private func refreshOpenDiff() {
        guard let open = diff else { return }
        let rows = status.staged + status.unstaged
        guard let change = rows.first(where: { $0.id == open.id }) else {
            diff = nil
            return
        }
        readDiff(change)
    }

    private func readDiff(_ change: GitWorkingTree.Change) {
        let dir = directory
        Task {
            let lines = await Task.detached(priority: .userInitiated) { () -> [Diff.Line] in
                do {
                    let text = try GitWorkingTree.diff(
                        change.path, originalPath: change.originalPath,
                        staged: change.staged, in: dir
                    )
                    return Self.lines(text)
                } catch {
                    return [.init(text: error.localizedDescription, kind: .note)]
                }
            }.value
            guard diff?.id == change.id else { return }
            diff = Diff(id: change.id, lines: lines)
        }
    }

    nonisolated private static func lines(_ text: String) -> [Diff.Line] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.init(text: "git 没有这个文件的可显示差异（可能只是权限或重命名）", kind: .note)]
        }
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false)
        let headers = ["diff ", "index ", "new file mode", "deleted file mode", "old mode", "new mode",
                       "similarity index", "rename from", "rename to", "Binary files"]
        var lines: [Diff.Line] = raw.prefix(diffLineCap).map { piece in
            let line = String(piece)
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@")
                || headers.contains(where: line.hasPrefix) {
                return .init(text: line, kind: .note)
            } else if line.hasPrefix("+") {
                return .init(text: line, kind: .added)
            } else if line.hasPrefix("-") {
                return .init(text: line, kind: .removed)
            }
            return .init(text: line, kind: .context)
        }
        if raw.count > diffLineCap {
            lines.append(.init(text: "… 还有 \(raw.count - diffLineCap) 行未显示", kind: .note))
        }
        return lines
    }

    private func diffView(_ diff: Diff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Offsets, not text, identify lines: a diff repeats lines like "+}".
            ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(foreground(line.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(background(line.kind))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .textSelection(.enabled)
        .accessibilityIdentifier("changes.diff")
    }

    private func foreground(_ kind: Diff.Kind) -> Color {
        switch kind {
        case .added: return Color.ompFlat(rgb: 0x2F9E5E)
        case .removed: return Color.ompFlat(rgb: 0xDE4A43)
        case .note: return Color.ompTextTertiary
        case .context: return Color.ompTextSecondary
        }
    }

    private func background(_ kind: Diff.Kind) -> Color {
        switch kind {
        case .added: return Color.ompFlat(rgb: 0x2F9E5E).opacity(0.10)
        case .removed: return Color.ompFlat(rgb: 0xDE4A43).opacity(0.10)
        default: return .clear
        }
    }
}
#endif
