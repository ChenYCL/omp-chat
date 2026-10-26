import XCTest
@testable import OMPCore
@testable import OMPChatUI

/// What the rest of the app receives from installed plugins: the skills
/// list for the system prompt, the readable folders, the MCP servers and
/// the AGENTS.md text. A disabled plugin leaking into any of them would keep
/// offering code the user switched off.
@MainActor
final class PluginModelTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-pluginmodel-\(UUID().uuidString)", isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ text: String, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeModel() async throws -> (ChatAppModel, UUID) {
        let model = ChatAppModel(
            store: InMemoryConversationStore(), secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: root.appendingPathComponent("media")), transport: URLSessionTransport()
        )
        await model.bootstrap()
        model.pluginStore = PluginStore(root: root.appendingPathComponent("store"))
        model.skillsHome = root.appendingPathComponent("home").path
        try write("---\nname: notes\ndescription: Keep personal notes.\n---\n", "home/.agents/skills/notes/SKILL.md")
        try write("---\nname: deploy\ndescription: Deploy this repo.\n---\n", "repo/.agents/skills/deploy/SKILL.md")
        try write("Run make test before committing.", "repo/AGENTS.md")
        try write(#"{"name": "helper", "version": "1.0.0"}"#, "src/helper/.codex-plugin/plugin.json")
        try write("---\nname: search\ndescription: Search the docs.\n---\n", "src/helper/skills/search/SKILL.md")
        try write(#"{"docs": {"command": "docs-mcp", "args": ["--stdio"]}}"#, "src/helper/.mcp.json")
        try model.confirmPluginInstall(try model.preparePluginInstall(folder: root.appendingPathComponent("src/helper").path))
        let conversation = model.newConversation()
        model.updateWorkingDirectory(conversation.id, repo.appendingPathComponent("app").path)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("app"), withIntermediateDirectories: true)
        return (model, conversation.id)
    }

    func testEnabledPluginContributesSkillsFoldersAndServers() async throws {
        let (model, id) = try await makeModel()
        guard model.toolProviders[BuiltinToolProvider.providerID] != nil else { throw XCTSkip("built-in tools are macOS only") }

        let section = try XCTUnwrap(model.skillPromptSection(for: id))
        let order = ["- deploy:", "- notes:", "- helper:search:"].map { section.range(of: $0)?.lowerBound }
        XCTAssertFalse(order.contains(nil), section)
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted(), "repository, then user, then plugin")
        XCTAssertTrue(section.contains("(file: \(repo.path)/.agents/skills/deploy/SKILL.md)"))

        let plugin = try XCTUnwrap(model.installedPlugins.first)
        XCTAssertTrue(model.pluginReadableRoots.contains(plugin.root))
        XCTAssertTrue(model.toolContext(for: id).readableRoots.contains(plugin.root), "read_file may read the plugin without asking")
        XCTAssertTrue(model.readableRoots(for: id).contains("\(repo.path)/.agents/skills/deploy"))
        XCTAssertEqual(model.pluginMCPServers.map(\.id), ["helper-docs"])

        let revision = model.pluginsRevision
        try model.setPluginEnabled(false, id: "helper")
        XCTAssertGreaterThan(model.pluginsRevision, revision, "the MCP manager re-syncs on this")
        XCTAssertTrue(model.pluginMCPServers.isEmpty)
        XCTAssertFalse(model.pluginReadableRoots.contains(plugin.root))
        XCTAssertFalse(model.toolContext(for: id).readableRoots.contains(plugin.root))
        XCTAssertFalse(try XCTUnwrap(model.skillPromptSection(for: id)).contains("helper:search"))
    }

    func testNoSkillsListWithoutTools() async throws {
        let (model, id) = try await makeModel()
        model.setToolsEnabled(false, for: id)
        XCTAssertNil(model.skillPromptSection(for: id), "skills are read with read_file; without tools the list would be a dead end")
    }

    func testAgentsDocForTheThread() async throws {
        let (model, id) = try await makeModel()
        let doc = try XCTUnwrap(model.agentsDocPrompt(for: id))
        XCTAssertEqual(doc.files.map { ($0 as NSString).standardizingPath }, [(repo.appendingPathComponent("AGENTS.md").path as NSString).standardizingPath])
        XCTAssertTrue(doc.text.hasSuffix("Run make test before committing."))

        let unbound = model.newConversation()
        XCTAssertNil(model.agentsDocPrompt(for: unbound.id))
    }

    func testUninstallClearsEverything() async throws {
        let (model, _) = try await makeModel()
        try model.uninstallPlugin("helper")
        XCTAssertTrue(model.installedPlugins.isEmpty)
        XCTAssertTrue(model.pluginMCPServers.isEmpty)
    }
}
