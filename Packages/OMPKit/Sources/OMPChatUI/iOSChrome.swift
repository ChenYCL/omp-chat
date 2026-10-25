import SwiftUI
import OMPCore
import OMPDesign

#if os(iOS)
/// iOS host panes (文件 / 终端 / 脚本 / 配置) rendered inside `IOSShell`'s 主机 tab.
/// Every row comes from the paired Mac over `RemoteSession`; unpaired, each pane
/// shows the same honest empty state instead of anything invented.

// MARK: - Shared empty state

/// Shown whenever the phone has no live Mac, or the Mac refused shell access.
struct HostUnavailableView: View {
    /// `nil` means "not paired"; a string is the host's own refusal.
    let reason: String?
    let onOpenRemote: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: reason == nil ? "desktopcomputer" : "lock")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.ompTextTertiary)
            Text(reason == nil ? "还没有连接 Mac" : "Mac 没有开放文件与终端")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ompText)
            Text(reason ?? "到「远程」页配对后，这里显示那台 Mac 的真实文件和终端。")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ompTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button(action: onOpenRemote) {
                Text("打开远程")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.ompInverseText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.ompPrimarySolid, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Files Pane

struct PaseoFilesPane: View {
    @Environment(RemoteSession.self) private var session
    let onOpenRemote: () -> Void

    /// Directory currently shown. Nil until the first `info` answers with a cwd.
    @State private var path: String?
    /// Crumbs from the session root down to `path`, each a full path.
    @State private var crumbs: [String] = []
    @State private var entries: [HostFSEntry] = []
    @State private var loading = false
    @State private var refusal: String?
    @State private var failure: String?
    @State private var viewing: ViewingFile?

    private struct ViewingFile: Identifiable {
        let id = UUID()
        let name: String
        let path: String
    }

    var body: some View {
        Group {
            if session.sink == nil {
                HostUnavailableView(reason: nil, onOpenRemote: onOpenRemote)
            } else if let refusal {
                HostUnavailableView(reason: refusal, onOpenRemote: onOpenRemote)
            } else {
                listing
            }
        }
        .task(id: session.isConnected) { await reload(reset: true) }
        .sheet(item: $viewing) { item in
            RemoteFileViewer(name: item.name, path: item.path)
        }
    }

    private var listing: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            if let failure, entries.isEmpty {
                failureNote(failure)
            } else if loading, entries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                Text(path == nil ? "" : "空目录")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries, id: \.name) { entry in
                        row(entry)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await reload(reset: false) }
            }
        }
        .background(Color.ompCanvas)
        .overlay(alignment: .top) {
            if loading, !entries.isEmpty {
                ProgressView().controlSize(.mini).padding(.top, 4)
            }
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    Button {
                        Task { await open(crumb, replacingTail: true) }
                    } label: {
                        Text(label(for: crumb, at: index))
                            .font(.system(size: 12.5, weight: index == crumbs.count - 1 ? .semibold : .regular).monospaced())
                            .foregroundStyle(index == crumbs.count - 1 ? Color.ompText : Color.ompTextSecondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func row(_ entry: HostFSEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 13))
                .foregroundStyle(entry.isDirectory ? Color.ompText : Color.ompTextTertiary)
                .frame(width: 20)
            Text(entry.name)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompText)
                .lineLimit(1)
            Spacer()
            if let size = entry.size, !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.ompTextTertiary)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let base = path else { return }
            let child = joined(base, entry.name)
            if entry.isDirectory {
                Task { await open(child, replacingTail: false) }
            } else {
                viewing = ViewingFile(name: entry.name, path: child)
            }
        }
    }

    private func failureNote(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompTextSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await reload(reset: false) } }
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `reset` drops back to the host's cwd/home; otherwise it refetches `path`.
    private func reload(reset: Bool) async {
        guard let sink = session.sink else { return }
        loading = true
        defer { loading = false }
        if reset || path == nil {
            guard await resolveRoot(sink) else { return }
        }
        guard let path else { return }
        await list(path, sink: sink, resetCrumbs: crumbs.isEmpty)
    }

    /// Asks the host who it is, then anchors the browser at its cwd (or home).
    private func resolveRoot(_ sink: any RelayRPCSink) async -> Bool {
        do {
            let response = try await HostRPC.call(sink, op: "info")
            guard response.ok, let info = response.info else {
                refusal = response.error == "shell_disabled" ? HostRPC.message(for: response) : nil
                failure = response.error == "shell_disabled" ? nil : HostRPC.message(for: response)
                return false
            }
            refusal = nil
            session.info = info
            let root = info.cwd.isEmpty ? info.home : info.cwd
            path = root
            crumbs = [root]
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    private func list(_ directory: String, sink: any RelayRPCSink, resetCrumbs: Bool) async {
        do {
            let response = try await HostRPC.call(sink, op: "fs.list", path: directory)
            guard response.ok else {
                if response.error == "shell_disabled" {
                    refusal = HostRPC.message(for: response)
                } else {
                    failure = HostRPC.message(for: response)
                }
                return
            }
            failure = nil
            entries = (response.entries ?? []).sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            if resetCrumbs { crumbs = [directory] }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func open(_ directory: String, replacingTail: Bool) async {
        guard let sink = session.sink else { return }
        path = directory
        if replacingTail {
            if let index = crumbs.firstIndex(of: directory) {
                crumbs = Array(crumbs.prefix(index + 1))
            }
        } else {
            crumbs.append(directory)
        }
        loading = true
        defer { loading = false }
        await list(directory, sink: sink, resetCrumbs: false)
    }

    private func label(for crumb: String, at index: Int) -> String {
        if index == 0 {
            if let home = session.info?.home, crumb == home { return "~" }
            return crumb.split(separator: "/").last.map(String.init) ?? crumb
        }
        return crumb.split(separator: "/").last.map(String.init) ?? crumb
    }

    private func joined(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}

/// Reads one remote file over `fs.read` and shows it, noting truncation.
struct RemoteFileViewer: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let name: String
    let path: String

    @State private var text = ""
    @State private var truncated = false
    @State private var notice: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let notice, text.isEmpty {
                    Text(notice)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    Text(text.isEmpty ? " " : text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.ompText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .textSelection(.enabled)
                }
            }
            .background(Color.ompCanvas)
            .safeAreaInset(edge: .bottom) {
                if truncated {
                    Text("文件超过 256 KB，只显示了前面的部分")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.ompFill)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(path)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(Color.ompTextTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let sink = session.sink else {
            notice = "连接已断开"
            return
        }
        do {
            let response = try await HostRPC.call(sink, op: "fs.read", path: path)
            guard response.ok else {
                notice = HostRPC.message(for: response)
                return
            }
            text = response.text ?? ""
            truncated = response.truncated ?? false
        } catch {
            notice = error.localizedDescription
        }
    }
}

// MARK: - Terminal Pane

struct PaseoTerminalPane: View {
    /// Seconds the host may hold an empty `exec.poll` (long-poll).
    static let pollWait: Double = 20
    @Environment(RemoteSession.self) private var session
    let onOpenRemote: () -> Void

    /// One finished or in-flight command plus what it printed.
    private struct Entry: Identifiable {
        let id = UUID()
        var command: String
        var output: String
        var exitCode: Int?
        var running: Bool
    }

    @State private var entries: [Entry] = []
    @State private var cwd = ""
    @State private var prompt = ""
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var refusal: String?
    /// Live output only scrolls to the bottom while the user has not swiped
    /// up to read earlier lines; any manual scroll pauses it until they
    /// return to the bottom edge.
    @State private var autoScrollEnabled = true
    /// Transport-level error shown above the scrollback (RPC failures).
    @State private var failure: String?
    /// The poll loop for the command currently running on the Mac.
    @State private var inflight: Task<Void, Never>?
    /// Request id of that command, needed for `exec.cancel`.
    @State private var inflightID: String?
    /// Polling tasks must not outlive the pane or a backgrounded app.
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group {
            if session.sink == nil {
                HostUnavailableView(reason: nil, onOpenRemote: onOpenRemote)
            } else if let refusal {
                HostUnavailableView(reason: refusal, onOpenRemote: onOpenRemote)
            } else {
                console
            }
        }
        .task(id: session.isConnected) { await refreshPrompt() }
        .onDisappear {
            // Leaving the pane (or the whole host tab) must not leak the
            // polling task; the host keeps the process, Ctrl-C's badge stays.
            stopPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding the app tears the local poll loop down; the host
            // process keeps running and the run stays pollable for 60 s, but
            // no task outlives the scene.
            if phase != .active { stopPolling() }
        }
    }

    private var console: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let failure {
                            Text(failure)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        ForEach(entries) { entry in
                            entryView(entry)
                        }
                        promptRow.id("prompt")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: entries.count) { _, _ in
                    if autoScrollEnabled {
                        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("prompt", anchor: .bottom) }
                    }
                }
                .onChange(of: entries.map(\.output.count)) { _, _ in
                    guard autoScrollEnabled else { return }
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("prompt", anchor: .bottom) }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.bounds.maxY - geometry.containerSize.height - geometry.contentInsets.bottom < 4
                } action: { _, atBottom in
                    autoScrollEnabled = atBottom
                }
            }
            .background(Color.ompCanvas)
            accessoryRow
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
            Text(prompt.isEmpty ? "…" : prompt)
                .font(.system(size: 11.5, weight: .medium).monospaced())
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Menu {
                Button("清屏") { entries.removeAll() }
                Button("复制全部输出") { UIPasteboard.general.string = transcript }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompText)
            }
        }
        .foregroundStyle(Color.ompText)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func entryView(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("$ \(entry.command)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.ompText)
                if entry.running {
                    ProgressView().controlSize(.mini)
                } else if let code = entry.exitCode {
                    Text("\(code)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(code == 0 ? Color.ompTextTertiary : Color.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(code == 0 ? Color.ompFill : Color.red, in: Capsule())
                }
            }
            if !entry.output.isEmpty {
                Text(entry.output)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.ompTextSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promptRow: some View {
        HStack(spacing: 6) {
            Text(prompt.isEmpty ? ">" : "\(prompt) >")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            TextField("", text: $input)
                .accessibilityIdentifier("host.terminal.input")
                .accessibilityLabel("终端命令输入")
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .focused($inputFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(inflight != nil)
                .onSubmit { run(input) }
        }
    }

    private var accessoryRow: some View {
        HStack(spacing: 4) {
            accessoryKey("Esc") { input = "" }
            accessoryKey("Tab") { completePrefix() }
            accessoryKey("Ctrl-C") { interrupt() }
            accessoryKey("↑") { recallOlder() }
            accessoryKey("↓") { recallNewer() }
            accessoryKey("⌨") { inputFocused.toggle() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Color.ompCard)
    }

    private func accessoryKey(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.ompText)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var transcript: String {
        entries.map { entry in
            "$ \(entry.command)\n\(entry.output)"
        }.joined(separator: "\n")
    }

    private func refreshPrompt() async {
        guard let sink = session.sink else { return }
        do {
            let response = try await HostRPC.call(sink, op: "info", cwd: cwd.isEmpty ? nil : cwd)
            guard response.ok, let info = response.info else {
                if response.error == "shell_disabled" { refusal = HostRPC.message(for: response) }
                else { failure = HostRPC.message(for: response) }
                return
            }
            refusal = nil
            failure = nil
            session.info = info
            cwd = info.cwd
            prompt = Self.promptLine(info)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func run(_ raw: String) {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, inflight == nil, let sink = session.sink else { return }
        if command == "clear" {
            entries.removeAll()
            input = ""
            return
        }
        history.append(command)
        historyIndex = nil
        input = ""
        let index = entries.count
        entries.append(Entry(command: command, output: "", exitCode: nil, running: true))
        let working = cwd
        let requestID = UUID().uuidString
        inflightID = requestID
        autoScrollEnabled = true
        inflight = Task {
            defer { inflight = nil }
            do {
                let started = try await HostRPC.call(
                    sink, op: "exec", id: requestID, command: command,
                    cwd: working.isEmpty ? nil : working, timeout: 30,
                    background: true
                )
                guard !Task.isCancelled else { return }
                // Streaming path: the host accepted `background` and parked
                // the process under this request id. Poll `exec.poll` and
                // append every chunk live.
                if started.ok, started.text == "started" {
                    await pollLoop(sink: sink, requestID: requestID, index: index)
                    return
                }
                // Old host: it answered the plain blocking exec as before.
                if started.ok {
                    finish(index, output: Self.rendered(started), exitCode: started.exitCode)
                    if let next = started.cwd, !next.isEmpty { cwd = next }
                    await refreshPrompt()
                    return
                }
                handleExecRefusal(started, index: index)
            } catch is CancellationError {
                finish(index, output: "^C 已取消", exitCode: 130)
            } catch {
                guard !Task.isCancelled else { return }
                finish(index, output: error.localizedDescription, exitCode: nil)
            }
        }
    }

    /// Streams one background run: polls `exec.poll` every 300 ms (backing
    /// off to 1 s after 20 empty polls), appends the stripped chunks to the
    /// entry's scrollback, and finishes with the exit-code badge, the
    /// cd-tracked cwd and a prompt refresh. A host that predates the op
    /// (`unsupported` / unknown op) falls back to one blocking `exec`.
    private func pollLoop(
        sink: any RelayRPCSink,
        requestID: String,
        index: Int
    ) async {
        var offset = 0
        var emptyPolls = 0
        while !Task.isCancelled {
            let asked = Date()
            do {
                // Long-poll: the host answers as soon as output arrives, so the
                // phone shows it without waiting for a poll tick.
                let poll = HostRPC.decodePoll(try await HostRPC.call(
                    sink, op: "exec.poll", id: "\(requestID)-p\(offset)",
                    cwd: cwd.isEmpty ? nil : cwd,
                    requestID: requestID, offset: offset, wait: Self.pollWait
                ))
                if poll.hostLacksPoll {
                    await fallbackBlockingExec(sink: sink, requestID: requestID, index: index)
                    return
                }
                guard poll.error == nil else {
                    finish(index, output: HostRPC.message(for: .init(
                        id: requestID, ok: false, error: poll.error
                    )), exitCode: nil)
                    return
                }
                if !poll.text.isEmpty {
                    append(index: index, chunk: poll.text, truncated: poll.truncated)
                    emptyPolls = 0
                } else {
                    emptyPolls += 1
                }
                offset = poll.nextOffset
                if poll.done {
                    if let next = poll.cwd, !next.isEmpty { cwd = next }
                    await refreshPrompt()
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                finish(index, output: error.localizedDescription, exitCode: nil)
                return
            }
            // A host that honours `wait` already held this answer, so ask again
            // at once. An older host answers empty immediately; keep the old
            // 300 ms cadence (1 s once idle) so it is not hammered.
            let held = Date().timeIntervalSince(asked) >= Self.pollWait / 2
            if emptyPolls > 0, !held {
                try? await Task.sleep(nanoseconds: emptyPolls > 20 ? 1_000_000_000 : 300_000_000)
            }
        }
    }

    /// The previous non-streaming behaviour, used when the host cannot poll:
    /// one blocking `exec` that answers once with everything it printed.
    private func fallbackBlockingExec(
        sink: any RelayRPCSink,
        requestID: String,
        index: Int
    ) async {
        do {
            let response = try await HostRPC.call(
                sink, op: "exec", id: requestID, command: entries[index].command,
                cwd: cwd.isEmpty ? nil : cwd, timeout: 30
            )
            guard !Task.isCancelled else { return }
            guard response.ok else {
                handleExecRefusal(response, index: index)
                return
            }
            finish(index, output: Self.rendered(response), exitCode: response.exitCode)
            if let next = response.cwd, !next.isEmpty { cwd = next }
            await refreshPrompt()
        } catch is CancellationError {
            finish(index, output: "^C 已取消", exitCode: 130)
        } catch {
            guard !Task.isCancelled else { return }
            finish(index, output: error.localizedDescription, exitCode: nil)
        }
    }

    /// Shared exec refusal handling: a shell-disabled answer locks the pane,
    /// everything else becomes that entry's output.
    private func handleExecRefusal(_ response: HostRPCResponse, index: Int) {
        if response.error == "shell_disabled" {
            refusal = HostRPC.message(for: response)
            finish(index, output: HostRPC.message(for: response), exitCode: nil)
        } else {
            finish(index, output: HostRPC.message(for: response), exitCode: nil)
        }
    }

    /// Appends one stripped chunk to the entry's live scrollback. Partial
    /// UTF-8 at the buffer edge stays raw until the next poll completes it.
    private func append(index: Int, chunk: String, truncated: Bool) {
        guard entries.indices.contains(index) else { return }
        var text = ANSIStripping.strip(chunk)
        if truncated { text += "\n…输出已超过 1 MB，较早的内容被丢弃" }
        if !text.isEmpty {
            entries[index].output += text
        }
    }

    private func finish(_ index: Int, output: String, exitCode: Int?) {
        guard entries.indices.contains(index) else { return }
        if !output.isEmpty { entries[index].output = output }
        entries[index].exitCode = exitCode
        entries[index].running = false
    }

    /// Ctrl-C: send `exec.cancel` for the pinned request id so the host kills
    /// the real process, and stop the local polling loop (the next poll would
    /// answer `done: true` with exit code 130, but the badge is already up).
    /// Leaving the pane or backgrounding the app calls the same teardown
    /// without touching the host process.
    private func interrupt() {
        guard let inflight else { return }
        if let requestID = inflightID, let sink = session.sink {
            let working = cwd
            Task {
                _ = try? await HostRPC.call(
                    sink, op: "exec.cancel", id: UUID().uuidString,
                    command: nil, cwd: working.isEmpty ? nil : working,
                    requestID: requestID
                )
            }
        }
        stopPolling()
        if let index = entries.indices.last, entries[index].running {
            finish(index, output: "^C", exitCode: 130)
        }
    }

    /// Cancels the in-flight task and clears the pinned request id, so no
    /// orphaned poll keeps hitting the host after the pane is gone. The host
    /// side process (if any) keeps running; the run stays pollable there.
    private func stopPolling() {
        inflight?.cancel()
        inflight = nil
        inflightID = nil
    }

    /// Completes the current token against the names in `cwd`, via `fs.list`.
    private func completePrefix() {
        guard let sink = session.sink else { return }
        let token = input.split(separator: " ").last.map(String.init) ?? ""
        guard !token.isEmpty else { return }
        Task {
            guard let response = try? await HostRPC.call(sink, op: "fs.list", path: cwd.isEmpty ? nil : cwd),
                  response.ok else { return }
            let names = (response.entries ?? []).map(\.name)
            guard let match = names.first(where: { $0.hasPrefix(token) }) else { return }
            if let range = input.range(of: token, options: .backwards) {
                input.replaceSubrange(range, with: match)
            }
        }
    }

    private func recallOlder() {
        guard !history.isEmpty else { return }
        let next = (historyIndex ?? history.count) - 1
        guard next >= 0 else { return }
        historyIndex = next
        input = history[next]
    }

    private func recallNewer() {
        guard let current = historyIndex else { return }
        if current + 1 >= history.count {
            historyIndex = nil
            input = ""
        } else {
            historyIndex = current + 1
            input = history[current + 1]
        }
    }

    private static func promptLine(_ info: HostInfo) -> String {
        var line = "\(info.user)@\(info.hostName)"
        let directory = info.cwd.hasPrefix(info.home) && !info.home.isEmpty
            ? "~" + info.cwd.dropFirst(info.home.count)
            : info.cwd
        line += " \(directory)"
        if let branch = info.gitBranch, !branch.isEmpty { line += " \(branch)" }
        return line
    }

    static func rendered(_ response: HostRPCResponse) -> String {
        var parts: [String] = []
        if let stdout = response.stdout, !stdout.isEmpty { parts.append(ANSIStripping.strip(stdout)) }
        if let stderr = response.stderr, !stderr.isEmpty { parts.append(ANSIStripping.strip(stderr)) }
        if response.truncated == true { parts.append("…输出超过 256 KB，已截断") }
        return parts.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}

// MARK: - Scripts Pane

struct PaseoScriptsPane: View {
    @Environment(RemoteSession.self) private var session
    let onOpenRemote: () -> Void

    private struct Script: Identifiable {
        let id: String
        let name: String
        /// What `exec` actually runs.
        let command: String
        var running: Bool = false
        var lastExit: Int?
        /// Section the row is listed under.
        var group: String = "可运行"
        /// Mutating actions ask before running.
        var confirm: Bool = false
        /// Asks for a one-line message first; it replaces `{{message}}` in
        /// the command. Empty input cancels.
        var needsMessage: Bool = false
    }

    @State private var scripts: [Script] = []
    @State private var cwd = ""
    @State private var loaded = false
    @State private var refusal: String?
    @State private var failure: String?
    @State private var log = ""
    @State private var pendingID: String?
    @State private var messagePrompt = false
    @State private var messageText = ""

    var body: some View {
        Group {
            if session.sink == nil {
                HostUnavailableView(reason: nil, onOpenRemote: onOpenRemote)
            } else if let refusal {
                HostUnavailableView(reason: refusal, onOpenRemote: onOpenRemote)
            } else {
                content
            }
        }
        .task(id: session.isConnected) { await load() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Text(cwd.isEmpty ? "脚本" : cwd.split(separator: "/").last.map(String.init) ?? "脚本")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                Text(failure)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scripts.isEmpty {
                Text("这个目录没有 package.json 脚本，也没有 Makefile 目标。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ompTextTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.self) { group in
                        Section(group) {
                            ForEach($scripts) { $script in
                                if script.group == group { scriptRow($script) }
                            }
                        }
                    }
                    if !log.isEmpty {
                        Section("输出") {
                            Text(log)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color.ompTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .confirmationDialog(
                    "运行这个操作？",
                    isPresented: Binding(get: { pendingID != nil }, set: { if !$0 { pendingID = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("运行") {
                        if let id = pendingID, let index = scripts.firstIndex(where: { $0.id == id }) {
                            run($scripts[index], message: nil)
                        }
                        pendingID = nil
                    }
                } message: {
                    Text(scripts.first { $0.id == pendingID }?.command ?? "")
                }
                .alert("提交说明", isPresented: $messagePrompt) {
                    TextField("一句话说明这次改动", text: $messageText)
                    Button("提交") {
                        if let id = pendingID, let index = scripts.firstIndex(where: { $0.id == id }) {
                            run($scripts[index], message: messageText)
                        }
                        pendingID = nil
                    }
                    Button("取消", role: .cancel) { pendingID = nil }
                } message: {
                    Text("会 git add -A 后提交，不会推送。")
                }
            }
        }
        .background(Color.ompCanvas)
    }

    private func scriptRow(_ script: Binding<Script>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.wrappedValue.name)
                    .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.ompText)
                Text(script.wrappedValue.command)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.ompTextTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let code = script.wrappedValue.lastExit {
                Text("\(code)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(code == 0 ? Color.ompTextTertiary : .red)
            }
            Button {
                request(script)
            } label: {
                Group {
                    if script.wrappedValue.running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ompText)
                    }
                }
                .frame(width: 28, height: 28)
                .background(Color.ompFill, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(script.wrappedValue.running)
            .accessibilityLabel("运行 \(script.wrappedValue.name)")
        }
        .padding(.vertical, 2)
    }

    /// Section titles in display order: git first (it is about the repo the
    /// phone is looking at), then project scripts.
    private var groups: [String] {
        var seen: [String] = []
        for script in scripts where !seen.contains(script.group) { seen.append(script.group) }
        return seen
    }

    private func request(_ script: Binding<Script>) {
        if script.wrappedValue.needsMessage {
            messageText = ""
            pendingID = script.wrappedValue.id
            messagePrompt = true
        } else if script.wrappedValue.confirm {
            pendingID = script.wrappedValue.id
        } else {
            run(script)
        }
    }

    /// Only offered when the host reports a git branch for this directory, so
    /// the buttons never appear outside a repository. All read-only except
    /// the fast-forward-only pull, which asks first.
    private static func gitActions(branch: String?) -> [Script] {
        guard let branch, !branch.isEmpty else { return [] }
        return [
            Script(id: "git:status", name: "状态", command: "git status -sb", group: "Git · \(branch)"),
            Script(id: "git:diff", name: "改动统计", command: "git diff --stat", group: "Git · \(branch)"),
            Script(id: "git:log", name: "最近提交", command: "git log --oneline -10", group: "Git · \(branch)"),
            Script(id: "git:pull", name: "拉取（仅快进）", command: "git pull --ff-only", group: "Git · \(branch)", confirm: true),
            Script(id: "git:commit", name: "暂存并提交", command: "git add -A && git commit -m {{message}}", group: "Git · \(branch)", needsMessage: true),
        ]
    }

    private func load() async {
        guard let sink = session.sink else { return }
        loaded = false
        defer { loaded = true }
        do {
            // Follow the directory the terminal last `cd`-ed into, so git and
            // script buttons act on the project the user is actually in.
            let info = try await HostRPC.call(sink, op: "info", cwd: session.info?.cwd)
            guard info.ok, let host = info.info else {
                if info.error == "shell_disabled" { refusal = HostRPC.message(for: info) }
                else { failure = HostRPC.message(for: info) }
                return
            }
            refusal = nil
            session.info = host
            cwd = host.cwd
            async let package = HostRPC.call(sink, op: "fs.read", path: joined(host.cwd, "package.json"))
            async let makefile = HostRPC.call(sink, op: "fs.read", path: joined(host.cwd, "Makefile"))
            let (packageResponse, makefileResponse) = try await (package, makefile)
            if packageResponse.error == "shell_disabled" || makefileResponse.error == "shell_disabled" {
                refusal = HostRPC.message(for: packageResponse.error == "shell_disabled" ? packageResponse : makefileResponse)
                return
            }
            var found: [Script] = Self.gitActions(branch: host.gitBranch)
            if packageResponse.ok, let text = packageResponse.text {
                found += Self.packageScripts(text)
            }
            if makefileResponse.ok, let text = makefileResponse.text {
                found += Self.makeTargets(text)
            }
            scripts = found
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func run(_ script: Binding<Script>, message: String? = nil) {
        guard let sink = session.sink, !script.wrappedValue.running else { return }
        let command = Self.command(script.wrappedValue, message: message)
        let working = cwd
        script.wrappedValue.running = true
        log += "\n$ \(command)\n"
        Task {
            defer { script.wrappedValue.running = false }
            do {
                let response = try await HostRPC.call(
                    sink, op: "exec", command: command, cwd: working.isEmpty ? nil : working, timeout: 120
                )
                guard response.ok else {
                    log += HostRPC.message(for: response) + "\n"
                    return
                }
                let rendered = PaseoTerminalPane.rendered(response)
                if !rendered.isEmpty { log += rendered + "\n" }
                script.wrappedValue.lastExit = response.exitCode
            } catch {
                log += error.localizedDescription + "\n"
            }
        }
    }

    private static func command(_ script: Script, message: String?) -> String? {
        HostCommandTemplate.fill(script.command, message: message)
    }

    /// `"scripts"` values of a package.json, read leniently so a trailing
    /// comment or odd formatting degrades to "no scripts" instead of an error.
    private static func packageScripts(_ text: String) -> [Script] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = root["scripts"] as? [String: Any] else { return [] }
        return scripts.compactMap { name, value -> Script? in
            guard let body = value as? String, !body.isEmpty else { return nil }
            return Script(id: "npm:\(name)", name: name, command: "npm run \(shellQuoted(name))")
        }
        .sorted { $0.name < $1.name }
    }

    /// Makefile rule names: a line whose first token ends in `:` and is not a
    /// variable assignment, dot directive, or pattern rule.
    private static func makeTargets(_ text: String) -> [Script] {
        var targets: [Script] = []
        var seen = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasPrefix("\t") ? "" : String(raw)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("."), !line.hasPrefix("\t") else { continue }
            guard !line.contains("=") || line.firstIndex(of: ":").map({ $0 < (line.firstIndex(of: "=") ?? line.endIndex) }) == true else { continue }
            guard let head = line.split(separator: ":").first else { continue }
            for token in head.split(separator: " ") {
                let name = String(token)
                guard !name.isEmpty, !name.contains("%"), seen.insert(name).inserted else { continue }
                targets.append(Script(id: "make:\(name)", name: name, command: "make \(shellQuoted(name))"))
            }
        }
        return targets
    }

    private static func shellQuoted(_ token: String) -> String {
        token.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) ? token : "'\(token.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func joined(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}

// MARK: - Config Pane

struct PaseoConfigPane: View {
    @Environment(RemoteSession.self) private var session
    let onOpenRemote: () -> Void

    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        Group {
            if session.sink == nil {
                HostUnavailableView(reason: nil, onOpenRemote: onOpenRemote)
            } else {
                details
            }
        }
        .task(id: session.isConnected) { await refresh() }
    }

    private var details: some View {
        List {
            if let info = session.info {
                Section("主机") {
                    row("主机名", info.hostName)
                    row("用户", info.user)
                    row("家目录", info.home)
                    row("当前目录", info.cwd)
                    row("分支", info.gitBranch ?? "不在 git 仓库里")
                    if let dirty = info.gitDirty {
                        row("未提交改动", "\(dirty)")
                    }
                }
            } else if loading {
                Section { ProgressView() }
            } else if let failure {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ompTextSecondary)
                        Button("重试") { Task { await refresh() } }
                            .font(.system(size: 13, weight: .medium))
                    }
                }
            }
            Section("连接") {
                row("方式", session.mode.rawValue)
                Button(action: onOpenRemote) {
                    HStack {
                        Text("管理连接")
                            .foregroundStyle(Color.ompText)
                        Spacer()
                        Text("远程")
                            .foregroundStyle(Color.ompTextTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.ompCanvas)
        .refreshable { await refresh() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.ompTextSecondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 13.5).monospaced())
                .foregroundStyle(Color.ompText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func refresh() async {
        guard let sink = session.sink else { return }
        loading = true
        defer { loading = false }
        do {
            let response = try await HostRPC.call(sink, op: "info", cwd: session.info?.cwd)
            guard response.ok, let info = response.info else {
                failure = HostRPC.message(for: response)
                return
            }
            failure = nil
            session.info = info
        } catch {
            failure = error.localizedDescription
        }
    }
}
#endif
