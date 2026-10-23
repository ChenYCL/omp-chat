import Foundation

public struct ModelCapabilities: Codable, Hashable, Sendable {
    public var chat: Bool
    public var streaming: Bool
    public var thinking: Bool
    public var vision: Bool
    public var tools: Bool
    public var imageGeneration: Bool
    public var imageEditing: Bool
    public var videoGeneration: Bool

    public init(
        chat: Bool = true,
        streaming: Bool = true,
        thinking: Bool = false,
        vision: Bool = false,
        tools: Bool = false,
        imageGeneration: Bool = false,
        imageEditing: Bool = false,
        videoGeneration: Bool = false
    ) {
        self.chat = chat
        self.streaming = streaming
        self.thinking = thinking
        self.vision = vision
        self.tools = tools
        self.imageGeneration = imageGeneration
        self.imageEditing = imageEditing
        self.videoGeneration = videoGeneration
    }
}

public struct ModelLimits: Codable, Hashable, Sendable {
    public var contextWindow: Int?
    public var maxOutputTokens: Int?

    public init(contextWindow: Int? = nil, maxOutputTokens: Int? = nil) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
    }
}

/// A model advertised by a provider, enriched with inferred capabilities.
public struct ModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var providerID: UUID
    public var displayName: String
    public var capabilities: ModelCapabilities
    public var limits: ModelLimits
    public var ownedBy: String?
    public var createdAt: Date?
    public var rawMetadata: [String: String]
    public var lastSeenAt: Date

    public init(
        id: String,
        providerID: UUID,
        displayName: String? = nil,
        capabilities: ModelCapabilities = .init(),
        limits: ModelLimits = .init(),
        ownedBy: String? = nil,
        createdAt: Date? = nil,
        rawMetadata: [String: String] = [:],
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName ?? id
        self.capabilities = capabilities
        self.limits = limits
        self.ownedBy = ownedBy
        self.createdAt = createdAt
        self.rawMetadata = rawMetadata
        self.lastSeenAt = lastSeenAt
    }
}
