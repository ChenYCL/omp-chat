import XCTest
import OMPCore
@testable import OMPChatUI

final class MentionIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-mention-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relative: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(GitBinary.resolve()))
        process.arguments = ["-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    // MARK: Walk

    func testTheWalkSkipsGitNodeModulesBuildOutputAndHiddenFolders() throws {
        for path in ["a.txt", ".env", "src/b.swift", ".git/config", "node_modules/x/index.js", "build/out.o",
                     "DerivedData/x.o", ".hidden/secret.txt", "deep/1/2/f.txt"] {
            try touch(path)
        }
        let listing = try MentionIndex.walk(root.path, limits: .init())
        XCTAssertEqual(Set(listing.files), [".env", "a.txt", "src/b.swift", "deep/1/2/f.txt"])
        XCTAssertTrue(listing.isComplete)
        XCTAssertFalse(listing.fromGit)
    }

    func testTheWalkStopsAtItsDepthAndEntryLimits() throws {
        for path in [".env", "a.txt", "deep/1/x.txt", "deep/1/2/f.txt"] { try touch(path) }

        let shallow = try MentionIndex.walk(root.path, limits: .init(maxDepth: 2))
        XCTAssertEqual(Set(shallow.files), [".env", "a.txt", "deep/1/x.txt"], "两层以下不再列")
        XCTAssertFalse(shallow.isComplete)

        // Sorted, the first two entries are `.env` and `a.txt`.
        let few = try MentionIndex.walk(root.path, limits: .init(maxEntries: 2))
        XCTAssertEqual(few.files, [".env", "a.txt"])
        XCTAssertFalse(few.isComplete)
    }

    func testAMissingFolderCannotBeSearched() async {
        let index = MentionIndex()
        do {
            _ = try await index.search(root.appendingPathComponent("gone").path, query: "a", limit: 5)
            XCTFail("不存在的目录应当报错")
        } catch {
            XCTAssertEqual(error as? MentionIndex.Failure, .unreadable)
        }
    }

    // MARK: Git

    func testAGitCheckoutListsWhatGitKeepsSoGitignoreHolds() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("这台机器没有 git") }
        try git(["init", "-q"])
        try touch(".gitignore", "secret.txt\nlogs/\n")
        for path in ["notes.md", "src/a.swift", "secret.txt", "logs/today.log", "gone.md", "node_modules/pkg/index.js"] {
            try touch(path)
        }
        try git(["add", "src/a.swift", "gone.md", "node_modules/pkg/index.js"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.md"))

        let listing = try MentionIndex.list(root.path, limits: .init())
        XCTAssertTrue(listing.fromGit)
        XCTAssertEqual(Set(listing.files), [".gitignore", "notes.md", "src/a.swift"],
                       "忽略的文件、已删除的跟踪文件和 node_modules 都不列")

        let capped = try MentionIndex.list(root.path, limits: .init(maxEntries: 1))
        XCTAssertTrue(capped.fromGit)
        XCTAssertFalse(capped.isComplete)
        XCTAssertLessThanOrEqual(capped.files.count, 1)
    }

    func testASubfolderOfACheckoutListsItsOwnFilesRelativeToIt() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("这台机器没有 git") }
        try git(["init", "-q"])
        try touch("top.md")
        try touch("app/main.swift")
        try touch("app/.gitignore", "*.tmp\n")
        try touch("app/scratch.tmp")
        let listing = try MentionIndex.list(root.appendingPathComponent("app").path, limits: .init())
        XCTAssertTrue(listing.fromGit)
        XCTAssertEqual(Set(listing.files), [".gitignore", "main.swift"])
    }

    // MARK: Cache

    func testAListingIsCachedUntilRefreshed() async throws {
        try touch("a.txt")
        let index = MentionIndex()
        let first = try await index.files(in: root.path)
        XCTAssertEqual(first.files, ["a.txt"])
        try touch("b.txt")
        let cached = try await index.files(in: root.path)
        XCTAssertEqual(cached.files, ["a.txt"], "刷新前用缓存，不重新遍历")
        let refreshed = try await index.refresh(root.path)
        XCTAssertEqual(refreshed.files, ["a.txt", "b.txt"])
        let hits = try await index.search(root.path, query: "b", limit: 5)
        XCTAssertEqual(hits, ["b.txt"])
    }

    // MARK: Ranking

    func testRankingPrefersTheNamePrefixThenTheNameThenThePathThenScatteredLetters() {
        let files = ["src/main.swift", "r/e/a/d/m/e.txt", "readme/guide.md", "src/old-readme.txt", "docs/readme.md", "README"]
        XCTAssertEqual(MentionIndex.rank(files, query: "ReadMe", limit: 10), [
            "README", "docs/readme.md", "src/old-readme.txt", "readme/guide.md", "r/e/a/d/m/e.txt",
        ])
        XCTAssertEqual(MentionIndex.rank(files, query: "readme", limit: 2), ["README", "docs/readme.md"])
        XCTAssertEqual(MentionIndex.rank(files, query: "  ", limit: 10), [], "空查询不列文件")
    }

    func testSkillsRankByNameThenDescription() throws {
        func skill(_ name: String, _ description: String) throws -> Skill {
            try touch("skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: \(description)\n---\n正文")
            return try SkillCatalog.parse(path: root.appendingPathComponent("skills/\(name)/SKILL.md").path, scope: .repository)
        }
        let skills = [try skill("lint", "检查 review 意见"), try skill("code-review", "审查"), try skill("review", "审查改动"), try skill("deploy", "发布")]
        XCTAssertEqual(MentionIndex.rankSkills(skills, query: "Review").map(\.name), ["review", "code-review", "lint"])
        XCTAssertEqual(MentionIndex.rankSkills(skills, query: "").map(\.name), ["lint", "code-review", "review", "deploy"])
        XCTAssertEqual(skills[2].mentionSourceLabel, "项目")
    }
}
