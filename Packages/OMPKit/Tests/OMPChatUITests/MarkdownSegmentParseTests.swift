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

    // MARK: Imported tool calls

    /// The scanner writes `〔调用工具 Name〕summary` lines; the transcript
    /// must turn them into collapsed rows, never body text.
    func testImportedToolCallParsing() {
        XCTAssertEqual(MarkdownText.Segment.importedToolCall("〔调用工具 Bash〕ls -la")?.name, "Bash")
        XCTAssertEqual(MarkdownText.Segment.importedToolCall("〔调用工具 Bash〕ls -la")?.detail, "ls -la")
        XCTAssertEqual(MarkdownText.Segment.importedToolCall("〔调用工具 Read〕/tmp/a.png")?.name, "Read")
        XCTAssertEqual(MarkdownText.Segment.importedToolCall("〔调用工具 Bash〕")?.detail, "")
        XCTAssertNil(MarkdownText.Segment.importedToolCall("普通段落〔调用工具 Bash〕x"), "只有整行以标记开头才算调用")
        XCTAssertNil(MarkdownText.Segment.importedToolCall("〔调用工具 〕x"))
        XCTAssertNil(MarkdownText.Segment.importedToolCall("〔调用工具 〕"), "空名字不算")
        XCTAssertTrue(MarkdownText.Segment.isImportedToolLine("〔调用工具 Bash〕ls -la"))
        XCTAssertFalse(MarkdownText.Segment.isImportedToolLine("文档里写着 〔调用工具 Bash〕 是一种标记。"))
        XCTAssertTrue(MarkdownText.Segment.isImportedToolLine("〔调用工具 Bash〕"), "只有标记没有摘要也是一次调用")
    }

    func testAnImportedToolCallLineBecomesARowSegment() throws {
        // The real shape: two full calls, then prose. A bare marker with no
        // summary is covered by testImportedToolCallParsing.
        let raw = "开工。\n〔调用工具 Bash〕cd /tmp && ls\n〔调用工具 Read〕屏幕截图 2026-08-10.png\n继续干活。"
        let kinds = try XCTUnwrap(parse(raw, limit: 10))
        XCTAssertEqual(kinds.count, 3)
        XCTAssertEqual(kinds[0], .text("开工。"))
        // Two adjacent calls fold into one group card.
        guard case .importedToolGroup(let rows) = kinds[1] else { return XCTFail("\(kinds[1])") }
        XCTAssertEqual(rows.map(\.name), ["Bash", "Read"])
        XCTAssertEqual(rows[0].detail, "cd /tmp && ls")
        XCTAssertEqual(rows[0].symbol, "terminal")
        XCTAssertEqual(rows[1].symbol, "doc.text")
        XCTAssertEqual(kinds[2], .text("继续干活。"))
    }

    func testBodyMentioningTheLabelStaysText() throws {
        let kinds = try XCTUnwrap(parse("文档里写着 〔调用工具 Bash〕 是一种标记。", limit: 10))
        XCTAssertEqual(kinds, [.text("文档里写着 〔调用工具 Bash〕 是一种标记。")], "正文引用标记不变成行")
    }

    func testLongCommandContinuationsFoldIntoTheRow() throws {
        // The scanner truncates long commands: the summary ends with a
        // truncation note and the next lines are shell/quote leftovers.
        let raw = "〔调用工具 Bash〕uname -sm; ls | head Check…\n" + "\"" + "Diff Something\"" + "\n"
            + "〔调用工具 Read〕/tmp/a.png\n正文总结。"
        let kinds = try XCTUnwrap(parse(raw, limit: 10))
        XCTAssertEqual(kinds.count, 2, "相邻调用并成一张卡，后续行并进各自折叠行")
        guard case .importedToolGroup(let rows) = kinds[0] else { return XCTFail("\(kinds[0])") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].detail.contains("Check…"), rows[0].detail)
        XCTAssertTrue(rows[0].detail.contains("Diff Something"), "截断命令的后半段在展开内容里")
        XCTAssertEqual(rows[1].name, "Read")
        XCTAssertEqual(kinds[1], .text("正文总结。"), "中文开头的正文不受影响")
    }

    func testProseIsNotFoldedIntoTheRow() throws {
        let raw = "〔调用工具 Read〕/tmp/a.png\n这是对结果的正常总结，不是命令的续行。"
        let kinds = try XCTUnwrap(parse(raw, limit: 10))
        XCTAssertEqual(kinds.count, 2)
        XCTAssertEqual(kinds[1], .text("这是对结果的正常总结，不是命令的续行。"))
    }

    func testCodeContinuationsFoldButTheNextCallDoesNot() throws {
        let raw = "〔调用工具 Bash〕mkdir -p w && cat > w/s.py <<'EOF'\nimport json\nprint(1)\nEOF\n〔调用工具 Bash〕ls w\n结论。"
        let kinds = try XCTUnwrap(parse(raw, limit: 10))
        XCTAssertEqual(kinds.count, 2, "heredoc 正文折进第一个调用；两个相邻调用并成一张卡；中文结论留正文")
        guard case .importedToolGroup(let rows) = kinds[0] else { return XCTFail("\(kinds[0])") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].detail.contains("import json") && rows[0].detail.contains("EOF"), rows[0].detail)
        XCTAssertEqual(rows[1].name, "Bash")
        XCTAssertEqual(kinds[1], .text("结论。"))
    }

    func testARunOfCallsWithBlankLinesFoldsIntoOneGroup() throws {
        // The real ms03 shape: marker, blank, marker, blank … then prose.
        let raw = "〔调用工具 Bash〕a\n\n〔调用工具 Bash〕b\n\n〔调用工具 Write〕/tmp/x\n\n结论正文。"
        let kinds = try XCTUnwrap(parse(raw, limit: 10))
        XCTAssertEqual(kinds.count, 2, "空行分隔的相邻调用也并成一张卡")
        guard case .importedToolGroup(let rows) = kinds[0] else { return XCTFail("\(kinds[0])") }
        XCTAssertEqual(rows.map(\.name), ["Bash", "Bash", "Write"])
        XCTAssertEqual(kinds[1], .text("结论正文。"))
    }
}
