import Foundation

public enum FinishReason: String, Codable, Hashable, Sendable {
    case stop
    case length
    case toolCalls
    case contentFilter
    case error
}

public enum StreamEvent: Hashable, Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    /// Closes the thinking block just streamed (or stands for a redacted one).
    case thinkingSeal(ThinkingSeal)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsDelta: String?)
    case usage(TokenUsage)
    case finished(FinishReason)
}

public enum ProviderError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case transport(String)
    case unauthorized
    case http(status: Int, body: String)
    case decoding(String)
    case stream(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value): "URL 无效：\(value)"
        case .transport(let value): "网络错误：\(value)"
        case .unauthorized: "API Key 无效或已过期"
        case .http(let status, let body): "HTTP \(status)：\(body.prefix(400))"
        case .decoding(let value): "解析失败：\(value)"
        case .stream(let value): "流式响应中断：\(value)"
        case .unsupported(let value): "不支持：\(value)"
        }
    }
}
