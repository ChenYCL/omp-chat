import Foundation

public protocol ChatProvider: Sendable {
    var profile: ProviderProfile { get }
    func fetchModels() async throws -> [ModelDescriptor]
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

/// Builds the right wire adapter for a profile.
public enum ProviderFactory {
    public static func makeProvider(
        profile: ProviderProfile,
        apiKey: String,
        transport: HTTPTransport = URLSessionTransport()
    ) -> any ChatProvider {
        switch profile.kind {
        case .openAICompatible:
            OpenAICompatibleProvider(profile: profile, apiKey: apiKey, transport: transport)
        case .anthropic:
            AnthropicProvider(profile: profile, apiKey: apiKey, transport: transport)
        }
    }
}
