import SwiftUI
import OMPCore
import OMPDesign

#if os(macOS)
import AppKit

/// Terminal that really executes commands on this Mac, with a Moshi-style
/// prompt (`~/path branch ❯`) and modifier key row.
public struct TerminalView: View {
    @State private var lines: [TerminalLine] = []
    @State private var input = ""
    @State private var workingDirectory = FileManager.default.currentDirectoryPath
    @State private var running = false
    @FocusState private var focused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(line.color)
                                .textSelection(.enabled)
                                .id(index)
                        }
                        promptRow
                            .id("prompt")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black)
                .onChange(of: lines.count) { _, _ in
                    proxy.scrollTo("prompt", anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)

            keyRow
        }
        .onAppear {
            if lines.isEmpty {
                append("OMP Chat 终端 — 输入命令直接在本机执行", color: .ompTextTertiary)
            }
        }
    }

    private var promptText: String {
        let branch = GitInfo.branch(at: URL(fileURLWithPath: workingDirectory))
        let short = GitInfo.tildified(workingDirectory)
        return branch.map { "\(short) \($0) ❯" } ?? "\(short) ❯"
    }

    private var promptRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(promptText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.green)
            // Single line, no `axis`: a vertical-axis field treats Return as a
            // newline, so `onSubmit` never fired and commands could not run.
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white)
                .focused($focused)
                .disabled(running)
                .onSubmit { run() }
            if running {
                ProgressView().controlSize(.mini)
            } else if !input.trimmingCharacters(in: .whitespaces).isEmpty {
                // A visible run button: Return alone was unreliable inside the
                // scroll view, and Moshi's terminal has one too.
                Button(action: run) {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 20, height: 18)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("运行")
            }
        }
        .padding(.top, 2)
        .onTapGesture { focused = true }
    }

    private func append(_ text: String, color: Color = Color(white: 0.82)) {
        lines.append(TerminalLine(text: text, color: color))
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    private func run() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !running else { return }
        input = ""
        append("\(promptText) \(command)", color: .green)
        running = true

        let isCd = command == "cd" || command.hasPrefix("cd ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", isCd
            ? "cd \(shellQuoted(command.dropFirst(2).trimmingCharacters(in: .whitespaces)).isEmpty ? "~" : shellQuoted(String(command.dropFirst(3)))) && pwd"
            : "cd \(shellQuoted(workingDirectory)) && \(command)"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let out = String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let err = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { append(out) }
            if !err.isEmpty { append(err, color: .red) }
            if process.terminationStatus != 0 {
                append("exit \(process.terminationStatus)", color: .red)
            }
            if isCd {
                workingDirectory = out.isEmpty ? workingDirectory : out
            }
        } catch {
            append("启动失败: \(error.localizedDescription)", color: .red)
        }
        running = false
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private var keyRow: some View {
        HStack(spacing: 5) {
            ForEach(["Esc", "Tab", "Ctrl", "Alt", "⇧", "↑", "↓", "←", "→", "⌨"], id: \.self) { key in
                Button {
                    handleKey(key)
                } label: {
                    Text(key)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func handleKey(_ key: String) {
        switch key {
        case "Esc": input = ""
        case "Tab": input += "\t"
        case "↑":
            focused = true
            append("↑ 历史: \(lastCommand ?? "—")", color: .ompTextTertiary)
        default:
            focused = true
        }
    }

    private var lastCommand: String? {
        lines.reversed()
            .first { $0.text.contains(" ❯ ") }?
            .text
            .components(separatedBy: " ❯ ").last
    }
}

struct TerminalLine {
    let text: String
    let color: Color
}
#else
/// iOS keeps the Moshi look; execution needs a host bridge.
public struct TerminalView: View {
    @State private var lines: [String] = []

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(index == lines.count - 1 ? .white : Color(white: 0.72))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black)
                .onChange(of: lines.count) { _, _ in
                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 5) {
                ForEach(["Esc", "Tab", "Ctrl", "Alt", "⇧", "↑", "↓", "←", "→", "⌨"], id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .onAppear {
            if lines.isEmpty {
                lines = ["OMP Chat 终端 — iOS 端需连接 Mac 主机后执行命令"]
            }
        }
    }
}
#endif
