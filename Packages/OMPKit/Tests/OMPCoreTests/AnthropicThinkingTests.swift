import XCTest
@testable import OMPCore

/// Anthropic extended thinking across a tool loop: the turn that made the
/// `tool_use` calls must go back opening with its original, signed thinking,
/// and nothing unsigned or altered may ever be sent.
final class AnthropicThinkingTests: XCTestCase {
    private let user = ChatMessage(role: .user, parts: [.text("看看项目")])

    private func body(_ messages: [ChatMessage], budget: Int? = 2048, maxTokens: Int? = 8192, temperature: Double? = nil) throws -> [String: Any] {
        let request = GenerationRequest(
            modelID: "claude-sonnet-4-5", messages: messages, temperature: temperature,
            maxOutputTokens: maxTokens, thinkingBudgetTokens: budget
        )
        return try RequestBuilderTests.jsonObject(from: AnthropicRequestBuilder.build(request))
    }

    private func wireMessages(_ body: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(body["messages"] as? [[String: Any]])
    }

    private func content(_ message: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(message["content"] as? [[String: Any]])
    }

    private func call(_ id: String, _ name: String = "list_dir") -> ContentPart {
        .toolCall(ToolCall(id: id, name: name, argumentsJSON: #"{"path":"."}"#))
    }

    private func result(_ id: String, _ name: String = "list_dir") -> ContentPart {
        .toolResult(ToolResult(callID: id, name: name, outputText: "README.md"))
    }

    private func signed(_ text: String, _ signature: String) -> [ContentPart] {
        [.thinking(text), .thinkingSeal(.signature(signature, sealing: text))]
    }

    // MARK: Request

    func testToolTurnGoesBackOpeningWithItsSignedThinking() throws {
        let turn = ChatMessage(role: .assistant, parts: signed("先列目录", "sig-1") + [.text("我先看一下。"), call("c1"), result("c1")])
        let json = try body([user, turn], temperature: 0.3)
        let messages = try wireMessages(json)
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])

        let assistant = try content(messages[1])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["thinking", "text", "tool_use"], "签名思考在最前，其后文本、工具调用，保持原顺序")
        XCTAssertEqual(assistant[0]["thinking"] as? String, "先列目录")
        XCTAssertEqual(assistant[0]["signature"] as? String, "sig-1")
        XCTAssertNil(assistant[0]["text"], "思考正文走 thinking 字段，不是 text")
        XCTAssertEqual(try content(messages[2]).first?["tool_use_id"] as? String, "c1")

        let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 2048)
        XCTAssertNil(json["temperature"], "开启思考时不能带 temperature")
    }

    func testUnsignedThinkingNeverGoesOutAndThinkingTurnsOffForTheLoop() throws {
        // Stream cut before the signature, another provider, or a relay that strips signatures.
        let turn = ChatMessage(role: .assistant, parts: [.thinking("先列目录"), call("c1"), result("c1")])
        let json = try body([user, turn], temperature: 0.3)
        let assistant = try content(try wireMessages(json)[1])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["tool_use"], "没有签名的思考块不发")
        XCTAssertNil(json["thinking"], "手动模式下工具轮必须以思考块开头，开不了就关掉这次请求的思考")
        XCTAssertEqual(json["temperature"] as? Double, 0.3, "思考关掉后 temperature 照常发送")
    }

    func testUnsignedThinkingOfAnEarlierTurnIsDroppedWithoutTurningThinkingOff() throws {
        let earlier = ChatMessage(role: .assistant, parts: [.thinking("别家模型的推理"), .text("答案")])
        let json = try body([user, earlier, ChatMessage(role: .user, parts: [.text("继续")])])
        let messages = try wireMessages(json)
        XCTAssertEqual(try content(messages[1]).map { $0["type"] as? String }, ["text"])
        XCTAssertNotNil(json["thinking"])
    }

    func testThinkingDisabledSendsNoThinkingBlocks() throws {
        let turn = ChatMessage(role: .assistant, parts: signed("先列目录", "sig-1") + [.thinkingSeal(.redacted("R")), call("c1"), result("c1")])
        let json = try body([user, turn], budget: nil, temperature: 0.3)
        XCTAssertEqual(try content(try wireMessages(json)[1]).map { $0["type"] as? String }, ["tool_use"])
        XCTAssertNil(json["thinking"])
        XCTAssertEqual(json["temperature"] as? Double, 0.3)
    }

    func testRedactedThinkingGoesBackInPlaceWithItsData() throws {
        let turn = ChatMessage(role: .assistant, parts: [.thinkingSeal(.redacted("opaque-data"))] + signed("再看一下", "sig-2") + [call("c1"), result("c1")])
        let json = try body([user, turn])
        let assistant = try content(try wireMessages(json)[1])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["redacted_thinking", "thinking", "tool_use"])
        XCTAssertEqual(assistant[0]["data"] as? String, "opaque-data")
        XCTAssertNil(assistant[0]["thinking"])
        XCTAssertNil(assistant[0]["signature"])
        XCTAssertEqual(assistant[1]["signature"] as? String, "sig-2")
        XCTAssertNotNil(json["thinking"], "以 redacted_thinking 开头也算以思考开头")
    }

    func testOmittedDisplayBlockGoesBackWithEmptyTextAndItsSignature() throws {
        let turn = ChatMessage(role: .assistant, parts: [.thinkingSeal(.signature("sig-empty", sealing: "")), call("c1"), result("c1")])
        let assistant = try content(try wireMessages(try body([user, turn]))[1])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["thinking", "tool_use"])
        XCTAssertEqual(assistant[0]["thinking"] as? String, "")
        XCTAssertEqual(assistant[0]["signature"] as? String, "sig-empty")
    }

    func testEditedThinkingDropsTheStaleSignature() throws {
        var turn = ChatMessage(role: .assistant, parts: signed("先列目录", "sig-1") + [call("c1"), result("c1")])
        turn.parts[0] = .thinking("先列目录，再读 README")
        let json = try body([user, turn])
        XCTAssertEqual(try content(try wireMessages(json)[1]).map { $0["type"] as? String }, ["tool_use"], "改过的思考不能带旧签名")
        XCTAssertNil(json["thinking"])
    }

    func testOnlyTheRunningToolLoopCarriesThinking() throws {
        let earlier = ChatMessage(role: .assistant, parts: signed("上一轮的思考", "sig-old") + [.text("上一轮答案")])
        let next = ChatMessage(role: .user, parts: [.text("再看看 Sources")])
        let first = ChatMessage(role: .assistant, parts: signed("先列目录", "sig-1") + [call("c1"), result("c1")])
        // Without interleaved thinking the loop's later replies carry none.
        let second = ChatMessage(role: .assistant, parts: [.text("再读文件"), call("c2", "read_file"), result("c2", "read_file")])
        let interleaved = ChatMessage(role: .assistant, parts: signed("读完了，再查一处", "sig-3") + [call("c3", "read_file"), result("c3", "read_file")])
        let json = try body([user, earlier, next, first, second, interleaved])
        let assistants = try wireMessages(json).filter { $0["role"] as? String == "assistant" }.map(content)

        XCTAssertEqual(assistants[0].map { $0["type"] as? String }, ["text"], "最新用户消息之前的思考一律不发")
        XCTAssertEqual(assistants[1].map { $0["type"] as? String }, ["thinking", "tool_use"])
        XCTAssertEqual(assistants[2].map { $0["type"] as? String }, ["text", "tool_use"])
        XCTAssertEqual(assistants[3].map { $0["type"] as? String }, ["thinking", "tool_use"])
        XCTAssertEqual(assistants[3][0]["signature"] as? String, "sig-3")
        XCTAssertNotNil(json["thinking"], "工具轮以思考开头，后续消息没有思考是正常的")
    }

    func testOneUnsignedBlockKeepsTheWholeMessagesThinkingOffTheWire() throws {
        // A turn's blocks may not be partially dropped.
        let turn = ChatMessage(role: .assistant, parts: signed("第一段", "sig-1") + [.thinking("第二段没有签名"), call("c1"), result("c1")])
        let json = try body([user, turn])
        XCTAssertEqual(try content(try wireMessages(json)[1]).map { $0["type"] as? String }, ["tool_use"])
        XCTAssertNil(json["thinking"])
    }

    func testBudgetMeetsTheMinimumAndStaysBelowMaxTokens() throws {
        let raised = try XCTUnwrap(try body([user], budget: 512, maxTokens: 2048)["thinking"] as? [String: Any])
        XCTAssertEqual(raised["budget_tokens"] as? Int, 1024, "budget_tokens 最小 1024")

        let tooSmall = try body([user], budget: 512, maxTokens: 1024, temperature: 0.5)
        XCTAssertNil(tooSmall["thinking"], "max_tokens 装不下 1024 的预算就不开思考")
        XCTAssertEqual(tooSmall["temperature"] as? Double, 0.5)
    }

    func testSealsDoNotTouchOpenAIReasoning() throws {
        let turn = ChatMessage(role: .assistant, parts: signed("需要先读文件", "sig-1") + [call("c1"), result("c1")])
        let body = OpenAIRequestBuilder.build(GenerationRequest(modelID: "m", messages: [user, turn]))
        let messages = try XCTUnwrap(try RequestBuilderTests.jsonObject(from: body)["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        XCTAssertEqual(assistant["reasoning_content"] as? String, "需要先读文件")
    }

    // MARK: Stream → message → next request

    private func stream(_ events: [String]) async throws -> ChatMessage {
        let transport = ThinkingCannedTransport(body: events.map { "data: \($0)\n\n" }.joined())
        let profile = ProviderProfile(name: "A", kind: .anthropic, baseURL: URL(string: "https://anthropic.test")!)
        let provider = AnthropicProvider(profile: profile, apiKey: "k", transport: transport)
        var message = ChatMessage(role: .assistant, parts: [], status: .streaming)
        for try await event in provider.stream(GenerationRequest(modelID: "claude", messages: [user])) {
            message.apply(event)
        }
        return message
    }

    func testStreamedThinkingSignatureAndToolUseRoundTripIntoTheNextRequest() async throws {
        var message = try await stream([
            #"{"type":"message_start","message":{"usage":{"input_tokens":5}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"先看"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"目录"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EosnCkYICxIM"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"EmwKAhgB"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"thinking_delta","thinking":"用 list_dir"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"signature_delta","signature":"Es8CCkYI"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"我先列目录。"}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"content_block_start","index":4,"content_block":{"type":"tool_use","id":"toolu_1","name":"list_dir","input":{}}}"#,
            #"{"type":"content_block_delta","index":4,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\".\"}"}}"#,
            #"{"type":"content_block_stop","index":4}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
            #"{"type":"message_stop"}"#,
        ])
        XCTAssertEqual(message.thinkingText, "先看目录用 list_dir", "界面与中继只看到可读思考，看不到签名")
        message.parts.append(result("toolu_1"))
        message.status = .complete

        // The stored document round trip must keep the seals.
        let stored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(stored, message)

        let assistant = try content(try wireMessages(try body([user, stored]))[1])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["thinking", "redacted_thinking", "thinking", "text", "tool_use"], "一轮里多个思考块逐个保留，不合并")
        XCTAssertEqual(assistant[0]["thinking"] as? String, "先看目录")
        XCTAssertEqual(assistant[0]["signature"] as? String, "EosnCkYICxIM")
        XCTAssertEqual(assistant[1]["data"] as? String, "EmwKAhgB")
        XCTAssertEqual(assistant[2]["thinking"] as? String, "用 list_dir")
        XCTAssertEqual(assistant[2]["signature"] as? String, "Es8CCkYI")
        XCTAssertEqual(assistant[4]["id"] as? String, "toolu_1")
        XCTAssertEqual((assistant[4]["input"] as? [String: Any])?["path"] as? String, ".")
    }

    func testOmittedDisplayStreamKeepsTheSignatureWithNoText() async throws {
        let message = try await stream([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EosnCkYI"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"list_dir"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ])
        XCTAssertEqual(message.thinkingText, "")
        var turn = message
        turn.parts.append(result("toolu_1"))
        let assistant = try content(try wireMessages(try body([user, turn]))[1])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["thinking", "tool_use"])
        XCTAssertEqual(assistant[0]["thinking"] as? String, "")
        XCTAssertEqual(assistant[0]["signature"] as? String, "EosnCkYI")
    }

    func testStreamCutBeforeTheSignatureLeavesNothingToReplay() async throws {
        var message = try await stream([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"先看目录"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"list_dir"}}"#,
        ])
        message.parts.append(result("toolu_1"))
        let json = try body([user, message])
        XCTAssertEqual(try content(try wireMessages(json)[1]).map { $0["type"] as? String }, ["tool_use"])
        XCTAssertNil(json["thinking"])
    }

    func testRegeneratedReplyCarriesOnlyItsOwnSignature() async throws {
        let replaced = ChatMessage(role: .assistant, parts: signed("旧的思考", "sig-old") + [call("c0"), result("c0")])
        var conversation = Conversation(messages: [user, replaced])
        // What `regenerateLast` does: the old reply moves aside, a fresh one streams in.
        conversation.alternativeReplies.append(conversation.messages.removeLast())
        var fresh = try await stream([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"新的思考","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-new"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"list_dir"}}"#,
        ])
        fresh.parts.append(result("toolu_1"))
        conversation.messages.append(fresh)

        let raw = String(decoding: try JSONEncoder().encode(AnthropicRequestBuilder.build(
            GenerationRequest(modelID: "claude", messages: conversation.messages, maxOutputTokens: 8192, thinkingBudgetTokens: 2048)
        )), as: UTF8.self)
        XCTAssertTrue(raw.contains("sig-new"))
        XCTAssertFalse(raw.contains("sig-old"), "被重新生成替换掉的回复的签名不能出现在请求里")
        XCTAssertFalse(raw.contains("旧的思考"))
    }
}

/// How thinking seals persist: old documents keep decoding, older builds can
/// still read new documents, and exports leave the seals behind.
final class ContentPartThinkingSealTests: XCTestCase {
    func testSealRoundTripsAndRidesOnAnEmptyThinkingKey() throws {
        let part = ContentPart.thinkingSeal(.signature("sig-1", sealing: "先列目录"))
        let data = try JSONEncoder().encode(part)
        XCTAssertEqual(try JSONDecoder().decode(ContentPart.self, from: data), part)

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["thinking"] as? String, "", "旧版本按 thinking 键解出空思考，不会整段解码失败")
        // Decoded the way builds before seals did: the first known key wins.
        struct OlderPart: Decodable {
            enum Key: String, CodingKey { case text, thinking, media, toolCall, toolResult }
            var thinking: String?
            init(from decoder: Decoder) throws {
                thinking = try decoder.container(keyedBy: Key.self).decodeIfPresent(String.self, forKey: .thinking)
            }
        }
        XCTAssertEqual(try JSONDecoder().decode(OlderPart.self, from: data).thinking, "")
    }

    func testDocumentsWithoutSealsStillDecode() throws {
        let current = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","parts":[{"thinking":"想一想"},{"text":"答案"}]}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(current.utf8))
        XCTAssertEqual(message.parts, [.thinking("想一想"), .text("答案")])

        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","parts":[{"thinking":{"_0":"想一想"}},{"text":{"_0":"答案"}},{"toolCall":{"_0":{"id":"c1","name":"ls","argumentsJSON":"{}"}}}]}"#
        let old = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.parts, [.thinking("想一想"), .text("答案"), .toolCall(ToolCall(id: "c1", name: "ls", argumentsJSON: "{}"))])
    }

    func testUnreadableSealDegradesToEmptyThinking() throws {
        let future = #"{"thinking":"","thinkingSeal":{"kind":"encrypted_reasoning","value":"x"}}"#
        XCTAssertEqual(try JSONDecoder().decode(ContentPart.self, from: Data(future.utf8)), .thinking(""))
    }

    func testUnknownPartStillFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(ContentPart.self, from: Data(#"{"hologram":"x"}"#.utf8)))
    }

    func testExportLeavesSealsBehindButKeepsTheThinking() throws {
        let reply = ChatMessage(role: .assistant, parts: [
            .thinking("先列目录"), .thinkingSeal(.signature("sig-1", sealing: "先列目录")),
            .thinkingSeal(.redacted("opaque")), .text("答案"),
        ])
        var conversation = Conversation(messages: [ChatMessage(role: .user, parts: [.text("看看")]), reply])
        conversation.alternativeReplies = [reply]

        let exported = conversation.withoutThinkingSeals
        XCTAssertEqual(exported.messages[1].parts, [.thinking("先列目录"), .text("答案")])
        XCTAssertEqual(exported.alternativeReplies[0].parts, [.thinking("先列目录"), .text("答案")])
        let raw = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        XCTAssertFalse(raw.contains("sig-1"))
        XCTAssertFalse(raw.contains("opaque"))
    }
}

private struct ThinkingCannedTransport: HTTPTransport {
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
