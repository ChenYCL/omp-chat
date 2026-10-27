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
    /// The command's process while one runs, so the stop button can reach it.
    @State private var runningProcess: Process?
    /// The request currently being executed, finished once through
    /// `onCommandFinished`.
    @State private var handledRequestID: UUID?
    /// A request that arrived while the terminal was busy, run on finish.
    @State private var deferredRequest: ChatAppModel.SidePanelTerminalRequest?
    @FocusState private var focused: Bool
    /// Repository the current thread is bound to. Re-points the prompt while
    /// the terminal is idle; a running command keeps its own cwd.
    private let startingDirectory: String?
    /// The model's request to run a command now (environment actions).
    private var pendingCommand: ChatAppModel.SidePanelTerminalRequest?
    /// Called when the command of request `id` finished (any exit status).
    private let onCommandFinished: (UUID) -> Void

    public init(
        startingDirectory: String? = nil,
        pendingCommand: ChatAppModel.SidePanelTerminalRequest? = nil,
        onCommandFinished: @escaping (UUID) -> Void = { _ in }
    ) {
        self.startingDirectory = startingDirectory
        self.pendingCommand = pendingCommand
        self.onCommandFinished = onCommandFinished
    }

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
            followStartingDirectory()
        }
        .onChange(of: startingDirectory) { _, _ in followStartingDirectory() }
        // An environment action (or another caller) asked the terminal to run
        // something now. `initial` covers a request that was set before this
        // view existed (the panel opens on the terminal in the same update);
        // while busy, it waits and runs right after.
        .onChange(of: pendingCommand, initial: true) { _, request in
            guard let request, request.id != handledRequestID else { return }
            if running {
                deferredRequest = request
                append("终端忙，命令已排队", color: .ompTextTertiary)
                return
            }
            take(request)
        }
    }

    /// Runs a requested command now: re-points the directory, echoes the
    /// prompt line and executes through the same path as typed commands.
    private func take(_ request: ChatAppModel.SidePanelTerminalRequest) {
        handledRequestID = request.id
        if let directory = request.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            workingDirectory = directory
        }
        input = request.command
        run()
    }

    /// Applies the thread's bound directory when it changes. Only while idle:
    /// moving the cwd under a running command would change what that command
    /// operates on mid-flight.
    private func followStartingDirectory() {
        guard !running,
              let target = startingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty,
              target != workingDirectory else { return }
        workingDirectory = target
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
                Button {
                    stopRunning()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 20, height: 18)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("停止当前命令")
                .accessibilityIdentifier("terminalStopButton")
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
        let directory = workingDirectory
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", isCd
            ? "cd \(shellQuoted(String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)).isEmpty ? "~" : shellQuoted(String(command.dropFirst(3)))) && pwd"
            : "cd \(shellQuoted(directory)) && \(command)"]
        process.environment = ChildProcessEnvironment.build()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        runningProcess = process

        do {
            try process.run()
        } catch {
            append("启动失败: \(error.localizedDescription)", color: .red)
            running = false
            runningProcess = nil
            finishRequest()
            return
        }
        // Reading pipes to EOF blocks, so it happens off the main actor; only
        // the result lands back here.
        Task.detached(priority: .userInitiated) {
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let out = String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let err = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = process.terminationStatus
            let stopped = process.terminationReason == .uncaughtSignal
            await MainActor.run { self.complete(
                out: out, err: err, status: status, stopped: stopped, isCd: isCd
            ) }
        }
    }

    /// Back on the main actor: shows what the command printed and unblocks
    /// the prompt.
    private func complete(out: String, err: String, status: Int32, stopped: Bool, isCd: Bool) {
        if !out.isEmpty { append(out) }
        if !err.isEmpty { append(err, color: .red) }
        if status != 0 {
            append(stopped ? "已停止" : "exit \(status)", color: .red)
        }
        if isCd, !out.isEmpty, !stopped {
            workingDirectory = out
        }
        running = false
        runningProcess = nil
        finishRequest()
    }

    /// Reports the request that started this command, then runs a command
    /// that was queued while the terminal was busy.
    private func finishRequest() {
        if let handled = handledRequestID {
            handledRequestID = nil
            onCommandFinished(handled)
        }
        if let queued = deferredRequest {
            deferredRequest = nil
            take(queued)
        }
    }

    /// 停止: SIGINT to the running command, SIGTERM two seconds later if it
    /// ignored that.
    private func stopRunning() {
        guard let process = runningProcess else { return }
        process.interrupt()
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning { process.terminate() }
        }
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
