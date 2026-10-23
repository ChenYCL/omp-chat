import Foundation

/// One-click starting points for the provider editor. Values are only
/// defaults; every field stays editable.
public struct ProviderPreset: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: ProviderKind
    public var baseURL: URL
    public var suggestedModel: String?
    public var note: String?

    public init(name: String, kind: ProviderKind, baseURL: URL, suggestedModel: String? = nil, note: String? = nil) {
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.suggestedModel = suggestedModel
        self.note = note
    }

    public static let all: [ProviderPreset] = [
        ProviderPreset(
            name: "ccLoad 网关",
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.ccload.ai")!,
            suggestedModel: nil,
            note: "自建中继，模型列表以 /v1/models 实际返回为准"
        ),
        ProviderPreset(
            name: "OpenAI",
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.openai.com")!,
            suggestedModel: "gpt-4.1"
        ),
        ProviderPreset(
            name: "Anthropic",
            kind: .anthropic,
            baseURL: URL(string: "https://api.anthropic.com")!,
            suggestedModel: "claude-sonnet-4-20250514"
        ),
        ProviderPreset(
            name: "DeepSeek",
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.deepseek.com")!,
            suggestedModel: "deepseek-chat"
        ),
        ProviderPreset(
            name: "OpenRouter",
            kind: .openAICompatible,
            baseURL: URL(string: "https://openrouter.ai/api")!,
            suggestedModel: "openai/gpt-4.1"
        ),
        ProviderPreset(
            name: "Ollama",
            kind: .openAICompatible,
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            suggestedModel: "llama3.1",
            note: "本地服务，无需 API Key"
        ),
        ProviderPreset(
            name: "SiliconFlow 硅基流动",
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.siliconflow.cn/v1")!,
            suggestedModel: "deepseek-ai/DeepSeek-V3",
            note: "聚合大量开源模型与极速推理"
        ),
        ProviderPreset(
            name: "Groq 极速",
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.groq.com/openai/v1")!,
            suggestedModel: "llama-3.3-70b-versatile",
            note: "超高每秒 token 吞吐速度"
        ),
        ProviderPreset(
            name: "Moonshot Kimi",
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.moonshot.cn/v1")!,
            suggestedModel: "moonshot-v1-8k",
            note: "月之暗面长文本模型"
        ),
        ProviderPreset(
            name: "智谱 GLM",
            kind: .openAICompatible,
            baseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4")!,
            suggestedModel: "glm-4-plus",
            note: "智谱开放平台 API"
        ),
    ]
}
