import Foundation

/// Wire protocol dialect spoken by a relay endpoint.
public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAICompatible
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .anthropic: "Anthropic"
        }
    }

    public var defaultModelsPath: String {
        switch self {
        case .openAICompatible: "/v1/models"
        case .anthropic: "/v1/models"
        }
    }

    public var defaultChatPath: String {
        switch self {
        case .openAICompatible: "/v1/chat/completions"
        case .anthropic: "/v1/messages"
        }
    }
}
