import XCTest
@testable import OMPCore

/// What the gateway receives for an agent turn: every assistant `tool_calls`
/// is followed by exactly one `tool` message per call id, and nothing is
/// orphaned in either direction.
final class AgentToolWireTests: XCTestCase {
    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        try RequestBuilderTests.jsonObject(from: value)
    }

    private func openAIMessages(_ messages: [ChatMessage], media: [UUID: MediaPayload] = [:], tools: [ToolSpec] = []) throws -> [[String: Any]] {
        let body = OpenAIRequestBuilder.build(GenerationRequest(modelID: "m", messages: messages, tools: tools), media: media)
        return try XCTUnwrap(try json(body)["messages"] as? [[String: Any]])
    }

    private let user = ChatMessage(role: .user, parts: [.text("看看项目")])

    func testInlineResultsBecomeToolMessagesAfterTheirCalls() throws {
        let turn = ChatMessage(role: .assistant, parts: [
            .thinking("先列目录"),
            .text("我先看一下。"),
            .toolCall(ToolCall(id: "c1", name: "list_dir", argumentsJSON: #"{"path":"."}"#)),
            .toolCall(ToolCall(id: "c2", name: "read_file", argumentsJSON: #"{"path":"README.md"}"#)),
            .toolResult(ToolResult(callID: "c1", name: "list_dir", outputText: "README.md\nSources/")),
            .toolResult(ToolResult(callID: "c2", name: "read_file", outputText: "# Demo", isError: true)),
        ])
        let answer = ChatMessage(role: .assistant, parts: [.text("这是一个演示项目。")])
        let messages = try openAIMessages([user, turn, answer])

        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "tool", "tool", "assistant"])
        let assistant = messages[1]
        XCTAssertEqual(assistant["content"] as? String, "我先看一下。", "工具输出不能混进助手正文")
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.map { $0["id"] as? String }, ["c1", "c2"])
        XCTAssertEqual(calls.map { $0["type"] as? String }, ["function", "function"])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "list_dir")
        XCTAssertEqual(function["arguments"] as? String, #"{"path":"."}"#)
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(messages[2]["content"] as? String, "README.md\nSources/")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "c2")
        XCTAssertNil(messages[0]["tool_call_id"])
        XCTAssertNil(messages[4]["tool_calls"])
    }

    func testReasoningRidesBackOnlyWithToolCalls() throws {
        let calling = ChatMessage(role: .assistant, parts: [
            .thinking("需要先读文件"),
            .toolCall(ToolCall(id: "c1", name: "read_file", argumentsJSON: "{}")),
            .toolResult(ToolResult(callID: "c1", name: "read_file", outputText: "x")),
        ])
        let answering = ChatMessage(role: .assistant, parts: [.thinking("想好了"), .text("答案")])
        let silent = ChatMessage(role: .assistant, parts: [
            .toolCall(ToolCall(id: "c2", name: "read_file", argumentsJSON: "{}")),
            .toolResult(ToolResult(callID: "c2", name: "read_file", outputText: "y")),
        ])
        let messages = try openAIMessages([user, calling, answering, silent])
        let assistants = messages.filter { $0["role"] as? String == "assistant" }
        XCTAssertEqual(assistants[0]["reasoning_content"] as? String, "需要先读文件", "DeepSeek 思考模式要求回传工具轮的推理")
        XCTAssertNil(assistants[1]["reasoning_content"])
        XCTAssertNil(assistants[2]["reasoning_content"])
    }

    func testSeparateToolRoleMessagesWork() throws {
        let call = ChatMessage(role: .assistant, parts: [.toolCall(ToolCall(id: "c1", name: "shell", argumentsJSON: #"{"command":"ls"}"#))])
        let result = ChatMessage(role: .tool, parts: [.toolResult(ToolResult(callID: "c1", name: "shell", outputText: "a\nb"))])
        let messages = try openAIMessages([user, call, result])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "tool"])
        XCTAssertNil(messages[1]["content"], "只有调用的助手消息不带正文")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "c1")
    }

    func testUnansweredCallsAndOrphanResultsStayOffTheWire() throws {
        // c1 was stopped mid-stream (no result); c9's call was deleted.
        let stopped = ChatMessage(role: .assistant, parts: [
            .text("正在读"),
            .toolCall(ToolCall(id: "c1", name: "read_file", argumentsJSON: #"{"pa"#)),
        ])
        let onlyCall = ChatMessage(role: .assistant, parts: [.toolCall(ToolCall(id: "c2", name: "shell", argumentsJSON: "{}"))])
        let orphan = ChatMessage(role: .tool, parts: [.toolResult(ToolResult(callID: "c9", name: "shell", outputText: "旧结果"))])
        let messages = try openAIMessages([user, stopped, onlyCall, orphan, ChatMessage(role: .user, parts: [.text("继续")])])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"] as? String, "正在读")
        XCTAssertNil(messages[1]["tool_calls"])
        for message in messages {
            XCTAssertNotEqual(message["role"] as? String, "tool")
        }
    }

    func testEveryCallIDIsAnsweredExactlyOnce() throws {
        var transcript: [ChatMessage] = [user]
        for turn in 0..<3 {
            let ids = (0..<2).map { "t\(turn)-\($0)" }
            var parts: [ContentPart] = ids.map { .toolCall(ToolCall(id: $0, name: "read_file", argumentsJSON: "{}")) }
            parts += ids.map { .toolResult(ToolResult(callID: $0, name: "read_file", outputText: "ok")) }
            transcript.append(ChatMessage(role: .assistant, parts: parts))
        }
        let messages = try openAIMessages(transcript)
        var open: [String] = []
        for message in messages {
            if let calls = message["tool_calls"] as? [[String: Any]] {
                XCTAssertTrue(open.isEmpty, "上一轮的调用都已回答")
                open = calls.compactMap { $0["id"] as? String }
            } else if message["role"] as? String == "tool" {
                let id = try XCTUnwrap(message["tool_call_id"] as? String)
                XCTAssertEqual(open.first, id, "tool 消息按调用顺序紧跟其后")
                open.removeFirst()
            } else {
                XCTAssertTrue(open.isEmpty)
            }
        }
        XCTAssertTrue(open.isEmpty)
    }

    func testToolImagesFollowTheToolMessagesAsUserMedia() throws {
        let shot = MediaRef(kind: .image, relativePath: "shot.png", mimeType: "image/png")
        let turn = ChatMessage(role: .assistant, parts: [
            .toolCall(ToolCall(id: "c1", name: "screenshot", argumentsJSON: "{}")),
            .toolCall(ToolCall(id: "c2", name: "list_dir", argumentsJSON: "{}")),
            .toolResult(ToolResult(callID: "c1", name: "screenshot", outputText: "已截图", media: [shot])),
            .toolResult(ToolResult(callID: "c2", name: "list_dir", outputText: "a")),
        ])
        let messages = try openAIMessages([user, turn], media: [shot.id: MediaPayload(mimeType: "image/png", base64: "QUJD")])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "tool", "tool", "user"])
        let content = try XCTUnwrap(messages[4]["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        let image = try XCTUnwrap(content.last?["image_url"] as? [String: Any])
        XCTAssertEqual(image["url"] as? String, "data:image/png;base64,QUJD")
    }

    func testMediaResolverIncludesToolImages() {
        let shot = MediaRef(kind: .image, relativePath: "shot.png", mimeType: "image/png")
        let message = ChatMessage(role: .assistant, parts: [.toolResult(ToolResult(callID: "c", name: "s", outputText: "", media: [shot]))])
        let resolved = MediaPayloadResolver.resolve(messages: [message]) { _ in MediaPayload(mimeType: "image/png", base64: "QQ==") }
        XCTAssertEqual(resolved[shot.id]?.base64, "QQ==")
    }

    func testMalformedOrEmptyArgumentsAreSentAsEmptyObject() throws {
        let turn = ChatMessage(role: .assistant, parts: [
            .toolCall(ToolCall(id: "c1", name: "read_file", argumentsJSON: #"{"path":"#)),
            .toolCall(ToolCall(id: "c2", name: "list_dir", argumentsJSON: "")),
            .toolResult(ToolResult(callID: "c1", name: "read_file", outputText: AgentLoop.invalidArgumentsText, isError: true)),
            .toolResult(ToolResult(callID: "c2", name: "list_dir", outputText: "a")),
        ])
        let messages = try openAIMessages([user, turn])
        let calls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        let arguments = calls.compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String }
        XCTAssertEqual(arguments, ["{}", "{}"])
    }

    func testFunctionToolsRideBesideWebSearch() throws {
        let tools = [
            ToolSpec(name: "web_search", description: "", parametersJSON: "{}", type: "web_search"),
            AgentToolSpec(name: "read_file", description: "读取", parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#, risk: .read, source: "内置").wireSpec,
        ]
        let body = OpenAIRequestBuilder.build(GenerationRequest(modelID: "m", messages: [user], tools: tools))
        let encoded = try XCTUnwrap(try json(body)["tools"] as? [[String: Any]])
        XCTAssertEqual(encoded.count, 2)
        XCTAssertEqual(encoded[0]["type"] as? String, "web_search")
        XCTAssertNil(encoded[0]["function"])
        XCTAssertEqual(encoded[1]["type"] as? String, "function")
        let function = try XCTUnwrap(encoded[1]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "read_file")
        XCTAssertEqual((function["parameters"] as? [String: Any])?["type"] as? String, "object")
    }

    // MARK: Anthropic

    func testAnthropicToolUseAndToolResultBlocks() throws {
        let shot = MediaRef(kind: .image, relativePath: "shot.png", mimeType: "image/png")
        let turn = ChatMessage(role: .assistant, parts: [
            .text("我来看看"),
            .toolCall(ToolCall(id: "toolu_1", name: "read_file", argumentsJSON: #"{"path":"a.txt"}"#)),
            .toolCall(ToolCall(id: "toolu_2", name: "screenshot", argumentsJSON: "")),
            .toolResult(ToolResult(callID: "toolu_1", name: "read_file", outputText: "内容")),
            .toolResult(ToolResult(callID: "toolu_2", name: "screenshot", outputText: "", media: [shot], isError: true)),
        ])
        let next = ChatMessage(role: .user, parts: [.text("接着做")])
        let body = AnthropicRequestBuilder.build(
            GenerationRequest(modelID: "claude", messages: [user, turn, next]),
            media: [shot.id: MediaPayload(mimeType: "image/png", base64: "QUJD")]
        )
        let messages = try XCTUnwrap(try json(body)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"], "工具结果与下一条用户消息合并成一轮")

        let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["text", "tool_use", "tool_use"])
        XCTAssertEqual(assistant[1]["id"] as? String, "toolu_1")
        XCTAssertEqual((assistant[1]["input"] as? [String: Any])?["path"] as? String, "a.txt")
        XCTAssertNotNil(assistant[2]["input"] as? [String: Any], "空参数编码为 {}")

        let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["type"] as? String }, ["tool_result", "tool_result", "text"], "tool_result 必须在最前")
        XCTAssertEqual(results[0]["tool_use_id"] as? String, "toolu_1")
        XCTAssertNil(results[0]["is_error"])
        XCTAssertEqual(results[1]["is_error"] as? Bool, true)
        let imageBlocks = try XCTUnwrap(results[1]["content"] as? [[String: Any]])
        XCTAssertEqual(imageBlocks.first?["type"] as? String, "image")
    }

    func testAnthropicDropsUnansweredCalls() throws {
        let stopped = ChatMessage(role: .assistant, parts: [.toolCall(ToolCall(id: "t1", name: "shell", argumentsJSON: "{}"))])
        let body = AnthropicRequestBuilder.build(GenerationRequest(modelID: "claude", messages: [user, stopped, ChatMessage(role: .user, parts: [.text("算了")])]))
        let messages = try XCTUnwrap(try json(body)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user"], "空的助手轮被省略，相邻用户消息合并")
        XCTAssertEqual((messages[0]["content"] as? [[String: Any]])?.count, 2)
    }

    func testAnthropicStreamNumbersToolCallsFromZero() async throws {
        let events = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":5}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"先读文件"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_a","name":"read_file"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"a.txt\"}"}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_b","name":"list_dir"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
        ]
        let transport = CannedTransport(body: events.map { "data: \($0)\n\n" }.joined())
        let profile = ProviderProfile(name: "A", kind: .anthropic, baseURL: URL(string: "https://anthropic.test")!)
        let provider = AnthropicProvider(profile: profile, apiKey: "k", transport: transport)
        var message = ChatMessage(role: .assistant, parts: [])
        var finish: FinishReason?
        for try await event in provider.stream(GenerationRequest(modelID: "claude", messages: [user])) {
            message.apply(event)
            if case .finished(let reason) = event { finish = reason }
        }
        let calls = message.parts.compactMap { part -> ToolCall? in
            if case .toolCall(let call) = part { call } else { nil }
        }
        XCTAssertEqual(calls.map(\.id), ["toolu_a", "toolu_b"], "文本块不能占用工具调用的序号")
        XCTAssertEqual(calls[0].argumentsJSON, #"{"path":"a.txt"}"#)
        XCTAssertEqual(calls[1].name, "list_dir")
        XCTAssertEqual(finish, .toolCalls)
    }
}

private struct CannedTransport: HTTPTransport {
    var body: String

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data())
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let data = Data(body.utf8)
        return AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        }
    }
}
