import SwiftUI
import OMPCore
import OMPDesign

#if os(iOS)
/// iOS host panes (文件 / 终端 / 脚本) rendered inside `IOSShell`'s 主机 tab.
/// The unified shell, drawer, chat screen and composer live in IOSShell.swift.
// MARK: - Files Pane (Frame 60s)

struct PaseoFilesPane: View {
    @Binding var directory: URL
    @State private var viewingURL: IdentifiableURL?
    @State private var bookmarks: [(icon: String, name: String, path: String)] = [
        ("folder", "根目录", "/"),
        ("house", "个人目录", NSHomeDirectory()),
        ("internaldrive", "系统卷", "/System/Volumes/Data"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Bookmark pills row: [📁 根目录] [🏠 个人目录] [💽 根目录] [+]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(bookmarks, id: \.path) { bm in
                        Button {
                            directory = URL(fileURLWithPath: bm.path)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: bm.icon)
                                    .font(.system(size: 11))
                                Text(bm.name)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(directory.path == bm.path ? Color.ompText : Color.ompTextSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().strokeBorder(Color.ompBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        let name = directory.lastPathComponent.isEmpty ? "根目录" : directory.lastPathComponent
                        if !bookmarks.contains(where: { $0.path == directory.path }) {
                            bookmarks.append(("folder.fill", name, directory.path))
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.ompText)
                            .frame(width: 28, height: 28)
                            .background(Circle().strokeBorder(Color.ompBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            // Path Header row: / on left, ≡: and Q on right
            HStack {
                Text(directory.path)
                    .font(.system(size: 13, weight: .medium).monospaced())
                    .foregroundStyle(Color.ompTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompText)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            // File / Folder rows
            List {
                ForEach(entries, id: \.path) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.isDir ? "folder.fill" : "doc")
                            .font(.system(size: 13))
                            .foregroundStyle(entry.isDir ? Color.ompText : Color.ompTextTertiary)
                            .frame(width: 20)
                        Text(entry.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ompText)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if entry.isDir {
                            directory = URL(fileURLWithPath: entry.path)
                        } else {
                            viewingURL = IdentifiableURL(url: URL(fileURLWithPath: entry.path))
                        }
                    }
                    .contextMenu {
                        if !entry.isDir {
                            Button {
                                viewingURL = IdentifiableURL(url: URL(fileURLWithPath: entry.path))
                            } label: {
                                Label("查看内容", systemImage: "eye")
                            }
                        }
                        Button {
                            #if os(macOS)
                            copyToPasteboard(entry.path)
                            #else
                            UIPasteboard.general.string = entry.path
                            #endif
                        } label: {
                            Label("复制路径", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.ompCanvas)
        }
        .sheet(item: $viewingURL) { item in
            FileViewerSheet(url: item.url)
        }
    }

    private var entries: [(name: String, path: String, isDir: Bool)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return items
            .filter { !$0.hasPrefix(".") || $0 == ".vol" }
            .sorted { lhs, rhs in
                let lDir = isDir(lhs), rDir = isDir(rhs)
                if lDir != rDir { return lDir }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { (name: $0, path: directory.appendingPathComponent($0).path, isDir: isDir($0)) }
    }

    private func isDir(_ name: String) -> Bool {
        var flag: ObjCBool = false
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &flag)
        return flag.boolValue
    }
}

// MARK: - Terminal Pane (Frame 75s)

struct PaseoTerminalPane: View {
    let directory: URL
    @State private var currentDir: URL
    @State private var lines: [String] = [
        "> ls",
        "__pycache__          infra",
        "AGENTS.md            machines",
        "aicc.egg-info        memories",
        "archive              pyproject.toml",
        "CLAUDE.bak.md        README.md",
        "CLAUDE.md            requirements-heavy.txt",
        "conftest.py          requirements.txt",
        "data                 test_aac",
        "docs                 test_aac.cpp",
        "experiments          uv.lock",
        "harness",
    ]
    @State private var input = ""
    @State private var history: [String] = ["ls"]
    @State private var historyIndex = 1
    @FocusState private var isInputFocused: Bool

    init(directory: URL) {
        self.directory = directory
        _currentDir = State(initialValue: directory)
    }
    var body: some View {
        VStack(spacing: 0) {
            // Top bookmark pills: [>_ ~/Documents/ai-command-center] + •••
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                    Text(GitInfo.tildified(directory.path))
                        .font(.system(size: 11.5, weight: .medium).monospaced())
                        .lineLimit(1)
                }
                .foregroundStyle(Color.ompText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.ompFill, in: Capsule())

                Spacer()

                Button {
                    lines.append("> 会话已就绪")
                    lines.append("> ls")
                    input = ""
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompText)
                }
                .buttonStyle(.plain)

                Menu {
                    Button("清屏 (Clear)") {
                        lines = []
                    }
                    Button("复制控制台输出") {
                        #if os(macOS)
                        copyToPasteboard(lines.joined(separator: "\n"))
                        #else
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                        #endif
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Terminal canvas: ompCanvas background, prompt-green / token-text monospace.
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(line.hasPrefix(">") ? Color.green : Color.ompText)
                            .textSelection(.enabled)
                    }

                    // Prompt row (Frame 75s): ~/Documents/c/ai-command-center main !19 ?25 > █
                    HStack(spacing: 6) {
                        Text("\(GitInfo.tildified(currentDir.path))  main  !19  ?25  >")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.blue.opacity(0.8))
                        TextField("", text: $input)
                .accessibilityIdentifier("host.terminal.input")
                .accessibilityLabel("终端命令输入")
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .focused($isInputFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit {
                                executeCommand(input)
                            }
                    }
                    .padding(.top, 4)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.ompCanvas)

            // Keyboard accessory row (Frame 75s)
            HStack(spacing: 4) {
                ForEach(["Esc", "Tab", "Ctrl", "Alt", "Shift", "↑", "↓", "←", "→", "⌨"], id: \.self) { key in
                    Button {
                        handleKey(key)
                    } label: {
                        Text(key)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.ompText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(Color.ompCard)
        }
    }

    private func executeCommand(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        lines.append("> \(cmd)")
        history.append(cmd)
        historyIndex = history.count
        input = ""

        if cmd == "clear" {
            lines = []
            return
        }
        if cmd == "pwd" {
            lines.append(currentDir.path)
            return
        }
        if cmd == "ls" {
            let fm = FileManager.default
            if let items = try? fm.contentsOfDirectory(atPath: currentDir.path) {
                let filtered = items.filter { !$0.hasPrefix(".") }.sorted()
                lines.append(filtered.joined(separator: "    "))
            } else {
                lines.append("(空目录或无权访问)")
            }
            return
        }
        if cmd.hasPrefix("cd ") {
            let target = String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if target == ".." {
                currentDir = currentDir.deletingLastPathComponent()
            } else if target.hasPrefix("/") {
                currentDir = URL(fileURLWithPath: target)
            } else {
                currentDir = currentDir.appendingPathComponent(target)
            }
            return
        }
        if cmd.hasPrefix("cat ") {
            let filename = String(cmd.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            let fileURL = currentDir.appendingPathComponent(filename)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                lines.append(String(content.prefix(500)) + (content.count > 500 ? "\n...(已截断)" : ""))
            } else {
                lines.append("cat: \(filename): 无法读取文件")
            }
            return
        }
        if cmd == "date" {
            lines.append(Date().description)
            return
        }
        if cmd == "whoami" {
            lines.append(NSUserName())
            return
        }
        if cmd.hasPrefix("echo ") {
            lines.append(String(cmd.dropFirst(5)))
            return
        }
        lines.append("zsh: command completed: \(cmd)")
    }

    private func handleKey(_ key: String) {
        switch key {
        case "Esc":
            input = ""
        case "Tab":
            let fm = FileManager.default
            if let items = try? fm.contentsOfDirectory(atPath: currentDir.path),
               let match = items.first(where: { $0.hasPrefix(input) }) {
                input = match
            }
        case "↑":
            if historyIndex > 0 {
                historyIndex -= 1
                input = history[historyIndex]
            }
        case "↓":
            if historyIndex < history.count - 1 {
                historyIndex += 1
                input = history[historyIndex]
            } else {
                historyIndex = history.count
                input = ""
            }
        case "⌨":
            isInputFocused.toggle()
        default:
            break
        }
    }

}

// MARK: - Scripts Pane (Paseo Workspace Scripts)

struct PaseoScriptsPane: View {
    let selectedHost: String
    @State private var scripts: [ScriptItem] = [
        ScriptItem(name: "dev", command: "bun run dev", desc: "启动本地开发热重载服务器", port: "3000", status: "运行中"),
        ScriptItem(name: "build", command: "swift build -c release", desc: "编译全平台生产版本二进制", port: nil, status: "就绪"),
        ScriptItem(name: "test", command: "swift test --jobs 4", desc: "运行全套自动化单元测试", port: nil, status: "通过"),
        ScriptItem(name: "sync", command: "paseo project sync", desc: "同步远程主机工作区变更", port: nil, status: "就绪"),
    ]
    @State private var outputLog: String

    init(selectedHost: String) {
        self.selectedHost = selectedHost
        _outputLog = State(initialValue: "已连接到主机 \(selectedHost)。运行环境就绪。\n> bun run dev\n[ready] Next.js dev server listening on http://localhost:3000\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("工作区脚本 (Paseo Scripts)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                Spacer()
                Text(selectedHost)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.ompFill, in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            List {
                Section("可用脚本") {
                    ForEach($scripts) { $script in
                        HStack(spacing: 12) {
                            Image(systemName: script.status == "运行中" ? "play.circle.fill" : "terminal")
                                .font(.system(size: 16))
                                .foregroundStyle(script.status == "运行中" ? Color.green : Color.ompTextSecondary)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(script.name)
                                        .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                                    Text(script.command)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Color.ompTextTertiary)
                                }
                                Text(script.desc)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.ompTextSecondary)
                            }

                            Spacer()

                            if let port = script.port {
                                Text(":\(port)")
                                    .font(.system(size: 10).monospaced())
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                            }

                            Button {
                                if script.status == "运行中" {
                                    script.status = "已停止"
                                    outputLog += "\n[stop] 脚本 \(script.name) 已停止。\n"
                                } else {
                                    script.status = "运行中"
                                    outputLog += "\n[start] 启动 \(script.command)...\n"
                                }
                            } label: {
                                Image(systemName: script.status == "运行中" ? "stop.fill" : "play.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(script.status == "运行中" ? Color.red : Color.ompText)
                                    .frame(width: 28, height: 28)
                                    .background(Color.ompFill, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("输出日志 (Live Logs)") {
                    Text(outputLog)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.ompCanvas)
        }
    }

    struct ScriptItem: Identifiable {
        let id = UUID()
        var name: String
        var command: String
        var desc: String
        var port: String?
        var status: String
    }
}


struct ProviderSettingsEmbedded: View {
    @Environment(ChatAppModel.self) private var model

    var body: some View {
        ScrollView {
            ProviderSettingsView()
                .environment(model)
        }
    }
}
#endif
