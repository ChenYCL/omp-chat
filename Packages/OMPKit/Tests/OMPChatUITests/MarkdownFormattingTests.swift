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

    func testSearchCursorWrapsBothWays() {
        XCTAssertEqual(SearchCursor.step(from: nil, by: 1, count: 3), 0, "还没跳过时，下一处是第一处")
        XCTAssertEqual(SearchCursor.step(from: nil, by: -1, count: 3), 2, "上一处从最后一处开始")
        XCTAssertEqual(SearchCursor.step(from: 2, by: 1, count: 3), 0, "走到末尾回到开头")
        XCTAssertEqual(SearchCursor.step(from: 0, by: -1, count: 3), 2, "开头往前回到末尾")
        XCTAssertNil(SearchCursor.step(from: nil, by: 1, count: 0), "没有匹配就没有下一处")
    }

    // MARK: - Block styles

    func testHeadingSetsAndReplacesLevel() {
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(2), to: "第一段"), "## 第一段")
        // An existing level is replaced, not stacked.
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(1), to: "### 已有标题"), "# 已有标题")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(3), to: "# 标题\n第二行"), "### 标题\n第二行")
    }

    func testSameHeadingLevelRemovesIt() {
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(2), to: "## 标题"), "标题")
        // Only the level being pressed toggles off.
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(1), to: "## 标题"), "# 标题")
    }

    func testParagraphRemovesHeadingAndListMarkers() {
        XCTAssertEqual(MarkdownFormatting.applyBlock(.paragraph, to: "### 标题"), "标题")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.paragraph, to: "- 甲\n- 乙"), "甲\n乙")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.paragraph, to: "1. 甲\n2. 乙"), "甲\n乙")
        // Plain text is left alone.
        XCTAssertEqual(MarkdownFormatting.applyBlock(.paragraph, to: "普通段落"), "普通段落")
    }

    func testBulletedListToggles() {
        XCTAssertEqual(MarkdownFormatting.applyBlock(.bulletedList, to: "甲\n乙"), "- 甲\n- 乙")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.bulletedList, to: "- 甲\n- 乙"), "甲\n乙", "已是无序列表时再按一次取消")
        // A numbered list is not a bulleted one, so it becomes bulleted.
        XCTAssertEqual(MarkdownFormatting.applyBlock(.bulletedList, to: "1. 甲\n2. 乙"), "- 甲\n- 乙")
    }

    func testNumberedListTogglesAndRenumbers() {
        XCTAssertEqual(MarkdownFormatting.applyBlock(.numberedList, to: "甲\n乙\n丙"), "1. 甲\n2. 乙\n3. 丙")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.numberedList, to: "1. 甲\n2. 乙"), "甲\n乙", "已编号时再按一次取消")
        // A bulleted list becomes numbered, not stacked.
        XCTAssertEqual(MarkdownFormatting.applyBlock(.numberedList, to: "- 甲\n- 乙"), "1. 甲\n2. 乙")
    }

    func testOnlyTheLastParagraphChanges() {
        let text = "第一段\n\n第二段"
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(1), to: text), "第一段\n\n# 第二段")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.bulletedList, to: text), "第一段\n\n- 第二段")
        // Trailing blank lines are not a new paragraph.
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(2), to: "甲\n\n乙\n"), "甲\n\n## 乙\n")
    }

    func testEmptyDraftBlockStyles() {
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(1), to: ""), "# ")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(2), to: "   "), "## ")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.paragraph, to: ""), "")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.bulletedList, to: ""), "- ")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.numberedList, to: ""), "1. ")
    }

    func testLinkWrapsTheWholeDraft() {
        XCTAssertEqual(MarkdownFormatting.applyBlock(.link, to: "说明文字"), "[说明文字](https://)")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.link, to: "第一段\n\n第二段"), "[第一段\n\n第二段](https://)")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.link, to: ""), "[链接文字](https://)")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.link, to: "  \n"), "[链接文字](https://)")
    }

    func testBlockStylesLeaveInlineFormattingAlone() {
        XCTAssertEqual(MarkdownFormatting.toggle(.bold, in: "整段文字", selection: nil).text, "**整段文字**")
        XCTAssertEqual(MarkdownFormatting.applyBlock(.heading(1), to: "**整段文字**"), "# **整段文字**")
    }
}
