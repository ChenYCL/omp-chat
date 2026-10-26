import XCTest
@testable import OMPCore

/// The side panel's 改动 list is built from this; a wrong path means the row
/// shows escapes and its diff comes back empty.
final class GitStatusTests: XCTestCase {
    func testChineseAndSpacedNamesComeThroughVerbatim() {
        let entries = GitStatus.parse("?? 中文文件.txt\0 M with space.txt\0")
        XCTAssertEqual(entries, [
            .init(code: "??", path: "中文文件.txt"),
            .init(code: "M", path: "with space.txt"),
        ], "不能出现 \\344… 转义或多余的引号")
    }

    func testRenameKeepsSourceAsItsOwnField() {
        let entries = GitStatus.parse("R  新名字.md\0old name.md\0 D gone.txt\0")
        XCTAssertEqual(entries, [
            .init(code: "R", path: "新名字.md", originalPath: "old name.md"),
            .init(code: "D", path: "gone.txt"),
        ], "改名的源路径是下一个字段，不能被当成一条新改动")
    }

    func testBothColumnsAreKept() {
        XCTAssertEqual(GitStatus.parse("MM a.swift\0A  b.swift\0"), [
            .init(code: "MM", path: "a.swift"),
            .init(code: "A", path: "b.swift"),
        ])
    }

    func testEmptyOutputIsNoChanges() {
        XCTAssertEqual(GitStatus.parse(""), [])
    }

    func testTheArgumentsAskForTheNulForm() {
        // Without -z the parser would be handed quoted, newline-separated text.
        XCTAssertEqual(GitStatus.arguments, ["status", "--porcelain", "-z"])
    }
}
