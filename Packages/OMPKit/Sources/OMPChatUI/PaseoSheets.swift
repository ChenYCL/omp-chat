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

    @State private var tasks: [ScheduledTask] = [
        ScheduledTask(name: "构建检查与测试", cron: "*/15 * * * *", desc: "每15分钟检查 main 分支构建", enabled: true),
        ScheduledTask(name: "每日代码审查总结", cron: "0 18 * * 1-5", desc: "工作日 18:00 汇总 PR 动态", enabled: true),
        ScheduledTask(name: "心跳监控 (Heartbeat)", cron: "*/30 * * * *", desc: "定时健康探测并回传状态", enabled: false)
    ]

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($tasks) { $task in
                        HStack(spacing: 12) {
                            Image(systemName: task.enabled ? "clock.fill" : "clock")
                                .font(.system(size: 16))
                                .foregroundStyle(task.enabled ? Color.accentColor : Color.ompTextTertiary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.name)
                                    .font(.system(size: 14, weight: .medium))
                                Text(task.desc)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.ompTextSecondary)
                                Text("Cron: \(task.cron)")
                                    .font(.system(size: 10.5).monospaced())
                                    .foregroundStyle(Color.ompTextTertiary)
                            }
                            Spacer()
                            Toggle("", isOn: $task.enabled)
                                .labelsHidden()
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("定时任务 (Schedules & Heartbeats)")
                } footer: {
                    Text("Paseo 守护进程在后台自动调度这些任务，不需要保持前台。")
                        .font(.caption2)
                }
            }
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
        .frame(minWidth: 500, minHeight: 400)
        #endif
    }

    struct ScheduledTask: Identifiable {
        let id = UUID()
        var name: String
        var cron: String
        var desc: String
        var enabled: Bool
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
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if session.isConnected {
                    Section("已配对") {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.ompTextSecondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.hostName.isEmpty ? "Mac" : session.hostName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.ompText)
                                Text(session.mode.rawValue)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.ompTextTertiary)
                            }
                            Spacer()
                            Text("在线")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有配对的设备")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.ompText)
                            Text("到「远程」页配对一台 Mac 后，它会出现在这里。")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.ompTextSecondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("可控设备")
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
}
#endif
// MARK: - 8. Subagents Inspector Sheet (子代理管理 - Frame 15s)

public struct PaseoSubagentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var subagents: [Subagent] = [
        Subagent(name: "代码审查专家", role: "P7 Senior Reviewer", status: "运行中", elapsed: "14.2s", tokens: "2.1k", task: "审查当前分支与 main 的安全风险与内存管理"),
        Subagent(name: "接口契约审计", role: "API Validator", status: "已完成", elapsed: "4.8s", tokens: "840", task: "校验 OpenAPI 契约与前端模型字段一致性"),
        Subagent(name: "单元测试执行员", role: "Test Runner", status: "已完成", elapsed: "2.1s", tokens: "320", task: "运行 OMPCore 与 OMPChatUI 全套测试"),
        Subagent(name: "前端组件比对", role: "UI Inspector", status: "等待指令", elapsed: "0.9s", tokens: "180", task: "分析截图与参考稿的边距与字体规范"),
    ]

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($subagents) { $agent in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle()
                                    .fill(statusColor(agent.status))
                                    .frame(width: 7, height: 7)
                                Text(agent.name)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(agent.role)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.ompTextTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.ompFill, in: Capsule())
                                Spacer()
                                Text(agent.status)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(statusColor(agent.status))
                            }

                            Text(agent.task)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ompTextSecondary)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                Label(agent.elapsed, systemImage: "clock")
                                Label("\(agent.tokens) tok", systemImage: "number")
                                Spacer()
                                Button {
                                    if agent.status == "运行中" {
                                        agent.status = "已暂停"
                                    } else if agent.status == "已暂停" {
                                        agent.status = "运行中"
                                    }
                                } label: {
                                    Text(agent.status == "运行中" ? "暂停" : "继续")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Color.ompTextTertiary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("活跃子代理 (Spawned Subagents · 4)")
                } footer: {
                    Text("Paseo 代理编排框架支持将复杂任务分解为独立的子代理并发推进。")
                        .font(.caption2)
                }
            }
            .navigationTitle("子代理管理 (Agents)")
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
        .frame(minWidth: 540, minHeight: 440)
        #endif
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "运行中": .green
        case "已完成": .blue
        case "已暂停": .orange
        default: Color.ompTextTertiary
        }
    }

    struct Subagent: Identifiable {
        let id = UUID()
        var name: String
        var role: String
        var status: String
        var elapsed: String
        var tokens: String
        var task: String
    }
}

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
