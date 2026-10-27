import XCTest
@testable import OMPCore

/// Managed worktree directory names are decided here so they can be checked
/// without a repository.
final class WorktreeForkTests: XCTestCase {
    func testSlugIsSafeAndDeterministic() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(WorktreeFork.slug(title: "Fix the SSE parser!", id: id), "fix-the-sse-parser-aaaaaaaa")
        XCTAssertEqual(WorktreeFork.slug(title: "  ", id: id), "thread-aaaaaaaa", "空标题也要有可用名字")
        XCTAssertEqual(WorktreeFork.slug(title: "中文标题", id: id), "中文标题-aaaaaaaa", "中文保留")
    }

    func testLongTitlesAreTruncated() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let slug = WorktreeFork.slug(title: String(repeating: "a", count: 100), id: id)
        XCTAssertLessThanOrEqual(slug.count, 49, "名字不能无限长")
    }

    func testSlugHasNoPathSeparators() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let slug = WorktreeFork.slug(title: "a/b\\c:d", id: id)
        XCTAssertFalse(slug.contains("/"), "slug 不能含路径分隔符")
        XCTAssertFalse(slug.contains("\\"))
        XCTAssertEqual(slug, "a-b-c-d-aaaaaaaa")
    }
}
