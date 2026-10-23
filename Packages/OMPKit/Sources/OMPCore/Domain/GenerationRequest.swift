import Foundation

public struct TokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens + reasoningTokens }
}

public struct ToolSpec: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema encoded as a JSON object string.
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct GenerationRequest: Hashable, Sendable {
    public var modelID: String
    public var messages: [ChatMessage]
    public var systemPrompt: String?
    public var temperature: Double?
    public var maxOutputTokens: Int?
    public var tools: [ToolSpec]
    public var thinkingBudgetTokens: Int?

    public init(
        modelID: String,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        tools: [ToolSpec] = [],
        thinkingBudgetTokens: Int? = nil
    ) {
        self.modelID = modelID
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.tools = tools
        self.thinkingBudgetTokens = thinkingBudgetTokens
    }
}
