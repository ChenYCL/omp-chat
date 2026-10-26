import XCTest
@testable import OMPCore

/// 新建 Worktree is the one fork mode that touches the file system; its name and
/// arguments are decided here so they can be checked without a repository.
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

    func testPlanCreatesSiblingDirectoryAndBranch() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let plan = WorktreeFork.plan(title: "Fork me", id: id, repository: "/Users/x/code/app")
        XCTAssertEqual(plan.path, "/Users/x/code/fork-me-aaaaaaaa", "新目录放在仓库旁边，而不是里面")
        XCTAssertEqual(plan.arguments, ["worktree", "add", "-b", "fork-me-aaaaaaaa", "/Users/x/code/fork-me-aaaaaaaa"])
    }

    func testPlanHonoursChosenBaseDirectory() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let plan = WorktreeFork.plan(
            title: "Fork me",
            id: id,
            repository: "/Users/x/code/app",
            baseDirectory: "/tmp/worktrees/"
        )
        XCTAssertEqual(plan.path, "/tmp/worktrees/fork-me-aaaaaaaa", "指定目录优先于仓库旁边")
        XCTAssertEqual(plan.arguments.last, "/tmp/worktrees/fork-me-aaaaaaaa")
    }

    func testBlankBaseDirectoryStaysBesideTheRepository() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let plan = WorktreeFork.plan(
            title: "Fork me",
            id: id,
            repository: "/Users/x/code/app",
            baseDirectory: "   "
        )
        XCTAssertEqual(plan.path, "/Users/x/code/fork-me-aaaaaaaa", "空白等于仓库旁边")
    }

    func testBranchPrefixIsSanitised() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let plan = WorktreeFork.plan(
            title: "Fork me",
            id: id,
            repository: "/repo/app",
            branchPrefix: "  OMP Feature! "
        )
        XCTAssertEqual(
            plan.arguments,
            ["worktree", "add", "-b", "omp-feature-fork-me-aaaaaaaa", "/repo/fork-me-aaaaaaaa"],
            "前缀只保留字母数字，目录名不加前缀"
        )
        let bare = WorktreeFork.plan(title: "Fork me", id: id, repository: "/repo/app", branchPrefix: "---")
        XCTAssertEqual(bare.arguments[3], "fork-me-aaaaaaaa", "清洗后为空等于不加前缀")
    }

    func testGitBinaryPrefersHomebrew() throws {
        guard let git = GitBinary.resolve() else {
            throw XCTSkip("no git on this machine")
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: git))
        XCTAssertEqual(GitBinary.candidates.first, "/opt/homebrew/bin/git", "先试 Homebrew，/usr/bin/git 要走 xcrun")
    }
}
