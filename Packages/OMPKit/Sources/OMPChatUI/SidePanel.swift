#if os(macOS)
import SwiftUI
import OMPCore
import OMPDesign

/// Right-hand panel with 终端 / 文件 / 改动 tabs (official `thread.sidePanel.*`).
/// Everything here is the real working tree: the terminal runs zsh, the file
/// list is the directory the terminal is in, and 改动 is `git status
/// --porcelain`. Nothing is invented when git is missing — the tab says so.
struct SidePanel: View {
    /// Display names for [`SidePanelTab`]; the stored value lives in the model
    /// so debug actions can drive it.
    private static let titles: [SidePanelTab: String] = [
        .terminal: "终端", .files: "文件", .changes: "改动", .browser: "浏览器"
    ]

    @Environment(ChatAppModel.self) private var model
    @State private var directory = FileManager.default.currentDirectoryPath
    @State private var entries: [Entry] = []
    @State private var changes: [Change] = []
    @State private var state: LoadState = .idle
    @State private var openFile: OpenFile?
    @State private var diff: Diff?
    @State private var picking = false
    @State private var saveFailure: String?

    private var tab: Tab {
        get { Tab(model.sidePanelTab) ?? .terminal }
    }

    private struct Entry: Identifiable {
        var name: String
        var isDirectory: Bool
        var id: String { name }
    }

    private struct Change: Identifiable {
        var code: String
        var path: String
        var id: String { code + path }
    }

    private enum LoadState: Equatable {
        case idle, loading, notARepo, gitMissing
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            switch tab {
            case .terminal:
                TerminalView(startingDirectory: followDirectory)
            case .files:
                fileList
            case .changes:
                changeList
            case .browser:
                BrowserPane()
            }
        }
        .background(Color.ompCanvas)
        .task(id: tab) { if tab != .terminal { await refresh() } }
        // A thread bound to a repository points the panel at it; switching
        // threads re-points it. The terminal keeps its own cwd once running.
        .onChange(of: model.selectedConversationID) { _, _ in followThread() }
        .onChange(of: model.selectedConversation?.workingDirectory) { _, _ in followThread() }
        .task { followThread() }
        // The panel starts in the app's own directory, which is usually not a
        // repository; this lets it point at one.
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            directory = url.path
            Task {
                await refresh()
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    /// The directory this thread wants the panel to work in (its bound
    /// repository, or whatever the panel already shows).
    private var followDirectory: String {
        SidePanelDirectory.resolve(
            threadDirectory: model.selectedConversation?.workingDirectory,
            current: directory
        )
    }

    /// Applies [`followDirectory`], refreshing the listing when it moves.
    private func followThread() {
        let target = followDirectory
        guard target != directory else { return }
        directory = target
        openFile = nil
        diff = nil
        Task { await refresh() }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { item in
                Button {
                    model.sidePanelTab = item.wire
                } label: {
                    Text(Self.titles[item.wire] ?? item.wire.rawValue)
                        .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? Color.ompText : Color.ompTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            if tab == item {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.ompFill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            // Text label rather than a lone glyph: an 11pt icon is a tiny
            // hit target, and this is the only way to point the panel at a
            // repository other than the app's own directory.
            Button {
                picking = true
            } label: {
                Label("选择文件夹", systemImage: "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            .buttonStyle(.plain)
            .help("选择文件夹")
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            .buttonStyle(.plain)
            .help("刷新")
            .padding(.trailing, 10)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Button {
                        goUp()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(directory == "/" ? Color.ompTextTertiary : Color.ompTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(directory == "/")
                    .help("上一级")
                    Text(GitInfo.tildified(directory))
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                if let saveFailure {
                    Text(saveFailure)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompFlat(rgb: 0xDE4A43))
                        .padding(.horizontal, 12)
                }
                if let openFile {
                    openedFile(openFile)
                } else if entries.isEmpty, state != .loading {
                    Text("这个目录是空的")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextTertiary)
                        .padding(12)
                }
                ForEach(entries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .font(.system(size: 10))
                                .foregroundStyle(entry.isDirectory ? Color.ompText : Color.ompTextTertiary)
                                .frame(width: 14)
                            Text(entry.name)
                                .font(.system(size: 12))
                                .foregroundStyle(openFile?.url.lastPathComponent == entry.name
                                                 ? Color.ompText : Color.ompTextSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// A file opened from the list: its text, read here rather than over the
    /// phone's channel because this is the Mac itself. `original` is what is on
    /// disk, so the save button appears only after a real edit.
    private struct OpenFile {
        var url: URL
        var text: String
        var original: String
        var truncated: Bool
        var binary: Bool = false
    }

    private func openedFile(_ file: OpenFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(file.url.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold).monospaced())
                    .foregroundStyle(Color.ompText)
                if file.truncated {
                    Text("仅前 256 KB")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.ompTextTertiary)
                }
                Spacer()
                // Always offered for an editable file, disabled until it
                // changes: a button that appears only after an edit depends on
                // the render snapshot being fresh, and it was not appearing.
                if !file.binary, !file.truncated {
                    Button {
                        // Commit IME composition first, then save what the field
                        // finally holds: clicking while a word was mid-composition
                        // wrote "EDITED IN THE" and dropped "PANEL".
                        GenUIButton.endTextEditing()
                        Task { @MainActor in
                            // The composition is committed into SwiftUI's
                            // binding on a later run-loop turn; one yield was not
                            // enough and the last word was written truncated.
                            try? await Task.sleep(for: .milliseconds(150))
                            if let current = openFile { save(current) }
                        }
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.ompText)
                    }
                    .buttonStyle(.plain)
                    .disabled(file.text == file.original)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("写回磁盘 (⌘S)")
                    .accessibilityIdentifier("panel.file.save")
                }
                Button {
                    openFile = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.ompTextSecondary)
                }
                .buttonStyle(.plain)
                .help("收起")
            }
            if file.binary {
                Text(file.text)
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Editable, like the phone's file viewer: a truncated file stays
                // read-only so saving cannot drop the part that was not loaded.
                TextEditor(text: Binding(
                    get: { file.text },
                    set: { openFile?.text = $0 }
                ))
                .font(.system(size: 10.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 320)
                .disabled(file.truncated)
                .accessibilityIdentifier("panel.file.editor")
            }
        }
        .padding(10)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
    }

    private func open(_ entry: Entry) {
        let path = directory == "/" ? "/\(entry.name)" : "\(directory)/\(entry.name)"
        if entry.isDirectory {
            openFile = nil
            directory = path
            Task { await refresh() }
            return
        }
        let cap = 256 * 1024
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: cap + 1)) ?? Data()
        let truncated = data.count > cap
        let body = data.prefix(cap)
        // Binary files would render as noise; say so instead of showing it.
        if body.contains(0) {
            openFile = OpenFile(
                url: URL(fileURLWithPath: path), text: "二进制文件，不显示内容。",
                original: "", truncated: false, binary: true
            )
            return
        }
        let text = String(decoding: body, as: UTF8.self)
        openFile = OpenFile(
            url: URL(fileURLWithPath: path), text: text, original: text, truncated: truncated
        )
    }

    /// Writes the edited text back to the same file. Errors are shown in the
    /// panel rather than swallowed.
    private func save(_ file: OpenFile) {
        do {
            try FileEdit.write(file.text, to: file.url, truncated: file.truncated)
            openFile?.original = file.text
            saveFailure = nil
        } catch FileEdit.Failure.truncated {
            saveFailure = "这个文件只加载了前 256 KB，不能保存，否则后半部分会丢失"
        } catch {
            saveFailure = "保存失败：\(error)"
        }
    }

    private func goUp() {
        guard directory != "/" else { return }
        openFile = nil
        directory = (directory as NSString).deletingLastPathComponent
        if directory.isEmpty { directory = "/" }
        Task { await refresh() }
    }

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                switch state {
                case .gitMissing:
                    Text("这台 Mac 上没有可用的 git，改动列表不可用。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextSecondary)
                        .padding(12)
                case .notARepo:
                    Text("当前目录不在 git 仓库里。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextSecondary)
                        .padding(12)
                default:
                    if changes.isEmpty, state != .loading {
                        Text("没有未提交的改动。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompTextTertiary)
                            .padding(12)
                    }
                    ForEach(changes) { change in
                        Button {
                            showDiff(change)
                        } label: {
                            HStack(spacing: 8) {
                                Text(change.code)
                                    .font(.system(size: 10, weight: .semibold).monospaced())
                                    .foregroundStyle(color(for: change.code))
                                Text(change.path)
                                    .font(.system(size: 12).monospaced())
                                    .foregroundStyle(diff?.path == change.path ? Color.ompText : Color.ompTextSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let diff {
                        diffView(diff)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Unified diff of one changed path, or the file's text when git has no
    /// diff for it (a new, untracked file).
    private struct Diff {
        var path: String
        var lines: [Line]
        struct Line: Identifiable {
            var text: String
            var kind: Kind
            var id: String { text + "\(kind)" }
        }
        enum Kind { case context, added, removed, note }
    }

    private func showDiff(_ change: Change) {
        if diff?.path == change.path { diff = nil; return }
        let dir = directory
        let path = change.path
        let untracked = change.code.contains("?")
        let body = Task.detached(priority: .userInitiated) {
            SidePanel.readDiff(directory: dir, path: path, untracked: untracked)
        }
        diff = Diff(path: path, lines: [.init(text: "读取中…", kind: .note)])
        Task {
            let lines = await body.value
            diff = Diff(path: path, lines: lines)
        }
    }

    private static func readDiff(directory: String, path: String, untracked: Bool) -> [Diff.Line] {
        let full = directory == "/" ? "/\(path)" : "\(directory)/\(path)"
        if untracked {
            guard let text = try? String(contentsOf: URL(fileURLWithPath: full), encoding: .utf8) else {
                return [.init(text: "无法读取这个文件", kind: .note)]
            }
            return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200).map {
                .init(text: String($0), kind: .added)
            }
        }
        guard let git = GitBinary.resolve() else {
            return [.init(text: "没有可用的 git", kind: .note)]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["diff", "--no-color", "--", path]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [.init(text: "git 启动失败", kind: .note)] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.init(text: "git 没有这个文件的可显示差异（可能只是权限或重命名）", kind: .note)]
        }
        var lines: [Diff.Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400) {
            let line = String(raw)
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                lines.append(.init(text: line, kind: .note))
            } else if line.hasPrefix("+") {
                lines.append(.init(text: line, kind: .added))
            } else if line.hasPrefix("-") {
                lines.append(.init(text: line, kind: .removed))
            } else if line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                lines.append(.init(text: line, kind: .note))
            } else {
                lines.append(.init(text: line, kind: .context))
            }
        }
        return lines
    }

    private func diffView(_ diff: Diff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.lines) { line in
                Text(line.text.isEmpty ? " " : line.text)
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
        .textSelection(.enabled)
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

    private func color(for code: String) -> Color {
        if code.contains("D") { return Color.ompFlat(rgb: 0xDE4A43) }
        if code.contains("A") || code.contains("?") { return Color.ompFlat(rgb: 0x2F9E5E) }
        return Color.ompFlat(rgb: 0xC98A1B)
    }

    private func refresh() async {
        state = .loading
        let dir = directory
        let (listing, git) = await Task.detached(priority: .userInitiated) {
            (Self.list(dir), Self.gitStatus(dir))
        }.value
        entries = listing
        switch git {
        case .success(let items): changes = items; state = .idle
        case .notARepo: changes = []; state = .notARepo
        case .gitMissing: changes = []; state = .gitMissing
        }
    }

    private static func list(_ directory: String) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .filter { !$0.hasPrefix(".git") }
            .sorted { lhs, rhs in
                let leftIsDir = isDirectory(directory, lhs)
                let rightIsDir = isDirectory(directory, rhs)
                if leftIsDir != rightIsDir { return leftIsDir }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { Entry(name: $0, isDirectory: isDirectory(directory, $0)) }
    }

    private static func isDirectory(_ base: String, _ name: String) -> Bool {
        var isDir: ObjCBool = false
        let path = base == "/" ? "/\(name)" : "\(base)/\(name)"
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private enum GitResult {
        case success([Change])
        case notARepo
        case gitMissing
    }

    private static func gitStatus(_ directory: String) -> GitResult {
        guard let git = GitBinary.resolve() else { return .gitMissing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        // -z: paths with spaces or Chinese characters are quoted/escaped in
        // plain porcelain output, and those strings cannot be diffed.
        process.arguments = GitStatus.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .gitMissing }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { return .notARepo }
        let entries = GitStatus.parse(String(decoding: data, as: UTF8.self))
        return .success(entries.map { Change(code: $0.code, path: $0.path) })
    }
}

extension SidePanel {
    /// Bridges the wire enum to the local case list.
    enum Tab: CaseIterable, Identifiable {
        case terminal, files, changes, browser
        var id: Self { self }

        init?(_ wire: SidePanelTab) {
            switch wire {
            case .terminal: self = .terminal
            case .files: self = .files
            case .changes: self = .changes
            case .browser: self = .browser
            }
        }

        var wire: SidePanelTab {
            switch self {
            case .terminal: .terminal
            case .files: .files
            case .changes: .changes
            case .browser: .browser
            }
        }
    }
}
#endif
