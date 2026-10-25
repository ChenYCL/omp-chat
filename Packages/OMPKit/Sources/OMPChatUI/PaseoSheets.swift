import SwiftUI
import OMPCore
import OMPDesign

// MARK: - 1. Projects Sheet (项目)

public struct PaseoProjectsSheet: View {
    @Environment(ChatAppModel.self) private var model
    #if os(iOS)
    @Environment(RemoteSession.self) private var session
    #endif
    @Environment(\.dismiss) private var dismiss

    @State private var showingNewProject = false
    @State private var newProjectName = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("活跃项目") {
                    if model.projects.isEmpty {
                        Text("还没有项目")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    ForEach(model.projects) { project in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(project.name)
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text("\(model.conversations(in: project.id).count) 会话")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Color.ompTextTertiary)
                            }
                            Text("创建于 \(project.createdAt, format: .dateTime.month().day())")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.ompTextSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            model.deleteProject(model.projects[index].id)
                        }
                    }
                }
                #if os(iOS)
                if session.isConnected {
                    Section("已连接的主机") {
                        hostRow
                    }
                }
                #endif
            }

            .navigationTitle("项目与工作区")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewProject = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("新建项目", isPresented: $showingNewProject) {
                TextField("项目名称", text: $newProjectName)
                Button("取消", role: .cancel) { newProjectName = "" }
                Button("创建") {
                    if !newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = model.createProject(name: newProjectName)
                        newProjectName = ""
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #endif
    }

    #if os(iOS)
    /// The paired Mac, from the live session — never a hardcoded workspace.
    private var hostRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 14))
                .foregroundStyle(Color.ompTextSecondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.info?.cwd.split(separator: "/").last.map(String.init) ?? (session.hostName.isEmpty ? "Mac" : session.hostName))
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    if let branch = session.info?.gitBranch, !branch.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8))
                            Text(branch)
                                .font(.system(size: 10).monospaced())
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.ompFill, in: Capsule())
                    }
                }
                Text(session.hostName.isEmpty ? session.mode.rawValue : "\(session.hostName) · \(session.mode.rawValue)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text("已连接")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1), in: Capsule())
        }
        .padding(.vertical, 4)
    }
    #endif
}

// MARK: - 2. Scheduled Tasks Sheet (计划任务)

public struct PaseoScheduledTasksSheet: View {
    @Environment(\.dismiss) private var dismiss
    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.ompTextTertiary)
                Text("定时任务暂不可用")
                    .font(.system(size: 15, weight: .semibold))
                Text("Mac 开了沙盒后读不到 crontab：`crontab -l` 被系统拒绝，任务文件只有 root 能读，沙盒例外也绕不过去。这里不再显示编造的任务。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("计划任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }
}

// MARK: - 3. Usage Sheet (用量)

public struct PaseoUsageSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("总体统计") {
                    statRow(title: "总会话数", value: "\(model.conversations.count)")
                    statRow(title: "总消息数", value: "\(totalMessages)")
                    statRow(title: "输入 Token (Prompt)", value: TokenFormat.compact(totalInputTokens))
                    statRow(title: "输出 Token (Completion)", value: TokenFormat.compact(totalOutputTokens))
                    statRow(title: "累计消耗 Token", value: TokenFormat.compact(totalTokens))
                }

                Section("模型使用分布") {
                    ForEach(model.models) { descriptor in
                        let count = model.conversations.filter { $0.modelID == descriptor.id }.count
                        if count > 0 {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(descriptor.displayName)
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("上下文上限: \(descriptor.limits.contextWindow.map { TokenFormat.compact($0) } ?? "未知")")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.ompTextTertiary)
                                }
                                Spacer()
                                Text("\(count) 个会话")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(Color.ompTextSecondary)
                            }
                        }
                    }
                }

                Section("当前连接网关") {
                    if let provider = model.activeProvider {
                        statRow(title: "供应商", value: provider.name)
                        statRow(title: "服务地址", value: provider.baseURL.host ?? "localhost")
                        statRow(title: "同步模型数", value: "\(model.models.filter { $0.providerID == provider.id }.count)")
                    }
                }
            }
            .navigationTitle("用量统计")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 450)
        #endif
    }

    private var totalMessages: Int {
        model.conversations.reduce(0) { $0 + $1.messages.count }
    }

    private var totalInputTokens: Int {
        model.conversations.reduce(0) { sum, conv in
            sum + conv.messages.compactMap(\.usage).reduce(0) { $0 + $1.inputTokens }
        }
    }

    private var totalOutputTokens: Int {
        model.conversations.reduce(0) { sum, conv in
            sum + conv.messages.compactMap(\.usage).reduce(0) { $0 + $1.outputTokens }
        }
    }

    private var totalTokens: Int {
        totalInputTokens + totalOutputTokens
    }

    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13.5))
            Spacer()
            Text(value)
                .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.ompText)
        }
    }
}

// MARK: - 4. Session History Sheet (会话历史)

public struct PaseoSessionHistorySheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    let onSelectConversation: (UUID) -> Void

    public init(onSelectConversation: @escaping (UUID) -> Void) {
        self.onSelectConversation = onSelectConversation
    }

    private var filtered: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return model.sortedConversations }
        return model.sortedConversations.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.lastMessagePreview.localizedCaseInsensitiveContains(q)
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { conv in
                    Button {
                        onSelectConversation(conv.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(conv.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.ompText)
                                    .lineLimit(1)
                                Spacer()
                                Text(ConversationRow_relativeTime(conv.updatedAt))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Color.ompTextTertiary)
                            }
                            Text(conv.lastMessagePreview)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ompTextSecondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "搜索历史会话")
            .navigationTitle("会话历史")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 450)
        #endif
    }
}

// MARK: - 5. MCP Plugins Sheet (插件与工具)

public struct MCPPluginsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var plugins: [PluginItem] = [
        PluginItem(name: "ccload-image", category: "生图与修改", desc: "OpenAI 兼容画图与图像编辑接口", icon: "photo", enabled: true),
        PluginItem(name: "local-terminal", category: "本地终端执行", desc: "在受控沙盒中运行 zsh 命令", icon: "terminal", enabled: true),
        PluginItem(name: "workspace-filesystem", category: "文件系统", desc: "读取和修改当前工作区文件树", icon: "folder", enabled: true),
        PluginItem(name: "web-search", category: "联网搜索", desc: "实时抓取互联网最新公开资料与网页", icon: "globe", enabled: true),
        PluginItem(name: "semgrep-security", category: "代码安全审计", desc: "静态安全分析与漏洞规则检查", icon: "shield.checkerboard", enabled: false),
    ]

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($plugins) { $plugin in
                        HStack(spacing: 12) {
                            Image(systemName: plugin.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(plugin.enabled ? Color.accentColor : Color.ompTextTertiary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(plugin.name)
                                        .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                                    Text(plugin.category)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.ompTextTertiary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.ompFill, in: Capsule())
                                }
                                Text(plugin.desc)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.ompTextSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: $plugin.enabled)
                                .labelsHidden()
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("已挂载的 MCP 服务器 (Connected MCP Tools)")
                } footer: {
                    Text("通过 Model Context Protocol (MCP) 扩展助手能力。开启后工具定义将自动注入到提示词中。")
                        .font(.caption2)
                }
            }
            .navigationTitle("MCP 扩展与工具")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    struct PluginItem: Identifiable {
        let id = UUID()
        var name: String
        var category: String
        var desc: String
        var icon: String
        var enabled: Bool
    }
}


#if os(iOS)

/// The only device the phone can actually reach is the paired Mac, so the
/// sheet shows that one host — or says plainly that nothing is paired.
public struct PaseoDevicesSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    public init() {}

    private var devices: [PairedDevice] { model.settings.pairedDevices }

    /// Live answers from `DeviceReachability`; a device without an entry has
    /// not been probed yet and shows no dot.
    @State private var reachability: [UUID: DeviceReachability] = [:]

    public var body: some View {
        NavigationStack {
            List {
                if devices.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有配对的设备")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.ompText)
                            Text("到「远程」页配对一台 Mac 后，它会出现在这里，之后可以一键切换。")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.ompTextSecondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section {
                        ForEach(devices) { device in
                            row(device)
                        }
                        .onDelete(perform: forget)
                    } header: {
                        Text("我的 Mac")
                    } footer: {
                        Text("点一台即可切换并重新连接；下拉刷新在线状态，左滑可忘记设备。令牌只保存在这部手机的保管库里。")
                    }
                }
            }
            .navigationTitle("可控设备")
            // Re-probe while the sheet is open, so a Mac that wakes up or goes
            // to sleep flips its dot without a manual pull. The task ends with
            // the sheet, so nothing polls in the background.
            .task(id: devices.map(\.id)) {
                await probe()
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.refreshInterval)
                    guard !Task.isCancelled else { return }
                    await probe(showSpinner: false)
                }
            }
            .refreshable { await probe() }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }

    private func row(_ device: PairedDevice) -> some View {
        let active = session.isConnected && session.activeDeviceID == device.id
        return Button {
            guard !active else { dismiss(); return }
            session.requestedDevice = device
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name.isEmpty ? "Mac" : device.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ompText)
                    Text(device.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                    if case .offline(let reason) = reachability[device.id], !active {
                        Text("离线 · \(reason)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ompTextTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                statusDot(for: device)
                if active {
                    Text("已连接")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextTertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("device.\(device.id.uuidString)")
    }

    @ViewBuilder
    private func statusDot(for device: PairedDevice) -> some View {
        switch reachability[device.id] {
        case .checking:
            ProgressView().controlSize(.mini)
        case .online:
            Circle().fill(Color.green).frame(width: 7, height: 7)
                .accessibilityLabel("在线")
        case .offline:
            Circle().fill(Color.ompTextTertiary.opacity(0.5)).frame(width: 7, height: 7)
                .accessibilityLabel("离线")
        case nil:
            EmptyView()
        }
    }

    static let refreshInterval: Duration = .seconds(15)

    /// `showSpinner: false` keeps the previous dot until the new answer lands,
    /// so the periodic refresh does not flicker every row to a spinner.
    private func probe(showSpinner: Bool = true) async {
        let current = devices
        if showSpinner {
            for device in current { reachability[device.id] = .checking }
        }
        await DeviceReachability.check(current) { id, state in
            await MainActor.run { reachability[id] = state }
        }
    }

    private func forget(at offsets: IndexSet) {
        var settings = model.settings
        settings.pairedDevices.remove(atOffsets: offsets)
        Task { await model.saveSettings(settings) }
    }
}
#endif
// MARK: - 9. File Viewer Sheet (文件查看器)

public struct IdentifiableURL: Identifiable {
    public let id = UUID()
    public let url: URL
    public init(url: URL) { self.url = url }
}

public struct FileViewerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var copied = false

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.ompText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            }
            .background(Color.ompCanvas)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                        let lines = content.split(separator: "\n").count
                        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? content.utf8.count
                        Text("\(lines) 行 · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyToPasteboard(content)
                        AudioFeedback.playSend(enabled: true)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            .task {
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? "(无法读取文件内容或为二进制文件)"
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 450)
        #endif
    }
}




private func ConversationRow_relativeTime(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    switch seconds {
    case ..<60: return "刚刚"
    case ..<3600: return "\(Int(seconds / 60)) 分钟前"
    case ..<86400: return "\(Int(seconds / 3600)) 小时前"
    default: return "\(Int(seconds / 86400)) 天前"
    }
}
