import SwiftUI
import OMPCore
import OMPDesign

// MARK: - 1. Projects Sheet (项目)

public struct PaseoProjectsSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showingNewProject = false
    @State private var newProjectName = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("活跃项目") {
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

                Section("工作区 (Workspaces)") {
                    workspaceRow(name: "ai-command-center", branch: "main", host: "Mac mini", status: "活跃")
                    workspaceRow(name: "omp-chat", branch: "feature/paseo", host: "Mac mini", status: "就绪")
                    workspaceRow(name: "polymarket-research", branch: "master", host: "macbook", status: "就绪")
                }
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

    private func workspaceRow(name: String, branch: String, host: String, status: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "macmini")
                .font(.system(size: 14))
                .foregroundStyle(Color.ompTextSecondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13.5, weight: .medium))
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
                Text("主机: \(host)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
            }
            Spacer()
            Text(status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1), in: Capsule())
        }
        .padding(.vertical, 4)
    }
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

private func ConversationRow_relativeTime(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    switch seconds {
    case ..<60: return "刚刚"
    case ..<3600: return "\(Int(seconds / 60)) 分钟前"
    case ..<86400: return "\(Int(seconds / 3600)) 小时前"
    default: return "\(Int(seconds / 86400)) 天前"
    }
}
