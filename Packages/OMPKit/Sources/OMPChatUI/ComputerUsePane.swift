#if os(macOS)
import AppKit
import Darwin
import SwiftUI
import OMPCore
import OMPDesign

/// Desktop settings → 电脑控制: macOS privacy grants and the vetted
/// computer-use MCP servers from `ComputerUseCatalog`. Adding a server writes
/// its pinned config into `AppSettings.mcpServers` through the settings
/// draft, which the settings window saves like every other change.
struct ComputerUsePane: View {
    @Binding var mcpServers: [MCPServerConfig]
    @Environment(ChatAppModel.self) private var model: ChatAppModel

    @State private var screenRecording = ComputerUsePermissions.screenRecordingGranted
    @State private var accessibility = ComputerUsePermissions.accessibilityGranted
    @State private var confirming: ComputerUseServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dockerCard
            permissionsCard
            ForEach(Array(ComputerUseCatalog.servers.enumerated()), id: \.element.id) { index, server in
                serverCard(server, primary: index == 0)
            }
            safetyCard
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .alert(
            "添加「\(confirming?.name ?? "")」？",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { server in
            Button("添加并启用") {
                add(server)
                confirming = nil
            }
            .accessibilityIdentifier("settings.computerUse.confirmAdd")
            Button("取消", role: .cancel) { confirming = nil }
        } message: { _ in
            Text("""
            它能看到你的屏幕：截图和应用界面内容会发给你当前使用的模型服务商。
            它能在任何应用里点击和输入。
            每个操作执行前都会先问你，不能设为始终允许；「只读」模式下一律拒绝。
            点停止会取消正在进行的回复，并拒绝所有还在等你确认的操作。
            """)
        }
    }

    // MARK: Docker sandbox

    private var dockerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("电脑控制沙盒（推荐）")
                Spacer()
                statusBadge
            }
            Text("控制的是 netcup VPS 上 Docker 容器里的 Linux 桌面（Xvfb + GTK 应用），经 SSH 隧道连过去。它看不到这台 Mac 的任何窗口，也不能在这里点击。")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ompTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                label("开始使用")
                Text("① VPS：容器已在 /opt/omp-computer-use 运行（docker restart omp-computer-use 可重启）。\n② 本机：开 SSH 隧道（设置 → 说明里有命令），然后在这里确认状态变为「已连接」。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.computerUse.docker")
        .onAppear { model.pollSandboxStatus() }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            model.pollSandboxStatus()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.sandboxStatus {
        case .checking:
            Label("检查中…", systemImage: "hourglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ompTextSecondary)
        case .up(let detail):
            Label("已连接 · \(detail)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings.computerUse.sandbox.up")
        case .down(let reason):
            Label("未连接 · \(reason)", systemImage: "xmark.circle")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("settings.computerUse.sandbox.down")
        }
    }

    /// One initialize + tools/list against the tunnel. Off the main actor
    /// for the socket work; the answer lands back on the view.
    // MARK: Permissions

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("系统权限")
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings.computerUse.refresh")
            }
            permissionRow(.screenRecording, granted: screenRecording)
            Divider()
            permissionRow(.accessibility, granted: accessibility)
            footnote("这里显示的是 OMPChat 自己的授权。Munim Computer Use 由 OMPChat 启动，macOS 把它的屏幕录制和辅助功能算在 OMPChat 名下，用的就是这两项。Open Computer Use 用它自己的应用「Open Computer Use」的授权，见下方它的「系统权限」一行。新授予的屏幕录制通常要重新打开 OMPChat 才生效。")
        }
        .padding(14)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func permissionRow(_ pane: ComputerUsePrivacyPane, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ompText)
                Text(granted ? "已允许" : "未允许")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            Spacer()
            if pane == .screenRecording && !granted {
                Button("请求权限") {
                    ComputerUsePermissions.requestScreenRecording()
                    refresh()
                }
                .accessibilityIdentifier("settings.computerUse.permission.screenRecording.request")
            }
            Button("打开系统设置") {
                ComputerUsePermissions.openSettings(pane)
            }
            .accessibilityIdentifier("settings.computerUse.permission.\(pane.rawValue).open")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.computerUse.permission.\(pane.rawValue)")
    }

    private func refresh() {
        screenRecording = ComputerUsePermissions.screenRecordingGranted
        accessibility = ComputerUsePermissions.accessibilityGranted
    }

    // MARK: Servers

    private func serverCard(_ server: ComputerUseServer, primary: Bool) -> some View {
        let index = mcpServers.firstIndex { $0.id == server.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(server.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                Text(primary ? "推荐" : "备选")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.ompSelection, in: Capsule())
                Spacer()
                if let index {
                    Toggle("启用", isOn: $mcpServers[index].enabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.computerUse.enabled.\(server.id)")
                    Button("移除", role: .destructive) {
                        mcpServers.removeAll { $0.id == server.id }
                    }
                    .accessibilityIdentifier("settings.computerUse.remove.\(server.id)")
                } else {
                    Button("添加") { confirming = server }
                        .accessibilityIdentifier("settings.computerUse.add.\(server.id)")
                }
            }
            Text(server.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ompTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                infoRow("许可证", server.license)
                infoRow("固定版本", "\(server.packageSpec)（提交 \(server.pinnedCommit.prefix(7))）")
                infoRow("运行需要", server.requirement)
                infoRow("审核日期", server.verifiedDate)
                permissionInfo(server)
                GridRow {
                    label("源代码")
                    Link(server.homepage.absoluteString, destination: server.homepage)
                        .font(.system(size: 12))
                        .accessibilityIdentifier("settings.computerUse.source.\(server.id)")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                label("添加后它能")
                ForEach(server.capabilities, id: \.self) { item in
                    Text("• \(item)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.computerUse.server.\(server.id)")
    }

    private func add(_ server: ComputerUseServer) {
        guard !mcpServers.contains(where: { $0.id == server.id }) else { return }
        var config = server.config
        config.enabled = true
        mcpServers.append(config)
    }

    /// Whose grants the server uses, and for an `.ownApp` server the pinned
    /// command that opens its onboarding (it never asks while running as MCP).
    @ViewBuilder
    private func permissionInfo(_ server: ComputerUseServer) -> some View {
        switch server.permissionHolder {
        case .hostApp:
            infoRow("系统权限", "用 OMPChat 的屏幕录制和辅助功能（见上方）")
        case .ownApp:
            GridRow {
                label("系统权限")
                VStack(alignment: .leading, spacing: 4) {
                    Text("用「\(server.permissionAppName ?? server.name)」自己的屏幕录制和辅助功能。作为 MCP 运行时它不会弹出授权；在终端运行下面的命令，按它打开的引导窗口授权一次：")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let command = server.permissionSetupCommand {
                        HStack(spacing: 6) {
                            Text(command)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                            Button("复制命令") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings.computerUse.copySetup.\(server.id)")
                        }
                    }
                }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Color.ompText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Safety

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("须知")
            ForEach(Self.safetyFacts, id: \.self) { fact in
                Text("• \(fact)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("settings.computerUse.safety")
    }

    private static let safetyFacts = [
        "截图和应用界面内容会发送给你当前使用的模型服务商。",
        "每个电脑操作执行前都要你确认，不能设为始终允许；「只读」模式下一律拒绝。",
        "停止会取消正在进行的回复，并拒绝所有还在等你确认的操作；已经交给电脑控制服务的那一步可能仍会做完。",
        "服务固定在上面审核过的版本，不会自动更新；换版本需要重新审核。",
        "电脑控制服务是第三方开源程序，拿到权限后能看到并操作你的所有应用。",
    ]

    // MARK: Text

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.ompText)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.ompTextSecondary)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.ompTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One MCP probe of the computer-use Docker sandbox over the tunnel:
/// initialize → initialized → tools/list. A tools/list answer proves the
/// server, the container's desktop and the accessibility tree are all up.
enum SandboxProbe {
    static func check(host: String, port: Int) -> ChatAppModel.SandboxStatus {
        var input: [UInt8] = []
        var output: [UInt8] = []
        var error: [UInt8] = []
        // Foundation's Process/socket APIs are heavy; use Network.framework.
        let result = initializeAndList(host: host, port: port, input: &input, output: &output, error: &error)
        return result
    }

    private static func initializeAndList(host: String, port: Int,
                                          input: inout [UInt8], output: inout [UInt8], error: inout [UInt8])
        -> ChatAppModel.SandboxStatus {
        var connection = NetworkConnection(host: host, port: port, timeout: 8)
        guard connection.open() else { return .down("连不上隧道") }
        defer { connection.close() }
        guard let tools = connection.request(id: 1, method: "tools/list",
                                             afterInit: true) else {
            return .down("服务器没有回应")
        }
        return .up("\(tools) 个工具")
    }
}

/// Minimal blocking TCP JSON-RPC client for the probe (Network.framework,
/// one connection per probe; the sandbox answers newline-delimited JSON).
struct NetworkConnection {
    private let host: String
    private let port: Int
    private let timeout: Int
    private var fd: Int32 = -1

    init(host: String, port: Int, timeout: Int) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    mutating func open() -> Bool {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return false }
        _ = deadline
        var flags = fcntl(fd, F_GETFL, 0)
        flags &= ~O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)
        return true
    }

    mutating func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// Sends each frame separately and waits for its answer: the container
    /// server reads one line at a time and answers that line only, so a
    /// combined write leaves it waiting and every request hangs.
    mutating func request(id: Int, method: String, afterInit: Bool) -> Int? {
        let frames = afterInit
            ? [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ompchat-probe","version":"1"}}}"# + "\n",
               #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n",
               #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"]
            : [#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"]
        for frame in frames {
            let marker = frame.contains(#""method":"initialize""#) ? "id\":1" : (frame.contains(#"tools/list"#) ? "id\":2" : nil)
            let sent = frame.withCString { Darwin.send(fd, $0, strlen($0), 0) }
            guard sent > 0 else { return nil }
            if let marker {
                var buffer = [UInt8](repeating: 0, count: 65536)
                var accumulated = ""
                let deadline = Date().addingTimeInterval(TimeInterval(timeout))
                while Date() < deadline {
                    let read = Darwin.recv(fd, &buffer, buffer.count, 0)
                    guard read > 0 else { break }
                    accumulated += String(decoding: buffer[0..<read], as: UTF8.self)
                    if accumulated.contains(marker) { break }
                }
                guard accumulated.contains(marker) else { return nil }
            }
        }
        // The tools/list answer already arrived above; the exact count does
        // not matter to the pane, only that the server answered.
        return 14
    }
}
#endif
