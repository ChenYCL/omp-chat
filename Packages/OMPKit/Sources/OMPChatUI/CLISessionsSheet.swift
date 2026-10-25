import SwiftUI
import OMPCore
import OMPDesign

#if os(iOS) || os(macOS)

// MARK: - CLISessionsSheet
//
// The Mac's coding-agent sessions (Claude Code today), listed and controlled
// from the phone through the paired host's `cli.sessions` / `cli.control` RPC.
// Every row is something the agent itself reported; there is no sample data.
// Background sessions can be read, stopped and removed. Sessions open in a
// terminal tab are shown but read-only: the phone does not reach into a
// terminal someone is typing in.

struct CLISessionsSheet: View {
    /// Where the sessions come from. The phone reads them through its paired
    /// Mac; the Mac itself reads them straight from its own executor, because
    /// the person at that keyboard does not need the phone-access switch on to
    /// see their own sessions.
    enum Source {
        case pairedMac
        case thisMac
    }

    var source: Source = .pairedMac

    @Environment(\.dismiss) private var dismiss
    @Environment(RemoteSession.self) private var session
    @Environment(ChatAppModel.self) private var model

    @State private var sessions: [CLISession] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var failure: String?
    @State private var busyID: String?
    @State private var logs: LogsRoute?
    @State private var showingStart = false
    @State private var pendingRemoval: CLISession?

    private struct LogsRoute: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    var body: some View {
        NavigationStack {
            Group {
                if !available {
                    emptyState(
                        title: "还没有连接 Mac",
                        detail: "先在「远程」页完成配对，这里会列出 Mac 上正在跑的 Claude Code 会话。"
                    )
                } else {
                    content
                }
            }
            .navigationTitle("CLI 会话")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                if available {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingStart = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("新建会话")
                            .accessibilityIdentifier("cli.start")
                    }
                }
            }
            .task(id: loadTrigger) { await load() }
            .sheet(item: $logs) { route in
                NavigationStack {
                    ScrollView {
                        Text(route.text.isEmpty ? "（没有输出）" : route.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.ompText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .navigationTitle(route.title)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { logs = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingStart) {
                StartCLISessionSheet(defaultDirectory: session.info?.cwd ?? session.info?.home ?? "") { directory, prompt in
                    await start(directory: directory, prompt: prompt)
                }
            }
            .confirmationDialog(
                "删除这个会话？",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { target in
                Button("删除", role: .destructive) { Task { await control(.remove, target) } }
            } message: { target in
                Text("「\(label(for: target))」的记录和它的工作树（在安全时）会从 Mac 上删除。")
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 440)
        #endif
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let failure, sessions.isEmpty {
            emptyState(title: "读取失败", detail: failure, retry: true)
        } else if loaded, sessions.isEmpty {
            emptyState(title: "Mac 上没有 Claude Code 会话", detail: "点右上角 + 在 Mac 上启动一个后台会话。", retry: true)
        } else {
            List {
                if let failure {
                    Section { Text(failure).font(.system(size: 12)).foregroundStyle(.red) }
                }
                if !background.isEmpty {
                    Section {
                        ForEach(background) { row($0) }
                    } header: {
                        Text("后台会话")
                    } footer: {
                        // Measured: the Mac app's sandbox denies signalling other
                        // processes, so Claude treats terminal sessions as dead
                        // and omits them from this list.
                        if interactive.isEmpty {
                            Text("在 Mac 终端里打开的会话看不到：沙盒版 OMPChat 无权探测其他进程。")
                        }
                    }
                }
                if !interactive.isEmpty {
                    Section {
                        ForEach(interactive) { row($0) }
                    } header: {
                        Text("终端里的会话")
                    } footer: {
                        Text("在 Mac 终端里打开的会话只读展示，不能从手机停止。")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .refreshable { await load() }
            .overlay { if loading && !loaded { ProgressView() } }
        }
    }

    private func emptyState(title: String, detail: String, retry: Bool = false) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 26))
                .foregroundStyle(Color.ompTextSecondary)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompTextSecondary)
                .multilineTextAlignment(.center)
            if retry {
                Button("重试") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var background: [CLISession] { sessions.filter(\.isControllable) }
    private var interactive: [CLISession] { sessions.filter { !$0.isControllable } }

    private func row(_ item: CLISession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(Self.tone(item.state)).frame(width: 7, height: 7)
                Text(label(for: item))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if busyID == item.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text(item.state)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Self.tone(item.state))
                }
            }
            HStack(spacing: 6) {
                Label(item.directoryName, systemImage: "folder")
                if let started = item.startedAt {
                    Text("·")
                    Text(started, style: .relative)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Color.ompTextTertiary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.isControllable {
                Button("删除", role: .destructive) { pendingRemoval = item }
                Button("停止") { Task { await control(.stop, item) } }.tint(.orange)
            }
        }
        .swipeActions(edge: .leading) {
            if item.isControllable {
                Button("日志") { Task { await control(.logs, item) } }.tint(.blue)
            }
        }
        .contextMenu {
            if item.isControllable {
                Button { Task { await control(.logs, item) } } label: { Label("查看日志", systemImage: "text.alignleft") }
                Button { Task { await control(.stop, item) } } label: { Label("停止", systemImage: "stop.circle") }
                Button(role: .destructive) { pendingRemoval = item } label: { Label("删除", systemImage: "trash") }
            }
        }
    }

    private func label(for item: CLISession) -> String {
        if let name = item.name, !name.isEmpty { return name }
        return item.directoryName
    }

    /// Colours the agent's own state word; the word itself is shown verbatim.
    private static func tone(_ state: String) -> Color {
        switch state.lowercased() {
        case "busy", "running", "working": .green
        case "blocked", "waiting": .orange
        case "error", "failed": .red
        default: Color.ompTextTertiary
        }
    }

    /// Whether there is anything to read: a paired Mac, or this Mac itself.
    private var available: Bool {
        switch source {
        case .pairedMac: return session.sink != nil
        case .thisMac: return true
        }
    }

    private var loadTrigger: Bool {
        switch source {
        case .pairedMac: return session.isConnected
        case .thisMac: return true
        }
    }

    // MARK: Actions

    private func call(_ op: String, _ configure: (inout HostRPCRequest) -> Void) async throws -> HostRPCResponse {
        switch source {
        case .pairedMac:
            guard let sink = session.sink else { throw CancellationError() }
            var request = HostRPCRequest(id: UUID().uuidString, op: op)
            configure(&request)
            return try await sink.call(request)
        case .thisMac:
            var request = HostRPCRequest(id: UUID().uuidString, op: op)
            configure(&request)
            return await model.handleHostRPCForThisMac(request)
        }
    }

    private func load() async {
        guard available else { return }
        loading = true
        defer { loading = false; loaded = true }
        do {
            let response = try await call("cli.sessions") { request in
                request.command = "claude"
                request.timeout = 30
            }
            guard response.ok else {
                failure = response.text ?? HostRPC.message(for: response)
                return
            }
            failure = nil
            sessions = (response.sessions ?? []).sorted {
                ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func control(_ action: CLISessionAction, _ target: CLISession) async {
        guard available else { return }
        busyID = target.id
        defer { busyID = nil }
        do {
            let response = try await call("cli.control") { request in
                request.path = action.rawValue
                request.command = target.agent
                request.timeout = 40
                request.requestID = target.id
            }
            guard response.ok else {
                failure = response.text.flatMap { $0.isEmpty ? nil : $0 } ?? HostRPC.message(for: response)
                return
            }
            failure = nil
            if action == .logs {
                logs = LogsRoute(title: label(for: target), text: ANSIStripping.strip(response.text ?? ""))
            } else {
                await load()
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Returns an error message for the start sheet to show, or `nil` on success.
    private func start(directory: String, prompt: String) async -> String? {
        guard available else { return "还没有连接 Mac" }
        do {
            let response = try await call("cli.control") { request in
                request.path = CLISessionAction.start.rawValue
                request.command = "claude"
                request.cwd = directory
                request.timeout = 40
                request.prompt = prompt
            }
            guard response.ok else { return HostRPC.message(for: response) }
            await load()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct StartCLISessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let defaultDirectory: String
    let onStart: (String, String) async -> String?

    @State private var directory = ""
    @State private var prompt = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("目录（在 Mac 上）") {
                    TextField("/Users/…/项目", text: $directory)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("cli.start.directory")
                }
                Section("第一条指令") {
                    TextField("让它做什么", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("cli.start.prompt")
                }
                if let error {
                    Section { Text(error).font(.system(size: 12.5)).foregroundStyle(.red) }
                }
            }
            .navigationTitle("新建后台会话")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            sending = true
                            error = await onStart(directory, prompt)
                            sending = false
                            if error == nil { dismiss() }
                        }
                    } label: {
                        if sending { ProgressView().controlSize(.small) } else { Text("启动") }
                    }
                    .disabled(sending || directory.trimmingCharacters(in: .whitespaces).isEmpty
                        || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if directory.isEmpty { directory = defaultDirectory } }
        }
    }
}
#endif
