import XCTest
@testable import OMPChatUI

/// The block parser runs on every render of every message. A line it
/// mis-classifies must still be consumed: the numbered-list branch once
/// re-read `...` or `3.14` forever, appending empty lists until the app had a
/// 28 GB footprint and the Mac was swapping.
final class MarkdownSegmentParseTests: XCTestCase {
    /// Parses off the main thread so a regression fails here after `limit`
    /// seconds instead of hanging the suite.
    private func parse(_ raw: String, limit: TimeInterval = 5) -> [MarkdownText.Segment.Kind]? {
        let done = expectation(description: "parse finishes")
        var result: [MarkdownText.Segment.Kind]?
        DispatchQueue.global().async {
            let kinds = MarkdownText.Segment.parse(raw).map(\.kind)
            DispatchQueue.main.async {
                result = kinds
                done.fulfill()
            }
        }
        wait(for: [done], timeout: limit)
        return result
    }

    func testLinesThatLookLikeListNumbersStayText() throws {
        for line in ["...", ".gitignore", "3.14 是圆周率", "1.", "1.2.3", "12.5% 的请求", "1.x"] {
            let kinds = try XCTUnwrap(parse(line), "「\(line)」没有解析完")
            XCTAssertEqual(kinds, [.text(line)], "「\(line)」不是列表项，应原样作为正文")
        }
    }

    func testAToolListingWithDotFilesParses() throws {
        let listing = "目录里有：\n.git\n.gitignore\nREADME.md\n..."
        XCTAssertEqual(try XCTUnwrap(parse(listing)), [.text(listing)])
    }

    func testNumberedListsStillParse() throws {
        let kinds = try XCTUnwrap(parse("步骤：\n1. 第一\n2. 第二\n10. 第十\n3.14 不是列表"))
        XCTAssertEqual(kinds, [
            .text("步骤："),
            .numberedList(["第一", "第二", "第十"]),
            .text("3.14 不是列表"),
        ], "列表在第一行不是列表项的地方结束，后面的照常是正文")
    }

    func testNumberedItemRule() {
        XCTAssertEqual(MarkdownText.Segment.numberedItem("1. 一"), "一")
        XCTAssertEqual(MarkdownText.Segment.numberedItem("42. "), "", "空的列表项也是列表项")
        XCTAssertNil(MarkdownText.Segment.numberedItem(". 无数字"), "点前面必须有数字")
        XCTAssertNil(MarkdownText.Segment.numberedItem("100. 三位数"), "最多两位，和原来一致")
        XCTAssertNil(MarkdownText.Segment.numberedItem("1.没有空格"))
        XCTAssertNil(MarkdownText.Segment.numberedItem("a. 字母"))
    }
}
