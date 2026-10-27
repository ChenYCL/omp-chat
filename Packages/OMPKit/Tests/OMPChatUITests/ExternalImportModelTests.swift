import XCTest
@testable import OMPCore
@testable import OMPChatUI

/// Model-level external import: scan → select → run → re-run skips, with
/// every write confined to temporary roots (store, skills, plugin store).
@MainActor
final class ExternalImportModelTests: XCTestCase {
    private var home = ""
    private var skillsRoot = ""
    private var model: ChatAppModel!

    override func setUp() {
        super.setUp()
        home = NSTemporaryDirectory() + "omp-import-model-\(UUID().uuidString)"
        skillsRoot = "\(home)/.agents/skills"
        try! FileManager.default.createDirectory(atPath: "\(home)/.claude/skills/source", withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(atPath: "\(skillsRoot)", withIntermediateDirectories: true)
        try! "---\nname: source\ndescription: 源技能\n---\n\n正文\n".write(toFile: "\(home)/.claude/skills/source/SKILL.md", atomically: true, encoding: .utf8)
        // "~/.claude.json" must exist for the provider to be found; keep MCP empty.
        try! #"{"mcpServers":{}}"#.write(toFile: "\(home)/.claude.json", atomically: true, encoding: .utf8)

        let store = FileConversationStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-import-model-store-\(UUID().uuidString)", isDirectory: true))
        model = ChatAppModel(store: store)
        model.skillsHome = home
        model.externalImportHome = home
        model.pluginStore = PluginStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-import-model-plugins-\(UUID().uuidString)", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    private func jsonlSession(id: String, prompt: String, cwd: String?) {
        let dir = "\(home)/.claude/projects/-tmp-fixture"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cwdLine = cwd.map { "\"cwd\":\"\($0)\"," } ?? ""
        let line = "{\"type\":\"user\",\(cwdLine)\"timestamp\":\"2026-10-06T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"\(prompt)\"}}"
        try! line.write(toFile: "\(dir)/\(id).jsonl", atomically: true, encoding: .utf8)
    }

    func testScanSeesClaudeSkills() async {
        let scan = await model.scanExternalAgents()
        XCTAssertTrue(scan.providersFound.contains(.claudeCode))
        let skills = scan.groups(provider: .claudeCode).first { $0.kind == .skills }?.rows ?? []
        XCTAssertEqual(skills.map(\.title), ["source"])
    }

    func testImportSessionThenRerunSkips() async {
        try! FileManager.default.createDirectory(atPath: "\(home)/projects/solo", withIntermediateDirectories: true)
        jsonlSession(id: "eeeeeeee-0001", prompt: "模型层导入", cwd: "\(home)/projects/solo")
        let scan = await model.scanExternalAgents()
        let selection = ExternalImportSelection(allOf: scan)
        let report = await model.runExternalImport(selection)

        XCTAssertEqual(report.importedCount, 2, "会话 + 技能：\(report.lines.map { "\($0.title): \($0.note ?? "ok")" })")
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertEqual(model.conversations[0].importedFrom, "claude-code:eeeeeeee-0001")
        XCTAssertEqual(model.conversations[0].title, "模型层导入")
        XCTAssertEqual(model.conversations[0].workingDirectory, "\(home)/projects/solo")
        XCTAssertEqual(model.projects.map(\.name), ["solo"], "会话按原文件夹归入新项目")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillsRoot + "/source/SKILL.md"))

        // A second run re-scans: the chat is already there, nothing imports.
        let rerun = await model.runExternalImport(ExternalImportSelection(allOf: await model.scanExternalAgents()))
        XCTAssertEqual(rerun.importedCount, 0)
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertEqual(rerun.lines.first { $0.id == "claude-code:eeeeeeee-0001" }?.note, "已导入过，跳过")
    }

    func testInstructionsAppendOnceThenSkip() async {
        try! "# 项目无关的全局说明".write(toFile: "\(home)/.claude/CLAUDE.md", atomically: true, encoding: .utf8)
        let scan = await model.scanExternalAgents()
        let instructions = scan.entries.first { $0.kind == .instructions }!
        _ = await model.runExternalImport(ExternalImportSelection(enabledEntryIDs: [instructions.id]))
        XCTAssertTrue(model.settings.customInstructions.contains("## 从 Claude Code 导入"))
        XCTAssertTrue(model.settings.customInstructions.contains("项目无关的全局说明"))

        let rerunScan = await model.scanExternalAgents()
        let again = rerunScan.entries.first { $0.kind == .instructions }!
        XCTAssertEqual(again.skippedReason, "已导入过同样的内容，跳过")
        _ = await model.runExternalImport(ExternalImportSelection(enabledEntryIDs: [again.id]))
        XCTAssertEqual(model.settings.customInstructions.components(separatedBy: "## 从 Claude Code 导入").count - 1, 1, "不重复追加")
    }

    func testMCPServerImportVaultsSecretsAndDedupes() async {
        try! #"{"mcpServers":{"fix-server":{"command":"node","args":["s.js"],"env":{"FIX_TOKEN":"sk-vault-me"}}}}"#
            .write(toFile: "\(home)/.claude.json", atomically: true, encoding: .utf8)
        let scan = await model.scanExternalAgents()
        let row = scan.entries.first { $0.kind == .mcpServers }!
        _ = await model.runExternalImport(ExternalImportSelection(enabledEntryIDs: [row.id]))

        XCTAssertEqual(model.settings.mcpServers.map(\.id), ["fix-server"])
        XCTAssertEqual(model.settings.mcpServers.first?.env["FIX_TOKEN"], "", "密钥进保管库，配置里留空")
        XCTAssertEqual(model.mcpSecret(serverID: "fix-server", variable: "FIX_TOKEN"), "sk-vault-me")

        let rerun = await model.runExternalImport(ExternalImportSelection(allOf: await model.scanExternalAgents()))
        XCTAssertEqual(model.settings.mcpServers.count, 1, "重复导入按同名同命令去重")
        XCTAssertEqual(rerun.lines.first { $0.title == "fix-server" }?.note, "与已有服务器重复（同名同命令），跳过")
    }

    func testPluginInstallFromClaudeCacheAndRerunSkips() async {
        let pluginRoot = "\(home)/.claude/plugins/cache/demo"
        try! FileManager.default.createDirectory(atPath: "\(pluginRoot)/.claude-plugin", withIntermediateDirectories: true)
        try! #"{"name":"demo-plugin","version":"1.0.0"}"#.write(toFile: "\(pluginRoot)/.claude-plugin/plugin.json", atomically: true, encoding: .utf8)
        let registry: [String: Any] = ["version": 2, "plugins": ["demo-plugin@market": [["scope": "user", "installPath": pluginRoot, "version": "1.0.0"]]]]
        try! JSONSerialization.data(withJSONObject: registry).write(to: URL(fileURLWithPath: "\(home)/.claude/plugins/installed_plugins.json"))

        let scan = await model.scanExternalAgents()
        let row = scan.entries.first { $0.kind == .plugins }!
        XCTAssertNotNil(row.operation)
        let report = await model.runExternalImport(ExternalImportSelection(enabledEntryIDs: [row.id]))
        XCTAssertEqual(report.lines.first { $0.kind == .plugins }?.note, nil)
        XCTAssertTrue(model.installedPlugins.contains { $0.id == "demo-plugin" })

        let rerunScan = await model.scanExternalAgents()
        let again = rerunScan.entries.first { $0.kind == .plugins }
        XCTAssertEqual(again?.skippedReason, "OMPChat 已安装同名插件")
    }

    func testDismissedPromptDoesNotComeBack() async {
        await model.saveSettings(AppSettings(externalImportPromptDismissed: true))
        await model.presentExternalImportPromptIfNeeded()
        XCTAssertNil(model.externalImportPrompt)
    }

    func testPromptRaisesWhenImportableAndDismissRemembers() async {
        jsonlSession(id: "ffffffff-0009", prompt: "提示场景", cwd: nil)
        await model.presentExternalImportPromptIfNeeded()
        XCTAssertNotNil(model.externalImportPrompt, "首次启动且发现可导入内容时应提示")
        model.dismissExternalImportPrompt()
        XCTAssertNil(model.externalImportPrompt)
        XCTAssertTrue(model.settings.externalImportPromptDismissed)
        await model.presentExternalImportPromptIfNeeded()
        XCTAssertNil(model.externalImportPrompt, "暂不之后不再提示")
    }
}
