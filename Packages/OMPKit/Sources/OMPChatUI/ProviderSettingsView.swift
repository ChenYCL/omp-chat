import SwiftUI
import OMPCore
import OMPDesign

public struct ProviderSettingsView: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AppSettings()
    @State private var loaded = false
    @State private var editing: ProviderDraft?
    @State private var deleting: ProviderProfile?
    @State private var showingClearConfirmation = false
    @State private var section: SettingsSection = .general
    @State private var sectionQuery = ""
    @State private var archiveQuery = ""
    @State private var archiveProjectFilter: UUID? = nil

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general, personalization, appearance, voice, notifications, archived, shortcuts, sorting, dataControls, remoteControl, providers, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "常规"
            case .personalization: "个性化"
            case .appearance: "外观"
            case .voice: "语音"
            case .notifications: "通知"
            case .archived: "已归档的聊天"
            case .shortcuts: "键盘快捷键"
            case .sorting: "会话排序"
            case .dataControls: "数据控制"
            case .remoteControl: "远程控制"
            case .providers: "连接"
            case .about: "关于"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .personalization: "person.crop.circle"
            case .appearance: "sparkles"
            case .voice: "waveform"
            case .notifications: "bell.badge"
            case .archived: "archivebox"
            case .shortcuts: "keyboard"
            case .sorting: "arrow.up.arrow.down"
            case .dataControls: "externaldrive"
            case .providers: "point.3.connected.trianglepath.dotted"
            case .remoteControl: "antenna.radiowaves.left.and.right"
            case .about: "info.circle"
            }
        }
    }
    public init() {}

    public var body: some View {
        Group {
        #if os(macOS)
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            settingsDetail
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 620, idealHeight: 720)
        #else
        NavigationStack {
            Form {
                providersSection
                defaultModelSection
                generationSection
                appearanceSection
                speechSection
                aboutSection
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #endif
        }
        .task {
            guard !loaded else { return }
            loaded = true
            draft = model.settings
            #if os(macOS)
            portDraft = String(draft.relayPort)
            await model.syncRelayController()
            #endif
        }
        .onChange(of: draft) { _, newValue in
            Task { await model.saveSettings(newValue) }
        }
        .sheet(item: $editing) { value in
            ProviderEditorSheet(draft: value)
                .environment(model)
        }
        .confirmationDialog(
            "删除供应商「\(deleting?.name ?? "")」？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let provider = deleting {
                    Task { await model.deleteProvider(provider.id) }
                }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("相关的模型缓存会一起移除，已存对话保留。")
        }
    }

    #if os(macOS)
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设置")
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
                TextField("搜索", text: $sectionQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ForEach(filteredSections) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12))
                            .frame(width: 16)
                        Text(item.title)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .foregroundStyle(Color.ompText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(section == item ? Color.ompSelection : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(width: 220)
        .background(Color.ompFill.opacity(0.4))
    }

    private var filteredSections: [SettingsSection] {
        let q = sectionQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { $0.title.lowercased().contains(q) }
    }

    private var settingsDetail: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(section.title)
                        .font(.system(size: 26, weight: .bold))
                    detailContent
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.ompCanvas)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch section {
        case .general:
            settingsCard { generationSection }
            settingsCard { defaultModelSection }
        case .personalization:
            settingsCard { personalizationSection }
        case .appearance:
            settingsCard { appearanceSection }
            settingsCard { accentColorContent }
        case .voice:
            settingsCard { speechSection }
        case .notifications:
            settingsCard { notificationsSection }
        case .archived:
            archivedContent
        case .shortcuts:
            shortcutsContent
        case .sorting:
            settingsCard { sortingSection }
        case .dataControls:
            dataControlsContent
        case .remoteControl:
            #if os(macOS)
            settingsCard { remoteControlSection }
            #else
            settingsCard {
                Text("远程控制仅在 macOS 上可用。")
                    .foregroundStyle(.secondary)
            }
            #endif
        case .providers:
            settingsCard { providersSection }
        case .about:
            settingsCard { aboutSection }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 60)
    }

    private var archivedContent: some View {
        let items = filteredArchived
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompTextTertiary)
                    TextField("搜索已归档的聊天", text: $archiveQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 8))

                if !model.projects.isEmpty {
                    Picker("项目", selection: $archiveProjectFilter) {
                        Text("全部项目").tag(UUID?.none)
                        ForEach(model.orderedProjects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .frame(width: 150)
                }
            }

            if items.isEmpty {
                Text(model.archivedConversations.isEmpty ? "没有已归档的聊天" : "没有匹配的归档聊天")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ompTextSecondary)
                    .padding(.vertical, 24)
            } else {
                ForEach(items) { conversation in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .font(.system(size: 13, weight: .medium))
                            Text(conversation.lastMessagePreview)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.ompTextTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("取消归档") {
                            model.toggleArchive(conversation.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private var filteredArchived: [Conversation] {
        let q = archiveQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.archivedConversations.filter { conversation in
            if let filter = archiveProjectFilter, conversation.projectID != filter { return false }
            guard !q.isEmpty else { return true }
            return conversation.title.localizedCaseInsensitiveContains(q)
                || conversation.lastMessagePreview.localizedCaseInsensitiveContains(q)
        }
    }

    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            shortcutRow("新建对话", "⌘N")
            shortcutRow("新建临时对话", "⇧⌘N")
            shortcutRow("重新生成", "⇧⌘R")
            shortcutRow("停止生成", "⌘.")
            shortcutRow("语音模式", "⇧⌘V")
            shortcutRow("会话内查找", "⌘F")
            shortcutRow("命令面板", "⌘K")
            shortcutRow("折叠侧栏", "⌘B")
            shortcutRow("上一个 / 下一个对话", "⌥↑ / ⌥↓")
            shortcutRow("偏好设置", "⌘,")
        }
    }

    private var sortingSection: some View {
        Section {
            Picker("排序方式", selection: $draft.conversationSort) {
                Text("最近更新").tag("updated")
                Text("创建时间").tag("created")
                Text("手动排序").tag("manual")
            }
            .pickerStyle(.inline)
        } header: {
            Text("侧栏会话排序")
        } footer: {
            Text("手动排序时，拖拽会话行调整的顺序会被保留；置顶会话始终排在最前。")
        }
    }

    private var personalizationSection: some View {
        Section {
            TextField("全局自定义指令", text: $draft.customInstructions, axis: .vertical)
                .lineLimit(3...8)
            Toggle("记忆上下文（跨对话记住要点）", isOn: $draft.enableMemories)
        } header: {
            Text("个性化")
        } footer: {
            Text("全局自定义指令会拼在系统提示词后，单对话留空时生效；「ChatGPT → 设置 → 个性化 → 自定义指令」同款。")
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("后台生成完成时通知我", isOn: $draft.completionNotifications)
        } header: {
            Text("通知")
        } footer: {
            Text("App 在后台时，回复生成完毕会发送系统通知。首次开启需要授权通知权限。")
        }
    }

    private var accentColorContent: some View {
        HStack(spacing: 12) {
            ForEach(AccentOption.all) { option in
                Button {
                    draft.accentColorHex = option.hex
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    draft.accentColorHex == option.hex ? Color.primary : Color.clear,
                                    lineWidth: 2
                                )
                                .padding(-4)
                        )
                }
                .buttonStyle(.plain)
                .help(option.name)
            }
            Spacer()
            Text(draft.accentColorHex.isEmpty ? "跟随系统" : draft.accentColorHex)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(Color.ompTextTertiary)
        }
    }

    struct AccentOption: Identifiable {
        let name: String
        let rgb: UInt32
        var id: String { name }
        var hex: String { String(format: "#%06X", rgb) }
        var color: Color { Color.ompFlat(rgb: rgb) }
        static let all: [AccentOption] = [
            .init(name: "系统", rgb: 0),
            .init(name: "蓝", rgb: 0x0A84FF),
            .init(name: "紫", rgb: 0x7D5AFF),
            .init(name: "绿", rgb: 0x30B15C),
            .init(name: "橙", rgb: 0xF59E0B),
            .init(name: "粉", rgb: 0xFF375F),
        ]
    }

    private var dataControlsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            let stats = model.workspaceStats
            VStack(alignment: .leading, spacing: 6) {
                statRow("会话", "\(stats.conversations) 个")
                statRow("消息", "\(stats.messages) 条")
                statRow("媒体", "\(stats.mediaFiles) 个")
                statRow("存储目录", stats.formattedSize)
            }
            Divider()
            Button {
                exportAllData()
            } label: {
                Label("导出全部数据 (JSON)", systemImage: "square.and.arrow.up.on.square")
            }
        }
    }

    private func statRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Color.ompTextSecondary)
        }
    }

    private func exportAllData() {
        let payload = model.exportWorkspaceJSON()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ompchat-export.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? payload.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func shortcutRow(_ name: String, _ keys: String) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 13))
            Spacer()
            Text(keys)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.ompTextSecondary)
                .padding(.vertical, 3)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.vertical, 7)
    }

    @State private var portDraft = ""
    @State private var hubURLDraft = ""
    private var remoteControlSection: some View {
        Section {
            Toggle("启用远程控制", isOn: Binding(
                get: { draft.relayEnabled },
                set: { enabled in
                    draft.relayEnabled = enabled
                    if enabled, draft.relayToken.isEmpty {
                        draft.relayToken = UUID().uuidString
                    }
                    var updated = draft
                    Task {
                        await model.saveSettings(updated)
                        await model.syncRelayController()
                    }
                }
            ))
            if draft.relayEnabled {
                HStack {
                    Text("端口")
                    Spacer()
                    TextField("8790", text: $portDraft)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitRelayPort() }
                    if portDraft != String(draft.relayPort) {
                        Button("应用") { commitRelayPort() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                HStack {
                    Text("配对码")
                    Spacer()
                    Text(maskedToken)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.relayToken, forType: .string)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.relayToken.isEmpty)
                    .help("复制完整配对码")
                }
                HStack {
                    Text("状态")
                    Spacer()
                    relayStatusLine
                }

                Divider()

                // MARK: Cross-network (relay hub)
                Toggle("跨网络（房间码 + 公网中继）", isOn: Binding(
                    get: { !draft.relayHubURL.isEmpty },
                    set: { on in
                        draft.relayHubURL = on ? (hubURLDraft.isEmpty ? Self.defaultHubURL : hubURLDraft) : ""
                        if on, draft.relayRoomCode.isEmpty {
                            draft.relayRoomCode = RelayHubClient.newRoomCode()
                        }
                        hubURLDraft = draft.relayHubURL
                        applyRelaySettings()
                    }
                ))

                if !draft.relayHubURL.isEmpty {
                    HStack {
                        Text("中继地址")
                        Spacer()
                        TextField("https://hub.example.com", text: $hubURLDraft)
                            .frame(width: 220)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                draft.relayHubURL = hubURLDraft.trimmingCharacters(in: .whitespaces)
                                applyRelaySettings()
                            }
                    }
                    HStack {
                        Text("房间码")
                        Spacer()
                        Text(draft.relayRoomCode.isEmpty ? "—" : draft.relayRoomCode)
                            .font(.system(size: 15, weight: .semibold).monospaced())
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(draft.relayRoomCode, forType: .string)
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .disabled(draft.relayRoomCode.isEmpty)
                        Button("换一个") { regenerateRoom() }
                            .buttonStyle(.borderless)
                    }
                    Text("在 iPhone 的「远程」页输入这 6 位房间码即可连接，不需要同一 Wi-Fi，也不需要公网 IP。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let hubError = model.relayController?.hubError {
                        Label(hubError, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Text("同一 Wi-Fi 下的 iPhone 可用配对码直连；开了跨网络后，蜂窝网络也能用房间码连上。配对码与房间码都不要外传。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("远程控制")
        } footer: {
            Text("局域网直连 + 可选公网中继；中继只转发结构化会话状态，不保存聊天内容。")
        }
    }

    static let defaultHubURL = "http://127.0.0.1:8899"

    private func applyRelaySettings() {
        var updated = draft
        Task {
            await model.saveSettings(updated)
            await model.syncRelayController()
        }
    }

    private func regenerateRoom() {
        model.regenerateRelayRoomCode()
        draft = model.settings
    }

    private var maskedToken: String {
        let token = draft.relayToken
        guard token.count > 10 else { return token }
        return "\(token.prefix(6))…\(token.suffix(4))"
    }

    @ViewBuilder
    private var relayStatusLine: some View {
        if let controller = model.relayController, controller.isRunning, let port = controller.port {
            Label("运行中 · 端口 \(port)", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        } else if let error = model.relayController?.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            Text("已停止")
                .foregroundStyle(.secondary)
        }
    }

    private func commitRelayPort() {
        let trimmed = portDraft.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(trimmed), port > 0 else {
            portDraft = String(draft.relayPort)
            return
        }
        draft.relayPort = port
        var updated = draft
        Task {
            await model.saveSettings(updated)
            await model.syncRelayController()
        }
    }
    #endif


    // MARK: Sections

    private var providersSection: some View {
        Section {
            ForEach(model.providers) { provider in
                providerRow(provider)
            }
            Button {
                editing = ProviderDraft.new()
            } label: {
                Label("添加供应商", systemImage: "plus.circle")
            }
        } header: {
            Text("供应商")
        } footer: {
            Text("API Key 存放在钥匙串；开发签名不可用时回落到沙盒内的私有文件。")
                .font(.caption2)
        }
    }

    private func providerRow(_ provider: ProviderProfile) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(provider.name).font(.body.weight(.medium))
                    Text(provider.kind.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    if provider.isDefault {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
                }
                Text(provider.baseURL.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(model.key(for: provider.id).isEmpty ? "未配置 Key" : "Key 已配置 · \(model.models.filter { $0.providerID == provider.id }.count) 个模型")
                    .font(.caption2)
                    .foregroundStyle(model.key(for: provider.id).isEmpty ? .orange : .secondary)
            }
            Spacer()
            if model.refreshingProviderIDs.contains(provider.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.refreshModels(for: provider.id) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("同步模型")
            }
            Button {
                editing = ProviderDraft(profile: provider, apiKey: model.key(for: provider.id))
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑")
        }
        .contextMenu {
            Button {
                editing = ProviderDraft(profile: provider, apiKey: model.key(for: provider.id))
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = provider
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var defaultModelSection: some View {
        Section("默认模型") {
            if model.models.isEmpty {
                Text("先添加供应商并同步模型")
                    .foregroundStyle(.secondary)
            } else {
                Picker("默认模型", selection: Binding(
                    get: { draft.defaultModelID ?? "" },
                    set: { newValue in
                        draft.defaultModelID = newValue.isEmpty ? nil : newValue
                        if let match = model.models.first(where: { $0.id == newValue }) {
                            draft.defaultProviderID = match.providerID
                        }
                    }
                )) {
                    Text("未选择").tag("")
                    ForEach(providerGroups, id: \.provider.id) { group in
                        Section(group.provider.name) {
                            ForEach(group.models) { descriptor in
                                Text(descriptor.displayName).tag(descriptor.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var generationSection: some View {
        Section("生成") {
            Toggle("Return 直接发送（Shift+Return 换行）", isOn: $draft.sendOnReturn)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("系统提示词").font(.caption).foregroundStyle(.secondary)
                TextField("可选，所有对话默认生效", text: $draft.systemPrompt, axis: .vertical)
                    .lineLimit(2...6)
            }
            HStack {
                Text("Temperature")
                Slider(value: Binding(
                    get: { draft.temperature ?? 0.7 },
                    set: { draft.temperature = $0 }
                ), in: 0...2, step: 0.1)
                Text(String(format: "%.1f", draft.temperature ?? 0.7))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private var appearanceSection: some View {
        Section("外观与交互") {
            Picker("主题", selection: $draft.appearance) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("字号")
                Slider(value: $draft.fontSize, in: 13...20, step: 1)
                Text("\(Int(draft.fontSize))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            Toggle("代码块显示行号", isOn: $draft.showLineNumbers)
            Toggle("触觉与音效反馈 (Audio Chimes)", isOn: $draft.soundEffects)
            Picker("代码字体", selection: $draft.codeFontName) {
                Text("SF Mono").tag("SF Mono")
                Text("Menlo").tag("Menlo")
                Text("Courier New").tag("Courier New")
            }
        }
    }

    private var speechSection: some View {
        Section("语音与朗读") {
            Picker("朗读语速", selection: $draft.speechRateMultiplier) {
                Text("0.8x 稍慢").tag(0.8)
                Text("1.0x 正常").tag(1.0)
                Text("1.2x 稍快").tag(1.2)
                Text("1.5x 极速").tag(1.5)
            }
            Picker("朗读声音语言", selection: $draft.speechVoiceLanguage) {
                Text("中文普通话 (zh-CN)").tag("zh-CN")
                Text("英语 (en-US)").tag("en-US")
                Text("粤语 (zh-HK)").tag("zh-HK")
                Text("日语 (ja-JP)").tag("ja-JP")
            }
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: AppInfo.version)
            LabeledContent("存储", value: "Application Support/OMPChat")
            #if os(macOS)
            if let dir = model.storageDirectoryURL {
                Button("在访达中显示数据文件…") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                }
            }
            #endif
            Button("清除全部对话") {
                showingClearConfirmation = true
            }
            .foregroundStyle(.red)
            .confirmationDialog(
                "确定要清除全部对话吗？",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清除全部对话", role: .destructive) {
                    for conversation in model.sortedConversations {
                        model.deleteConversation(conversation.id)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作将永久删除全部历史对话，无法撤销。")
            }
        }
    }

    private var providerGroups: [(provider: ProviderProfile, models: [ModelDescriptor])] {
        model.providers.compactMap { provider in
            let list = model.models
                .filter { $0.providerID == provider.id && $0.capabilities.chat }
                .sorted { $0.displayName < $1.displayName }
            return list.isEmpty ? nil : (provider, list)
        }
    }
}

public enum AppInfo {
    public static var version: String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return bundleVersion ?? "0.1.0"
    }
}

// MARK: - Editor

struct ProviderDraft: Identifiable {
    var id: UUID
    var isNew: Bool
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var modelsPath: String
    var chatPath: String
    var apiKey: String

    static func new() -> ProviderDraft {
        let preset = ProviderPreset.all.first
        return ProviderDraft(
            id: UUID(),
            isNew: true,
            name: "",
            kind: preset?.kind ?? .openAICompatible,
            baseURL: preset?.baseURL.absoluteString ?? "https://",
            modelsPath: "/v1/models",
            chatPath: "/v1/chat/completions",
            apiKey: ""
        )
    }

    init(profile: ProviderProfile, apiKey: String) {
        self.id = profile.id
        self.isNew = false
        self.name = profile.name
        self.kind = profile.kind
        self.baseURL = profile.baseURL.absoluteString
        self.modelsPath = profile.modelsPath
        self.chatPath = profile.chatPath
        self.apiKey = apiKey
    }

    init(id: UUID, isNew: Bool, name: String, kind: ProviderKind, baseURL: String, modelsPath: String, chatPath: String, apiKey: String) {
        self.id = id
        self.isNew = isNew
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.modelsPath = modelsPath
        self.chatPath = chatPath
        self.apiKey = apiKey
    }

    var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "名称不能为空" }
        guard let url = URL(string: baseURL), url.scheme != nil, url.host != nil else { return "Base URL 无效" }
        return nil
    }

    var profile: ProviderProfile? {
        guard let url = URL(string: baseURL) else { return nil }
        return ProviderProfile(
            id: id,
            name: name,
            kind: kind,
            baseURL: url,
            modelsPath: modelsPath,
            chatPath: chatPath
        )
    }
}

struct ProviderEditorSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ProviderDraft
    @State private var saving = false
    @State private var testing = false
    @State private var testResult: (success: Bool, message: String, latencyMs: Int?)? = nil
    var body: some View {
        NavigationStack {
            Form {
                Section("预设") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.s) {
                            ForEach(ProviderPreset.all) { preset in
                                Button(preset.name) {
                                    apply(preset)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section("基本信息") {
                    TextField("名称", text: $draft.name)
                    Picker("协议", selection: $draft.kind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .onChange(of: draft.kind) { _, newValue in
                        if draft.isNew {
                            draft.modelsPath = newValue.defaultModelsPath
                            draft.chatPath = newValue.defaultChatPath
                        }
                    }
                    TextField("Base URL", text: $draft.baseURL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }

                Section {
                    SecureField("API Key", text: $draft.apiKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("凭据")
                } footer: {
                    Text("仅保存在本机钥匙串。留空表示该供应商无需 Key（如本地 Ollama）。")
                }

                Section("网络体检与延迟") {
                    Button {
                        testConnection()
                    } label: {
                        HStack(spacing: 8) {
                            if testing {
                                ProgressView().controlSize(.small)
                                Text("正在测试连接…")
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("测试连接与延迟")
                            }
                        }
                    }
                    .disabled(testing || draft.profile == nil)

                    if let result = testResult {
                        HStack {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.success ? Color.green : Color.red)
                            Text(result.message)
                                .font(.system(size: 12))
                                .foregroundStyle(result.success ? Color.ompText : Color.red)
                            Spacer()
                            if let latency = result.latencyMs {
                                Text("\(latency) ms")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }

                Section("高级") {
                    TextField("模型列表路径", text: $draft.modelsPath)
                        .font(.callout.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("对话路径", text: $draft.chatPath)
                        .font(.callout.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                if let error = draft.validationError {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.isNew ? "添加供应商" : "编辑供应商")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.validationError != nil || saving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func apply(_ preset: ProviderPreset) {
        draft.name = preset.name
        draft.kind = preset.kind
        draft.baseURL = preset.baseURL.absoluteString
        draft.modelsPath = preset.kind.defaultModelsPath
        draft.chatPath = preset.kind.defaultChatPath
    }

    private func save() {
        guard let profile = draft.profile else { return }
        saving = true
        Task {
            if draft.isNew {
                await model.addProvider(profile, apiKey: draft.apiKey)
            } else {
                await model.updateProvider(profile, apiKey: draft.apiKey)
                await model.refreshModels(for: profile.id, silent: true)
            }
            saving = false
            dismiss()
        }
    }

    private func testConnection() {
        guard let profile = draft.profile else { return }
        testing = true
        testResult = nil
        let apiKey = draft.apiKey
        let start = Date()

        Task {
            do {
                let adapter = ProviderFactory.makeProvider(profile: profile, apiKey: apiKey)
                let models = try await adapter.fetchModels()
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                await MainActor.run {
                    testing = false
                    testResult = (true, "连接成功，探测到 \(models.count) 个可用模型", ms)
                    AudioFeedback.playComplete(enabled: true)
                }
            } catch {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                await MainActor.run {
                    testing = false
                    testResult = (false, "连接失败: \(error.localizedDescription)", ms)
                }
            }
        }
    }
}
