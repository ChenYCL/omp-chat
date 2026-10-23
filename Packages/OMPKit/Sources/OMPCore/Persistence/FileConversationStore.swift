import Foundation

/// File-backed workspace store: one JSON document, atomic replacement.
///
/// The whole workspace (conversations, provider profiles, model catalog,
/// settings) is persisted together so a crash can never leave a conversation
/// pointing at a provider that no longer exists.
public actor FileConversationStore: ConversationStoring {
    public struct Snapshot: Codable, Sendable {
        public var version: Int
        public var conversations: [Conversation]
        public var providers: [ProviderProfile]
        public var models: [ModelDescriptor]
        public var settings: AppSettings
        public var projects: [Project]

        public init(
            version: Int = 1,
            conversations: [Conversation] = [],
            providers: [ProviderProfile] = [],
            models: [ModelDescriptor] = [],
            settings: AppSettings = AppSettings(),
            projects: [Project] = []
        ) {
            self.version = version
            self.conversations = conversations
            self.providers = providers
            self.models = models
            self.settings = settings
            self.projects = projects
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            conversations = try container.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
            providers = try container.decodeIfPresent([ProviderProfile].self, forKey: .providers) ?? []
            models = try container.decodeIfPresent([ModelDescriptor].self, forKey: .models) ?? []
            settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
            projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        }
    }

    public let directoryURL: URL
    public var fileURL: URL { directoryURL.appendingPathComponent("workspace.json") }

    private var cache: Snapshot?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// `~/Library/Application Support/OMPChat` (sandbox container aware).
    /// `OMPCHAT_STORE_DIR` redirects every default location (store, secrets,
    /// media) so headless probes and UI runs can share a workspace.
    public static func defaultStore() -> FileConversationStore {
        FileConversationStore(directoryURL: Self.defaultDirectory())
    }

    public static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["OMPCHAT_STORE_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("OMPChat", isDirectory: true)
    }

    // MARK: - ConversationStoring

    public func loadAll() async throws -> [Conversation] {
        try current().conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ conversation: Conversation) async throws {
        var snapshot = try current()
        if let index = snapshot.conversations.firstIndex(where: { $0.id == conversation.id }) {
            snapshot.conversations[index] = conversation
        } else {
            snapshot.conversations.append(conversation)
        }
        try commit(snapshot)
    }

    public func delete(id: UUID) async throws {
        var snapshot = try current()
        snapshot.conversations.removeAll { $0.id == id }
        try commit(snapshot)
    }

    public func loadModelCatalog() async throws -> [ModelDescriptor] {
        try current().models
    }

    public func replaceModelCatalog(_ models: [ModelDescriptor]) async throws {
        var snapshot = try current()
        snapshot.models = models
        try commit(snapshot)
    }

    public func loadProviders() async throws -> [ProviderProfile] {
        try current().providers
    }

    public func saveProviders(_ profiles: [ProviderProfile]) async throws {
        var snapshot = try current()
        snapshot.providers = profiles
        // Drop the cached catalog for providers that vanished.
        let known = Set(profiles.map(\.id))
        snapshot.models.removeAll { !known.contains($0.providerID) }
        try commit(snapshot)
    }

    public func loadSettings() async throws -> AppSettings {
        try current().settings
    }

    public func loadProjects() async throws -> [Project] {
        try current().projects
    }

    public func saveProjects(_ projects: [Project]) async throws {
        var snapshot = try current()
        snapshot.projects = projects
        try commit(snapshot)
    }

    public func saveSettings(_ settings: AppSettings) async throws {
        var snapshot = try current()
        snapshot.settings = settings
        try commit(snapshot)
    }

    // MARK: - Internals

    private func current() throws -> Snapshot {
        if let cache { return cache }
        let snapshot = try readFromDisk()
        cache = snapshot
        return snapshot
    }

    private func readFromDisk() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Snapshot() }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return Snapshot() }
        do {
            return try decoder.decode(Snapshot.self, from: data)
        } catch {
            // Corrupt document: preserve it for forensics instead of clobbering.
            let backup = directoryURL.appendingPathComponent("workspace.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return Snapshot()
        }
    }

    private func commit(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        cache = snapshot
    }
}
