import XCTest
@testable import OMPChatUI

/// Formatting works on the selection when there is one and on the caret
/// otherwise; the same key toggles the marker off again.
final class MarkdownFormattingTests: XCTestCase {
    private func toggle(_ style: MarkdownFormatting.Style, _ text: String, _ start: Int, _ length: Int) -> (String, NSRange) {
        let result = MarkdownFormatting.toggle(style, in: text, selection: NSRange(location: start, length: length))
        return (result.text, result.selection)
    }

    func testWrapsOnlyTheSelection() {
        // "hello world" with "world" selected
        let (text, selection) = toggle(.bold, "hello world", 6, 5)
        XCTAssertEqual(text, "hello **world**")
        XCTAssertEqual(selection, NSRange(location: 8, length: 5), "选中的字仍在选区内")
    }

    func testSecondPressUnwraps() {
        let (text, selection) = toggle(.italic, "前*中*后", 1, 3)
        XCTAssertEqual(text, "前中后")
        XCTAssertEqual(selection, NSRange(location: 1, length: 1))
    }

    func testUnwrapsMarkersJustOutsideTheSelection() {
        // "**x**" with only "x" selected → markers outside
        let (text, selection) = toggle(.bold, "**x**", 2, 1)
        XCTAssertEqual(text, "x")
        XCTAssertEqual(selection, NSRange(location: 0, length: 1))
    }

    func testCaretInsertsEmptyMarkersAndSitsBetween() {
        let (text, selection) = toggle(.bold, "ab", 1, 0)
        XCTAssertEqual(text, "a****b")
        XCTAssertEqual(selection, NSRange(location: 3, length: 0), "光标落在标记中间")
    }

    func testUnderlineUsesHTML() {
        let (text, _) = toggle(.underline, "x", 0, 1)
        XCTAssertEqual(text, "<u>x</u>")
    }

    func testItalicOnBoldKeepsTheBoldMarkers() {
        let (text, _) = toggle(.italic, "**x**", 0, 5)
        XCTAssertEqual(text, "***x***", "在已加粗的文字外再加斜体，不能吞掉加粗")
    }

    func testOutOfRangeSelectionIsClamped() {
        let (text, selection) = toggle(.bold, "abc", 99, 5)
        XCTAssertEqual(text, "abc****")
        XCTAssertEqual(selection, NSRange(location: 5, length: 0))
    }

    func testEmptyTextJustInsertsMarkers() {
        let (text, selection) = toggle(.italic, "", 0, 0)
        XCTAssertEqual(text, "**")
        XCTAssertEqual(selection, NSRange(location: 1, length: 0))
    }

    func testNoSelectionFormatsTheWholeDraft() {
        // The SwiftUI field reports no range; the pills then style everything.
        let result = MarkdownFormatting.toggle(.bold, in: "整段文字", selection: nil)
        XCTAssertEqual(result.text, "**整段文字**")
        let again = MarkdownFormatting.toggle(.bold, in: result.text, selection: nil)
        XCTAssertEqual(again.text, "整段文字", "再按一次回到原文")
    }

    func testPillKeysMapToStyles() {
        XCTAssertEqual(ComposerBar.style(for: "b"), .bold)
        XCTAssertEqual(ComposerBar.style(for: "I"), .italic, "大写也认")
        XCTAssertEqual(ComposerBar.style(for: "u"), .underline)
        XCTAssertNil(ComposerBar.style(for: "x"))
    }
}
