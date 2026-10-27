import XCTest
#if canImport(SQLite3)
import SQLite3
#endif
@testable import OMPCore

/// Fixture-driven tests for the external import scan + executor. Everything
/// lives in a temporary "home"; the user's real ~/.claude / ~/.cursor are
/// never touched.
@MainActor
final class ExternalImportScanTests: XCTestCase {
    private var home = ""

    override func setUp() {
        super.setUp()
        home = NSTemporaryDirectory() + "omp-import-tests-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    // MARK: Fixture builders

    @discardableResult
    private func write(_ path: String, _ contents: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
        return path
    }

    private func claudeClaudeJSON(mcpServers: [String: Any]) {
        let object: [String: Any] = [
            "mcpServers": mcpServers,
            "projects": [
                "\(home)/projects/alpha": ["hasTrustDialogAccepted": true],
                "\(home)/projects/beta": [:],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        write("\(home)/.claude.json", String(decoding: data, as: UTF8.self))
    }

    private func claudeSession(
        _ name: String, project: String, lines: [String], mtimeOffset: TimeInterval = 0
    ) -> String {
        let dir = "\(home)/.claude/projects/\(project)"
        let path = "\(dir)/\(name).jsonl"
        write(path, lines.joined(separator: "\n") + "\n")
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(mtimeOffset)], ofItemAtPath: path)
        return path
    }

    private func pluginFolder(_ name: String, manifest: String) -> String {
        let root = "\(home)/plugins-src/\(name)"
        write("\(root)/.claude-plugin/plugin.json", manifest)
        write("\(root)/skills/demo/SKILL.md", "---\nname: demo\ndescription: 插件自带技能\n---\n\n正文\n")
        return root
    }

    /// Builds a full Claude Code + Cursor fixture tree.
    private func fullFixture() {
        write("\(home)/.claude/CLAUDE.md", "# 全局规则\n\n先写测试再写实现。\n")
        claudeClaudeJSON(mcpServers: [
            "local-tool": ["type": "stdio", "command": "node", "args": ["server.js"], "env": ["API_TOKEN": "sk-super-secret-value"]],
            "remote-ok": ["type": "http", "url": "https://mcp.example.com"],
            "remote-headers": ["type": "http", "url": "https://hdr.example.com", "headers": ["Authorization": "Bearer abc"]],
            "legacy-sse": ["type": "sse", "url": "https://sse.example.com"],
        ])
        write("\(home)/.claude/skills/alpha/SKILL.md", "---\nname: alpha\ndescription: 阿尔法技能\n---\n\n步骤\n")
        write("\(home)/.claude/skills/just-a-folder/notes.txt", "不是技能")
        write("\(home)/.claude/commands/deploy.md", "---\ndescription: 部署到服务器\n---\n\n按顺序执行：$ARGUMENTS\n")
        write("\(home)/.claude/agents/backend.md", "# 后端代理\n")
        write("\(home)/.claude/settings.json", #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]},"enabledPlugins":{"demo-plugin@market": true}}"#)

        let plugin = pluginFolder("demo-plugin", manifest: #"{"name":"demo-plugin","version":"1.0.0","description":"演示插件"}"#)
        let registry: [String: Any] = ["version": 2, "plugins": ["demo-plugin@market": [["scope": "user", "installPath": plugin, "version": "1.0.0"]]]]
        let registryData = try! JSONSerialization.data(withJSONObject: registry)
        write("\(home)/.claude/plugins/installed_plugins.json", String(decoding: registryData, as: UTF8.self))

        // Two sessions: one well-formed with tool calls and secrets, one for
        // the "already imported" case.
        claudeSession("aaaaaaaa-1111", project: "-tmp-fixtures-alpha", lines: [
            #"{"type":"summary","summary":"旧摘要标题"}"#,
            #"{"type":"custom-title","customTitle":"订单同步排查"}"#,
            #"{"type":"user","cwd":"\#(home)/projects/alpha","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"帮我把订阅订单同步到对账表"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"先看代码。"},{"type":"tool_use","name":"Bash","input":{"command":"curl -H 'Authorization: Bearer live-token-xyz' https://api.example.com"}}]}}"#,
            #"{"type":"user","cwd":"\#(home)/projects/alpha","timestamp":"2026-10-01T10:00:06.000Z","isMeta":true,"message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"这行不是 JSON"#,
            #"{"type":"assistant","cwd":"\#(home)/projects/alpha","timestamp":"2026-10-01T10:01:00.000Z","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"子代理的话不该出现"}]}}"#,
            #"{"type":"user","cwd":"\#(home)/projects/alpha","timestamp":"2026-10-01T10:02:00.000Z","message":{"role":"user","content":"<command-name>/ace-debug</command-name><command-message>调试</command-message><command-args></command-args>"}}"#,
            #"{"type":"user","cwd":"\#(home)/projects/alpha","timestamp":"2026-10-01T10:03:00.000Z","message":{"role":"user","content":"改完了吗？"}}"#,
            #"{"type":"assistant","cwd":"\#(home)/projects/alpha","timestamp":"2026-10-01T10:03:10.000Z","message":{"role":"assistant","content":[{"type":"text","text":"改完了。"}]}}"#,
        ])
        claudeSession("aaaaaaaa-2222", project: "-tmp-fixtures-beta", lines: [
            #"{"type":"user","cwd":"\#(home)/projects/missing-folder","timestamp":"2026-10-02T10:00:00.000Z","message":{"role":"user","content":"已导入过的会话"}}"#,
        ], mtimeOffset: -60)
        write("\(home)/.claude/projects/alpha/memory/MEMORY.md", "用户偏好深色主题。")
        // A project whose AGENTS.md already exists.
        try! FileManager.default.createDirectory(atPath: "\(home)/projects/alpha", withIntermediateDirectories: true)
        write("\(home)/projects/alpha/CLAUDE.md", "# Alpha 项目规则\n")
        write("\(home)/projects/beta/CLAUDE.md", "# Beta 项目规则\n")
        write("\(home)/projects/beta/AGENTS.md", "# 已有内容，不许动\n")

        // Cursor side.
        write("\(home)/.cursor/mcp.json", #"{"mcpServers":{"local-tool":{"command":"node","args":["server.js"]},"remote-plain":{"type":"http","url":"https://plain.example.com"}}}"#)
        write("\(home)/.cursor/skills/cursor-skill/SKILL.md", "---\nname: cursor-skill\ndescription: Cursor 技能\n---\n\n正文\n")
        let project = "\(home)/projects/gamma"
        write("\(project)/.cursor/rules/ style.mdc".replacingOccurrences(of: " ", with: ""), "---\ndescription: 命名规范\nglobs: \"*.ts\"\nalwaysApply: true\n---\n\nTypeScript 一律严格模式。\n")
        write("\(project)/.cursorrules", "提交信息用中文。\n")
        let storage = "\(home)/Library/Application Support/Cursor/User/workspaceStorage/abc123"
        write("\(storage)/workspace.json", "{\"folder\":\"file://\(project)\"}")
        writeCursorChatFixture()
    }

    private func scan(
        existingSkillNames: Set<String> = [],
        importedSessionKeys: Set<String> = [],
        mcpServers: [MCPServerConfig] = [],
        customInstructions: String = "",
        installedPluginNames: Set<String> = [],
        projectIDByName: [String: UUID] = [:]
    ) -> ExternalImportScan {
        ExternalImportScanner.scan(environment: ExternalImportScanner.Environment(
            home: home,
            skillsRoot: "\(home)/.agents/skills",
            existingSkillNames: existingSkillNames,
            projectNames: Set(projectIDByName.keys),
            importedSessionKeys: importedSessionKeys,
            mcpServers: mcpServers,
            customInstructions: customInstructions,
            installedPluginNames: installedPluginNames,
            projectIDByName: projectIDByName
        ))
    }

    // MARK: Claude Code scan

    func testClaudeScanCountsAndMappings() {
        fullFixture()
        let result = scan()
        XCTAssertEqual(result.providersFound, [.claudeCode, .cursor])

        let skills = result.groups(provider: .claudeCode).first { $0.kind == .skills }
        XCTAssertEqual(skills?.rows.map(\.title), ["alpha", "just-a-folder"], "无 SKILL.md 的文件夹也要显示，并说明原因")
        XCTAssertEqual(skills?.rows.first?.operation, .copySkill(sourceFolder: "\(home)/.claude/skills/alpha", name: "alpha"))
        XCTAssertEqual(skills?.rows.last?.skippedReason, "没有 SKILL.md，不是 Codex 形状的技能")

        let commands = result.groups(provider: .claudeCode).first { $0.kind == .commands }
        XCTAssertEqual(commands?.rows.map(\.title), ["/deploy"])
        if case .copySkill(_, let name)? = commands?.rows.first?.operation {
            XCTAssertEqual(name, "deploy")
        } else {
            XCTFail("命令应转换为技能")
        }

        let instructions = result.entries.first { $0.provider == .claudeCode && $0.kind == .instructions }
        XCTAssertNotNil(instructions?.operation)
        XCTAssertEqual(instructions?.tooltip, "CLAUDE.md 将导入为 AGENTS.md")
        if case .appendInstructions(_, let block)? = instructions?.operation {
            XCTAssertTrue(block.contains("# 全局规则"))
            XCTAssertTrue(block.contains("## 从 Claude Code 导入"))
        } else {
            XCTFail("全局指令应有追加操作")
        }

        // Project with CLAUDE.md and no AGENTS.md → write; with AGENTS.md → skipped.
        let projects = result.groups(provider: .claudeCode).first { $0.kind == .projects }
        let alpha = projects?.rows.first { $0.title == "alpha" }
        XCTAssertEqual(alpha?.skippedReason, nil)
        if case .writeAgentsMD(let root, _, _)? = alpha?.operation {
            XCTAssertEqual(root, "\(home)/projects/alpha")
        } else {
            XCTFail("alpha 应写入 AGENTS.md")
        }
        let beta = projects?.rows.first { $0.title == "beta" }
        XCTAssertEqual(beta?.skippedReason, "项目已有 AGENTS.md，不会覆盖或合并")
    }

    func testMCPDedupeTransportAndHeaderSkips() {
        fullFixture()
        let existing = MCPServerConfig(id: "local-tool", name: "local-tool", command: "node", args: ["server.js"])
        let result = scan(mcpServers: [existing])
        let rows = result.groups(provider: .claudeCode).first { $0.kind == .mcpServers }?.rows ?? []
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0) })

        XCTAssertEqual(byName["local-tool"]?.skippedReason, "与已有服务器重复（同名同命令），跳过")
        XCTAssertNil(byName["local-tool"]?.operation, "去重后的服务器不应再有导入操作")
        // Secrets are masked: the env key is named, the value never appears.
        XCTAssertFalse(byName["local-tool"]!.detail.contains("sk-super-secret-value"))
        XCTAssertTrue(byName["local-tool"]!.detail.contains("API_TOKEN"))
        if case .addMCPServer(let server)? = byName["remote-ok"]?.operation {
            XCTAssertEqual(server.url, "https://mcp.example.com")
        } else {
            XCTFail("remote-ok 应可导入")
        }
        // The deduped server still carries its config for a future run when
        // the duplicate goes away — checked via a fresh scan without it.
        let clean = scan()
        let cleanRows = clean.groups(provider: .claudeCode).first { $0.kind == .mcpServers }?.rows ?? []
        let local = cleanRows.first { $0.title == "local-tool" }
        if case .addMCPServer(let server)? = local?.operation {
            XCTAssertEqual(server.env["API_TOKEN"], "sk-super-secret-value", "值随操作携带，模型负责入保管库")
            XCTAssertFalse(local!.detail.contains("sk-super-secret-value"))
        } else {
            XCTFail("没有重复时 local-tool 应可导入")
        }
    }

    func testClaudePluginImportOfferedWhenEnabledAndMissing() {
        fullFixture()
        let result = scan(installedPluginNames: [])
        let plugins = result.groups(provider: .claudeCode).first { $0.kind == .plugins }?.rows ?? []
        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.title, "demo-plugin")
        if case .installPlugin(let folder, _)? = plugins.first?.operation {
            XCTAssertTrue(folder.hasSuffix("demo-plugin"))
        } else {
            XCTFail("已启用的插件应可安装")
        }

        let again = scan(installedPluginNames: ["demo-plugin"])
        let rows = again.groups(provider: .claudeCode).first { $0.kind == .plugins }?.rows ?? []
        XCTAssertEqual(rows.first?.skippedReason, "OMPChat 已安装同名插件")
    }

    func testSessionsParsedFromRealisticJSONL() {
        fullFixture()
        let result = scan()
        let sessions = result.groups(provider: .claudeCode).first { $0.kind == .sessions }?.rows ?? []
        let titles = sessions.map(\.title)
        XCTAssertEqual(titles, ["订单同步排查", "已导入过的会话"], "按修改时间倒序")

        let first = try! XCTUnwrap(sessions.first)
        XCTAssertNil(first.skippedReason)
        if case .importSession(let session)? = first.operation {
            XCTAssertEqual(session.key, "claude-code:aaaaaaaa-1111")
            XCTAssertEqual(session.workingDirectory, "\(home)/projects/alpha")
            XCTAssertEqual(session.projectFolderName, "alpha")
            let joined = session.messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
            XCTAssertTrue(joined.contains("帮我把订阅订单同步到对账表"))
            XCTAssertTrue(joined.contains("改完了吗"))
            XCTAssertTrue(joined.contains("〔调用工具 Bash〕"))
            XCTAssertTrue(joined.contains("curl"))
            XCTAssertFalse(joined.contains("live-token-xyz"), "工具摘要必须打码")
            XCTAssertFalse(joined.contains("子代理的话不该出现"))
            XCTAssertFalse(joined.contains("ace-debug"), "命令回显不是用户输入")
            XCTAssertEqual(session.messages.first?.role, "user")
            XCTAssertEqual(session.messages.last?.role, "assistant")
        } else {
            XCTFail("第一个会话应可导入")
        }

        // Already-imported keys come back skipped with no operation.
        let rerun = scan(importedSessionKeys: ["claude-code:aaaaaaaa-2222"])
        let again = rerun.groups(provider: .claudeCode).first { $0.kind == .sessions }?.rows.first { $0.title == "已导入过的会话" }
        XCTAssertEqual(again?.skippedReason, "已导入过，跳过")
        XCTAssertNil(again?.operation)
    }

    func testSessionFolderGoneLeavesThreadUnbound() {
        claudeSession("bbbbbbbb-3333", project: "-tmp-fixtures-gone", lines: [
            #"{"type":"user","cwd":"/nonexistent/path/xyz","timestamp":"2026-10-03T10:00:00.000Z","message":{"role":"user","content":"文件夹没了"}}"#,
        ])
        let result = scan()
        let row = result.groups(provider: .claudeCode).first { $0.kind == .sessions }?.rows.first
        if case .importSession(let session)? = row?.operation {
            XCTAssertNil(session.workingDirectory)
            XCTAssertNil(session.projectFolderName)
        } else {
            XCTFail("会话应可导入")
        }
    }

    func testSessionScanCapsAtTwentyPerProvider() {
        for index in 0..<25 {
            claudeSession("cccccccc-\(String(format: "%04d", index))", project: "-tmp-fixtures-many", lines: [
                #"{"type":"user","timestamp":"2026-10-04T10:00:00.000Z","message":{"role":"user","content":"会话 \#(index)"}}"#,
            ], mtimeOffset: TimeInterval(-index * 60))
        }
        let result = scan()
        let rows = result.groups(provider: .claudeCode).first { $0.kind == .sessions }?.rows ?? []
        XCTAssertEqual(rows.count, ExternalImportScanner.maxSessionsPerProvider)
        XCTAssertEqual(rows.first?.title, "会话 0", "最新者优先")
    }

    func testClaudeNotImportedListExplainsSkippedCategories() {
        fullFixture()
        let result = scan()
        let kinds = Set(result.notImported.filter { $0.provider == .claudeCode }.map(\.kind))
        XCTAssertEqual(kinds, [.settings, .hooks, .agents, .memory])
    }

    // MARK: Cursor scan

    func testCursorScanMCPInstructionsSkillsAndChat() {
        fullFixture()
        let result = scan()
        let mcp = result.groups(provider: .cursor).first { $0.kind == .mcpServers }?.rows ?? []
        XCTAssertEqual(mcp.count, 2, "remote-plain 可导入，且与 Claude 的 local-tool 去重无关（不同 provider 互不去重）")
        XCTAssertTrue(mcp.allSatisfy { $0.skippedReason == nil })

        let project = "\(home)/projects/gamma"
        let projects = result.groups(provider: .cursor).first { $0.kind == .projects }?.rows ?? []
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.tooltip, "Cursor 规则将导入为 AGENTS.md")
        if case .writeAgentsMD(let root, _, let body)? = projects.first?.operation {
            XCTAssertEqual(root, project)
            XCTAssertTrue(body.contains("TypeScript 一律严格模式。"))
            XCTAssertTrue(body.contains("提交信息用中文。"))
            XCTAssertTrue(projects.first!.detail.contains("命名规范"), "frontmatter 的 description 以注释形式进入说明，不进正文")
        } else {
            XCTFail("Cursor 规则应写入 AGENTS.md")
        }

        let sessions = result.groups(provider: .cursor).first { $0.kind == .sessions }?.rows ?? []
        XCTAssertEqual(sessions.count, 1)
        if case .importSession(let session)? = sessions.first?.operation {
            XCTAssertEqual(session.title, "样式讨论")
            XCTAssertTrue(session.messages.contains { $0.role == "user" && $0.text.contains("帮我把按钮改成圆角") })
            XCTAssertEqual(session.workingDirectory, project)
        } else {
            XCTFail("Cursor 会话应可导入")
        }

        let skills = result.groups(provider: .cursor).first { $0.kind == .skills }?.rows ?? []
        XCTAssertEqual(skills.map(\.title), ["cursor-skill"])
    }

    func testCursorNotImportedListExplainsSkippedCategories() {
        fullFixture()
        let result = scan()
        let kinds = Set(result.notImported.filter { $0.provider == .cursor }.map(\.kind))
        XCTAssertEqual(kinds, [.settings, .hooks, .agents, .memory, .plugins])
    }

    func testNothingFoundYieldsEmptyScan() {
        let result = scan()
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.providersFound.isEmpty)
    }

    // MARK: Executor

    private func run(_ selection: ExternalImportSelection, _ result: ExternalImportScan, projectIDByName: [String: UUID] = [:]) -> (ExternalImportReport, ExternalImportExecutor.Outcome) {
        ExternalImportExecutor.run(
            selection: selection,
            scan: result,
            environment: ExternalImportScanner.Environment(
                home: home,
                skillsRoot: "\(home)/.agents/skills",
                existingSkillNames: [],
                projectNames: Set(projectIDByName.keys),
                importedSessionKeys: [],
                mcpServers: [],
                customInstructions: "",
                installedPluginNames: [],
                projectIDByName: projectIDByName
            )
        )
    }

    func testExecutorWritesAgentsMDAndSkillsWithoutTouchingSources() {
        fullFixture()
        let result = scan()
        let selection = ExternalImportSelection(allOf: result)
        // Keep the run focused: instructions + the alpha AGENTS.md + skills.
        let focused = ExternalImportSelection(enabledEntryIDs: Set(selection.enabledEntryIDs.filter { id in
            guard let entry = result.entries.first(where: { $0.id == id }) else { return false }
            return entry.kind == .instructions || entry.kind == .skills || entry.kind == .commands || entry.id.contains(".projects.")
        }))
        let (report, outcome) = run(focused, result)

        let agentsPath = "\(home)/projects/alpha/AGENTS.md"
        let agents = try! String(contentsOfFile: agentsPath, encoding: .utf8)
        XCTAssertTrue(agents.contains("Alpha 项目规则"))
        XCTAssertTrue(agents.contains("源文件没有改动"))
        XCTAssertTrue(outcome.agentsMDWritten.contains(agentsPath))
        // beta was skipped: its file is untouched.
        XCTAssertEqual(try! String(contentsOfFile: "\(home)/projects/beta/AGENTS.md", encoding: .utf8), "# 已有内容，不许动\n")
        XCTAssertEqual(report.lines.first { $0.id.contains(".projects.") && $0.title == "beta" }?.note, "项目已有 AGENTS.md，不会覆盖或合并")

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(home)/.agents/skills/alpha/SKILL.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(home)/.agents/skills/deploy/SKILL.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(home)/.agents/skills/cursor-skill/SKILL.md"))
        XCTAssertEqual(outcome.skillsCopied.sorted(), ["alpha", "cursor-skill", "deploy"])
        // Source tree unchanged: the original skill is still the only copy in ~/.claude/skills.
        XCTAssertEqual(try! FileManager.default.contentsOfDirectory(atPath: "\(home)/.claude/skills").sorted(), ["alpha", "just-a-folder"])

        // Rerun: everything that landed is now skipped.
        let rerunScan = scan(existingSkillNames: Set(outcome.skillsCopied), customInstructions: outcome.instructionsBlocks.joined(separator: "\n\n"))
        let (_, rerunOutcome) = run(ExternalImportSelection(allOf: rerunScan), rerunScan)
        XCTAssertTrue(rerunOutcome.skillsCopied.isEmpty)
        XCTAssertTrue(rerunOutcome.instructionsBlocks.isEmpty)
        let rerunCommands = rerunScan.groups(provider: .claudeCode).first { $0.kind == .commands }?.rows ?? []
        XCTAssertEqual(rerunCommands.first?.skippedReason, "技能「deploy」已存在，跳过")
    }

    func testExecutorBuildsConversationsGroupsAndVaultBoundMCP() {
        fullFixture()
        let result = scan()
        let sessions = result.entries.filter { $0.kind == .sessions && $0.provider == .claudeCode }
        let mcp = result.entries.first { $0.kind == .mcpServers && $0.title == "local-tool" }!
        let projectRow = result.entries.first { $0.kind == .projects && $0.provider == .claudeCode && $0.title == "alpha" }!
        let selection = ExternalImportSelection(enabledEntryIDs: Set([sessions.first!.id, mcp.id, projectRow.id]))
        let existingProject = Project(name: "alpha")
        let (report, outcome) = run(selection, result, projectIDByName: ["alpha": existingProject.id])

        XCTAssertEqual(outcome.conversations.count, 1)
        let conversation = outcome.conversations[0]
        XCTAssertEqual(conversation.importedFrom, "claude-code:aaaaaaaa-1111")
        XCTAssertEqual(conversation.projectID, existingProject.id, "同名项目复用，不新建")
        XCTAssertEqual(conversation.workingDirectory, "\(home)/projects/alpha")
        XCTAssertTrue(conversation.messages.contains { $0.role == .user })
        XCTAssertTrue(outcome.newProjects.isEmpty)

        XCTAssertEqual(outcome.mcpServers.count, 1)
        XCTAssertEqual(outcome.mcpSecrets.first?.variable, "API_TOKEN")
        XCTAssertEqual(outcome.mcpSecrets.first?.value, "sk-super-secret-value")

        XCTAssertEqual(report.importedCount, 3, "\(report.lines.map { "\($0.title): \($0.note ?? "ok")" })")
        XCTAssertEqual(report.lines.first { $0.kind == .projects && $0.title == "项目分组" }?.note, "导入的会话已按原文件夹归入项目")

        // No conversation selected → the projects row says so.
        let (_, emptyOutcome) = run(ExternalImportSelection(enabledEntryIDs: [projectRow.id]), result)
        XCTAssertTrue(emptyOutcome.newProjects.isEmpty)
    }

    func testExecutorCreatesProjectWhenFolderHasNoGroupYet() {
        try! FileManager.default.createDirectory(atPath: "\(home)/projects/solo", withIntermediateDirectories: true)
        claudeSession("dddddddd-4444", project: "-tmp-fixtures-solo", lines: [
            #"{"type":"user","cwd":"\#(home)/projects/solo","timestamp":"2026-10-05T10:00:00.000Z","message":{"role":"user","content":"独立项目"}}"#,
        ])
        let result = scan()
        let sessionRow = result.entries.first { $0.kind == .sessions }!
        let (_, outcome) = run(ExternalImportSelection(enabledEntryIDs: [sessionRow.id]), result)
        XCTAssertEqual(outcome.newProjects.map(\.name), ["solo"])
        XCTAssertEqual(outcome.conversations.first?.projectID, outcome.newProjects.first?.id)
    }

    // MARK: Cursor chat database

    /// Writes a minimal real store.db (meta + blobs) with the same shapes the
    /// app finds on disk, including a `-wal`-adjacent table layout.
    private func writeCursorChatFixture() {
        let agent = UUID().uuidString
        let dir = "\(home)/.cursor/chats/fixturehash/\(agent)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/store.db"
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { return }
        defer { sqlite3_close(database) }
        exec(database, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        exec(database, "CREATE TABLE blobs (id TEXT PRIMARY KEY, data TEXT)")
        let workspaceField = protobufField(9, string: "file://\(home)/projects/gamma")
        let root = protobufField(1, bytes: Data(repeating: 1, count: 32)) + workspaceField
        let rootID = "root\(agent.prefix(8))"
        let userJSON = #"{"role":"user","content":"<timestamp>Fri</timestamp><user_query>帮我把按钮改成圆角</user_query>"}"#
        let assistantJSON = #"{"role":"assistant","content":[{"type":"text","text":"好的。"}]}"#
        let meta: [String: Any] = [
            "agentId": agent, "latestRootBlobId": rootID, "name": "样式讨论", "mode": "default", "createdAt": 1_787_284_493_655.0,
        ]
        exec(database, "INSERT INTO meta (key, value) VALUES ('0', ?)", hex(String(decoding: try! JSONSerialization.data(withJSONObject: meta), as: UTF8.self)))
        exec(database, "INSERT INTO blobs (id, data) VALUES (?, ?)", rootID, hexBinary(root))
        exec(database, "INSERT INTO blobs (id, data) VALUES ('user1', ?)", hex(userJSON))
        exec(database, "INSERT INTO blobs (id, data) VALUES ('assistant1', ?)", hex(assistantJSON))
    }

    private func exec(_ database: OpaquePointer?, _ sql: String, _ arguments: String...) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            XCTFail("fixture SQL 失败：\(sql)")
            return
        }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            XCTFail("fixture SQL 未完成：\(sql)")
            return
        }
    }

    private func hex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// Hex for arbitrary bytes: the blobs column stores hex text.
    private func hexBinary(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func protobufField(_ number: Int, string: String) -> Data {
        var key = UInt64(number << 3 | 2)
        var out = Data()
        while key >= 0x80 { out.append(UInt8(key & 0x7F | 0x80)); key >>= 7 }
        out.append(UInt8(key))
        var length = UInt64(string.utf8.count)
        while length >= 0x80 { out.append(UInt8(length & 0x7F | 0x80)); length >>= 7 }
        out.append(UInt8(length))
        out.append(contentsOf: string.utf8)
        return out
    }

    private func protobufField(_ number: Int, bytes: Data) -> Data {
        var out = Data([UInt8(number << 3 | 2)])
        out.append(UInt8(bytes.count))
        out.append(bytes)
        return out
    }
}
