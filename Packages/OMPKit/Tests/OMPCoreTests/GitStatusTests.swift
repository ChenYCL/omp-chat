import XCTest
@testable import OMPCore

/// The side panel's 改动 list is built from this; a wrong path means the row
/// shows escapes and its diff comes back empty.
final class GitStatusTests: XCTestCase {
    func testChineseAndSpacedNamesComeThroughVerbatim() {
        let entries = GitStatus.parse("?? 中文文件.txt\0 M with space.txt\0")
        XCTAssertEqual(entries, [
            .init(xy: "??", path: "中文文件.txt"),
            .init(xy: " M", path: "with space.txt"),
        ], "不能出现 \\344… 转义或多余的引号")
    }

    func testRenameKeepsSourceAsItsOwnField() {
        let entries = GitStatus.parse("R  新名字.md\0old name.md\0 D gone.txt\0")
        XCTAssertEqual(entries, [
            .init(xy: "R ", path: "新名字.md", originalPath: "old name.md"),
            .init(xy: " D", path: "gone.txt"),
        ], "改名的源路径是下一个字段，不能被当成一条新改动")
    }

    func testBothColumnsAreKept() {
        let entries = GitStatus.parse("MM a.swift\0A  b.swift\0 M c.swift\0")
        XCTAssertEqual(entries.map(\.code), ["MM", "A", "M"])
        XCTAssertEqual(entries.map(\.index), ["M", "A", " "], "暂存列")
        XCTAssertEqual(entries.map(\.worktree), ["M", " ", "M"], "工作区列：只改了工作区和只暂存了不能混成同一种")
    }

    func testEmptyOutputIsNoChanges() {
        XCTAssertEqual(GitStatus.parse(""), [])
    }
}
