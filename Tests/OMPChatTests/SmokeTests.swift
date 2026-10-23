import XCTest
@testable import OMPCore

final class SmokeTests: XCTestCase {
    func testSSEParserSplitsEvents() {
        var parser = SSEParser()
        let payload = Data("data: {\"a\":1}\n\ndata: [DONE]\n\n".utf8)
        let events = parser.consume(payload)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.data, "{\"a\":1}")
        XCTAssertEqual(events.last?.data, "[DONE]")
    }

    func testSSEParserHandlesCRLFAndChunkBoundaries() {
        var parser = SSEParser()
        XCTAssertTrue(parser.consume(Data("event: delta\r".utf8)).isEmpty)
        XCTAssertTrue(parser.consume(Data("\ndata: hel".utf8)).isEmpty)
        let events = parser.consume(Data("lo\r\n\r\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, "delta")
        XCTAssertEqual(events.first?.data, "hello")
    }

    func testConversationPreviewFallsBack() {
        let conversation = Conversation()
        XCTAssertEqual(conversation.lastMessagePreview, "开始新的对话")
    }
}
