import Foundation

/// A configured relay endpoint. Secrets never live here: the API key is stored
/// in the Keychain under `keychainAccount`.
public struct ProviderProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var baseURL: URL
    public var modelsPath: String
    public var chatPath: String
    public var extraHeaders: [String: String]
    public var isDefault: Bool
    public var createdAt: Date

    public var keychainAccount: String { "provider.\(id.uuidString)" }

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        baseURL: URL,
        modelsPath: String? = nil,
        chatPath: String? = nil,
        extraHeaders: [String: String] = [:],
        isDefault: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.modelsPath = modelsPath ?? kind.defaultModelsPath
        self.chatPath = chatPath ?? kind.defaultChatPath
        self.extraHeaders = extraHeaders
        self.isDefault = isDefault
        self.createdAt = createdAt
    }

    public func resolvedURL(path: String) -> URL {
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let trimmed = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + trimmed) ?? baseURL
    }
}
