#if os(macOS)
import OMPCore
import OMPDesign
import SwiftUI
import UniformTypeIdentifiers

/// 设置 → MCP 服务器: the configured servers with live status and tools,
/// adding one by form or pasted JSON, and the one-click catalog.
struct MCPSettingsPane: View {
    @Environment(ChatAppModel.self) private var model
    /// The settings window's `draft.mcpServers`; its onChange saves.
    @Binding var servers: [MCPServerConfig]

    @State private var expanded: Set<String> = []
    @State private var editing: MCPEditorTarget?
    @State private var importing = false
    @State private var logTarget: MCPServerConfig?
    @State private var deleting: MCPServerConfig?
    @State private var installing: MCPCatalogEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCP 服务器把浏览器、文件、Git 等外部工具接给对话里的智能体。每次调用按工具的风险等级和对话的权限模式决定是否先问你。")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ompTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            card { serversSection }
            card { catalogSection }
        }
        .accessibilityIdentifier("settings.mcp.pane")
        .task { model.startMCP() }
        .sheet(item: $editing) { target in
            MCPServerEditor(original: target.original, servers: $servers)
                .environment(model)
        }
        .sheet(isPresented: $importing) {
            MCPImportSheet(servers: $servers)
                .environment(model)
        }
        .sheet(item: $logTarget) { config in
            MCPLogSheet(config: config)
                .environment(model)
        }
        .sheet(item: $installing) { entry in
            MCPCatalogInstallSheet(entry: entry, servers: $servers)
                .environment(model)
        }
        .confirmationDialog(
            "删除服务器「\(deleting?.name ?? "")」？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let config = deleting { delete(config) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("会停止这个服务器，并删掉它存在钥匙串里的密钥。")
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 60)
    }

    // MARK: Servers

    private var serversSection: some View {
        Section {
            if servers.isEmpty && pluginServers.isEmpty {
                Text("还没有服务器。从下面的目录安装，或手动添加。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextTertiary)
            }
            ForEach(servers) { config in
                serverRow(config, editable: true)
                if expanded.contains(config.id) { toolRows(config, editable: true) }
            }
            // Plugin servers are switched on and off in 插件与技能.
            ForEach(pluginServers) { config in
                serverRow(config, editable: false)
                if expanded.contains(config.id) { toolRows(config, editable: false) }
            }
            HStack(spacing: 8) {
                Button("添加服务器…") { editing = MCPEditorTarget(original: nil) }
                    .accessibilityIdentifier("settings.mcp.add")
                Button("粘贴 JSON 导入…") { importing = true }
                    .accessibilityIdentifier("settings.mcp.import")
                Spacer()
            }
        } header: {
            Text("服务器")
        }
    }

    /// Enabled plugins' servers whose id no server in settings already uses.
    private var pluginServers: [MCPServerConfig] {
        model.pluginMCPServers.filter { plugin in !servers.contains { $0.id == plugin.id } }
    }

    private func serverRow(_ config: MCPServerConfig, editable: Bool) -> some View {
        let status = model.mcp.status(of: config.id)
        let isExpanded = expanded.contains(config.id)
        return HStack(spacing: 10) {
            Circle()
                .fill(Self.color(of: status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name)
                        .font(.system(size: 13, weight: .medium))
                    badge(Self.originTitle(config.origin))
                        .help(editable ? "" : "由插件提供，在「插件与技能」里启用或停用")
                }
                Text(Self.statusText(status))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Self.isProblem(status) ? Self.color(of: status) : Color.ompTextSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.mcp.server.\(config.id).status")
            }
            Spacer(minLength: 8)
            if Self.isProblem(status) {
                Button("重试") { model.mcp.retry(config.id) }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.mcp.server.\(config.id).retry")
            }
            iconButton(isExpanded ? "chevron.down" : "chevron.right", help: isExpanded ? "收起工具" : "展开工具",
                       id: "settings.mcp.server.\(config.id).expand") {
                if isExpanded { expanded.remove(config.id) } else { expanded.insert(config.id) }
            }
            iconButton("doc.text.magnifyingglass", help: "查看日志", id: "settings.mcp.server.\(config.id).log") {
                logTarget = config
            }
            if editable {
                iconButton("pencil", help: "编辑", id: "settings.mcp.server.\(config.id).edit") {
                    editing = MCPEditorTarget(original: config)
                }
                iconButton("trash", help: "删除", id: "settings.mcp.server.\(config.id).delete") {
                    deleting = config
                }
                Toggle("启用", isOn: enabledBinding(config.id))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.mcp.server.\(config.id).enabled")
            }
        }
        .accessibilityIdentifier("settings.mcp.server.\(config.id)")
    }

    @ViewBuilder
    private func toolRows(_ config: MCPServerConfig, editable: Bool) -> some View {
        let tools = model.mcp.tools[config.id] ?? []
        if tools.isEmpty {
            Text(config.enabled ? "连接成功后在这里列出工具。" : "启用并连接后在这里列出工具。")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextTertiary)
                .padding(.leading, 18)
        } else {
            ForEach(tools, id: \.name) { tool in
                HStack(spacing: 8) {
                    Toggle(isOn: toolBinding(config, tool.name)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.name)
                                .font(.system(size: 12).monospaced())
                            if !tool.description.isEmpty {
                                Text(tool.description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.ompTextSecondary)
                                    .lineLimit(1)
                                    .help(tool.description)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!editable)
                    Spacer(minLength: 8)
                    riskBadge(MCPToolProvider.risk(of: tool, on: config))
                }
                .padding(.leading, 18)
                .accessibilityIdentifier("settings.mcp.server.\(config.id).tool.\(tool.name)")
            }
        }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { servers.first { $0.id == id }?.enabled ?? false },
            set: { value in
                guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
                servers[index].enabled = value
            }
        )
    }

    /// On when the tool is offered. Plugin servers are not in `servers`, so
    /// their own config answers (read-only).
    private func toolBinding(_ config: MCPServerConfig, _ tool: String) -> Binding<Bool> {
        Binding(
            get: { !((servers.first { $0.id == config.id } ?? config).disabledTools.contains(tool)) },
            set: { on in
                guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
                servers[index].disabledTools.removeAll { $0 == tool }
                if !on { servers[index].disabledTools.append(tool) }
            }
        )
    }

    private func delete(_ config: MCPServerConfig) {
        for variable in config.env.keys {
            model.setMCPSecret(nil, serverID: config.id, variable: variable)
        }
        servers.removeAll { $0.id == config.id }
        expanded.remove(config.id)
    }

    // MARK: Catalog

    private var catalogSection: some View {
        Section {
            ForEach(MCPCatalog.entries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(.system(size: 13, weight: .medium))
                            badge(entry.license)
                        }
                        Text(entry.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            if let requirement = entry.requirement ?? entry.runtime?.title {
                                Text("需要 \(requirement)")
                                    .foregroundStyle(Color.ompTextTertiary)
                            }
                            if let url = URL(string: entry.homepage) {
                                Link("主页", destination: url)
                            }
                        }
                        .font(.system(size: 11))
                    }
                    Spacer(minLength: 8)
                    if servers.contains(where: entry.matches) {
                        Text("已添加")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompTextTertiary)
                    } else {
                        Button("安装") { installing = entry }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings.mcp.catalog.\(entry.id).install")
                    }
                }
                .accessibilityIdentifier("settings.mcp.catalog.\(entry.id)")
            }
        } header: {
            Text("目录")
        } footer: {
            Text("目录里的版本是固定的，首次连接时由 npx 或 uvx 下载。目录服务器自报「只读且不访问外部」的工具直接运行；其余工具，以及自定义和插件服务器的全部工具，都按服务器的风险等级处理。")
        }
    }

    // MARK: Pieces

    private func iconButton(_ symbol: String, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Color.ompTextSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 4))
    }

    private func riskBadge(_ risk: ToolRisk) -> some View {
        Text(Self.riskTitle(risk))
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Self.riskColor(risk))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Self.riskColor(risk).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .help("风险等级：\(Self.riskTitle(risk))")
    }

    static func riskTitle(_ risk: ToolRisk) -> String {
        switch risk {
        case .read: "读取"
        case .write: "写入"
        case .execute: "执行"
        case .control: "控制"
        }
    }

    private static func riskColor(_ risk: ToolRisk) -> Color {
        switch risk {
        case .read: .green
        case .write: .orange
        case .execute: .red
        case .control: .purple
        }
    }

    private static func originTitle(_ origin: String) -> String {
        if origin == "catalog" { return "目录" }
        if origin.hasPrefix("plugin:") { return "插件" }
        return "自定义"
    }

    private static func isProblem(_ status: MCPServerStatus) -> Bool {
        switch status {
        case .failed, .needsRuntime: true
        default: false
        }
    }

    static func color(of status: MCPServerStatus) -> Color {
        switch status {
        case .ready: .green
        case .connecting: .yellow
        case .failed: .red
        case .needsRuntime: .orange
        case .disabled: Color.ompTextTertiary
        }
    }

    static func statusText(_ status: MCPServerStatus) -> String {
        switch status {
        case .disabled: "已停用"
        case .connecting: "正在连接…"
        case .ready(let count): "已连接 · \(count) 个工具"
        case .failed(let reason, _): "连接失败：\(reason)"
        case .needsRuntime(let runtime): "需要安装 \(runtime.title)"
        }
    }
}

/// Which server the editor sheet edits; nil `original` adds a new one.
struct MCPEditorTarget: Identifiable {
    let id = UUID()
    var original: MCPServerConfig?
}

// MARK: - Editor

/// Adds or edits one server by hand. Variables marked 密钥 are written to the
/// vault; the config keeps their names with blank values.
struct MCPServerEditor: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: MCPServerConfig?
    @Binding var servers: [MCPServerConfig]

    private struct EnvRow: Identifiable {
        let id = UUID()
        var name: String
        var value: String
        var secret: Bool
        /// A vault value exists; a blank field keeps it.
        var stored: Bool
    }

    @State private var name = ""
    @State private var remote = false
    @State private var command = ""
    @State private var arguments = ""
    @State private var cwd = ""
    @State private var url = ""
    @State private var risk: ToolRisk = .execute
    @State private var env: [EnvRow] = []
    @State private var failure: String?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text("例如 Playwright"))
                        .accessibilityIdentifier("settings.mcp.editor.name")
                    Picker("类型", selection: $remote) {
                        Text("本地命令").tag(false)
                        Text("远程地址").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.mcp.editor.kind")
                } header: {
                    Text(original == nil ? "添加服务器" : "编辑服务器")
                }

                if remote {
                    Section {
                        TextField("地址", text: $url, prompt: Text("https://example.com/mcp"))
                            .accessibilityIdentifier("settings.mcp.editor.url")
                    } footer: {
                        Text("使用 Streamable HTTP 传输。需要自定义请求头（如登录令牌）的服务器暂不支持。")
                    }
                } else {
                    Section {
                        TextField("命令", text: $command, prompt: Text("npx"))
                            .accessibilityIdentifier("settings.mcp.editor.command")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("参数（每行一个）")
                            TextEditor(text: $arguments)
                                .font(.system(size: 12).monospaced())
                                .frame(minHeight: 64)
                                .accessibilityIdentifier("settings.mcp.editor.args")
                        }
                        TextField("工作目录", text: $cwd, prompt: Text("留空为个人文件夹"))
                            .accessibilityIdentifier("settings.mcp.editor.cwd")
                    }
                    Section {
                        ForEach($env) { $row in
                            HStack(spacing: 6) {
                                TextField("变量名", text: $row.name)
                                    .frame(width: 150)
                                if row.secret {
                                    SecureField("值", text: $row.value, prompt: Text(row.stored ? "已保存，留空不变" : "值"))
                                } else {
                                    TextField("值", text: $row.value)
                                }
                                Toggle("密钥", isOn: $row.secret)
                                    .toggleStyle(.checkbox)
                                Button {
                                    env.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("移除")
                            }
                            .labelsHidden()
                        }
                        Button("添加环境变量") {
                            env.append(EnvRow(name: "", value: "", secret: true, stored: false))
                        }
                        .accessibilityIdentifier("settings.mcp.editor.addEnv")
                    } header: {
                        Text("环境变量")
                    } footer: {
                        Text("标为密钥的值存入钥匙串，不写进工作区文件。")
                    }
                }

                Section {
                    Picker("风险等级", selection: $risk) {
                        ForEach(ToolRisk.allCases, id: \.self) { level in
                            Text(MCPSettingsPane.riskTitle(level)).tag(level)
                        }
                    }
                    .accessibilityIdentifier("settings.mcp.editor.risk")
                } footer: {
                    Text("这个服务器的每个工具都按此等级决定是否要你确认；自定义服务器自报的「只读」标记不被采信。")
                }

                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings.mcp.editor.error")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.mcp.editor.save")
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let original else { return }
        name = original.name
        remote = original.url != nil
        command = original.command ?? ""
        arguments = original.args.joined(separator: "\n")
        cwd = original.cwd ?? ""
        url = original.url ?? ""
        risk = original.risk
        env = original.env.keys.sorted().map { key in
            let value = original.env[key] ?? ""
            let stored = model.mcpSecret(serverID: original.id, variable: key) != nil
            return value.isEmpty && stored
                ? EnvRow(name: key, value: "", secret: true, stored: true)
                : EnvRow(name: key, value: value, secret: false, stored: false)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { failure = "请填写名称"; return }
        let id: String
        if let original {
            id = original.id
        } else {
            guard let sanitized = MCPServerConfig.sanitizedID(trimmedName) else {
                failure = "名称里需要有英文字母或数字，用作服务器 id"
                return
            }
            guard !servers.contains(where: { $0.id == sanitized }) else {
                failure = "已经有 id 为「\(sanitized)」的服务器"
                return
            }
            id = sanitized
        }

        var config = original ?? MCPServerConfig(id: id, name: trimmedName)
        config.name = trimmedName
        config.risk = risk
        var vaultWrites: [(String, String?)] = []
        if remote {
            let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: address), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", parsed.host != nil else {
                failure = "请填写 http 或 https 地址"
                return
            }
            config.url = address
            config.command = nil
            config.args = []
            config.cwd = nil
            vaultWrites = config.env.keys.map { ($0, nil) }
            config.env = [:]
        } else {
            let launcher = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !launcher.isEmpty else { failure = "请填写命令"; return }
            config.command = launcher
            config.url = nil
            config.args = arguments.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let directory = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            config.cwd = directory.isEmpty ? nil : directory
            var newEnv: [String: String] = [:]
            for row in env {
                let key = row.name.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                guard !key.contains("="), !key.contains(" ") else {
                    failure = "环境变量名「\(key)」不能含空格或等号"
                    return
                }
                if row.secret {
                    newEnv[key] = ""
                    if !row.value.isEmpty { vaultWrites.append((key, row.value)) }
                } else {
                    newEnv[key] = row.value
                    vaultWrites.append((key, nil))
                }
            }
            for old in config.env.keys where newEnv[old] == nil { vaultWrites.append((old, nil)) }
            config.env = newEnv
        }
        for (variable, value) in vaultWrites where !model.setMCPSecret(value, serverID: id, variable: variable) {
            failure = "无法把「\(variable)」写入钥匙串，没有保存"
            return
        }

        if let index = servers.firstIndex(where: { $0.id == id }) {
            let unchanged = servers[index] == config
            servers[index] = config
            // Only a secret changed: settings do not, so ask for the restart.
            if unchanged { model.mcp.sync() }
        } else {
            servers.append(config)
        }
        dismiss()
    }
}

// MARK: - JSON import

/// Imports servers from a pasted MCP config. Every environment value goes to
/// the vault: a pasted config often carries tokens, and nothing tells them
/// apart from plain settings.
struct MCPImportSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var servers: [MCPServerConfig]

    @State private var text = ""
    @State private var parsed: MCPConfigParse?
    @State private var failure: String?

    private var existing: Set<String> { Set(servers.map(\.id)) }
    private var addable: [MCPServerConfig] { parsed?.servers.filter { !existing.contains($0.id) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("粘贴 JSON 导入")
                .font(.system(size: 15, weight: .semibold))
            Text("支持 Claude Desktop、Cursor 的 {\"mcpServers\": …}，Codex 的 {\"mcp_servers\": …}，以及直接的 {名称: 配置}。环境变量的值一律存入钥匙串，不写进工作区文件。")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 12).monospaced())
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.ompBorder))
                .accessibilityIdentifier("settings.mcp.import.text")
                .onChange(of: text) { _, _ in
                    parsed = nil
                    failure = nil
                }
            HStack {
                Button("解析") { parse() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.mcp.import.parse")
                Spacer()
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.mcp.import.error")
            }
            if let parsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(parsed.servers) { server in
                            if existing.contains(server.id) {
                                Label("\(server.name)：已有 id 为「\(server.id)」的服务器，跳过", systemImage: "minus.circle")
                                    .foregroundStyle(Color.ompTextTertiary)
                            } else {
                                Label("\(server.name)：\(server.url ?? ([server.command ?? ""] + server.args).joined(separator: " "))",
                                      systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                            }
                        }
                        ForEach(Array(parsed.skipped.enumerated()), id: \.offset) { _, item in
                            Label("\(item.name)：\(item.reason)", systemImage: "xmark.circle")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .accessibilityIdentifier("settings.mcp.import.result")
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addable.isEmpty ? "添加" : "添加 \(addable.count) 个") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(addable.isEmpty)
                    .accessibilityIdentifier("settings.mcp.import.confirm")
            }
        }
        .padding(20)
        .frame(width: 580, height: 520)
    }

    private func parse() {
        do {
            parsed = try MCPServerConfig.parse(Data(text.utf8), origin: "custom")
            failure = nil
        } catch MCPServerConfig.ParseError.noServers {
            parsed = nil
            failure = "没有找到服务器配置"
        } catch {
            parsed = nil
            failure = "不是合法的 JSON 对象"
        }
    }

    private func add() {
        var added: [MCPServerConfig] = []
        for server in addable {
            var config = server
            for (variable, value) in server.env where !value.isEmpty {
                guard model.setMCPSecret(value, serverID: config.id, variable: variable) else {
                    failure = "无法把「\(server.name)」的「\(variable)」写入钥匙串，没有导入"
                    return
                }
                config.env[variable] = ""
            }
            added.append(config)
        }
        servers.append(contentsOf: added)
        dismiss()
    }
}

// MARK: - Log

/// The stderr tail of one server, and why it failed.
struct MCPLogSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let config: MCPServerConfig

    @State private var lines: [String] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("日志 · \(config.name)")
                .font(.system(size: 15, weight: .semibold))
            if case .failed(let reason, _) = model.mcp.status(of: config.id) {
                Text(reason)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ScrollView {
                Text(lines.isEmpty ? (loaded ? "没有日志输出。" : "正在读取…") : lines.joined(separator: "\n"))
                    .font(.system(size: 11.5).monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .accessibilityIdentifier("settings.mcp.log.text")
            }
            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 8))
            Text(config.url == nil ? "服务器 stderr 的最后 200 行。" : "远程服务器没有本地日志，这里只显示连接错误。")
                .font(.system(size: 11))
                .foregroundStyle(Color.ompTextTertiary)
            HStack {
                Button("刷新") { Task { await refresh() } }
                    .accessibilityIdentifier("settings.mcp.log.refresh")
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 480)
        .task { await refresh() }
    }

    private func refresh() async {
        lines = await model.mcp.log(for: config.id)
        loaded = true
    }
}

// MARK: - Catalog install

/// Installs one catalog entry: checks the runtime, asks for the inputs, adds
/// the server, then follows it until it is connected or has failed.
struct MCPCatalogInstallSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: MCPCatalogEntry
    @Binding var servers: [MCPServerConfig]

    @State private var runtimeFound: Bool?
    /// Picked paths per input.
    @State private var picked: [String: [String]] = [:]
    /// Typed text per input (a path, a secret or plain text).
    @State private var typed: [String: String] = [:]
    @State private var picking: MCPCatalogEntry.Input?
    @State private var installedID: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安装 \(entry.name)")
                .font(.system(size: 15, weight: .semibold))
            Text(entry.summary)
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let installedID {
                progress(installedID)
            } else if let runtime = entry.runtime, runtimeFound == false {
                Label(runtime.installHint, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.mcp.install.runtime")
            } else if runtimeFound == true {
                inputs
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.mcp.install.error")
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 560, height: 500)
        .onAppear(perform: checkRuntime)
        .fileImporter(
            isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: picking?.allowsMultiple ?? false
        ) { result in
            guard let input = picking, case .success(let urls) = result else { return }
            let paths = urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return url.path
            }
            if input.allowsMultiple {
                picked[input.id, default: []].append(contentsOf: paths.filter { !(picked[input.id] ?? []).contains($0) })
            } else {
                picked[input.id] = Array(paths.prefix(1))
            }
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry.inputs.isEmpty {
                Text("不需要额外设置。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            ForEach(entry.inputs) { input in
                VStack(alignment: .leading, spacing: 4) {
                    Text(input.label)
                        .font(.system(size: 12.5, weight: .medium))
                    switch input.kind {
                    case .path:
                        ForEach(picked[input.id] ?? [], id: \.self) { path in
                            HStack {
                                Text(GitInfo.tildified(path))
                                    .font(.system(size: 12).monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    picked[input.id]?.removeAll { $0 == path }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("移除")
                            }
                        }
                        HStack {
                            TextField("或输入路径", text: typedBinding(input.id))
                                .accessibilityIdentifier("settings.mcp.install.input.\(input.id)")
                            Button("选择…") { picking = input }
                                .accessibilityIdentifier("settings.mcp.install.pick.\(input.id)")
                        }
                    case .secret:
                        SecureField(input.label, text: typedBinding(input.id))
                            .labelsHidden()
                            .accessibilityIdentifier("settings.mcp.install.input.\(input.id)")
                    case .text:
                        TextField(input.label, text: typedBinding(input.id))
                            .labelsHidden()
                            .accessibilityIdentifier("settings.mcp.install.input.\(input.id)")
                    }
                    Text(input.help)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompTextTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func progress(_ id: String) -> some View {
        switch model.mcp.status(of: id) {
        case .connecting, .disabled:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在连接…首次运行要下载软件包，可能需要一两分钟。")
            }
            .accessibilityIdentifier("settings.mcp.install.status")
        case .ready(let count):
            Label("已连接，\(count) 个工具可用。", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings.mcp.install.status")
        case .needsRuntime(let runtime):
            Label(runtime.installHint, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("settings.mcp.install.status")
        case .failed(let reason, let log):
            VStack(alignment: .leading, spacing: 6) {
                Text("连接失败：\(reason)")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.mcp.install.status")
                if !log.isEmpty {
                    ScrollView {
                        Text(log.suffix(40).joined(separator: "\n"))
                            .font(.system(size: 11).monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 180)
                    .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            if let installedID {
                if case .failed = model.mcp.status(of: installedID) {
                    Button("移除") {
                        let variables = servers.first { $0.id == installedID }.map { Array($0.env.keys) } ?? []
                        for variable in variables {
                            model.setMCPSecret(nil, serverID: installedID, variable: variable)
                        }
                        servers.removeAll { $0.id == installedID }
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.mcp.install.remove")
                    Button("重试") { model.mcp.retry(installedID) }
                        .accessibilityIdentifier("settings.mcp.install.retry")
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.mcp.install.done")
            } else {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if runtimeFound == false {
                    Button("重新检查") { checkRuntime() }
                        .accessibilityIdentifier("settings.mcp.install.recheck")
                } else {
                    Button("安装") { install() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(runtimeFound != true)
                        .accessibilityIdentifier("settings.mcp.install.confirm")
                }
            }
        }
    }

    private func typedBinding(_ id: String) -> Binding<String> {
        Binding(get: { typed[id] ?? "" }, set: { typed[id] = $0 })
    }

    private func checkRuntime() {
        guard let runtime = entry.runtime else {
            runtimeFound = true
            return
        }
        let home = HostExecutor.realHomeDirectory()
        let path = HostExecutor.childEnvironment(home: home)["PATH"] ?? ""
        runtimeFound = MCPLaunchPlanner.locate(runtime.probeCommand, path: path, home: home) != nil
    }

    private func install() {
        var values = picked
        for (id, text) in typed where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values[id, default: []].append(text)
        }
        do {
            let installation = try entry.install(
                values: values, existingIDs: Set(servers.map(\.id)), home: HostExecutor.realHomeDirectory()
            )
            for (variable, value) in installation.secrets
            where !model.setMCPSecret(value, serverID: installation.config.id, variable: variable) {
                failure = "无法把「\(variable)」写入钥匙串，没有安装"
                return
            }
            failure = nil
            servers.append(installation.config)
            installedID = installation.config.id
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
#endif
