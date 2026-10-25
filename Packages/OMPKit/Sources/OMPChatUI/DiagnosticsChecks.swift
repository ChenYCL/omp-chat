import Foundation
import OMPCore

/// Inputs a check needs that only the app model knows. Everything else is
/// probed directly so a check never reports a value it did not measure.
public struct DiagnosticsContext: Sendable {
    public var providers: [ProviderProfile]
    /// Provider id → API key. Keys are used only to build the probe request
    /// and are never copied into a result.
    public var apiKeys: [UUID: String]
    public var storeDirectory: URL?
    public var relayEnabled: Bool
    public var relayPort: UInt16
    public var relayListening: Bool
    public var relayToken: String
    public var relayRoomCode: String
    public var relayHubURL: String
    public var relayAllowShell: Bool
    /// iOS: whether a pairing is currently up.
    /// iOS paired-host probe. Production runs a real `info` RPC; tests inject
    /// a stand-in. `nil` means there is no pairing to probe.
    public var pairedHostProbe: (@Sendable () async -> Bool)?
    public var pairedHostReachable: Bool?
    /// iOS: age in seconds of the last mirrored snapshot, when known.
    public var lastSnapshotAge: TimeInterval?
    public var transport: HTTPTransport

    public init(
        providers: [ProviderProfile],
        apiKeys: [UUID: String],
        storeDirectory: URL?,
        relayEnabled: Bool,
        relayPort: UInt16,
        relayListening: Bool,
        relayToken: String,
        relayRoomCode: String,
        relayHubURL: String,
        relayAllowShell: Bool,
        pairedHostReachable: Bool? = nil,
        lastSnapshotAge: TimeInterval? = nil,
        transport: HTTPTransport
    ) {
        self.providers = providers
        self.apiKeys = apiKeys
        self.storeDirectory = storeDirectory
        /// iOS paired-host probe. Production does a real `info` RPC; tests inject
        /// a stand-in. `nil` means there is no pairing to probe.
        self.pairedHostProbe = nil
        self.relayEnabled = relayEnabled
        self.relayPort = relayPort
        self.relayListening = relayListening
        self.relayToken = relayToken
        self.relayRoomCode = relayRoomCode
        self.relayHubURL = relayHubURL
        self.relayAllowShell = relayAllowShell
        self.pairedHostReachable = pairedHostReachable
        self.lastSnapshotAge = lastSnapshotAge
        self.transport = transport
    }
}

/// The health checks behind the 诊断 screen and `GET /debug/report`.
///
/// Every check either performs a real probe or returns `skip` with the reason
/// it could not run. No value is invented.
public enum DiagnosticsChecks {
    public static func runAll(_ context: DiagnosticsContext) async -> [DiagnosticsCheckResult] {
        var results: [DiagnosticsCheckResult] = []
        results.append(await providerRoundTrip(context))
        results.append(workspaceDecodes(context))
        results.append(storeWritable(context))
        results.append(await relayListening(context))
        results.append(relayCredentials(context))

        results.append(await hubReachable(context))
        results.append(shellAccess(context))
        results.append(homeDirectory())
        results.append(loginShellGit())
        results.append(await pairedHost(context))
        results.append(snapshotFreshness(context))
        return results
    }

    // MARK: - Provider

    /// Confirms a provider is configured and measures a real `/v1/models`
    /// (or the profile's models path) round trip.
    public static func providerRoundTrip(_ context: DiagnosticsContext) async -> DiagnosticsCheckResult {
        guard let provider = context.providers.first else {
            return DiagnosticsCheckResult(
                id: "provider", title: "供应商", status: .fail,
                detail: "还没有配置任何供应商", hint: "在「设置 → 连接」里添加一个供应商")
        }
        let key = context.apiKeys[provider.id] ?? ""
        guard !key.isEmpty else {
            return DiagnosticsCheckResult(
                id: "provider", title: "供应商", status: .fail,
                detail: "「\(provider.name)」没有 API Key", hint: "在供应商编辑页填入 API Key")
        }
        let url = provider.resolvedURL(path: provider.modelsPath)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        for (name, value) in provider.extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let started = Date()
        do {
            let response = try await context.transport.send(request)
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            guard (200..<300).contains(response.statusCode) else {
                return DiagnosticsCheckResult(
                    id: "provider", title: "供应商", status: .fail,
                    detail: "\(url.host ?? url.absoluteString) 返回 HTTP \(response.statusCode)（\(millis) ms）",
                    hint: "核对 Base URL 和 API Key")
            }
            return DiagnosticsCheckResult(
                id: "provider", title: "供应商", status: .ok,
                detail: "\(provider.name) · \(url.host ?? "") \(provider.modelsPath) 往返 \(millis) ms")
        } catch {
            return DiagnosticsCheckResult(
                id: "provider", title: "供应商", status: .fail,
                detail: "请求 \(url.host ?? url.absoluteString) 失败：\(error.localizedDescription)",
                hint: "检查网络和 Base URL")
        }
    }

    // MARK: - Workspace

    /// Decodes the workspace document from disk exactly as the store does.
    public static func workspaceDecodes(_ context: DiagnosticsContext) -> DiagnosticsCheckResult {
        guard let directory = context.storeDirectory else {
            return DiagnosticsCheckResult(
                id: "workspace", title: "工作区文档", status: .skip,
                detail: "当前存储不是文件存储，无法从磁盘解码")
        }
        let file = directory.appendingPathComponent("workspace.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return DiagnosticsCheckResult(
                id: "workspace", title: "工作区文档", status: .warn,
                detail: "还没有 workspace.json（首次启动前正常）", hint: "打开一次应用以创建工作区")
        }
        do {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode(WorkspaceDocumentProbe.self, from: data)
            return DiagnosticsCheckResult(
                id: "workspace", title: "工作区文档", status: .ok,
                detail: "workspace.json 可解码（\(data.count) 字节）")
        } catch {
            return DiagnosticsCheckResult(
                id: "workspace", title: "工作区文档", status: .fail,
                detail: "解码失败：\(error.localizedDescription)",
                hint: "查看同目录下的 workspace.corrupt-*.json 备份")
        }
    }

    /// Minimal mirror of the on-disk document: only the keys the store writes,
    /// all optional so older documents still decode.
    private struct WorkspaceDocumentProbe: Decodable {
        var conversations: [Conversation]?
        var providers: [ProviderProfile]?
        var settings: AppSettings?
        var projects: [Project]?
    }

    /// Confirms the store directory is writable and reports free disk space.
    public static func storeWritable(_ context: DiagnosticsContext) -> DiagnosticsCheckResult {
        guard let directory = context.storeDirectory else {
            return DiagnosticsCheckResult(
                id: "store", title: "存储目录", status: .skip,
                detail: "当前存储不是文件存储")
        }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".diagnostics-write-probe")
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try manager.removeItem(at: probe)
        } catch {
            return DiagnosticsCheckResult(
                id: "store", title: "存储目录", status: .fail,
                detail: "目录不可写：\(error.localizedDescription)", hint: "检查磁盘权限和剩余空间")
        }
        let free = (try? manager.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value
        guard let free else {
            return DiagnosticsCheckResult(
                id: "store", title: "存储目录", status: .warn,
                detail: "目录可写，但读不到剩余空间")
        }
        let gigabytes = Double(free) / 1_073_741_824
        let status: DiagnosticsStatus = gigabytes < 1 ? .warn : .ok
        return DiagnosticsCheckResult(
            id: "store", title: "存储目录", status: status,
            detail: String(format: "可写，剩余 %.1f GB", gigabytes),
            hint: status == .warn ? "磁盘空间不足 1 GB" : "")
    }

    // MARK: - Relay

    /// Connects to 127.0.0.1 on the configured port; the TCP handshake itself
    /// is the probe, so this does not depend on the token.
    public static func relayListening(_ context: DiagnosticsContext) async -> DiagnosticsCheckResult {
        guard context.relayEnabled else {
            return DiagnosticsCheckResult(
                id: "relay-listen", title: "中继监听", status: .skip,
                detail: "远程控制未开启")
        }
        let port = context.relayPort
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        request.timeoutInterval = 3
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return DiagnosticsCheckResult(
                id: "relay-listen", title: "中继监听", status: .ok,
                detail: "127.0.0.1:\(port) 有响应（HTTP \(code)）")
        } catch {
            let detail = context.relayListening
                ? "端口 \(port) 连接失败：\(error.localizedDescription)"
                : "已开启但端口 \(port) 没有在监听"
            return DiagnosticsCheckResult(
                id: "relay-listen", title: "中继监听", status: .fail,
                detail: detail, hint: "在「设置 → 远程控制」里重新开启，或换一个端口")
        }
    }

    /// Reports whether a pairing token and (when hub mode is on) a room code
    /// exist. Values are masked.
    public static func relayCredentials(_ context: DiagnosticsContext) -> DiagnosticsCheckResult {
        guard context.relayEnabled else {
            return DiagnosticsCheckResult(
                id: "relay-credentials", title: "配对凭据", status: .skip,
                detail: "远程控制未开启")
        }
        guard !context.relayToken.isEmpty else {
            return DiagnosticsCheckResult(
                id: "relay-credentials", title: "配对凭据", status: .fail,
                detail: "没有配对码", hint: "重新开启远程控制以生成配对码")
        }
        var detail = "配对码 \(DiagnosticsMask.hint(context.relayToken))"
        if !context.relayHubURL.isEmpty {
            if context.relayRoomCode.isEmpty {
                return DiagnosticsCheckResult(
                    id: "relay-credentials", title: "配对凭据", status: .fail,
                    detail: detail + "；已配置中继但没有房间码", hint: "在远程控制里生成房间码")
            }
            detail += "；房间码 \(DiagnosticsMask.hint(context.relayRoomCode))"
        }
        return DiagnosticsCheckResult(
            id: "relay-credentials", title: "配对凭据", status: .ok, detail: detail)
    }

    /// GETs the hub base URL when one is configured.
    public static func hubReachable(_ context: DiagnosticsContext) async -> DiagnosticsCheckResult {
        let raw = context.relayHubURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            return DiagnosticsCheckResult(
                id: "hub", title: "公网中继", status: .skip,
                detail: "没有配置中继地址（仅局域网模式）")
        }
        guard let url = URL(string: raw), url.scheme != nil else {
            return DiagnosticsCheckResult(
                id: "hub", title: "公网中继", status: .fail,
                detail: "中继地址不是合法 URL", hint: "在「设置 → 远程控制」里修正中继地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpMethod = "GET"
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            guard (200..<500).contains(code) else {
                return DiagnosticsCheckResult(
                    id: "hub", title: "公网中继", status: .fail,
                    detail: "\(url.host ?? raw) 返回 HTTP \(code)", hint: "确认中继进程在运行")
            }
            return DiagnosticsCheckResult(
                id: "hub", title: "公网中继", status: .ok,
                detail: "\(url.host ?? raw) 可达（HTTP \(code)，\(millis) ms）")
        } catch {
            return DiagnosticsCheckResult(
                id: "hub", title: "公网中继", status: .fail,
                detail: "连不上 \(url.host ?? raw)：\(error.localizedDescription)",
                hint: "确认中继地址和网络")
        }
    }

    public static func shellAccess(_ context: DiagnosticsContext) -> DiagnosticsCheckResult {
        DiagnosticsCheckResult(
            id: "shell-access", title: "手机访问文件与终端",
            status: context.relayAllowShell ? .ok : .warn,
            detail: context.relayAllowShell ? "已允许" : "未允许（默认）",
            hint: context.relayAllowShell ? "" : "如需手机端文件和终端，在「设置 → 远程控制」里打开")
    }

    // MARK: - macOS only

    /// Compares the process home directory with the real user home from the
    /// `HOME` environment the app was launched with. Inside the sandbox they
    /// differ.
    public static func homeDirectory() -> DiagnosticsCheckResult {
        #if os(macOS)
        let container = FileManager.default.homeDirectoryForCurrentUser.path
        let real = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard !real.isEmpty else {
            return DiagnosticsCheckResult(
                id: "home", title: "用户主目录", status: .warn,
                detail: "进程没有 HOME 环境变量，无法对比")
        }
        if container == real {
            return DiagnosticsCheckResult(
                id: "home", title: "用户主目录", status: .ok,
                detail: "进程主目录即真实主目录")
        }
        return DiagnosticsCheckResult(
            id: "home", title: "用户主目录", status: .warn,
            detail: "进程运行在容器内，主目录不是真实用户主目录",
            hint: "沙盒内的 ~ 指向容器，手机端终端看到的也是它")
        #else
        return DiagnosticsCheckResult(
            id: "home", title: "用户主目录", status: .skip,
            detail: "仅 macOS 检查")
        #endif
    }

    /// Runs `git --version` through the user's login shell.
    public static func loginShellGit() -> DiagnosticsCheckResult {
        #if os(macOS)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "git --version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return DiagnosticsCheckResult(
                id: "git", title: "登录 shell 的 git", status: .fail,
                detail: "无法启动 \(shell)：\(error.localizedDescription)")
        }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !output.isEmpty else {
            return DiagnosticsCheckResult(
                id: "git", title: "登录 shell 的 git", status: .fail,
                detail: "git 不可用（退出码 \(process.terminationStatus)）",
                hint: "安装 git 或检查登录 shell 的 PATH")
        }
        return DiagnosticsCheckResult(
            id: "git", title: "登录 shell 的 git", status: .ok,
            detail: output)
        #else
        return DiagnosticsCheckResult(
            id: "git", title: "登录 shell 的 git", status: .skip,
            detail: "仅 macOS 检查")
        #endif
    }

    // MARK: - iOS only

    /// Probes the paired host with a real `info` RPC when the phone is paired.
    public static func pairedHost(_ context: DiagnosticsContext) async -> DiagnosticsCheckResult {
        if let probe = context.pairedHostProbe {
            let reachable = await probe()
            return DiagnosticsCheckResult(
                id: "paired-host", title: "已配对主机",
                status: reachable ? .ok : .fail,
                detail: reachable ? "主机 info 探活成功" : "已配对但 info 探活失败",
                hint: reachable ? "" : "确认 Mac 端远程控制仍在运行")
        }
        #if os(iOS)
        return DiagnosticsCheckResult(
            id: "paired-host", title: "已配对主机", status: .skip,
            detail: "没有可用的配对会话")
        #else
        return DiagnosticsCheckResult(
            id: "paired-host", title: "已配对主机", status: .skip,
            detail: "仅 iOS 检查")
        #endif
    }

    /// Reports how old the last mirrored snapshot is.
    public static func snapshotFreshness(_ context: DiagnosticsContext) -> DiagnosticsCheckResult {
        #if os(iOS)
        guard let age = context.lastSnapshotAge else {
            return DiagnosticsCheckResult(
                id: "snapshot-age", title: "快照新鲜度", status: .skip,
                detail: "还没有收到主机快照")
        }
        let seconds = Int(age)
        let status: DiagnosticsStatus = age > 30 ? .warn : .ok
        return DiagnosticsCheckResult(
            id: "snapshot-age", title: "快照新鲜度", status: status,
            detail: "最近一次快照在 \(seconds) 秒前",
            hint: status == .warn ? "超过 30 秒没有新快照，连接可能已中断" : "")
        #else
        return DiagnosticsCheckResult(
            id: "snapshot-age", title: "快照新鲜度", status: .skip,
            detail: "仅 iOS 检查")
        #endif
    }
}
