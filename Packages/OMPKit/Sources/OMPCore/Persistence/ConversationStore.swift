import Foundation

public protocol ConversationStoring: Sendable {
    func loadAll() async throws -> [Conversation]
    func save(_ conversation: Conversation) async throws
    func delete(id: UUID) async throws
    func loadModelCatalog() async throws -> [ModelDescriptor]
    func replaceModelCatalog(_ models: [ModelDescriptor]) async throws
    func loadProviders() async throws -> [ProviderProfile]
    func saveProviders(_ profiles: [ProviderProfile]) async throws
}

/// In-memory store used by tests and previews.
public actor InMemoryConversationStore: ConversationStoring {
    private var conversations: [UUID: Conversation] = [:]
    private var models: [ModelDescriptor] = []
    private var profiles: [ProviderProfile] = []

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
}
