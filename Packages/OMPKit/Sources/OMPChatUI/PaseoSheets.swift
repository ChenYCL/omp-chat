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
    @State private var renamingProject: Project?
    @State private var renameText = ""
    @State private var renamingSection: Project?
    @State private var sectionRenameText = ""
    @State private var showingNewSection = false
    @State private var newSectionName = ""

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
                            // The chats inside, so a project is not just a name
                            // with a count; tap one to open it.
                            let chats = model.conversations(in: project.id).filter { !$0.isArchived }
                            if chats.isEmpty {
                                Text("这个项目还没有会话")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.ompTextTertiary)
                            } else {
                                ForEach(chats.prefix(5)) { chat in
                                    Text("· \(chat.title)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.ompTextSecondary)
                                        .lineLimit(1)
                                }
                                if chats.count > 5 {
                                    Text("还有 \(chats.count - 5) 条")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.ompTextTertiary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                renameText = project.name
                                renamingProject = project
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            model.deleteProject(model.projects[index].id)
                        }
                    }
                }
                // Custom sections group chats the way the desktop sidebar does;
                // the phone could not see or create them.
                Section {
                    if model.orderedCustomSections.isEmpty {
                        Text("还没有自定义分区")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    ForEach(model.orderedCustomSections) { section in
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up")
                                .foregroundStyle(Color.accentColor)
                            Text(section.name)
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text("\(model.conversations(inCustomSection: section.id).count) 会话")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Color.ompTextTertiary)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button {
                                sectionRenameText = section.name
                                renamingSection = section
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                model.deleteCustomSection(section.id)
                            } label: {
                                Label("删除分区", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            model.deleteCustomSection(model.orderedCustomSections[index].id)
                        }
                    }
                } header: {
                    Text("自定义分区")
                } footer: {
                    Text("分区挂在会话上，用来把不同类型的对话分开；桌面侧栏与这里同步。")
                        .font(.caption2)
                }

                #if os(iOS)
                if session.isConnected {
                    Section("已连接的主机") {
                        hostRow
                    }
                }
                #endif
            }

            .alert("重命名项目", isPresented: Binding(
                get: { renamingProject != nil },
                set: { if !$0 { renamingProject = nil } }
            )) {
                TextField("项目名称", text: $renameText)
                Button("保存") {
                    if let project = renamingProject {
                        model.renameProject(project.id, name: renameText)
                    }
                    renamingProject = nil
                }
                Button("取消", role: .cancel) { renamingProject = nil }
            }
            .navigationTitle("项目与工作区")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                // Two plain buttons rather than a Menu: a menu's items are not
                // reliably addressable from the toolbar, and this is one tap
                // either way.
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showingNewSection = true } label: {
                        Image(systemName: "square.stack.3d.up")
                    }
                    .accessibilityLabel("新建自定义分区")
                    Button { showingNewProject = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建项目")
                }
            }
            .alert("新建自定义分区", isPresented: $showingNewSection) {
                TextField("分区名称", text: $newSectionName)
                Button("取消", role: .cancel) { newSectionName = "" }
                Button("创建") {
                    if !newSectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = model.createCustomSection(name: newSectionName)
                        newSectionName = ""
                    }
                }
            }
            .alert("重命名分区", isPresented: Binding(
                get: { renamingSection != nil },
                set: { if !$0 { renamingSection = nil } }
            )) {
                TextField("分区名称", text: $sectionRenameText)
                Button("保存") {
                    if let section = renamingSection {
                        model.renameCustomSection(section.id, name: sectionRenameText)
                    }
                    renamingSection = nil
                }
                Button("取消", role: .cancel) { renamingSection = nil }
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

// The scheduled-tasks page was removed: a sandboxed Mac app cannot read
// the user's crontab (`crontab -l` is denied, and the spool file is root-only),
// and the page was showing invented tasks. See commit 53d9581.

// MARK: - 3. Usage Sheet (用量)

public struct PaseoUsageSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        let usage = UsageSummary(conversations: model.conversations)
        NavigationStack {
            List {
                Section("总体统计") {
                    statRow(title: "总会话数", value: "\(model.conversations.count)")
                    statRow(title: "总消息数", value: "\(totalMessages)")
                    statRow(title: "请求次数", value: "\(usage.all.requests)")
                    statRow(title: "输入 Token (Prompt)", value: TokenFormat.compact(usage.all.inputTokens))
                    statRow(title: "输出 Token (Completion)", value: TokenFormat.compact(usage.all.outputTokens))
                    statRow(title: "其中推理", value: TokenFormat.compact(usage.all.reasoningTokens))
                    statRow(title: "累计消耗 Token", value: TokenFormat.compact(usage.all.totalTokens))
                }

                Section("近期") {
                    statRow(title: "最近 7 天", value: TokenFormat.compact(usage.last7Days.totalTokens))
                    statRow(title: "最近 30 天", value: TokenFormat.compact(usage.last30Days.totalTokens))
                }

                Section {
                    ForEach(usage.byModel) { group in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(modelName(group.modelID))
                                    .font(.system(size: 13.5, weight: .medium))
                                Text("\(group.conversations) 个会话 · \(group.totals.requests) 次请求")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.ompTextTertiary)
                            }
                            Spacer()
                            Text(TokenFormat.compact(group.totals.totalTokens))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Color.ompTextSecondary)
                        }
                    }
                } header: {
                    Text("按对话模型")
                } footer: {
                    Text("消息不记录生成它的模型，这里按每个对话当前的模型归类。合计 = 输入 + 输出，推理已含在输出里；已归档和临时对话也计入。")
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

    private func modelName(_ modelID: String?) -> String {
        guard let modelID else { return "默认模型" }
        return model.models.first { $0.id == modelID }?.displayName ?? modelID
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
        ConversationSearch.filter(model.sortedConversations, query: query)
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

/// Archived chats: hidden from Recents and search, reachable only here, and
/// restorable. The desktop has an 已归档 section; this is the phone's way in.
public struct PaseoArchivedSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onSelect: (UUID) -> Void

    @State private var query = ""

    public init(onSelect: @escaping (UUID) -> Void) {
        self.onSelect = onSelect
    }

    private var items: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.archivedConversations }
        return model.archivedConversations.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.lastMessagePreview.localizedCaseInsensitiveContains(q)
        }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.archivedConversations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.ompTextTertiary)
                        Text("没有已归档的会话")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.ompTextSecondary)
                        Text("在会话菜单里选「归档」，它会移到这。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(items) { conv in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conv.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.ompText)
                                    .lineLimit(1)
                                Text(conv.lastMessagePreview)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.ompTextSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(conv.id)
                                dismiss()
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.deleteConversation(conv.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    model.toggleArchive(conv.id)
                                } label: {
                                    Label("取消归档", systemImage: "tray.and.arrow.up")
                                }
                                .tint(.green)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.ompCanvas)
            .searchable(text: $query, prompt: "搜索已归档会话")
            .navigationTitle("已归档")
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
        .frame(minWidth: 480, minHeight: 380)
        #endif
    }
}

// MARK: - 5. Tools sheet (本对话可用的工具)

/// What the next request of the selected thread offers the model: the
/// built-in tools and every connected MCP server's, grouped by source, with
/// the risk that decides whether a call asks first.
public struct MCPPluginsSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var specs: [AgentToolSpec] = []
    @State private var loaded = false
    public init() {}

    private var conversationID: UUID? { model.selectedConversationID }

    private var toolsOn: Bool {
        conversationID.map(model.toolsEnabled(for:)) ?? false
    }

    /// Built-in tools first, then MCP servers and skills by name.
    private var groups: [(source: String, tools: [AgentToolSpec])] {
        Dictionary(grouping: specs, by: \.source)
            .map { (source: $0.key, tools: $0.value) }
            .sorted { lhs, rhs in
                let lhsBuiltin = lhs.source == "内置", rhsBuiltin = rhs.source == "内置"
                return lhsBuiltin != rhsBuiltin ? lhsBuiltin : lhs.source < rhs.source
            }
    }

    /// Reload when the thread, the providers or an MCP server's tools change.
    private var reloadKey: String {
        var key = "\(conversationID?.uuidString ?? "-")-\(model.toolProvidersRevision)-\(toolsOn)"
        #if os(macOS)
        key += "-\(model.mcp.tools.values.reduce(0) { $0 + $1.count })"
        #endif
        return key
    }

    public var body: some View {
        NavigationStack {
            List {
                if let id = conversationID {
                    Section {
                        HStack {
                            Text("权限")
                            Spacer()
                            Text(toolsOn ? model.permissionMode(for: id).title : "仅聊天")
                                .foregroundStyle(Color.ompTextSecondary)
                        }
                    } footer: {
                        Text(toolsOn
                             ? "旁边写的是工具的默认风险：读取直接运行，其余按权限决定是否先问你。读写工作目录以外的路径按运行命令处理。"
                             : "这个对话没有开工具。在输入栏的「工具与权限」菜单里打开；绑定了工作目录的对话默认开启。")
                    }
                }
                if toolsOn, loaded, specs.isEmpty {
                    Section { Text("没有可用的工具").foregroundStyle(Color.ompTextSecondary) }
                }
                ForEach(groups, id: \.source) { group in
                    Section(group.source) {
                        ForEach(group.tools, id: \.name) { spec in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(spec.name)
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(spec.risk.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.ompTextSecondary)
                                }
                                if !spec.description.isEmpty {
                                    Text(spec.description)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.ompTextTertiary)
                                        .lineLimit(2)
                                }
                            }
                            .accessibilityIdentifier("tools.spec.\(spec.name)")
                        }
                    }
                }
                #if os(macOS)
                Section("MCP 服务器") {
                    if model.mcp.servers.isEmpty {
                        Text("还没有添加 MCP 服务器").foregroundStyle(Color.ompTextSecondary)
                    }
                    ForEach(model.mcp.servers) { server in
                        let status = model.mcp.status(of: server.id)
                        HStack(spacing: 6) {
                            Circle().fill(MCPSettingsPane.color(of: status)).frame(width: 7, height: 7)
                            Text(server.name)
                            Spacer()
                            Text(MCPSettingsPane.statusText(status))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.ompTextSecondary)
                                .lineLimit(1)
                        }
                    }
                    Button("管理 MCP 服务器…") {
                        model.requestedSettingsSection = "mcp"
                        model.showSettings = true
                        dismiss()
                    }
                    .accessibilityIdentifier("tools.manageMCP")
                }
                #else
                Section {
                    Text("工具在 Mac 上运行，手机上的对话不调用工具。")
                        .foregroundStyle(Color.ompTextSecondary)
                }
                #endif
            }
            .task(id: reloadKey) {
                guard let id = conversationID else { specs = []; loaded = true; return }
                specs = await model.offeredToolSpecs(for: id)
                loaded = true
            }
            .navigationTitle("本对话可用的工具")
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
        .frame(minWidth: 460, minHeight: 420)
        #endif
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
private func ConversationRow_relativeTime(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    switch seconds {
    case ..<60: return "刚刚"
    case ..<3600: return "\(Int(seconds / 60)) 分钟前"
    case ..<86400: return "\(Int(seconds / 3600)) 小时前"
    default: return "\(Int(seconds / 86400)) 天前"
    }
}
