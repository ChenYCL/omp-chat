import Foundation

struct OpenAIModelsResponse: Decodable {
    struct Entry: Decodable {
        var id: String
        var object: String?
        var created: Int?
        var ownedBy: String?
        var extra: [String: JSONValue]?

        enum CodingKeys: String, CodingKey {
            case id, object, created, ownedBy = "owned_by"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            object = try container.decodeIfPresent(String.self, forKey: .object)
            created = try container.decodeIfPresent(Int.self, forKey: .created)
            ownedBy = try container.decodeIfPresent(String.self, forKey: .ownedBy)
            extra = nil
        }

        func rawMetadata() -> [String: String] {
            var result: [String: String] = [:]
            if let object { result["object"] = object }
            return result
        }
    }

    var data: [Entry]
}

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        var role: String?
        var content: String?
        var reasoningContent: String?
        var reasoning: String?
        var toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case role, content, reasoning
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable {
        var index: Int?
        var id: String?
        var type: String?
        var function: FunctionDelta?
    }

    struct FunctionDelta: Decodable {
        var name: String?
        var arguments: String?
    }

    struct Usage: Decodable {
        struct CompletionDetails: Decodable {
            var reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }
        var promptTokens: Int?
        var completionTokens: Int?
        var completionTokensDetails: CompletionDetails?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case completionTokensDetails = "completion_tokens_details"
        }
    }

    var choices: [Choice]?
    var usage: Usage?
}

struct OpenAIRequestBuilder {
    struct Body: Encodable {
        struct WireMessage: Encodable {
            var role: String
            var content: WireContent?
            var toolCalls: [WireToolCall]?
            var toolCallID: String?
            /// The turn's reasoning, echoed back on assistant turns that call
            /// tools: DeepSeek's thinking mode rejects the next request
            /// (HTTP 400) without it. Omitted when the model streamed none.
            var reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
                case toolCallID = "tool_call_id"
                case reasoningContent = "reasoning_content"
            }
        }

        struct WireToolCall: Encodable {
            var id: String
            var type: String = "function"
            var function: Function
            struct Function: Encodable {
                var name: String
                var arguments: String
            }
        }

        var model: String
        var messages: [WireMessage]
        var stream: Bool = true
        var temperature: Double?
        var maxTokens: Int?
        var tools: [WireTool]?
        var streamOptions: StreamOptions = StreamOptions()

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature, tools
            case maxTokens = "max_tokens"
            case streamOptions = "stream_options"
        }

        struct StreamOptions: Encodable {
            var includeUsage: Bool = true
            enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
        }

        struct WireTool: Encodable {
            var type: String = "function"
            var function: Function?
            struct Function: Encodable {
                var name: String
                var description: String
                var parameters: JSONValue
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(type, forKey: .type)
                // Omit the key for a server-side tool rather than sending null.
                try c.encodeIfPresent(function, forKey: .function)
            }

            enum CodingKeys: String, CodingKey { case type, function }
        }
    }

    enum WireContent: Encodable {
        case text(String)
        case blocks([Block])

        struct Block: Encodable {
            var type: String
            var text: String?
            var imageURL: ImageURL?
            enum CodingKeys: String, CodingKey {
                case type, text
                case imageURL = "image_url"
            }
        }

        struct ImageURL: Encodable { var url: String }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .blocks(let blocks): try container.encode(blocks)
            }
        }
    }

    static func build(_ request: GenerationRequest, media: [UUID: MediaPayload] = [:]) -> Body {
        var messages: [Body.WireMessage] = []
        if let system = request.systemPrompt, !system.isEmpty {
            messages.append(.init(role: "system", content: .text(system)))
        }
        let pairing = ToolCallPairing(request.messages)
        // Images a tool returned cannot ride in a `tool` message. They follow
        // the run of tool messages as one user message, so the run stays
        // contiguous after its assistant `tool_calls`.
        var toolImages: [WireContent.Block] = []
        func flushToolImages() {
            guard !toolImages.isEmpty else { return }
            let note = WireContent.Block(type: "text", text: "以上工具调用返回的图片：", imageURL: nil)
            messages.append(.init(role: "user", content: .blocks([note] + toolImages)))
            toolImages = []
        }
        func appendResults(_ results: [ToolResult]) {
            for result in results {
                messages.append(.init(role: "tool", content: .text(result.outputText), toolCallID: result.callID))
                toolImages += result.media.compactMap { ref in
                    guard ref.kind == .image, let payload = media[ref.id] else { return nil }
                    return WireContent.Block(type: "image_url", text: nil, imageURL: .init(url: payload.dataURL))
                }
            }
        }

        for message in request.messages where message.role != .system {
            let results = pairing.pairedResults(in: message)
            if message.role == .tool {
                appendResults(results)
                continue
            }
            flushToolImages()
            let text = message.parts.compactMap { part -> String? in
                switch part {
                case .text(let value): value
                // A result whose call is gone is kept as plain text.
                case .toolResult(let result) where !pairing.isPaired(result): result.outputText
                default: nil
                }
            }.joined()
            let imageBlocks = message.parts.compactMap { part -> WireContent.Block? in
                guard case .media(let ref) = part, let payload = media[ref.id] else { return nil }
                return WireContent.Block(type: "image_url", text: nil, imageURL: .init(url: payload.dataURL))
            }
            let unresolved = message.parts.compactMap { part -> String? in
                guard case .media(let ref) = part, media[ref.id] == nil else { return nil }
                return "[附件] \(ref.originalName ?? ref.relativePath)"
            }
            let bodyText = ([text] + unresolved).filter { !$0.isEmpty }.joined(separator: "\n")
            let content: WireContent?
            if imageBlocks.isEmpty {
                content = bodyText.isEmpty ? nil : .text(bodyText)
            } else {
                var blocks = imageBlocks
                if !bodyText.isEmpty {
                    blocks.insert(WireContent.Block(type: "text", text: bodyText, imageURL: nil), at: 0)
                }
                content = .blocks(blocks)
            }
            let calls = pairing.pairedCalls(in: message).map { call in
                // Malformed arguments (the model's own, already answered with an
                // error) go back as `{}`: a gateway that translates to another
                // dialect must parse them, and would reject the whole request.
                let arguments = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                let valid = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) is [String: Any]
                return Body.WireToolCall(id: call.id, function: .init(name: call.name, arguments: valid ? arguments : "{}"))
            }
            // An assistant turn that only held unanswered calls has nothing left to say.
            if content == nil && calls.isEmpty && message.role == .assistant { continue }
            let reasoning = message.thinkingText
            messages.append(.init(
                role: message.role.rawValue,
                content: content,
                toolCalls: calls.isEmpty ? nil : calls,
                toolCallID: nil,
                reasoningContent: calls.isEmpty || reasoning.isEmpty ? nil : reasoning
            ))
            // The agent loop stores results beside their calls.
            appendResults(results)
        }
        flushToolImages()
        let tools = request.tools.isEmpty ? nil : request.tools.map { spec in
            // A server-side tool (web_search) has no function schema.
            if spec.type != "function" { return Body.WireTool(type: spec.type, function: nil) }
            return Body.WireTool(function: .init(
                name: spec.name,
                description: spec.description,
                parameters: (try? JSONDecoder().decode(JSONValue.self, from: Data(spec.parametersJSON.utf8))) ?? .object([:])
            ))
        }
        return Body(
            model: request.modelID,
            messages: messages,
            stream: true,
            temperature: request.temperature,
            maxTokens: request.maxOutputTokens,
            tools: tools
        )
    }
}

/// Which tool calls and results may go on the wire. Gateways reject an
/// assistant turn whose calls are not each answered by a result, and a
/// result whose call was never made, so a call stopped mid-stream (or a
/// result left over from an edited transcript) is kept off the wire.
struct ToolCallPairing {
    private let answered: Set<String>
    private let called: Set<String>

    init(_ messages: [ChatMessage]) {
        var answered: Set<String> = []
        var called: Set<String> = []
        for message in messages {
            for part in message.parts {
                switch part {
                case .toolCall(let call): called.insert(call.id)
                case .toolResult(let result): answered.insert(result.callID)
                default: break
                }
            }
        }
        self.answered = answered
        self.called = called
    }

    func isPaired(_ result: ToolResult) -> Bool { called.contains(result.callID) }

    func pairedCalls(in message: ChatMessage) -> [ToolCall] {
        message.parts.compactMap { part in
            guard case .toolCall(let call) = part, answered.contains(call.id) else { return nil }
            return call
        }
    }

    func pairedResults(in message: ChatMessage) -> [ToolResult] {
        message.parts.compactMap { part in
            guard case .toolResult(let result) = part, called.contains(result.callID) else { return nil }
            return result
        }
    }
}
