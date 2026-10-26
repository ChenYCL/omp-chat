#if os(macOS)
import AppKit
import SwiftUI
import OMPCore
import OMPDesign

/// Desktop settings → 插件与技能: installed Codex plugins, the skills the
/// selected thread sees, and the AGENTS.md files it reads.
struct PluginsSettingsPane: View {
    @Environment(ChatAppModel.self) private var model
    @State private var installStage: PluginInstallStage?
    @State private var uninstalling: InstalledPlugin?
    @State private var errorText: String?
    @State private var catalog = SkillCatalog()
    @State private var agentsDoc: AgentsDoc?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            installBar
            if let errorText {
                Text(errorText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.plugins.error")
            }
            pluginsSection
            skillsSection
            agentsSection
            hookLogSection
            Text("插件按 Codex 的格式读取：.codex-plugin/plugin.json、skills/、.mcp.json、hooks/hooks.json。技能只是说明文字，模型需要时用 read_file 读取；钩子和 MCP 服务器会在这台 Mac 上运行命令，所以钩子要你单独信任后才运行，插件改动钩子后需要重新信任。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ompTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { model.reloadPlugins() }
        .task(id: refreshKey) { refreshThreadView() }
        .sheet(item: $installStage) { stage in
            PluginInstallSheet(stage: stage)
                .environment(model)
        }
        .confirmationDialog(
            "卸载插件「\(uninstalling?.displayName ?? "")」？",
            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
            titleVisibility: .visible
        ) {
            Button("卸载", role: .destructive) {
                if let plugin = uninstalling { perform { try model.uninstallPlugin(plugin.id) } }
                uninstalling = nil
            }
            Button("取消", role: .cancel) { uninstalling = nil }
        } message: {
            Text("插件的文件和它的数据文件夹会被删除。")
        }
    }

    private var refreshKey: String {
        "\(model.pluginsRevision)|\(model.selectedConversationID?.uuidString ?? "")"
    }

    private func refreshThreadView() {
        catalog = model.skillCatalog(for: model.selectedConversationID)
        if let directory = model.selectedConversation?.workingDirectory, !directory.isEmpty {
            agentsDoc = AgentsMDLoader.load(workingDirectory: directory)
        } else {
            agentsDoc = nil
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: Install

    private var installBar: some View {
        HStack(spacing: 8) {
            Button("从文件夹安装…") { chooseFolder() }
                .accessibilityIdentifier("settings.plugins.installFolder")
            Button("从 git 安装…") { installStage = .git }
                .accessibilityIdentifier("settings.plugins.installGit")
            Spacer()
            Button("重新读取") {
                model.reloadPlugins()
                refreshThreadView()
            }
            .help("重新读取插件、技能和 AGENTS.md")
            .accessibilityIdentifier("settings.plugins.reload")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "读取插件"
        panel.message = "选择含有 .codex-plugin/plugin.json 的插件文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            installStage = .confirm(try model.preparePluginInstall(folder: url.path))
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: Plugins

    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("已安装的插件")
            if model.installedPlugins.isEmpty {
                emptyRow("还没有安装插件")
            }
            ForEach(model.installedPlugins) { plugin in
                pluginCard(plugin)
            }
        }
    }

    private func pluginCard(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plugin.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        if let version = plugin.manifest?.version {
                            Text(version)
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(Color.ompTextTertiary)
                        }
                    }
                    Text(plugin.source.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(plugin.source.summary)
                }
                Spacer()
                Toggle("启用", isOn: Binding(
                    get: { plugin.enabled },
                    set: { value in perform { try model.setPluginEnabled(value, id: plugin.id) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("settings.plugins.enabled")
            }
            if let description = plugin.manifest?.interface?.shortDescription ?? plugin.manifest?.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = plugin.problem {
                Text("无法载入：\(problem)")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PluginContentsView(contents: plugin.contents, pluginID: plugin.id, editable: true)
            if !plugin.contents.hooks.isEmpty {
                Toggle("信任此插件的钩子", isOn: Binding(
                    get: { plugin.hooksTrusted },
                    set: { value in perform { try model.setPluginHooksTrusted(value, id: plugin.id) } }
                ))
                .toggleStyle(.checkbox)
                .help("钩子会在每次相关的工具调用前后，以你的身份在这台 Mac 上运行上面的命令")
                .accessibilityIdentifier("settings.plugins.trustHooks")
                if plugin.hooksTrusted, !plugin.enabled {
                    Text("插件已停用，钩子不会运行。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextTertiary)
                }
            }
            HStack {
                Spacer()
                Button("卸载", role: .destructive) { uninstalling = plugin }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.plugins.uninstall")
            }
        }
        .padding(12)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.plugins.row.\(plugin.id)")
    }

    // MARK: Skills

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("技能")
            Text(threadCaption)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ompTextTertiary)
            if catalog.skills.isEmpty {
                emptyRow("没有可用的技能。技能放在仓库的 .agents/skills、~/.agents/skills 或插件的 skills/ 里。")
            }
            ForEach(catalog.skills) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(skill.scope.title)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ompTextTertiary)
                        if !skill.allowsImplicitInvocation {
                            Text("仅限显式调用，不列给模型")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.ompTextTertiary)
                        }
                    }
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextSecondary)
                        .lineLimit(2)
                        .help(skill.description)
                    Text(skill.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.plugins.skill")
                Divider()
            }
            ForEach(catalog.shadowed) { skill in
                problemRow("同名技能「\(skill.name)」未使用（已有更近的同名技能）", path: skill.path)
            }
            ForEach(catalog.problems, id: \.path) { problem in
                problemRow(problem.reason, path: problem.path)
            }
        }
    }

    private var threadCaption: String {
        guard let conversation = model.selectedConversation else { return "没有选中的对话：只列出用户和插件的技能。" }
        if let directory = conversation.workingDirectory, !directory.isEmpty {
            return "当前对话「\(conversation.title)」，工作目录 \(directory)"
        }
        return "当前对话「\(conversation.title)」没有工作目录：只列出用户和插件的技能。"
    }

    // MARK: AGENTS.md

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("AGENTS.md")
            if let conversation = model.selectedConversation, let directory = conversation.workingDirectory, !directory.isEmpty {
                if let agentsDoc {
                    Text("当前对话读取这些文件（从仓库根目录到工作目录，越靠后越优先）：")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextTertiary)
                    ForEach(agentsDoc.files, id: \.self) { file in
                        Text(file)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.vertical, 2)
                            .accessibilityIdentifier("settings.plugins.agentsFile")
                    }
                    if agentsDoc.truncated {
                        Text("合计超过 \(AgentsMDLoader.defaultMaxBytes / 1024) KiB，超出部分没有载入。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                    }
                    if agentsDoc.projectRoot == nil {
                        Text("工作目录不在 git 仓库里，只读取工作目录本身。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                } else {
                    emptyRow("在 \(directory) 到仓库根目录之间没有找到有内容的 AGENTS.md 或 AGENTS.override.md")
                }
            } else {
                emptyRow("当前对话没有工作目录，不读取 AGENTS.md")
            }
        }
    }

    // MARK: Hook runs

    @ViewBuilder
    private var hookLogSection: some View {
        if !model.hookRunLog.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("最近的钩子运行")
                ForEach(model.hookRunLog.reversed()) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(record.at, style: .time)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Color.ompTextTertiary)
                            Text("\(record.pluginID) · \(record.event.rawValue) · \(record.toolName)")
                                .font(.system(size: 12))
                            Spacer()
                            Text(Self.statusTitle(record.status))
                                .font(.system(size: 11.5))
                                .foregroundStyle(record.status == .failed ? Color.orange : Color.ompTextSecondary)
                        }
                        if let message = record.message {
                            Text(message)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.ompTextSecondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.plugins.hookRun")
                    Divider()
                }
            }
        }
    }

    static func statusTitle(_ status: HookRunStatus) -> String {
        switch status {
        case .completed: "已运行"
        case .blocked: "已阻止"
        case .failed: "失败（调用照常进行）"
        case .stopped: "已停止后续处理"
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 4)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Color.ompTextTertiary)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func problemRow(_ text: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.ompTextTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }
}

/// What the install sheet shows: the git form, or a staged plugin to confirm.
enum PluginInstallStage: Identifiable {
    case git
    case confirm(PluginInstallPlan)

    var id: String {
        switch self {
        case .git: "git"
        case .confirm(let plan): plan.id.uuidString
        }
    }
}

/// A plugin's skills, MCP servers and hooks, as listed in its card and in
/// the install confirmation.
private struct PluginContentsView: View {
    @Environment(ChatAppModel.self) private var model
    let contents: PluginContents
    let pluginID: String
    /// Server switches are shown for an installed plugin only.
    let editable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            group("技能（\(contents.skills.count)）") {
                if contents.skills.isEmpty { none() }
                ForEach(contents.skills) { skill in
                    Text("\(skill.name)：\(skill.description)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextSecondary)
                        .lineLimit(2)
                        .help(skill.description)
                }
            }
            group("MCP 服务器（\(contents.mcpServers.count)）") {
                if contents.mcpServers.isEmpty { none() }
                ForEach(contents.mcpServers) { server in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(Self.commandLine(server))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color.ompTextSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if editable {
                            Toggle("", isOn: Binding(
                                get: { server.enabled },
                                set: { value in try? model.setPluginMCPServerEnabled(value, server: server.name, pluginID: pluginID) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("启用这个服务器（连接由「MCP 服务器」管理）")
                            .accessibilityIdentifier("settings.plugins.mcpServer")
                        }
                    }
                }
            }
            group("钩子（\(contents.hooks.count)）") {
                if contents.hooks.isEmpty { none() }
                ForEach(contents.hooks) { hook in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hook.event.rawValue + (hook.matcher.map { "（matcher：\($0)）" } ?? "") + "，超时 \(hook.handler.timeout) 秒")
                            .font(.system(size: 12, weight: .medium))
                        Text(hook.handler.command ?? "（无命令）")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.ompTextSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let note = Self.hookNote(hook) {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.ompTextTertiary)
                        }
                    }
                }
            }
            let notes = contents.warnings + contents.mcpProblems + contents.skillProblems.map { "\($0.path)：\($0.reason)" }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ompTextSecondary)
            content()
        }
    }

    private func none() -> some View {
        Text("无")
            .font(.system(size: 12))
            .foregroundStyle(Color.ompTextTertiary)
    }

    static func commandLine(_ server: MCPServerConfig) -> String {
        guard let command = server.command else { return server.url ?? "" }
        let line = ([command] + server.args).map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }.joined(separator: " ")
        return line + (server.cwd.map { "（工作目录 \($0)）" } ?? "")
    }

    static func hookNote(_ hook: HookDefinition) -> String? {
        if let problem = hook.matcherProblem { return problem }
        if let skip = hook.handler.skipReason { return skip }
        if !hook.event.isTriggered { return "本应用不触发 \(hook.event.rawValue)，这个钩子不会运行" }
        return nil
    }
}

/// 从 git 安装 (URL → clone) and the confirmation of any staged install. A
/// staged copy that is not confirmed is discarded when the sheet closes.
private struct PluginInstallSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let stage: PluginInstallStage

    @State private var plan: PluginInstallPlan?
    @State private var url = ""
    @State private var ref = ""
    @State private var subdirectory = ""
    @State private var fetching = false
    @State private var errorText: String?
    @State private var installed = false
    /// Outlives the view, so a clone that finishes after the sheet closed
    /// can still discard its staged copy.
    @State private var lifetime = SheetLifetime()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan {
                confirmation(plan)
            } else {
                gitForm
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 260)
        .onAppear {
            if case .confirm(let staged) = stage { plan = staged }
        }
        .onDisappear {
            lifetime.closed = true
            if let plan, !installed { model.cancelPluginInstall(plan) }
        }
    }

    private var gitForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从 git 安装插件")
                .font(.system(size: 17, weight: .semibold))
            Text("浅克隆仓库（--depth 1），读取根目录或子目录里的 .codex-plugin/plugin.json。安装前会列出插件要运行的全部命令。")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("仓库地址，例如 https://github.com/owner/plugin.git", text: $url)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.plugins.install.url")
            HStack {
                TextField("分支或标签（可选）", text: $ref)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.plugins.install.ref")
                TextField("子目录（可选）", text: $subdirectory)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.plugins.install.subdirectory")
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.plugins.install.error")
            }
            Spacer(minLength: 0)
            HStack {
                if fetching { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.plugins.install.cancel")
                Button("获取") { fetch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fetching || url.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("settings.plugins.install.fetch")
            }
        }
    }

    private func fetch() {
        fetching = true
        errorText = nil
        Task {
            do {
                let staged = try await model.preparePluginInstall(gitURL: url, ref: ref, subdirectory: subdirectory)
                if lifetime.closed { model.cancelPluginInstall(staged) } else { plan = staged }
            } catch {
                errorText = error.localizedDescription
            }
            fetching = false
        }
    }

    private func confirmation(_ plan: PluginInstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("安装「\(plan.manifest.displayName)」")
                    .font(.system(size: 17, weight: .semibold))
                if let version = plan.manifest.version {
                    Text(version)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.ompTextTertiary)
                }
            }
            if let description = plan.manifest.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(plan.source.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ompTextTertiary)
                .textSelection(.enabled)
            if let replacing = plan.replacing {
                Text("将替换已安装的版本\(replacing.map { " \($0)" } ?? "")；启用状态保留，钩子有变化时需要重新信任。")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    commandsBlock(
                        title: "钩子会运行的命令",
                        lines: plan.hookCommands,
                        note: "安装后钩子默认不运行，要在插件里勾选「信任此插件的钩子」。"
                    )
                    commandsBlock(
                        title: "MCP 服务器会运行的命令",
                        lines: plan.mcpCommands,
                        note: "启用插件后由「MCP 服务器」连接。"
                    )
                    PluginContentsView(contents: plan.contents, pluginID: plan.manifest.name, editable: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.plugins.install.cancel")
                Button("安装") { confirm(plan) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.plugins.install.confirm")
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func commandsBlock(title: String, lines: [String], note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if lines.isEmpty {
                Text("无")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompTextTertiary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 6))
                }
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ompTextTertiary)
            }
        }
    }

    private func confirm(_ plan: PluginInstallPlan) {
        do {
            try model.confirmPluginInstall(plan)
            installed = true
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Whether the install sheet is gone; read by its clone task.
private final class SheetLifetime {
    var closed = false
}
#endif
