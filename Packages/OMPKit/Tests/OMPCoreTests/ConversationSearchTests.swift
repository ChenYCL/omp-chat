import XCTest
@testable import OMPCore

/// One rule for "does this chat match what I typed", shared by every search box.
final class ConversationSearchTests: XCTestCase {
    private func conversation(_ title: String, last: String = "") -> Conversation {
        var c = Conversation(title: title)
        c.messages = [ChatMessage(role: .assistant, parts: [.text(last)])]
        return c
    }

    func testMatchesTitleCaseInsensitively() {
        XCTAssertTrue(ConversationSearch.matches(conversation("Mermaid 图表"), query: "mermaid"))
    }

    func testMatchesLastMessagePreview() {
        XCTAssertTrue(ConversationSearch.matches(conversation("无关标题", last: "讨论 SSE 流式"), query: "sse"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(ConversationSearch.matches(conversation("x"), query: "   "), "空查询不过滤")
        let all = [conversation("a"), conversation("b")]
        XCTAssertEqual(ConversationSearch.filter(all, query: "").count, 2)
    }

    func testNoMatchIsFilteredOut() {
        let all = [conversation("alpha"), conversation("beta")]
        XCTAssertEqual(ConversationSearch.filter(all, query: "gamma").count, 0)
        XCTAssertEqual(ConversationSearch.filter(all, query: "alp").map(\.title), ["alpha"])
    }

    func testSurroundingWhitespaceInTheQueryIsIgnored() {
        XCTAssertTrue(ConversationSearch.matches(conversation("alpha"), query: "  alpha  "))
    }
}
