import Foundation

/// Reads the on-disk state of Claude Code and Cursor and builds an
/// `ExternalImportScan`. Pure over `ExternalImportEnvironment` (injected
/// home, skills root, existing OMPChat state): tests drive it with fixture
/// folders and nothing outside those roots is read or written.
///
/// Formats relied on (verified 2026-10-27 against the real files on this
/// Mac; read-only):
///
/// Claude Code, under `~/.claude` / `~/.claude.json`:
/// - `~/.claude/CLAUDE.md` — global instructions (plain Markdown; may use
///   `@path` imports, which are copied verbatim, not expanded — the preview
///   counts them).
/// - `~/.claude.json` — top-level `mcpServers` map (stdio `command/args/env`
///   or remote `type:"http"|"sse", url, headers?`), plus `projects`
///   keyed by absolute project path (only used to find project folders).
/// - `~/.claude/settings.json` — `hooks`, `permissions`, `env`, `model` …
///   (not importable; listed with a reason).
/// - `~/.claude/skills/<name>/SKILL.md` — YAML frontmatter `name`/
///   `description`, folder may hold scripts. May be symlinks.
/// - `~/.claude/commands/<name>.md` — optional frontmatter
///   (`description`, `argument-hint`, `allowed-tools`, `model`), body with
///   `$ARGUMENTS`.
/// - `~/.claude/agents/<name>.md` — subagent definitions (not importable).
/// - `~/.claude/plugins/installed_plugins.json` —
///   `{"version":2,"plugins":{"name@marketplace":[{scope, installPath, …}]}}`
///   with `~/.claude/settings.json` `enabledPlugins` naming the live ones;
///   `installPath` is a plugin root OMPChat's own plugin reader accepts
///   (`.claude-plugin/plugin.json`).
/// - `~/.claude/projects/<encoded-path>/<sessionId>.jsonl` — one line
///   per event; imported kinds are `user`/`assistant` (message.content is a
///   string or a block list: text / thinking / tool_use / tool_result),
///   `summary`/`customTitle`/`aiTitle` for naming, `cwd`/`timestamp` for
///   binding. `isMeta`, `isSidechain`, `isCompactSummary`,
///   `isVisibleInTranscriptOnly` entries are skipped; malformed lines are
///   counted and skipped.
///
/// Cursor, under `~/.cursor` and
/// `~/Library/Application Support/Cursor/User`:
/// - `~/.cursor/mcp.json` — `{"mcpServers": {name: {command|url, …}}}`.
/// - `<project>/.cursor/rules/*.mdc` and `<project>/.cursorrules` — project
///   rules; `.mdc` may carry a frontmatter (`description`, `globs`,
///   `alwaysApply`), body is Markdown.
/// - `~/.cursor/skills/<name>/SKILL.md` — same shape as Codex skills.
/// - `~/.cursor/chats/<hash>/<agentId>/store.db` (data often in its
///   `-wal`) — SQLite `meta` (`"0"` → JSON with `name`, `createdAt`,
///   `latestRootBlobId`) and `blobs` (hex text). Root blobs are a protobuf
///   tree (only field 9 = workspace `file://` URI is read); message blobs
///   are JSON `{role, content}` where content is a string or a list of
///   `{type:"text", text}` parts. Cursor-specific blob fields are ignored.
/// - `workspaceStorage/<id>/workspace.json` — `{"folder":"file://…"}` names
///   the project folders to scan for rules.
///
/// Nothing here writes, moves or deletes anything in the source apps.
public enum ExternalImportScanner {
    /// Chats offered per provider, newest first.
    public static let maxSessionsPerProvider = 20
    /// Cap so a corrupted export cannot stall the scan.
    static let maxInstructionsBytes = 512 * 1024

    public struct Environment: Sendable {
        /// Home of the source apps (`~/.claude`, `~/.cursor`, `~/Library/…`).
        public var home: String
        /// Target user skills root, normally `<home>/.agents/skills`.
        public var skillsRoot: String
        /// Names of OMPChat's existing skills at `skillsRoot`.
        public var existingSkillNames: Set<String>
        /// Existing sidebar projects (imported sessions reuse same-name projects).
        public var projectNames: Set<String>
        /// `Conversation.importedFrom` values already in the workspace.
        public var importedSessionKeys: Set<String>
        /// Existing MCP servers, for dedupe.
        public var mcpServers: [MCPServerConfig]
        /// Current 全局自定义指令 (the instructions block refuses to double-import).
        public var customInstructions: String
        /// Installed plugin manifest names.
        public var installedPluginNames: Set<String>
        /// Existing sidebar projects by name, so imported sessions reuse them.
        public var projectIDByName: [String: UUID]

        public init(
            home: String, skillsRoot: String, existingSkillNames: Set<String>,
            projectNames: Set<String>, importedSessionKeys: Set<String>,
            mcpServers: [MCPServerConfig] = [], customInstructions: String = "",
            installedPluginNames: Set<String> = [],
            projectIDByName: [String: UUID] = [:]
        ) {
            self.home = home
            self.skillsRoot = skillsRoot
            self.existingSkillNames = existingSkillNames
            self.projectNames = projectNames
            self.importedSessionKeys = importedSessionKeys
            self.mcpServers = mcpServers
            self.customInstructions = customInstructions
            self.installedPluginNames = installedPluginNames
            self.projectIDByName = projectIDByName
        }
    }

    // MARK: Scan

    public static func scan(environment: Environment) -> ExternalImportScan {
        var scan = ExternalImportScan(providersFound: [], entries: [], notImported: [])
        let fm = FileManager.default
        let claudeRoot = (environment.home as NSString).appendingPathComponent(".claude")
        let cursorRoot = (environment.home as NSString).appendingPathComponent(".cursor")

        let hasClaude = fm.fileExists(atPath: (environment.home as NSString).appendingPathComponent(".claude.json"))
            || isDirectory(claudeRoot)
        let hasCursor = isDirectory(cursorRoot)
        if hasClaude { scan.providersFound.append(.claudeCode) }
        if hasCursor { scan.providersFound.append(.cursor) }

        if hasClaude { scanClaudeCode(environment: environment, root: claudeRoot, into: &scan) }
        if hasCursor { scanCursor(environment: environment, root: cursorRoot, into: &scan) }
        return scan
    }

    // MARK: Claude Code

    static func scanClaudeCode(environment: Environment, root: String, into scan: inout ExternalImportScan) {
        let provider = ExternalImportProvider.claudeCode
        let fm = FileManager.default
        scan.instructionsEntry(
            provider: provider, tooltip: "CLAUDE.md 将导入为 AGENTS.md",
            globalFile: (root as NSString).appendingPathComponent("CLAUDE.md"),
            existing: environment.customInstructions,
            sourceName: "Claude Code 全局 CLAUDE.md"
        )
        let state = readClaudeState(root: root)
        scanMCPTable(
            provider: provider, table: state.mcpServers, environment: environment, into: &scan
        )
        scanSkillFolders(provider: provider, folder: (root as NSString).appendingPathComponent("skills"), environment: environment, sourceLabel: "Claude Code", into: &scan)
        scanCommandFiles(provider: provider, folder: (root as NSString).appendingPathComponent("commands"), environment: environment, into: &scan)
        scanClaudePlugins(environment: environment, root: root, into: &scan)
        let sessions = claudeSessions(environment: environment, root: root)
        scan.sessionsAppend(provider: provider, kind: .sessions, rows: sessionEntries(provider: provider, environment: environment, sessions: sessions))

        // Project folders: every known Claude Code project that has a
        // CLAUDE.md and no AGENTS.md.
        let folders = Set(state.projectFolders.union(sessions.compactMap(\.workingDirectory)))
        var projectRows: [ExternalImportEntry] = []
        for folder in folders.sorted() where isDirectory(folder) {
            let source = (folder as NSString).appendingPathComponent("CLAUDE.md")
            guard let body = readBounded(source), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let agents = (folder as NSString).appendingPathComponent(AgentsMDLoader.fileName)
            let name = (folder as NSString).lastPathComponent
            if fm.fileExists(atPath: agents) {
                projectRows.append(ExternalImportEntry(
                    id: "\(provider.rawValue).projects.\(folder)", provider: provider, kind: .projects,
                    title: name, detail: folder, count: 1,
                    skippedReason: "项目已有 \(AgentsMDLoader.fileName)，不会覆盖或合并", tooltip: "CLAUDE.md 将导入为 AGENTS.md",
                    operation: nil
                ))
            } else {
                projectRows.append(ExternalImportEntry(
                    id: "\(provider.rawValue).projects.\(folder)", provider: provider, kind: .projects,
                    title: name, detail: "在 \(folder) 写入 \(AgentsMDLoader.fileName)（来自 CLAUDE.md）", count: 1,
                    skippedReason: nil, tooltip: "CLAUDE.md 将导入为 AGENTS.md",
                    operation: .writeAgentsMD(projectRoot: folder, sourceName: "Claude Code CLAUDE.md", body: body)
                ))
            }
        }
        scan.sessionsAppend(provider: provider, kind: .projects, rows: projectRows)
        scan.notImported.append(contentsOf: claudeNotImported(root: root))
    }

    static func claudeNotImported(root: String) -> [ExternalImportScan.NotImported] {
        let provider = ExternalImportProvider.claudeCode
        var list = [
            ExternalImportScan.NotImported(
                id: "\(provider.rawValue).settings", provider: provider, kind: .settings,
                reason: "settings.json 的 permissions、env、model 是 Claude Code 自己的运行配置，OMPChat 没有对应设置"
            ),
            ExternalImportScan.NotImported(
                id: "\(provider.rawValue).hooks", provider: provider, kind: .hooks,
                reason: "settings.json 里的钩子绑定 Claude Code 的工具名与输入格式，无法安全迁移"
            ),
            ExternalImportScan.NotImported(
                id: "\(provider.rawValue).agents", provider: provider, kind: .agents,
                reason: "OMPChat 没有子代理，~/.claude/agents 的定义无法导入"
            ),
            ExternalImportScan.NotImported(
                id: "\(provider.rawValue).memory", provider: provider, kind: .memory,
                reason: "Claude Code 的记忆按项目存放，放进 OMPChat 的全局记忆会污染其他对话"
            ),
        ]
        if !isDirectory((root as NSString).appendingPathComponent("memory")),
           !hasAnySubdirectory((root as NSString).appendingPathComponent("projects"), named: "memory") {
            list.removeAll { $0.kind == .memory }
        }
        return list
    }

    /// `~/.claude.json` pieces the scanner needs. Secrets stay in `mcpServers`
    /// ops only; never logged or previewed.
    static func readClaudeState(root: String) -> (mcpServers: [String: Any], projectFolders: Set<String>) {
        // ~/.claude.json sits beside the .claude folder.
        let path = ((root as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".claude.json")
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([:], [])
        }
        var folders = Set<String>()
        if let table = object["projects"] as? [String: Any] {
            for key in table.keys {
                let trimmed = key.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("/") { folders.insert(trimmed) }
            }
        }
        let servers = object["mcpServers"] as? [String: Any] ?? [:]
        return (servers, folders)
    }

    static func scanClaudePlugins(environment: Environment, root: String, into scan: inout ExternalImportScan) {
        let provider = ExternalImportProvider.claudeCode
        let registry = (root as NSString).appendingPathComponent("plugins/installed_plugins.json")
        guard let data = FileManager.default.contents(atPath: registry),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = object["plugins"] as? [String: [Any]] else { return }

        // enabledPlugins: {"plugin@marketplace": true} in settings.json.
        var enabled: Set<String> = []
        if let settingsData = FileManager.default.contents(atPath: (root as NSString).appendingPathComponent("settings.json")),
           let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
           let table = settings["enabledPlugins"] as? [String: Any] {
            enabled = Set(table.filter { ($0.value as? Bool) == true }.keys)
        }
        let keys = plugins.keys.filter { enabled.isEmpty || enabled.contains($0) }.sorted()
        for key in keys {
            guard let entries = plugins[key], let entry = entries.first as? [String: Any],
                  let folder = entry["installPath"] as? String else { continue }
            let name = key.split(separator: "@").first.map(String.init) ?? key
            if environment.installedPluginNames.contains(name) {
                scan.entries.append(ExternalImportEntry(
                    id: "\(provider.rawValue).plugins.\(key)", provider: provider, kind: .plugins,
                    title: name, detail: folder, count: 1,
                    skippedReason: "OMPChat 已安装同名插件", tooltip: nil,
                    operation: nil
                ))
                continue
            }
            guard isDirectory(folder), manifestExists(folder) else {
                scan.entries.append(ExternalImportEntry(
                    id: "\(provider.rawValue).plugins.\(key)", provider: provider, kind: .plugins,
                    title: name, detail: folder, count: 1,
                    skippedReason: "插件文件夹没有 plugin.json 清单", tooltip: nil,
                    operation: nil
                ))
                continue
            }
            scan.entries.append(ExternalImportEntry(
                id: "\(provider.rawValue).plugins.\(key)", provider: provider, kind: .plugins,
                title: name, detail: "安装插件「\(name)」（钩子装好后保持未信任，需单独确认）", count: 1,
                skippedReason: nil, tooltip: nil,
                operation: .installPlugin(folder: folder, name: name)
            ))
        }
    }

    static func manifestExists(_ pluginRoot: String) -> Bool {
        [PluginManifest.manifestPath, PluginManifest.legacyManifestPath].contains {
            FileManager.default.fileExists(atPath: (pluginRoot as NSString).appendingPathComponent($0))
        }
    }

    // MARK: Cursor

    static func scanCursor(environment: Environment, root: String, into scan: inout ExternalImportScan) {
        let provider = ExternalImportProvider.cursor
        // MCP: ~/.cursor/mcp.json
        let mcpPath = (root as NSString).appendingPathComponent("mcp.json")
        if let data = FileManager.default.contents(atPath: mcpPath),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let table = (object["mcpServers"] as? [String: Any]) ?? (object.count > 0 && object["mcpServers"] == nil ? object : nil) {
            scanMCPTable(provider: provider, table: table, environment: environment, into: &scan)
        }
        scanSkillFolders(provider: provider, folder: (root as NSString).appendingPathComponent("skills"), environment: environment, sourceLabel: "Cursor", into: &scan)
        scanCommandFiles(provider: provider, folder: (root as NSString).appendingPathComponent("commands"), environment: environment, into: &scan)

        let sessions = cursorSessions(environment: environment, root: root)
        scan.sessionsAppend(provider: provider, kind: .sessions, rows: sessionEntries(provider: provider, environment: environment, sessions: sessions))

        // Project rules come from the workspace folders Cursor remembers.
        let folders = cursorWorkspaceFolders(environment: environment)
        var projectRows: [ExternalImportEntry] = []
        for folder in folders.sorted() {
            let body = cursorRulesBody(projectRoot: folder)
            guard let text = body?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let agents = (folder as NSString).appendingPathComponent(AgentsMDLoader.fileName)
            let name = (folder as NSString).lastPathComponent
            let detail = "在 \(folder) 写入 \(AgentsMDLoader.fileName)（来自 Cursor 规则）"
            let tooltip = "Cursor 规则将导入为 AGENTS.md"
            if FileManager.default.fileExists(atPath: agents) {
                projectRows.append(ExternalImportEntry(
                    id: "\(provider.rawValue).projects.\(folder)", provider: provider, kind: .projects,
                    title: name, detail: folder, count: 1,
                    skippedReason: "项目已有 \(AgentsMDLoader.fileName)，不会覆盖或合并", tooltip: tooltip, operation: nil
                ))
            } else {
                projectRows.append(ExternalImportEntry(
                    id: "\(provider.rawValue).projects.\(folder)", provider: provider, kind: .projects,
                    title: name, detail: detail + (body?.note.map { "。注释：\($0)" } ?? ""), count: 1,
                    skippedReason: nil, tooltip: tooltip,
                    operation: .writeAgentsMD(projectRoot: folder, sourceName: "Cursor 规则", body: text)
                ))
            }
        }
        scan.sessionsAppend(provider: provider, kind: .projects, rows: projectRows)
        scan.notImported.append(contentsOf: [
            ExternalImportScan.NotImported(
                id: "\(provider.rawValue).settings", provider: provider, kind: .settings,
                reason: "Cursor 的设置在编辑器私有的 state.vscdb 里，没有可迁移的文件"
            ),
            ExternalImportScan.NotImported(
                id: "\(provider.rawValue).hooks", provider: provider, kind: .hooks,
                reason: "hooks.json 是 Cursor 自己的事件模型，OMPChat 的钩子随插件提供"
            ),
            ExternalImportScan.NotImported(
                id: "\(provider.rawValue).agents", provider: provider, kind: .agents,
                reason: "OMPChat 没有子代理，Cursor 的子代理定义无法导入"
            ),
            ExternalImportScan.NotImported(
                id: "\(provider.rawValue).memory", provider: provider, kind: .memory,
                reason: "Cursor 的全局 Rules 存在私有数据库里，无法读取；项目规则走「项目」一项"
            ),
            ExternalImportScan.NotImported(
                id: "\(provider.rawValue).plugins", provider: provider, kind: .plugins,
                reason: "Cursor 插件是 VS Code 扩展，OMPChat 用 Codex 插件格式"
            ),
        ])
    }

    /// Folders from `workspaceStorage/*/workspace.json` that still exist.
    static func cursorWorkspaceFolders(environment: Environment) -> Set<String> {
        let storage = ((environment.home as NSString).appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage"))
        var folders = Set<String>()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: storage) else { return folders }
        for name in names {
            let path = (storage as NSString).appendingPathComponent("\(name)/workspace.json")
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uri = object["folder"] as? String,
                  let url = URL(string: uri), url.isFileURL else { continue }
            let folder = url.path
            if isDirectory(folder) { folders.insert(folder) }
        }
        return folders
    }

    /// Joins `.cursor/rules/*.mdc` bodies and `.cursorrules` into one
    /// AGENTS.md text, with a note about dropped frontmatter.
    static func cursorRulesBody(projectRoot: String) -> (text: String, note: String?)? {
        let fm = FileManager.default
        var sections: [String] = []
        var note: String?
        let rulesDir = (projectRoot as NSString).appendingPathComponent(".cursor/rules")
        if let names = try? fm.contentsOfDirectory(atPath: rulesDir).sorted() {
            for name in names where name.hasSuffix(".mdc") {
                let path = (rulesDir as NSString).appendingPathComponent(name)
                guard let raw = readBounded(path) else { continue }
                let (front, body) = splitMDC(raw)
                if let front, !front.isEmpty {
                    note = [note, "\(name)：frontmatter（\(front)）保留为注释"].compactMap { $0 }.joined(separator: "；")
                }
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                sections.append("## \(name)\n\n\(trimmed)")
            }
        }
        let legacy = (projectRoot as NSString).appendingPathComponent(".cursorrules")
        if let raw = readBounded(legacy), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("## .cursorrules\n\n\(raw.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard !sections.isEmpty else { return nil }
        return (sections.joined(separator: "\n\n"), note)
    }

    /// `.mdc` frontmatter is not YAML-compatible for our purposes; its
    /// `description`/`globs` ride along as a comment instead of being parsed.
    static func splitMDC(_ raw: String) -> (front: String?, body: String) {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, text)
        }
        lines.removeFirst()
        var front: [String] = []
        while let line = lines.popFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            front.append(line)
        }
        let meaningful = front.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (meaningful.isEmpty ? nil : meaningful.joined(separator: ", "), lines.joined(separator: "\n"))
    }

    // MARK: Shared scans


    static func scanSkillFolders(provider: ExternalImportProvider, folder: String, environment: Environment, sourceLabel: String, into scan: inout ExternalImportScan) {
        guard isDirectory(folder) else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder).sorted() else { return }
        var rows: [ExternalImportEntry] = []
        var taken = environment.existingSkillNames
        for name in names where !name.hasPrefix(".") {
            let source = (folder as NSString).appendingPathComponent(name)
            guard isDirectory(source) else { continue }
            guard FileManager.default.fileExists(atPath: (source as NSString).appendingPathComponent(SkillCatalog.fileName)) else {
                rows.append(ExternalImportEntry(
                    id: "\(provider.rawValue).skills.\(name)", provider: provider, kind: .skills,
                    title: name, detail: source, count: 1,
                    skippedReason: "没有 SKILL.md，不是 Codex 形状的技能", tooltip: nil, operation: nil
                ))
                continue
            }
            if taken.contains(name) {
                rows.append(ExternalImportEntry(
                    id: "\(provider.rawValue).skills.\(name)", provider: provider, kind: .skills,
                    title: name, detail: source, count: 1,
                    skippedReason: "技能「\(name)」已存在，跳过", tooltip: nil, operation: nil
                ))
                continue
            }
            taken.insert(name)
            rows.append(ExternalImportEntry(
                id: "\(provider.rawValue).skills.\(name)", provider: provider, kind: .skills,
                title: name, detail: "复制到 \(environment.skillsRoot)/\(name)", count: 1,
                skippedReason: nil, tooltip: nil,
                operation: .copySkill(sourceFolder: source, name: name)
            ))
        }
        scan.sessionsAppend(provider: provider, kind: .skills, rows: rows)
    }

    /// Claude Code `commands/*.md` become skills (official Codex does the
    /// same: "Converted into skills"), because OMPChat's slash palette is
    /// built-in only. `$ARGUMENTS` is kept and explained in a header line.
    static func scanCommandFiles(provider: ExternalImportProvider, folder: String, environment: Environment, into scan: inout ExternalImportScan) {
        guard isDirectory(folder) else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder).sorted() else { return }
        var rows: [ExternalImportEntry] = []
        var taken = environment.existingSkillNames
        for fileName in names where fileName.hasSuffix(".md") {
            let path = (folder as NSString).appendingPathComponent(fileName)
            var isDir: ObjCBool = false
            guard fmFileExists(path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let stem = (fileName as NSString).deletingPathExtension
            guard let raw = readBounded(path), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let (front, body) = splitMDC(raw)
            let description = front.flatMap { value -> String? in
                guard let range = value.range(of: "description:") else { return nil }
                return String(value[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            var skillBody = "来自 \(provider.displayName) 命令 /\(stem)；`$ARGUMENTS` 处填入用户的参数。\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let description, !description.isEmpty {
                skillBody = "来自 \(provider.displayName) 命令 /\(stem)：\(description)。`$ARGUMENTS` 处填入用户的参数。\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let target = stem
            if taken.contains(target) {
                rows.append(ExternalImportEntry(
                    id: "\(provider.rawValue).commands.\(stem)", provider: provider, kind: .commands,
                    title: "/\(stem)", detail: path, count: 1,
                    skippedReason: "技能「\(target)」已存在，跳过", tooltip: nil, operation: nil
                ))
                continue
            }
            taken.insert(target)
            let skillMD = "---\nname: \(target)\ndescription: \(yamlLine(description ?? "\(provider.displayName) 命令 /\(target) 的说明"))\n---\n\n\(skillBody)\n"
            rows.append(ExternalImportEntry(
                id: "\(provider.rawValue).commands.\(stem)", provider: provider, kind: .commands,
                title: "/\(stem)", detail: "转成技能「\(target)」装到 \(environment.skillsRoot)/\(target)", count: 1,
                skippedReason: nil, tooltip: "官方做法：命令转换为技能",
                operation: .copySkill(sourceFolder: commandSourceFolder(path: path, skillMD: skillMD), name: target)
            ))
        }
        scan.sessionsAppend(provider: provider, kind: .commands, rows: rows)
    }

    /// A command is a single file; it becomes a one-file skill folder built
    /// in the destination, so nothing is staged in the source tree. The op
    /// carries the text via a marker file inside the temp container.
    static func commandSourceFolder(path: String, skillMD: String) -> String {
        let container = (NSTemporaryDirectory() as NSString).appendingPathComponent("omp-import-cmd-\(UUID().uuidString)")
        let folder = (container as NSString).appendingPathComponent("skill")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: (folder as NSString).appendingPathComponent(SkillCatalog.fileName), contents: Data(skillMD.utf8))
        return folder
    }

    static func yamlLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\"" + collapsed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func scanMCPTable(provider: ExternalImportProvider, table: [String: Any], environment: Environment, into scan: inout ExternalImportScan) {
        var rows: [ExternalImportEntry] = []
        var workable: [String: Any] = [:]
        for name in table.keys.sorted() {
            guard let entry = table[name] as? [String: Any] else { continue }
            let type = entry["type"] as? String
            if type == "sse" {
                rows.append(mcpEntry(provider: provider, name: name, table: table, reason: "SSE 传输：OMPChat 只支持 Streamable HTTP", op: nil))
                continue
            }
            if let headers = entry["headers"] as? [String: Any], !headers.isEmpty {
                rows.append(mcpEntry(provider: provider, name: name, table: table, reason: "需要请求头（headers），OMPChat 暂不支持远程请求头", op: nil))
                continue
            }
            workable[name] = entry
        }
        if !workable.isEmpty, let data = try? JSONSerialization.data(withJSONObject: workable) {
            let parsed = try? MCPServerConfig.parse(data, origin: "import:\(provider.rawValue)")
            for server in parsed?.servers ?? [] {
                let duplicate = environment.mcpServers.contains {
                    $0.id == server.id || ($0.name == server.name && $0.command == server.command && $0.url == server.url)
                }
                if duplicate {
                    rows.append(mcpEntry(provider: provider, name: server.name, table: workable, reason: "与已有服务器重复（同名同命令），跳过", op: nil))
                } else {
                    rows.append(mcpEntry(provider: provider, name: server.name, table: workable, reason: nil, op: .addMCPServer(server)))
                }
            }
            for item in parsed?.skipped ?? [] {
                rows.append(mcpEntry(provider: provider, name: item.name, table: workable, reason: item.reason, op: nil))
            }
        }
        scan.sessionsAppend(provider: provider, kind: .mcpServers, rows: rows)
    }

    /// Preview never carries values: env shows key names only, secrets and
    /// long values are redacted.
    static func mcpEntry(provider: ExternalImportProvider, name: String, table: [String: Any], reason: String?, op: ExternalImportOperation?) -> ExternalImportEntry {
        let entry = table[name] as? [String: Any] ?? [:]
        let command = entry["command"] as? String
        let url = entry["url"] as? String
        let args = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        var detail = command.map { ([ $0 ] + args).joined(separator: " ") } ?? (url ?? name)
        if detail.count > 160 { detail = String(detail.prefix(160)) + "…" }
        let envKeys = (entry["env"] as? [String: Any])?.keys.sorted() ?? []
        if !envKeys.isEmpty {
            detail += " · 环境变量 \(envKeys.joined(separator: "、")) 存入钥匙串"
        }
        return ExternalImportEntry(
            id: "\(provider.rawValue).mcpServers.\(name)", provider: provider, kind: .mcpServers,
            title: name, detail: detail, count: 1, skippedReason: reason, tooltip: nil, operation: op
        )
    }

    static func sessionEntries(provider: ExternalImportProvider, environment: Environment, sessions: [ExternalImportSession]) -> [ExternalImportEntry] {
        sessions.map { session in
            let imported = environment.importedSessionKeys.contains(session.key)
            let binding = session.workingDirectory ?? "未绑定文件夹（原文件夹已不存在）"
            return ExternalImportEntry(
                id: session.key, provider: provider, kind: .sessions,
                title: session.title,
                detail: "\(session.messages.count) 条消息 · \(binding) · \(session.preview)",
                count: 1,
                skippedReason: imported ? "已导入过，跳过" : nil,
                tooltip: "\(session.messages.count) 条消息来自 \(provider.displayName)",
                operation: imported ? nil : .importSession(session)
            )
        }
    }

    // MARK: Claude Code sessions

    static func claudeSessions(environment: Environment, root: String) -> [ExternalImportSession] {
        let projectsDir = (root as NSString).appendingPathComponent("projects")
        var files: [(path: String, mtime: Date)] = []
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) {
            for dir in dirs {
                let dirPath = (projectsDir as NSString).appendingPathComponent(dir)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { continue }
                for name in names where name.hasSuffix(".jsonl") {
                    let path = (dirPath as NSString).appendingPathComponent(name)
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                       let mtime = attributes[.modificationDate] as? Date {
                        files.append((path, mtime))
                    }
                }
            }
        }
        let newest = files.sorted { $0.mtime > $1.mtime }.prefix(maxSessionsPerProvider)
        var sessions: [ExternalImportSession] = []
        for file in newest {
            if let session = parseClaudeSession(path: file.path) { sessions.append(session) }
        }
        return sessions
    }

    /// One `<sessionId>.jsonl`. Session id, its project folder and a title
    /// come from the file; nothing outside is consulted. Long transcripts
    /// stop at `maxLinesPerSession` — the head of a chat is what imports.
    static let maxLinesPerSession = 800

    static func parseClaudeSession(path: String) -> ExternalImportSession? {
        let lines = readLines(path, maxLines: maxLinesPerSession)
        guard !lines.isEmpty else { return nil }
        var key = ((path as NSString).deletingPathExtension as NSString).lastPathComponent
        var cwd: String?
        var firstDate: Date?
        var lastDate: Date?
        var customTitle: String?
        var aiTitle: String?
        var messages: [ExternalImportMessage] = []
        var malformed = 0

        func append(_ role: String, _ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let last = messages.last, last.role == role {
                messages[messages.count - 1].text += "\n\n" + trimmed
            } else {
                messages.append(ExternalImportMessage(role: role, text: trimmed))
            }
        }

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                malformed += 1
                continue
            }
            if let stamp = (object["timestamp"] as? String).flatMap(parseClaudeDate) {
                if firstDate == nil { firstDate = stamp }
                lastDate = stamp
            }
            if cwd == nil, let value = object["cwd"] as? String, value.hasPrefix("/") { cwd = value }
            switch object["type"] as? String {
            case "summary":
                if let text = object["summary"] as? String, customTitle == nil, aiTitle == nil { customTitle = text }
            case "custom-title":
                if let text = object["customTitle"] as? String { customTitle = text }
            case "ai-title":
                if let text = object["aiTitle"] as? String { aiTitle = text }
            case "user":
                if object["isMeta"] as? Bool == true
                    || object["isSidechain"] as? Bool == true
                    || object["isCompactSummary"] as? Bool == true
                    || object["isVisibleInTranscriptOnly"] as? Bool == true { continue }
                guard let message = object["message"] as? [String: Any] else { continue }
                for text in claudeUserTexts(message["content"]) { append("user", text) }
            case "assistant":
                if object["isSidechain"] as? Bool == true { continue }
                guard let message = object["message"] as? [String: Any] else { continue }
                for (role, text) in claudeAssistantTexts(message["content"]) { append(role, text) }
            default:
                continue
            }
        }
        guard messages.contains(where: { $0.role == "user" }) else { return nil }
        let title = customTitle ?? aiTitle ?? String(messages.first(where: { $0.role == "user" })?.text.prefix(40) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ExternalImportSession(
            key: "claude-code:\(key)", title: title.isEmpty ? "未命名会话" : title,
            workingDirectory: cwd.flatMap { isDirectory($0) ? $0 : nil },
            messages: messages, createdAt: firstDate, updatedAt: lastDate
        )
    }

    /// Real user words only: command invocations, local stdout, reminders
    /// and results are machine wrappers, not what the user typed.
    static func claudeUserTexts(_ content: Any?) -> [String] {
        if let text = content as? String {
            return textHasTag(text) ? [] : [text]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        var out: [String] = []
        for block in blocks where block["type"] as? String == "text" {
            guard let text = block["text"] as? String, !textHasTag(text) else { continue }
            out.append(text)
        }
        return out
    }

    /// Assistant replies keep their words; tool calls become one-line
    /// summaries with redacted arguments.
    static func claudeAssistantTexts(_ content: Any?) -> [(role: String, text: String)] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        var out: [(String, String)] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { out.append(("assistant", text)) }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let summary = redactedToolSummary(block["input"] as? [String: Any])
                out.append(("assistant", "〔调用工具 \(name)〕\(summary)"))
            default:
                continue
            }
        }
        return out
    }

    static func textHasTag(_ text: String) -> Bool {
        let prefixes = ["<command-message", "<command-name", "<local-command-stdout", "<local-command-caveat", "<system-reminder", "<task-notification"]
        return prefixes.contains { text.hasPrefix($0) }
    }

    /// Prefers the useful keys of a tool input, truncates, and strips
    /// secret-looking `key=value` / `Authorization:` content.
    static func redactedToolSummary(_ input: [String: Any]?) -> String {
        guard let input, !input.isEmpty else { return "" }
        let preferred = ["command", "file_path", "url", "pattern", "query", "prompt", "description"]
        var parts: [String] = []
        for key in preferred {
            if let value = input[key] as? String, !value.isEmpty { parts.append(value) }
        }
        if parts.isEmpty {
            parts = input.keys.sorted().compactMap { input[$0] as? String }
        }
        var line = parts.joined(separator: " ")
        line = ExternalImportRedact.string(line)
        if line.count > 120 { line = String(line.prefix(120)) + "…" }
        return line
    }

    static func parseClaudeDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Cursor sessions

    static func cursorSessions(environment: Environment, root: String) -> [ExternalImportSession] {
        let chats = (root as NSString).appendingPathComponent("chats")
        var files: [(path: String, mtime: Date)] = []
        if let hashes = try? FileManager.default.contentsOfDirectory(atPath: chats) {
            for hash in hashes {
                let hashPath = (chats as NSString).appendingPathComponent(hash)
                guard let agents = try? FileManager.default.contentsOfDirectory(atPath: hashPath) else { continue }
                for agent in agents {
                    let path = (hashPath as NSString).appendingPathComponent("\(agent)/store.db")
                    guard FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: path + "-wal") else { continue }
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: path + "-wal"),
                       let mtime = attributes[.modificationDate] as? Date {
                        files.append((path, mtime))
                    } else if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                              let mtime = attributes[.modificationDate] as? Date {
                        files.append((path, mtime))
                    }
                }
            }
        }
        let newest = files.sorted { $0.mtime > $1.mtime }.prefix(maxSessionsPerProvider)
        var sessions: [ExternalImportSession] = []
        for file in newest {
            let key = "cursor:" + ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if let session = CursorChatReader.read(path: file.path, key: key) {
                sessions.append(session)
            }
        }
        return sessions
    }

    // MARK: Small helpers

    static func readBounded(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        let bounded = data.prefix(maxInstructionsBytes)
        return String(decoding: bounded, as: UTF8.self)
    }

    /// Newline-separated lines without loading the whole file as one string;
    /// big session transcripts stay bounded in memory. `maxLines` stops the
    /// read early so a multi-megabyte transcript cannot stall the scan.
    static func readLines(_ path: String, maxLines: Int? = nil) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        var lines: [String] = []
        var buffer = Data()
        let chunk = 1 << 20
        while true {
            if let maxLines, lines.count >= maxLines { break }
            let data = handle.readData(ofLength: chunk)
            if data.isEmpty { break }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
                if let maxLines, lines.count >= maxLines { return lines }
            }
        }
        if !buffer.isEmpty { lines.append(String(decoding: buffer, as: UTF8.self)) }
        return lines
    }

    static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }

    static func fmFileExists(_ path: String, isDirectory: inout ObjCBool) -> Bool {
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    }

    static func hasAnySubdirectory(_ root: String, named name: String) -> Bool {
        guard isDirectory(root), let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else { return false }
        return dirs.contains { isDirectory((root as NSString).appendingPathComponent("\($0)/\(name)")) }
    }
}

/// Secrets never reach previews or logs: values after `key=`/`key:` for
/// secret-looking keys, and `Authorization:` headers, are masked.
public enum ExternalImportRedact {
    static let secretKeys = ["token", "key", "secret", "password", "authorization", "api_key", "apikey", "apikeyheader", "bearer"]

    public static func string(_ text: String) -> String {
        var output = text
        for key in secretKeys {
            output = mask(output, pattern: key + "=")
            output = mask(output, pattern: key + ":")
            output = mask(output, pattern: key + " ")
        }
        return output
    }

    /// Replaces the rest of the token after the marker up to whitespace/quote
    /// with •••.
    static func mask(_ text: String, pattern: String) -> String {
        var result = text
        var searchStart = result.startIndex
        while let marker = result.range(of: pattern, options: .caseInsensitive, range: searchStart..<result.endIndex) {
            let valueStart = marker.upperBound
            var valueEnd = valueStart
            while valueEnd < result.endIndex, !"\"' \t\n&".contains(result[valueEnd]) { valueEnd = result.index(after: valueEnd) }
            if valueEnd > valueStart {
                result.replaceSubrange(valueStart..<valueEnd, with: "•••")
                searchStart = result.index(valueStart, offsetBy: 3, limitedBy: result.endIndex) ?? result.endIndex
            } else {
                searchStart = marker.upperBound
            }
        }
        return result
    }
}
