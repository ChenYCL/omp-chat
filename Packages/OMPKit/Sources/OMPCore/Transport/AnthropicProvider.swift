import Foundation

/// Anthropic Messages API dialect (`/v1/messages` + `/v1/models`).
public struct AnthropicProvider: ChatProvider {
    public let profile: ProviderProfile
    private let apiKey: String
    private let transport: HTTPTransport
    private let apiVersion: String
    private let mediaPayloads: MediaPayloadProvider?

    public init(
        profile: ProviderProfile,
        apiKey: String,
        transport: HTTPTransport = URLSessionTransport(),
        apiVersion: String = "2023-06-01",
        mediaPayloads: MediaPayloadProvider? = nil
    ) {
        self.profile = profile
        self.apiKey = apiKey
        self.transport = transport
        self.apiVersion = apiVersion
        self.mediaPayloads = mediaPayloads
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
                    // Content-block index → position among this turn's tool calls.
                    // Text and thinking blocks share the block index space, and
                    // `ChatMessage.apply` expects tool calls numbered from 0.
                    var toolOrdinals: [Int: Int] = [:]
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
                                    if block.type == "tool_use", toolOrdinals[index] == nil {
                                        toolOrdinals[index] = toolOrdinals.count
                                    }
                                    if block.type == "text", let text = block.text, !text.isEmpty {
                                        continuation.yield(.textDelta(text))
                                    }
                                    if block.type == "thinking", let thinking = block.thinking, !thinking.isEmpty {
                                        continuation.yield(.thinkingDelta(thinking))
                                    }
                                    if block.type == "tool_use", let name = block.name, let id = block.id, let ordinal = toolOrdinals[index] {
                                        continuation.yield(.toolCallDelta(index: ordinal, id: id, name: name, argumentsDelta: nil))
                                    }
                                }
                            case "content_block_delta":
                                if let delta = payload.delta {
                                    if let text = delta.text, !text.isEmpty {
                                        continuation.yield(.textDelta(text))
                                    } else if let thinking = delta.thinking, !thinking.isEmpty {
                                        continuation.yield(.thinkingDelta(thinking))
                                    } else if let partial = delta.partialJSON, let index = payload.index, let ordinal = toolOrdinals[index] {
                                        continuation.yield(.toolCallDelta(index: ordinal, id: nil, name: nil, argumentsDelta: partial))
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
        let media = MediaPayloadResolver.resolve(messages: request.messages, using: mediaPayloads)
        urlRequest.httpBody = try JSONEncoder().encode(AnthropicRequestBuilder.build(request, media: media))
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
            var toolUseID: String?
            var content: [Block]?
            var isError: Bool?

            enum CodingKeys: String, CodingKey {
                case type, text, source, id, name, input, content
                case toolUseID = "tool_use_id"
                case isError = "is_error"
            }
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

    static func build(_ request: GenerationRequest, media: [UUID: MediaPayload] = [:]) -> Body {
        let pairing = ToolCallPairing(request.messages)
        var messages: [Body.WireMessage] = []
        // Turns must alternate, and tool results ride in the user turn right
        // after the assistant's `tool_use` blocks, so same-role neighbours merge.
        func append(_ role: String, _ blocks: [Body.Block]) {
            guard !blocks.isEmpty else { return }
            if messages.last?.role == role {
                messages[messages.count - 1].content += blocks
            } else {
                messages.append(Body.WireMessage(role: role, content: blocks))
            }
        }
        func imageBlock(_ ref: MediaRef) -> Body.Block? {
            guard ref.kind == .image, let payload = media[ref.id] else { return nil }
            return Body.Block(type: "image", source: .init(mediaType: payload.mimeType, data: payload.base64))
        }
        func resultBlocks(_ results: [ToolResult]) -> [Body.Block] {
            results.map { result in
                var content: [Body.Block] = []
                if !result.outputText.isEmpty { content.append(Body.Block(type: "text", text: result.outputText)) }
                content += result.media.compactMap(imageBlock)
                return Body.Block(
                    type: "tool_result",
                    toolUseID: result.callID,
                    content: content.isEmpty ? nil : content,
                    isError: result.isError ? true : nil
                )
            }
        }

        for message in request.messages where message.role != .system {
            let results = pairing.pairedResults(in: message)
            if message.role == .tool {
                append("user", resultBlocks(results))
                continue
            }
            var blocks = message.parts.compactMap { part -> Body.Block? in
                switch part {
                case .text(let value):
                    return value.isEmpty ? nil : Body.Block(type: "text", text: value)
                case .thinking(let value):
                    return value.isEmpty ? nil : Body.Block(type: "thinking", text: value)
                case .media(let ref):
                    guard let payload = media[ref.id] else { return nil }
                    return Body.Block(
                        type: "image",
                        source: .init(mediaType: payload.mimeType, data: payload.base64)
                    )
                case .toolResult(let result) where !pairing.isPaired(result):
                    // A result whose call is gone is kept as plain text.
                    return result.outputText.isEmpty ? nil : Body.Block(type: "text", text: result.outputText)
                default:
                    return nil
                }
            }
            blocks += pairing.pairedCalls(in: message).map { call in
                let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(call.argumentsJSON.utf8))
                let input: JSONValue
                if case .object = parsed { input = parsed ?? .object([:]) } else { input = .object([:]) }
                return Body.Block(type: "tool_use", id: call.id, name: call.name, input: input)
            }
            append(message.role.rawValue, blocks)
            // The agent loop stores results beside their calls.
            append("user", resultBlocks(results))
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
