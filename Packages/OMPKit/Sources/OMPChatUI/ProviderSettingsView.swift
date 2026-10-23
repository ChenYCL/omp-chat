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
        case general, appearance, voice, archived, shortcuts, providers, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "常规"
            case .appearance: "外观"
            case .voice: "语音"
            case .archived: "已归档的聊天"
            case .shortcuts: "键盘快捷键"
            case .providers: "连接"
            case .about: "关于"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "sparkles"
            case .voice: "waveform"
            case .archived: "archivebox"
            case .shortcuts: "keyboard"
            case .providers: "point.3.connected.trianglepath.dotted"
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
        case .appearance:
            settingsCard { appearanceSection }
        case .voice:
            settingsCard { speechSection }
        case .archived:
            archivedContent
        case .shortcuts:
            shortcutsContent
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

    private func shortcutRow(_ name: String, _ keys: String) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 13))
            Spacer()
            Text(keys)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.ompTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.vertical, 7)
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
