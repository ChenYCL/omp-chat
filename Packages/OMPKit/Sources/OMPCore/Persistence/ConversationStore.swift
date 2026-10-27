import Foundation

public protocol ConversationStoring: Sendable {
    func loadAll() async throws -> [Conversation]
    func save(_ conversation: Conversation) async throws
    func delete(id: UUID) async throws
    func loadModelCatalog() async throws -> [ModelDescriptor]
    func replaceModelCatalog(_ models: [ModelDescriptor]) async throws
    func loadProviders() async throws -> [ProviderProfile]
    func saveProviders(_ profiles: [ProviderProfile]) async throws
    func loadSettings() async throws -> AppSettings
    func saveSettings(_ settings: AppSettings) async throws
    func loadProjects() async throws -> [Project]
    func saveProjects(_ projects: [Project]) async throws
    func loadScheduledTasks() async throws -> [ScheduledTask]
    func saveScheduledTasks(_ tasks: [ScheduledTask]) async throws
}

/// In-memory store used by tests and previews.
public actor InMemoryConversationStore: ConversationStoring {
    private var conversations: [UUID: Conversation] = [:]
    private var models: [ModelDescriptor] = []
    private var profiles: [ProviderProfile] = []
    private var settings = AppSettings()
    private var projects: [Project] = []
    private var scheduledTasks: [ScheduledTask] = []

    public init() {}

    public func loadAll() async throws -> [Conversation] {
        conversations.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }

    public func delete(id: UUID) async throws {
        conversations.removeValue(forKey: id)
    }

    public func loadModelCatalog() async throws -> [ModelDescriptor] { models }

    public func replaceModelCatalog(_ models: [ModelDescriptor]) async throws { self.models = models }

    public func loadProviders() async throws -> [ProviderProfile] { profiles }

    public func saveProviders(_ profiles: [ProviderProfile]) async throws { self.profiles = profiles }

    public func loadSettings() async throws -> AppSettings { settings }

    public func saveSettings(_ settings: AppSettings) async throws { self.settings = settings }

    public func loadProjects() async throws -> [Project] { projects }

    public func saveProjects(_ projects: [Project]) async throws { self.projects = projects }

    public func loadScheduledTasks() async throws -> [ScheduledTask] { scheduledTasks }

    public func saveScheduledTasks(_ tasks: [ScheduledTask]) async throws { scheduledTasks = tasks }
}
