import Foundation

/// Anthropic Messages API dialect (`/v1/messages` + `/v1/models`).
public struct AnthropicProvider: ChatProvider {
    public let profile: ProviderProfile
    private let apiKey: String
    private let transport: HTTPTransport
    private let apiVersion: String

    public init(profile: ProviderProfile, apiKey: String, transport: HTTPTransport = URLSessionTransport(), apiVersion: String = "2023-06-01") {
        self.profile = profile
        self.apiKey = apiKey
        self.transport = transport
        self.apiVersion = apiVersion
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        var request = URLRequest(url: profile.resolvedURL(path: profile.modelsPath))
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        for (key, value) in profile.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }

        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.http(status: response.statusCode, body: String(decoding: response.body, as: UTF8.self))
        }
        let payload = try JSONDecoder().decode(AnthropicModelsResponse.self, from: response.body)
        return payload.data.map { entry in
            ModelDescriptor(
                id: entry.id,
                providerID: profile.id,
                displayName: entry.displayName ?? entry.id,
                capabilities: ModelCapabilityInference.infer(modelID: entry.id, raw: entry.rawMetadata()),
                limits: ModelLimitInference.infer(modelID: entry.id),
                ownedBy: entry.type,
                createdAt: entry.createdAt,
                rawMetadata: entry.rawMetadata()
            )
        }
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeRequest(request)
                    let stream = try await transport.stream(urlRequest)
                    var parser = SSEParser()
                    var blockKinds: [Int: String] = [:]
                    var usage = TokenUsage()
                    var stopReason: FinishReason = .stop

                    for try await chunk in stream {
                        for event in parser.consume(chunk) {
                            guard !event.data.isEmpty else { continue }
                            guard let payload = try? JSONDecoder().decode(AnthropicStreamPayload.self, from: Data(event.data.utf8)) else { continue }
                            switch payload.type {
                            case "message_start":
                                if let input = payload.message?.usage?.inputTokens {
                                    usage.inputTokens = input
                                }
                            case "content_block_start":
                                if let index = payload.index, let block = payload.contentBlock {
                                    blockKinds[index] = block.type
                                    if block.type == "text", let text = block.text, !text.isEmpty {
                                        continuation.yield(.textDelta(text))
                                    }
                                    if block.type == "thinking", let thinking = block.thinking, !thinking.isEmpty {
                                        continuation.yield(.thinkingDelta(thinking))
                                    }
                                    if block.type == "tool_use", let name = block.name, let id = block.id {
                                        continuation.yield(.toolCallDelta(index: index, id: id, name: name, argumentsDelta: nil))
                                    }
                                }
                            case "content_block_delta":
                                if let delta = payload.delta {
                                    if let text = delta.text, !text.isEmpty {
                                        continuation.yield(.textDelta(text))
                                    } else if let thinking = delta.thinking, !thinking.isEmpty {
                                        continuation.yield(.thinkingDelta(thinking))
                                    } else if let partial = delta.partialJSON, let index = payload.index {
                                        continuation.yield(.toolCallDelta(index: index, id: nil, name: nil, argumentsDelta: partial))
                                    }
                                }
                            case "message_delta":
                                if let reason = payload.delta?.stopReason {
                                    stopReason = FinishReasonWire.mapAnthropic(reason)
                                }
                                if let output = payload.usage?.outputTokens {
                                    usage.outputTokens = output
                                }
                            case "message_stop":
                                break
                            case "error":
                                let message = payload.error?.message ?? "unknown stream error"
                                throw ProviderError.stream(message)
                            default:
                                break
                            }
                        }
                    }
                    continuation.yield(.usage(usage))
                    continuation.yield(.finished(stopReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(_ request: GenerationRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: profile.resolvedURL(path: profile.chatPath))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        for (key, value) in profile.extraHeaders { urlRequest.setValue(value, forHTTPHeaderField: key) }
        urlRequest.httpBody = try JSONEncoder().encode(AnthropicRequestBuilder.build(request))
        return urlRequest
    }
}

extension FinishReasonWire {
    static func mapAnthropic(_ raw: String) -> FinishReason {
        switch raw {
        case "end_turn", "stop_sequence": .stop
        case "max_tokens": .length
        case "tool_use": .toolCalls
        case "refusal": .contentFilter
        default: .stop
        }
    }
}

struct AnthropicModelsResponse: Decodable {
    struct Entry: Decodable {
        var id: String
        var type: String?
        var displayName: String?
        var createdAt: Date?
        enum CodingKeys: String, CodingKey {
            case id, type
            case displayName = "display_name"
            case createdAt = "created_at"
        }
        func rawMetadata() -> [String: String] {
            var result: [String: String] = [:]
            if let type { result["type"] = type }
            return result
        }
    }
    var data: [Entry]
}

struct AnthropicStreamPayload: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            var inputTokens: Int?
            enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens" }
        }
        var usage: Usage?
    }

    struct ContentBlock: Decodable {
        var type: String
        var text: String?
        var thinking: String?
        var id: String?
        var name: String?
    }

    struct Delta: Decodable {
        var type: String?
        var text: String?
        var thinking: String?
        var partialJSON: String?
        var stopReason: String?
        enum CodingKeys: String, CodingKey {
            case type, text, thinking
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    struct Usage: Decodable {
        var outputTokens: Int?
        enum CodingKeys: String, CodingKey { case outputTokens = "output_tokens" }
    }

    struct ErrorPayload: Decodable { var message: String? }

    var type: String
    var index: Int?
    var message: Message?
    var contentBlock: ContentBlock?
    var delta: Delta?
    var usage: Usage?
    var error: ErrorPayload?

    enum CodingKeys: String, CodingKey {
        case type, index, message, delta, usage, error
        case contentBlock = "content_block"
    }
}

struct AnthropicRequestBuilder {
    struct Body: Encodable {
        struct WireMessage: Encodable {
            var role: String
            var content: [Block]
        }
        struct Block: Encodable {
            var type: String
            var text: String?
            var source: ImageSource?
            var id: String?
            var name: String?
            var input: JSONValue?
        }
        struct ImageSource: Encodable {
            var type: String = "base64"
            var mediaType: String
            var data: String
            enum CodingKeys: String, CodingKey {
                case type, data
                case mediaType = "media_type"
            }
        }
        struct Thinking: Encodable {
            var type: String = "enabled"
            var budgetTokens: Int
            enum CodingKeys: String, CodingKey {
                case type
                case budgetTokens = "budget_tokens"
            }
        }
        struct Tool: Encodable {
            var name: String
            var description: String
            var inputSchema: JSONValue
            enum CodingKeys: String, CodingKey {
                case name, description
                case inputSchema = "input_schema"
            }
        }

        var model: String
        var maxTokens: Int
        var system: String?
        var messages: [WireMessage]
        var stream: Bool = true
        var temperature: Double?
        var thinking: Thinking?
        var tools: [Tool]?

        enum CodingKeys: String, CodingKey {
            case model, system, messages, stream, temperature, thinking, tools
            case maxTokens = "max_tokens"
        }
    }

    static func build(_ request: GenerationRequest) -> Body {
        let messages = request.messages
            .filter { $0.role == .user || $0.role == .assistant }
            .map { message -> Body.WireMessage in
                let blocks = message.parts.compactMap { part -> Body.Block? in
                    switch part {
                    case .text(let value):
                        return value.isEmpty ? nil : Body.Block(type: "text", text: value)
                    case .thinking(let value):
                        return value.isEmpty ? nil : Body.Block(type: "thinking", text: value)
                    default:
                        return nil
                    }
                }
                return Body.WireMessage(role: message.role.rawValue, content: blocks)
            }
        let tools = request.tools.isEmpty ? nil : request.tools.map { spec in
            Body.Tool(
                name: spec.name,
                description: spec.description,
                inputSchema: (try? JSONDecoder().decode(JSONValue.self, from: Data(spec.parametersJSON.utf8))) ?? .object([:])
            )
        }
        return Body(
            model: request.modelID,
            maxTokens: request.maxOutputTokens ?? 4096,
            system: request.systemPrompt,
            messages: messages,
            stream: true,
            temperature: request.temperature,
            thinking: request.thinkingBudgetTokens.map { Body.Thinking(budgetTokens: $0) },
            tools: tools
        )
    }
}
