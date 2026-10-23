import XCTest
@testable import OMPCore

final class SSEParserTests: XCTestCase {
    func testSingleEvent() {
        var parser = SSEParser()
        let events = parser.consume(Data("data: {\"a\":1}\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "{\"a\":1}")
    }

    func testMultipleEventsAndDone() {
        var parser = SSEParser()
        let events = parser.consume(Data("data: one\n\ndata: [DONE]\n\n".utf8))
        XCTAssertEqual(events.map(\.data), ["one", "[DONE]"])
    }

    func testCRLFAndSplitChunks() {
        var parser = SSEParser()
        XCTAssertTrue(parser.consume(Data("event: delta\r".utf8)).isEmpty)
        XCTAssertTrue(parser.consume(Data("\ndata: hel".utf8)).isEmpty)
        let events = parser.consume(Data("lo\r\n\r\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, "delta")
        XCTAssertEqual(events.first?.data, "hello")
    }

    func testMultiLineDataJoinedWithNewline() {
        var parser = SSEParser()
        let events = parser.consume(Data("data: line1\ndata: line2\n\n".utf8))
        XCTAssertEqual(events.first?.data, "line1\nline2")
    }

    func testCommentsIgnored() {
        var parser = SSEParser()
        let events = parser.consume(Data(": keep-alive\n\ndata: x\n\n".utf8))
        XCTAssertEqual(events.map(\.data), ["x"])
    }

    func testFinishFlushesTrailingEvent() {
        var parser = SSEParser()
        _ = parser.consume(Data("data: tail".utf8))
        let event = parser.finish()
        XCTAssertEqual(event?.data, "tail")
    }
}
