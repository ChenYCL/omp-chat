import XCTest
@testable import OMPCore

final class WorkspaceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("omp-store-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripsAcrossInstances() async throws {
        let store = FileConversationStore(directoryURL: directory)
        let profile = ProviderProfile(name: "Relay", kind: .openAICompatible, baseURL: URL(string: "https://relay.test")!)
        try await store.saveProviders([profile])

        var settings = AppSettings()
        settings.defaultProviderID = profile.id
        settings.defaultModelID = "model-x"
        settings.appearance = .dark
        try await store.saveSettings(settings)

        let conversation = Conversation(
            title: "持久化",
            providerID: profile.id,
            modelID: "model-x",
            messages: [ChatMessage(role: .user, parts: [.text("hello")])]
        )
        try await store.save(conversation)

        let reopened = FileConversationStore(directoryURL: directory)
        let conversations = try await reopened.loadAll()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.title, "持久化")
        XCTAssertEqual(conversations.first?.messages.first?.concatenatedText, "hello")
        let providers = try await reopened.loadProviders()
        XCTAssertEqual(providers.first?.baseURL.absoluteString, "https://relay.test")
        let loadedSettings = try await reopened.loadSettings()
        XCTAssertEqual(loadedSettings.defaultModelID, "model-x")
        XCTAssertEqual(loadedSettings.appearance, .dark)
    }

    func testSaveUpdatesExistingConversation() async throws {
        let store = FileConversationStore(directoryURL: directory)
        var conversation = Conversation(title: "一")
        try await store.save(conversation)
        conversation.title = "二"
        conversation.messages.append(ChatMessage(role: .assistant, parts: [.text("ok")]))
        try await store.save(conversation)

        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "二")
        XCTAssertEqual(all.first?.messages.count, 1)
    }

    func testRemovingProviderPrunesItsModelCatalog() async throws {
        let store = FileConversationStore(directoryURL: directory)
        let profile = ProviderProfile(name: "A", kind: .openAICompatible, baseURL: URL(string: "https://a.test")!)
        try await store.saveProviders([profile])
        try await store.replaceModelCatalog([
            ModelDescriptor(id: "m1", providerID: profile.id),
            ModelDescriptor(id: "m2", providerID: UUID()),
        ])

        try await store.saveProviders([])
        let models = try await store.loadModelCatalog()
        XCTAssertTrue(models.isEmpty)
    }

    func testCorruptDocumentIsQuarantined() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("workspace.json")
        try Data("{ not json".utf8).write(to: file)

        let store = FileConversationStore(directoryURL: directory)
        do {
            _ = try await store.loadAll()
            XCTFail("corrupt document must surface an error")
        } catch {
            // expected
        }

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("workspace.corrupt-") })
        XCTAssertTrue(siblings.contains("workspace.json"), "original document must be preserved")
    }
    func testProjectsRoundTrip() async throws {
        let store = FileConversationStore(directoryURL: directory)
        let project = Project(name: "研究", order: 0)
        try await store.saveProjects([project])

        let conversation = Conversation(title: "分组内", projectID: project.id)
        try await store.save(conversation)

        let reopened = FileConversationStore(directoryURL: directory)
        let projects = try await reopened.loadProjects()
        XCTAssertEqual(projects.map(\.name), ["研究"])
        let loaded = try await reopened.loadAll()
        XCTAssertEqual(loaded.first?.projectID, project.id)

        // Documents written before projects existed still decode.
        let legacy = FileConversationStore(directoryURL: directory)
        let legacyProjects = try await legacy.loadProjects()
        XCTAssertFalse(legacyProjects.isEmpty)
    }

}

final class SecretStoreTests: XCTestCase {
    func testFallbackWritesWhenPrimaryThrows() throws {
        struct FailingStore: SecretStoring {
            func secret(for account: String) throws -> String? { throw ProviderError.unauthorized }
            func setSecret(_ value: String?, for account: String) throws { throw ProviderError.unauthorized }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omp-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = FileSecretVault(fileURL: directory.appendingPathComponent("secrets.json"))
        let store = FallbackSecretStore(primary: FailingStore(), fileFallback: vault)
        try store.setSecret("sk-test", for: "provider.1")
        XCTAssertEqual(try store.secret(for: "provider.1"), "sk-test")

        let attributes = try FileManager.default.attributesOfItem(atPath: vault.fileURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        try store.setSecret(nil, for: "provider.1")
        XCTAssertNil(try store.secret(for: "provider.1"))
    }

    func testVaultPersistsBetweenInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omp-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("secrets.json")

        try FileSecretVault(fileURL: url).setSecret("token", for: "a")
        XCTAssertEqual(try FileSecretVault(fileURL: url).secret(for: "a"), "token")
    }
}
