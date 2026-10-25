import XCTest
@testable import OMPChatUI

/// ⌘B / ⌘I / ⌘U and the B / I / U pills write Markdown source into the draft.
final class ComposerFormatTests: XCTestCase {
    func testShortcutsMapToMarkup() {
        XCTAssertEqual(ComposerBar.markdownWrap(for: "b")?.open, "**")
        XCTAssertEqual(ComposerBar.markdownWrap(for: "I")?.open, "*", "大写也认")
        XCTAssertEqual(ComposerBar.markdownWrap(for: "u")?.open, "<u>", "下划线在 Markdown 里没有语法，用 HTML")
        XCTAssertNil(ComposerBar.markdownWrap(for: "x"))
    }

    func testWrappingToggles() {
        var text = "重点"
        XCTAssertTrue(ComposerBar.wrapSelection(&text, with: ("**", "**")))
        XCTAssertEqual(text, "**重点**")
        XCTAssertTrue(ComposerBar.wrapSelection(&text, with: ("**", "**")), "再按一次应取消")
        XCTAssertEqual(text, "重点")
    }

    func testEmptyDraftIsLeftAlone() {
        var text = ""
        XCTAssertFalse(ComposerBar.wrapSelection(&text, with: ("**", "**")), "空输入不该变成一对空标记")
        XCTAssertEqual(text, "")
    }

    func testAlreadyWrappedNestedLookalikeIsNotStrippedBlindly() {
        var text = "****"
        XCTAssertTrue(ComposerBar.wrapSelection(&text, with: ("**", "**")))
        let expected = ("**" + "****" + "**")
        XCTAssertEqual(text, expected, "刚好等于一对空标记时按包裹处理，不吞掉字符")
    }

    func testItalicOnBoldDoesNotStealTheBoldMarkers() {
        var text = "**重点**"
        XCTAssertTrue(ComposerBar.wrapSelection(&text, with: ("*", "*")))
        XCTAssertEqual(text, "***重点***", "已有加粗再加斜体应叠加，不能吞掉加粗的一侧星号")
        XCTAssertTrue(ComposerBar.wrapSelection(&text, with: ("*", "*")))
        XCTAssertEqual(text, "**重点**", "再按一次斜体应回到只有加粗")
    }
}
