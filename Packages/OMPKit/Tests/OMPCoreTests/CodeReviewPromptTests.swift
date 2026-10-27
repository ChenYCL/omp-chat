import XCTest
@testable import OMPCore

/// 「用 Codex 审查」's request: what the reviewer gets to see, in what order,
/// and what it is told it did not get.
final class CodeReviewPromptTests: XCTestCase {
    private typealias Change = CodeReviewPrompt.FileChange

    private func material(
        staged: [Change] = [], unstaged: [Change] = [], untracked: [Change] = []
    ) -> CodeReviewPrompt.Material {
        CodeReviewPrompt.Material(
            subject: "main", directory: "/w/repo", staged: staged, unstaged: unstaged, untracked: untracked
        )
    }

    private func diff(_ path: String, _ body: String) -> Change {
        Change(path: path, text: "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1 +1 @@\n\(body)")
    }

    // MARK: Building

    func testRequestCarriesStagedThenUnstagedThenUntracked() throws {
        let request = try XCTUnwrap(CodeReviewPrompt.build(material(
            staged: [diff("a.swift", "-old\n+staged")],
            unstaged: [diff("b.swift", "-old\n+unstaged")],
            untracked: [Change(path: "notes/new.txt", text: "brand new\n")]
        )))
        let order = ["## 已暂存的改动", "### `a.swift`", "+staged", "## 未暂存的改动", "### `b.swift`", "+unstaged",
                     "## 未跟踪的文件", "### `notes/new.txt`", "brand new"]
        var cursor = request.startIndex
        for piece in order {
            let found = try XCTUnwrap(request.range(of: piece, range: cursor..<request.endIndex), "缺少或顺序不对：\(piece)")
            cursor = found.upperBound
        }
        XCTAssertTrue(request.contains("`/w/repo`（main）"))
        XCTAssertTrue(request.contains("文件:行号"))
        XCTAssertTrue(request.contains("严重程度"))
        XCTAssertTrue(request.contains("建议的修复"))
        XCTAssertTrue(request.contains("不要修改任何文件"))
        XCTAssertTrue(request.contains("没有发现问题"))
        XCTAssertTrue(request.contains("结论：可以提交"))
        XCTAssertFalse(request.contains("没有附上的文件"), "没有超出上限就不该有截断说明")
    }

    func testOnlyNonEmptySectionsAppear() throws {
        let request = try XCTUnwrap(CodeReviewPrompt.build(material(unstaged: [diff("b.swift", "+x")])))
        XCTAssertFalse(request.contains("## 已暂存的改动"))
        XCTAssertFalse(request.contains("## 未跟踪的文件"))
        XCTAssertTrue(request.contains("## 未暂存的改动"))
    }

    func testNothingToReviewBuildsNothing() {
        XCTAssertNil(CodeReviewPrompt.build(material()))
        XCTAssertTrue(material().isEmpty)
    }

    func testOverBudgetFilesAreLeftOutWholeAndListedInOrder() throws {
        let huge = String(repeating: "+huge line\n", count: 200)
        let request = try XCTUnwrap(CodeReviewPrompt.build(material(
            staged: [diff("small1.swift", "+one"), diff("big.json", huge)],
            unstaged: [diff("small2.swift", "+two")],
            untracked: [Change(path: "dump.log", text: huge), Change(path: "unread.bin", text: nil)]
        ), budget: 1024))

        XCTAssertTrue(request.contains("### `small1.swift`"))
        XCTAssertTrue(request.contains("### `small2.swift`"), "后面放得下的小文件照样放进来")
        XCTAssertFalse(request.contains("+huge line"), "放不下的文件整个不放，不截半截")
        XCTAssertFalse(request.contains("### `big.json`"))
        let note = try XCTUnwrap(request.range(of: "## 没有附上的文件")).upperBound
        let tail = String(request[note...])
        XCTAssertTrue(tail.contains("1 KB"))
        let listed = tail.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(listed, ["- 已暂存 `big.json`", "- 未跟踪 `dump.log`", "- 未跟踪 `unread.bin`"])
        XCTAssertLessThan(request.range(of: "### `small2.swift`")!.lowerBound, request.range(of: "## 没有附上的文件")!.lowerBound,
                          "截断说明在最后")
    }

    func testIncludedChangesStayWithinTheBudget() throws {
        let files = (0..<40).map { diff("f\($0).swift", String(repeating: "+line \($0)\n", count: 20)) }
        let budget = 4096
        let request = try XCTUnwrap(CodeReviewPrompt.build(material(staged: files), budget: budget))
        let start = try XCTUnwrap(request.range(of: "## 已暂存的改动")).lowerBound
        let end = try XCTUnwrap(request.range(of: "## 没有附上的文件")).lowerBound
        XCTAssertLessThanOrEqual(request[start..<end].utf8.count, budget + "\n## 已暂存的改动\n".utf8.count)
    }

    func testFenceIsLongerThanAnyBacktickRunInTheChange() throws {
        let request = try XCTUnwrap(CodeReviewPrompt.build(material(
            untracked: [Change(path: "README.md", text: "```swift\nlet a = 1\n```\n")]
        )))
        XCTAssertTrue(request.contains("````\n```swift\nlet a = 1\n```\n````"), request)
    }

    func testBinaryAndEmptyUntrackedFilesAreNamedNotDumped() throws {
        let request = try XCTUnwrap(CodeReviewPrompt.build(material(untracked: [
            Change(path: "logo.png", text: nil, isBinary: true),
            Change(path: "empty.txt", text: ""),
        ])))
        XCTAssertTrue(request.contains("### `logo.png`\n\n（二进制文件，内容未列出）"))
        XCTAssertTrue(request.contains("### `empty.txt`\n\n（空文件）"))
        XCTAssertFalse(request.contains("没有附上的文件"))
    }

    func testTitleNamesTheBranch() {
        XCTAssertEqual(CodeReviewPrompt.title(for: material()), "审查：main")
    }

    // MARK: Splitting git's diff

    func testSplitDiffFindsEachFileIncludingRenamesDeletionsAndSpaces() {
        let output = """
        diff --git a/a b.txt b/a b.txt
        index 1234567..89abcde 100644
        --- a/a b.txt
        +++ b/a b.txt
        @@ -1 +1 @@
        -x
        +y
        diff --git a/old.swift b/new.swift
        similarity index 90%
        rename from old.swift
        rename to new.swift
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 1234567..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/logo.png b/logo.png
        index 1234567..89abcde 100644
        Binary files a/logo.png and b/logo.png differ

        """
        let files = CodeReviewPrompt.splitDiff(output)
        XCTAssertEqual(files.map(\.path), ["a b.txt", "new.swift", "gone.txt", "logo.png"])
        XCTAssertEqual(files[0].text, "diff --git a/a b.txt b/a b.txt\nindex 1234567..89abcde 100644\n--- a/a b.txt\n+++ b/a b.txt\n@@ -1 +1 @@\n-x\n+y")
        XCTAssertEqual(files[3].text?.hasSuffix("differ"), true, "末尾的空行不算内容")
        XCTAssertTrue(CodeReviewPrompt.splitDiff("").isEmpty)
    }

    // MARK: Reading a real working tree

    private var root: URL!

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL) throws -> String {
        let git = try XCTUnwrap(GitBinary.resolve())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ text: String, _ path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `a.txt` staged and edited again, `b.txt` edited, `new.txt` and a
    /// binary untracked, `ignored.log` ignored.
    private func makeRepo() throws -> URL {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-review-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("工程 repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["config", "user.email", "a@b"], in: repo)
        try git(["config", "user.name", "a"], in: repo)
        try git(["config", "commit.gpgsign", "false"], in: repo)
        // A user's prefix settings must not change what is parsed.
        try git(["config", "diff.noprefix", "true"], in: repo)
        try write("1\n", "a.txt", in: repo)
        try write("1\n", "b.txt", in: repo)
        try write("*.log\n", ".gitignore", in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        try write("2\n", "a.txt", in: repo)
        try git(["add", "a.txt"], in: repo)
        try write("3\n", "a.txt", in: repo)
        try write("2\n", "b.txt", in: repo)
        try write("hello\n", "sub/new.txt", in: repo)
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: repo.appendingPathComponent("img.bin"))
        try write("noise\n", "ignored.log", in: repo)
        return repo
    }

    func testCollectReadsStagedUnstagedAndUntrackedFromARealRepository() throws {
        let repo = try makeRepo()
        let material = try CodeReviewPrompt.collect(in: repo.path)

        XCTAssertEqual(material.subject, "main")
        XCTAssertEqual(material.directory, repo.path)
        XCTAssertEqual(material.staged.map(\.path), ["a.txt"])
        XCTAssertEqual(material.unstaged.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(material.untracked.map(\.path), ["img.bin", "sub/new.txt"], "忽略的文件不在里面")
        XCTAssertTrue(material.staged[0].text?.contains("-1\n+2") == true)
        XCTAssertTrue(material.unstaged[0].text?.contains("-2\n+3") == true)
        XCTAssertTrue(material.unstaged[1].text?.contains("-1\n+2") == true)
        XCTAssertEqual(material.untracked[0].isBinary, true)
        XCTAssertEqual(material.untracked[1].text, "hello\n")

        let request = try XCTUnwrap(CodeReviewPrompt.build(material))
        XCTAssertTrue(request.contains("### `sub/new.txt`"))
        XCTAssertTrue(request.contains("### `img.bin`\n\n（二进制文件，内容未列出）"))
    }

    func testCollectDoesNotReadUntrackedFilesThatCannotFit() throws {
        let repo = try makeRepo()
        try write(String(repeating: "x", count: 10_000), "big.txt", in: repo)
        let material = try CodeReviewPrompt.collect(in: repo.path, budget: 4096)
        let big = try XCTUnwrap(material.untracked.first { $0.path == "big.txt" })
        XCTAssertNil(big.text)
        XCTAssertEqual(material.untracked.first { $0.path == "sub/new.txt" }?.text, "hello\n")
        let request = try XCTUnwrap(CodeReviewPrompt.build(material, budget: 4096))
        XCTAssertTrue(request.contains("- 未跟踪 `big.txt`"))
    }

    func testCleanTreeHasNothingToReview() throws {
        let repo = try makeRepo()
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "all"], in: repo)
        let material = try CodeReviewPrompt.collect(in: repo.path)
        XCTAssertTrue(material.isEmpty)
        XCTAssertNil(CodeReviewPrompt.build(material))
    }

    func testDetachedHeadIsNamedAfterTheDirectory() throws {
        let repo = try makeRepo()
        try git(["checkout", "-q", "--detach"], in: repo)
        XCTAssertEqual(try CodeReviewPrompt.collect(in: repo.path).subject, "工程 repo")
    }

    func testOutsideARepositoryFails() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CodeReviewPrompt.collect(in: root.path)) { error in
            XCTAssertEqual(error as? GitWorkingTree.Failure, .notARepository)
        }
    }

    // MARK: How the review ended

    private func review(_ messages: [ChatMessage]) -> Conversation {
        var conversation = Conversation(messages: messages)
        conversation.isCodeReview = true
        return conversation
    }

    func testOutcomeOfTheReviewReply() {
        let request = ChatMessage(role: .user, parts: [.text("请审查")])
        let report = ChatMessage(role: .assistant, parts: [.text("没有发现问题。\n结论：可以提交")], status: .complete)
        let toolsOnly = ChatMessage(role: .assistant, parts: [], status: .complete)
        let failed = ChatMessage(role: .assistant, parts: [.text("读到一半")], status: .failed)

        XCTAssertNil(CodeReviewPrompt.outcome(of: Conversation(messages: [request, report]), isStreaming: false),
                     "普通对话没有审查说明")
        XCTAssertEqual(CodeReviewPrompt.outcome(of: review([request]), isStreaming: true), .running)
        XCTAssertEqual(CodeReviewPrompt.outcome(of: review([request]), isStreaming: false), .unreported)
        XCTAssertEqual(CodeReviewPrompt.outcome(of: review([request, toolsOnly, report]), isStreaming: false), .reported)
        XCTAssertEqual(CodeReviewPrompt.outcome(of: review([request, report, toolsOnly]), isStreaming: false), .unreported,
                       "看的是最后一条助手消息")
        XCTAssertEqual(CodeReviewPrompt.outcome(of: review([request, failed]), isStreaming: false), .unreported)
    }

    func testOnlyTheReplyToTheRequestCounts() {
        let request = ChatMessage(role: .user, parts: [.text("请审查")])
        let report = ChatMessage(role: .assistant, parts: [.text("结论：需要修改")], status: .complete)
        let followUp = ChatMessage(role: .user, parts: [.text("第二条怎么修？")])
        let failed = ChatMessage(role: .assistant, parts: [], status: .failed)

        XCTAssertEqual(CodeReviewPrompt.outcome(of: review([request, report, followUp]), isStreaming: true), .reported,
                       "追问在跑不影响审查报告")
        XCTAssertEqual(CodeReviewPrompt.outcome(of: review([request, failed, followUp, report]), isStreaming: false), .unreported)
    }
}
