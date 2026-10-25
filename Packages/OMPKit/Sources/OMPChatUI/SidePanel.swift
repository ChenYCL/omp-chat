#if os(macOS)
import SwiftUI
import OMPCore
import OMPDesign

/// Right-hand panel with 终端 / 文件 / 改动 tabs (official `thread.sidePanel.*`).
/// Everything here is the real working tree: the terminal runs zsh, the file
/// list is the directory the terminal is in, and 改动 is `git status
/// --porcelain`. Nothing is invented when git is missing — the tab says so.
struct SidePanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case terminal = "终端"
        case files = "文件"
        case changes = "改动"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .terminal
    @State private var directory = FileManager.default.currentDirectoryPath
    @State private var entries: [Entry] = []
    @State private var changes: [Change] = []
    @State private var state: LoadState = .idle
    @State private var picking = false

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
                TerminalView()
            case .files:
                fileList
            case .changes:
                changeList
            }
        }
        .background(Color.ompCanvas)
        .task(id: tab) { if tab != .terminal { await refresh() } }
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

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
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
                Text(GitInfo.tildified(directory))
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                if entries.isEmpty, state != .loading {
                    Text("这个目录是空的")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextTertiary)
                        .padding(12)
                }
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .font(.system(size: 10))
                            .foregroundStyle(entry.isDirectory ? Color.ompText : Color.ompTextTertiary)
                            .frame(width: 14)
                        Text(entry.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                }
            }
            .padding(.vertical, 4)
        }
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
                        HStack(spacing: 8) {
                            Text(change.code)
                                .font(.system(size: 10, weight: .semibold).monospaced())
                                .foregroundStyle(color(for: change.code))
                            Text(change.path)
                                .font(.system(size: 12).monospaced())
                                .foregroundStyle(Color.ompText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                    }
                }
            }
            .padding(.vertical, 4)
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
        // `/usr/bin/git` goes through xcrun on this Mac; Homebrew's git works
        // from a sandboxed app. Try both before giving up.
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        guard let git = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .gitMissing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["status", "--porcelain"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .gitMissing }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { return .notARepo }
        let text = String(decoding: data, as: UTF8.self)
        var items: [Change] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard line.count > 3 else { continue }
            let code = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            let path = String(line.dropFirst(3))
            items.append(Change(code: code.isEmpty ? "?" : code, path: path))
        }
        return .success(items)
    }
}
#endif
