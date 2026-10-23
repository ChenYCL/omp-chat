import XCTest
@testable import OMPCore

final class RequestBuilderTests: XCTestCase {
    private func imageRef() -> MediaRef {
        MediaRef(kind: .image, relativePath: "shot.png", mimeType: "image/png", originalName: "shot.png")
    }

    func testOpenAIInlinesImagesAsDataURLs() throws {
        let ref = imageRef()
        let message = ChatMessage(role: .user, parts: [.text("这是什么"), .media(ref)])
        let request = GenerationRequest(modelID: "m1", messages: [message], systemPrompt: "be brief")
        let body = OpenAIRequestBuilder.build(
            request,
            media: [ref.id: MediaPayload(mimeType: "image/png", base64: "QUJD")]
        )
        let json = try Self.jsonObject(from: body)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")

        let user = try XCTUnwrap(messages.last)
        XCTAssertEqual(user["role"] as? String, "user")
        let content = try XCTUnwrap(user["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "这是什么")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(content[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,QUJD")
    }

    func testOpenAINotesUnresolvedAttachments() throws {
        let ref = MediaRef(kind: .file, relativePath: "spec.pdf", mimeType: "application/pdf", originalName: "spec.pdf")
        let message = ChatMessage(role: .user, parts: [.media(ref)])
        let body = OpenAIRequestBuilder.build(GenerationRequest(modelID: "m1", messages: [message]))
        let json = try Self.jsonObject(from: body)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "[附件] spec.pdf")
    }

    func testAnthropicEncodesBase64ImageBlocks() throws {
        let ref = imageRef()
        let message = ChatMessage(role: .user, parts: [.text("画了什么"), .media(ref)])
        let request = GenerationRequest(modelID: "claude", messages: [message], maxOutputTokens: 1024)
        let body = AnthropicRequestBuilder.build(
            request,
            media: [ref.id: MediaPayload(mimeType: "image/png", base64: "QUJD")]
        )
        let json = try Self.jsonObject(from: body)
        XCTAssertEqual(json["max_tokens"] as? Int, 1024)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["type"] as? String, "image")
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "QUJD")
        XCTAssertEqual(source["type"] as? String, "base64")
    }

    func testAnthropicToolSpecUsesInputSchema() throws {
        let spec = ToolSpec(name: "search", description: "web", parametersJSON: #"{"type":"object","properties":{}}"#)
        let request = GenerationRequest(modelID: "claude", messages: [], tools: [spec])
        let body = AnthropicRequestBuilder.build(request)
        let json = try Self.jsonObject(from: body)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "search")
        XCTAssertNotNil(tools.first?["input_schema"])
    }

    private static func jsonObject<T: Encodable>(from value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}

final class StreamAssemblyTests: XCTestCase {
    func testToolCallDeltasAccumulateByIndex() {
        var message = ChatMessage(role: .assistant, parts: [])
        message.apply(.toolCallDelta(index: 0, id: "call_a", name: "search", argumentsDelta: "{\"q\":"))
        message.apply(.toolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "\"swift\"}"))
        message.apply(.toolCallDelta(index: 1, id: "call_b", name: "fetch", argumentsDelta: "{\"url\":"))

        let calls = message.parts.compactMap { part -> ToolCall? in
            if case .toolCall(let call) = part { call } else { nil }
        }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].id, "call_a")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"q\":\"swift\"}")
        XCTAssertEqual(calls[1].name, "fetch")
        XCTAssertEqual(calls[1].argumentsJSON, "{\"url\":")
    }

    func testTextAndThinkingInterleave() {
        var message = ChatMessage(role: .assistant, parts: [], status: .streaming)
        message.apply(.thinkingDelta("想一想"))
        message.apply(.textDelta("答案"))
        message.apply(.usage(TokenUsage(inputTokens: 3, outputTokens: 2)))
        XCTAssertEqual(message.thinkingText, "想一想")
        XCTAssertEqual(message.concatenatedText, "答案")
        XCTAssertEqual(message.usage?.totalTokens, 5)
    }
}
