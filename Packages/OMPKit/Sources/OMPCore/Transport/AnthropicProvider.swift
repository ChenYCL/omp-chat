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
                    // Content-block index → thinking text so far, so each
                    // signature is bound to exactly the text it was issued for.
                    var thinkingTexts: [Int: String] = [:]
                    var sealedBlocks: Set<Int> = []
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
                                    if block.type == "thinking" {
                                        let text = block.thinking ?? ""
                                        thinkingTexts[index] = text
                                        if !text.isEmpty { continuation.yield(.thinkingDelta(text)) }
                                        // A relay replaying a finished message may send the block whole.
                                        if let signature = block.signature, !signature.isEmpty {
                                            sealedBlocks.insert(index)
                                            continuation.yield(.thinkingSeal(.signature(signature, sealing: text)))
                                        }
                                    }
                                    if block.type == "redacted_thinking", let data = block.data, !data.isEmpty {
                                        continuation.yield(.thinkingSeal(.redacted(data)))
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
                                        if let index = payload.index { thinkingTexts[index, default: ""] += thinking }
                                        continuation.yield(.thinkingDelta(thinking))
                                    } else if let signature = delta.signature, !signature.isEmpty,
                                              let index = payload.index, sealedBlocks.insert(index).inserted {
                                        // `signature_delta` arrives once, just before the block's
                                        // `content_block_stop`; display "omitted" streams no text first.
                                        continuation.yield(.thinkingSeal(.signature(signature, sealing: thinkingTexts[index] ?? "")))
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
        var signature: String?
        /// `redacted_thinking` payload.
        var data: String?
        var id: String?
        var name: String?
    }

    struct Delta: Decodable {
        var type: String?
        var text: String?
        var thinking: String?
        var signature: String?
        var partialJSON: String?
        var stopReason: String?
        enum CodingKeys: String, CodingKey {
            case type, text, thinking, signature
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

/// Builds the `/v1/messages` body.
///
/// Thinking rules relied on here (Anthropic docs, read 2026-10-26):
/// - A tool-use loop is one assistant turn. When tool results go back, the
///   thinking of that turn must go back complete and unmodified: `thinking`
///   text with its `signature`, `redacted_thinking` with its `data`, in the
///   order generated. Rebuilt, edited, reordered or partially dropped blocks
///   get a 400, so a message's thinking goes back whole or not at all, and an
///   unsigned block is never sent.
///   https://platform.claude.com/docs/en/build-with-claude/thinking#preserving-thinking-blocks
///   https://platform.claude.com/docs/en/build-with-claude/thinking#redacted-thinking-blocks
/// - Outside tool use, earlier turns' thinking may be omitted.
///   https://platform.claude.com/docs/en/build-with-claude/thinking#thinking-encryption
/// - A block is bound to the system prompt, tools and messages before it and
///   to the thinking block before it; blocks may only be removed from the
///   front. Dropping all thinking before the latest user message, on every
///   request, only ever removes from the front, and a system prompt or tool
///   list that changed between turns (memories, skills, MCP) cannot
///   invalidate it.
///   https://platform.claude.com/docs/en/build-with-claude/preserved-thinking#keeping-the-prefix-unchanged
/// - With `display: "omitted"` (the default on newer models) a block's text is
///   empty; it still goes back, with its signature.
///   https://platform.claude.com/docs/en/build-with-claude/thinking#controlling-thinking-display
/// - Manual mode (`type: "enabled"`): the final assistant turn, i.e. the
///   running tool loop, must open with a thinking block; later messages of the
///   loop have thinking only when interleaved. Thinking cannot change inside a
///   turn; the API silently turns it off when it would. When the loop cannot
///   open with a signed block, thinking is turned off here for the request.
///   https://platform.claude.com/docs/en/build-with-claude/extended-thinking#turn-structure-in-manual-mode
///   https://platform.claude.com/docs/en/build-with-claude/thinking-tool-workflows#how-interleaved-thinking-changes-the-flow
/// - `budget_tokens` is at least 1024 and below `max_tokens` (the interleaved
///   exception needs a beta header this builder does not send).
///   https://platform.claude.com/docs/en/build-with-claude/extended-thinking#budget-rules-and-tuning
/// - `temperature` is incompatible with thinking on models before 4.7.
///   https://platform.claude.com/docs/en/build-with-claude/thinking#sampling-parameters
/// - Manual thinking accepts only `tool_choice` auto / none; no `tool_choice`
///   is sent, which means auto.
///   https://platform.claude.com/docs/en/build-with-claude/thinking#thinking-with-tool-use
/// - The `interleaved-thinking-2025-05-14` beta only lets the model also think
///   between tool calls. Replaying blocks where they arrived covers both
///   shapes, so the header is not needed and not sent.
///   https://platform.claude.com/docs/en/build-with-claude/extended-thinking#interleaved-thinking-in-manual-mode
struct AnthropicRequestBuilder {
    struct Body: Encodable {
        struct WireMessage: Encodable {
            var role: String
            var content: [Block]
        }
        struct Block: Encodable {
            var type: String
            var text: String?
            var thinking: String?
            var signature: String?
            /// `redacted_thinking` payload.
            var data: String?
            var source: ImageSource?
            var id: String?
            var name: String?
            var input: JSONValue?
            var toolUseID: String?
            var content: [Block]?
            var isError: Bool?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking, signature, data, source, id, name, input, content
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
        let maxTokens = request.maxOutputTokens ?? 4096
        var budget = request.thinkingBudgetTokens.map { max(1024, $0) }
        if let value = budget, value >= maxTokens { budget = nil }
        var encoded = encodeMessages(request, media: media, replayThinking: budget != nil)
        if budget != nil, let opening = encoded.loopOpening, opening != "thinking", opening != "redacted_thinking" {
            budget = nil
            encoded = encodeMessages(request, media: media, replayThinking: false)
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
            maxTokens: maxTokens,
            system: request.systemPrompt,
            messages: encoded.messages,
            stream: true,
            temperature: budget == nil ? request.temperature : nil,
            thinking: budget.map { Body.Thinking(budgetTokens: $0) },
            tools: tools
        )
    }

    /// The wire messages, plus the type of the first block of the running
    /// tool loop (nil when the request ends with the user's turn).
    private static func encodeMessages(
        _ request: GenerationRequest,
        media: [UUID: MediaPayload],
        replayThinking: Bool
    ) -> (messages: [Body.WireMessage], loopOpening: String?) {
        let pairing = ToolCallPairing(request.messages)
        // The tool loop still running: everything after the latest user message.
        let loopStart = request.messages.lastIndex { $0.role == .user }.map { $0 + 1 } ?? 0
        var messages: [Body.WireMessage] = []
        var loopOpening: String?
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

        for (index, message) in request.messages.enumerated() where message.role != .system {
            let results = pairing.pairedResults(in: message)
            if message.role == .tool {
                append("user", resultBlocks(results))
                continue
            }
            let inLoop = index >= loopStart && message.role == .assistant
            let thinking = replayThinking && inLoop ? replayableThinking(message.parts) : nil
            let answered = Set(pairing.pairedCalls(in: message).map(\.id))
            // Part order is stream order, which the thinking signatures cover.
            var blocks: [Body.Block] = []
            for (position, part) in message.parts.enumerated() {
                switch part {
                case .text(let value):
                    if !value.isEmpty { blocks.append(Body.Block(type: "text", text: value)) }
                case .thinking, .thinkingSeal:
                    if let block = thinking?[position] { blocks.append(block) }
                case .media(let ref):
                    guard let payload = media[ref.id] else { continue }
                    blocks.append(Body.Block(type: "image", source: .init(mediaType: payload.mimeType, data: payload.base64)))
                case .toolCall(let call):
                    guard answered.contains(call.id) else { continue }
                    let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(call.argumentsJSON.utf8))
                    let input: JSONValue
                    if case .object = parsed { input = parsed ?? .object([:]) } else { input = .object([:]) }
                    blocks.append(Body.Block(type: "tool_use", id: call.id, name: call.name, input: input))
                case .toolResult(let result):
                    // A result whose call is gone is kept as plain text.
                    if !pairing.isPaired(result), !result.outputText.isEmpty {
                        blocks.append(Body.Block(type: "text", text: result.outputText))
                    }
                }
            }
            if inLoop, loopOpening == nil { loopOpening = blocks.first?.type }
            append(message.role.rawValue, blocks)
            // The agent loop stores results beside their calls.
            append("user", resultBlocks(results))
        }
        return (messages, loopOpening)
    }

    /// A message's thinking as wire blocks, keyed by the part each one stands
    /// in for; nil when any of it cannot go back exactly as generated: text
    /// with no signature (stream cut, another provider, a relay that strips
    /// them) or text that no longer matches its signature.
    private static func replayableThinking(_ parts: [ContentPart]) -> [Int: Body.Block]? {
        var blocks: [Int: Body.Block] = [:]
        var open: (position: Int, text: String)?
        for (position, part) in parts.enumerated() {
            switch part {
            case .thinking(let text):
                guard !text.isEmpty else { continue }
                guard open == nil else { return nil }
                open = (position, text)
            case .thinkingSeal(let seal) where seal.kind == .redacted:
                guard open == nil else { return nil }
                blocks[position] = Body.Block(type: "redacted_thinking", data: seal.value)
            case .thinkingSeal(let seal):
                if let pending = open, seal.seals(pending.text) {
                    blocks[pending.position] = Body.Block(type: "thinking", thinking: pending.text, signature: seal.value)
                    open = nil
                } else if open == nil, seal.seals("") {
                    blocks[position] = Body.Block(type: "thinking", thinking: "", signature: seal.value)
                } else {
                    return nil
                }
            default:
                guard open == nil else { return nil }
            }
        }
        return open == nil ? blocks : nil
    }
}
