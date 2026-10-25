import XCTest
import SwiftUI
@testable import OMPChatUI

/// In-chat search marks the visible characters, leaving the Markdown syntax
/// (bold markers, code ticks) parsed rather than tinted.
final class SearchHighlightTests: XCTestCase {
    private func highlighted(_ text: String, query: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        MarkdownText.applyHighlight(query, to: &attributed)
        return attributed
    }

    private func highlightedRuns(_ attributed: AttributedString) -> [String] {
        attributed.runs.compactMap { run in
            run.backgroundColor == nil ? nil : String(attributed[run.range].characters)
        }
    }

    func testMarksEveryOccurrenceCaseInsensitively() {
        let attributed = highlighted("Mermaid 和 mermaid 都算", query: "mermaid")
        XCTAssertEqual(highlightedRuns(attributed), ["Mermaid", "mermaid"], "大小写都要标出来，且两处都标")
    }

    func testLeavesMarkdownMarkersUnmarked() {
        let attributed = highlighted("这是 **重点** 内容", query: "重点")
        XCTAssertEqual(highlightedRuns(attributed), ["重点"], "只标可见文字，不把星号算进去")
        let plain = String(attributed.characters)
        XCTAssertFalse(plain.contains("**"), "渲染后不应出现 Markdown 记号")
    }

    func testNoQueryMarksNothing() {
        let attributed = highlighted("没有任何匹配", query: "")
        XCTAssertTrue(highlightedRuns(attributed).isEmpty)
    }

    func testQueryWithRegexCharactersIsLiteral() {
        let attributed = highlighted("a.b 与 axb", query: "a.b")
        XCTAssertEqual(highlightedRuns(attributed), ["a.b"], "点号按字面匹配，不能当成通配符")
    }
}
