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

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
                case toolCallID = "tool_call_id"
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
            var function: Function
            struct Function: Encodable {
                var name: String
                var description: String
                var parameters: JSONValue
            }
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

    static func build(_ request: GenerationRequest) -> Body {
        var messages: [Body.WireMessage] = []
        if let system = request.systemPrompt, !system.isEmpty {
            messages.append(.init(role: "system", content: .text(system)))
        }
        for message in request.messages where message.role != .system {
            let text = message.parts.compactMap { part -> String? in
                switch part {
                case .text(let value): value
                case .toolResult(let result): result.outputText
                default: nil
                }
            }.joined()
            let calls = message.parts.compactMap { part -> Body.WireToolCall? in
                guard case .toolCall(let call) = part else { return nil }
                return Body.WireToolCall(id: call.id, function: .init(name: call.name, arguments: call.argumentsJSON))
            }
            messages.append(.init(
                role: message.role.rawValue,
                content: text.isEmpty ? nil : .text(text),
                toolCalls: calls.isEmpty ? nil : calls,
                toolCallID: nil
            ))
        }
        let tools = request.tools.isEmpty ? nil : request.tools.map { spec in
            Body.WireTool(function: .init(
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
