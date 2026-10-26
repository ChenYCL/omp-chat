import XCTest
@testable import OMPCore

/// The 改动 tab's stage / commit / push, run against real temporary
/// repositories: a wrong split hides a change from the user, a wrong unstage
/// or discard loses their work.
final class GitWorkingTreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Fixtures

    @discardableResult
    private func git(_ args: [String], in directory: URL) throws -> String {
        let git = try XCTUnwrap(GitBinary.resolve())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-c", "core.quotePath=false"] + args
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

    /// A repository with an identity of its own, so commits never depend on
    /// (or get signed by) the machine's global config.
    private func makeRepo(_ name: String = "repo", commit files: [String: String] = [:]) throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["config", "user.email", "a@b"], in: repo)
        try git(["config", "user.name", "a"], in: repo)
        try git(["config", "commit.gpgsign", "false"], in: repo)
        if !files.isEmpty {
            for (path, text) in files { try write(text, path, in: repo) }
            try git(["add", "-A"], in: repo)
            try git(["commit", "-q", "-m", "init"], in: repo)
        }
        return repo
    }

    private func write(_ text: String, _ path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in repo: URL) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    private func head(_ repo: URL) throws -> String {
        try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func codes(_ changes: [GitWorkingTree.Change]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0.code) })
    }

    // MARK: Status

    func testSplitsStagedAndUnstagedByColumn() throws {
        let repo = try makeRepo(commit: ["both.txt": "1\n", "staged.txt": "1\n", "worktree.txt": "1\n", "gone.txt": "1\n"])
        try write("1\n2\n", "both.txt", in: repo)
        try git(["add", "both.txt"], in: repo)
        try write("1\n2\n3\n", "both.txt", in: repo)
        try write("1\nstaged\n", "staged.txt", in: repo)
        try git(["add", "staged.txt"], in: repo)
        try write("1\nworktree\n", "worktree.txt", in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        try write("new\n", "新目录/new.txt", in: repo)

        let status = try GitWorkingTree.status(in: repo.path)

        XCTAssertEqual(codes(status.staged), ["both.txt": "M", "staged.txt": "M"],
                       "只改了工作区的文件不能出现在已暂存里")
        XCTAssertEqual(codes(status.unstaged), [
            "both.txt": "M", "worktree.txt": "M", "gone.txt": "D", "新目录/new.txt": "??",
        ], "MM 两组都有；未跟踪算未暂存，新目录里的文件逐个列出")
        XCTAssertTrue(status.staged.allSatisfy(\.staged))
        XCTAssertFalse(status.unstaged.contains(where: \.staged))
    }

    func testStatusFromASubdirectoryUsesRepositoryRootPaths() throws {
        let repo = try makeRepo(commit: ["Sources/a.swift": "a\n", "README.md": "r\n"])
        try write("b\n", "Sources/a.swift", in: repo)
        try write("changed\n", "README.md", in: repo)
        let nested = repo.appendingPathComponent("Sources").path

        let status = try GitWorkingTree.status(in: nested)
        XCTAssertEqual(Set(status.unstaged.map(\.path)), ["Sources/a.swift", "README.md"],
                       "线程绑在子目录时，整个仓库的改动都要看到，路径相对仓库根")

        try GitWorkingTree.stage(["README.md"], in: nested)
        XCTAssertEqual(try GitWorkingTree.status(in: nested).staged.map(\.path), ["README.md"],
                       "在子目录里暂存仓库根的路径")
    }

    func testOutsideARepositoryIsReportedAsSuch() throws {
        XCTAssertThrowsError(try GitWorkingTree.status(in: root.path)) { error in
            XCTAssertEqual(error as? GitWorkingTree.Failure, .notARepository)
        }
    }

    // MARK: Staging

    func testStageAndUnstageRoundTrip() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        try write("2\n", "a.txt", in: repo)
        try write("n\n", "n.txt", in: repo)

        try GitWorkingTree.stage(["a.txt", "n.txt"], in: repo.path)
        var status = try GitWorkingTree.status(in: repo.path)
        XCTAssertEqual(codes(status.staged), ["a.txt": "M", "n.txt": "A"])
        XCTAssertTrue(status.unstaged.isEmpty)

        try GitWorkingTree.unstage(["a.txt", "n.txt"], in: repo.path)
        status = try GitWorkingTree.status(in: repo.path)
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(codes(status.unstaged), ["a.txt": "M", "n.txt": "??"])
        XCTAssertEqual(try read("a.txt", in: repo), "2\n", "取消暂存不能动工作区")

        try GitWorkingTree.stageAll(in: repo.path)
        XCTAssertEqual(try GitWorkingTree.status(in: repo.path).staged.count, 2)
        try GitWorkingTree.unstageAll(in: repo.path)
        status = try GitWorkingTree.status(in: repo.path)
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(status.unstaged.count, 2)
    }

    func testStagingADeletedFileStagesTheDeletion() throws {
        let repo = try makeRepo(commit: ["gone.txt": "1\n"])
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        try GitWorkingTree.stage(["gone.txt"], in: repo.path)
        XCTAssertEqual(codes(try GitWorkingTree.status(in: repo.path).staged), ["gone.txt": "D"])
    }

    func testUnstageWorksBeforeTheFirstCommit() throws {
        let repo = try makeRepo()
        try write("1\n", "a.txt", in: repo)
        try write("1\n", "b.txt", in: repo)
        try GitWorkingTree.stage(["a.txt", "b.txt"], in: repo.path)
        // Staged, then edited again: the index copy matches neither HEAD
        // (there is none) nor the file.
        try write("1\n2\n", "a.txt", in: repo)

        try GitWorkingTree.unstage(["a.txt"], in: repo.path)

        let status = try GitWorkingTree.status(in: repo.path)
        XCTAssertEqual(codes(status.staged), ["b.txt": "A"], "只取消暂存选中的那个")
        XCTAssertEqual(codes(status.unstaged), ["a.txt": "??"])
        XCTAssertEqual(try read("a.txt", in: repo), "1\n2\n", "文件内容保留")

        try GitWorkingTree.unstageAll(in: repo.path)
        XCTAssertTrue(try GitWorkingTree.status(in: repo.path).staged.isEmpty)
    }

    func testNamesWithPatternCharactersAreTakenLiterally() throws {
        let repo = try makeRepo(commit: ["a*.txt": "1\n", "ab.txt": "1\n"])
        try write("2\n", "a*.txt", in: repo)
        try write("2\n", "ab.txt", in: repo)
        try GitWorkingTree.stage(["a*.txt"], in: repo.path)
        let status = try GitWorkingTree.status(in: repo.path)
        XCTAssertEqual(status.staged.map(\.path), ["a*.txt"], "a*.txt 不能当通配符把 ab.txt 一起暂存")
        XCTAssertEqual(status.unstaged.map(\.path), ["ab.txt"])
    }

    // MARK: Discard

    func testDiscardRestoresATrackedFileInIndexAndWorktree() throws {
        let repo = try makeRepo(commit: ["a.txt": "original\n", "keep.txt": "k\n"])
        try write("staged\n", "a.txt", in: repo)
        try git(["add", "a.txt"], in: repo)
        try write("staged\nand more\n", "a.txt", in: repo)
        try write("other\n", "keep.txt", in: repo)

        try GitWorkingTree.discard("a.txt", in: repo.path)

        XCTAssertEqual(try read("a.txt", in: repo), "original\n")
        let status = try GitWorkingTree.status(in: repo.path)
        XCTAssertTrue(status.staged.isEmpty, "暂存的那份也要还原")
        XCTAssertEqual(status.unstaged.map(\.path), ["keep.txt"], "别的文件不受影响")
    }

    func testDiscardDeletesAnUntrackedFile() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        try write("scratch\n", "scratch.txt", in: repo)

        try GitWorkingTree.discard("scratch.txt", in: repo.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("scratch.txt").path))
        XCTAssertTrue(try GitWorkingTree.status(in: repo.path).unstaged.isEmpty)
    }

    func testDiscardRemovesANewlyStagedFile() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        try write("new\n", "new.txt", in: repo)
        try git(["add", "new.txt"], in: repo)

        try GitWorkingTree.discard("new.txt", in: repo.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("new.txt").path),
                       "还原到 HEAD：HEAD 里没有这个文件")
        XCTAssertTrue(try GitWorkingTree.status(in: repo.path).staged.isEmpty)
    }

    func testDiscardRefusesAPathThatIsNotAChange() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        try write("*.log\n", ".gitignore", in: repo)
        try git(["add", ".gitignore"], in: repo)
        try git(["commit", "-q", "-m", "ignore"], in: repo)
        try write("log\n", "build.log", in: repo)

        XCTAssertThrowsError(try GitWorkingTree.discard("build.log", in: repo.path)) { error in
            XCTAssertEqual(error as? GitWorkingTree.Failure, .notAChange("build.log"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("build.log").path),
                      "被忽略的文件不是改动，不能被删掉")
    }

    // MARK: Diff

    func testStagedAndUnstagedDiffsOfTheSameFileDiffer() throws {
        let repo = try makeRepo(commit: ["a.txt": "base\n"])
        try write("base\nstaged line\n", "a.txt", in: repo)
        try git(["add", "a.txt"], in: repo)
        try write("base\nstaged line\nworktree line\n", "a.txt", in: repo)

        let staged = try GitWorkingTree.diff("a.txt", staged: true, in: repo.path)
        let unstaged = try GitWorkingTree.diff("a.txt", staged: false, in: repo.path)

        XCTAssertTrue(staged.contains("+staged line"))
        XCTAssertFalse(staged.contains("worktree line"), "已暂存的差异只比索引和 HEAD")
        XCTAssertTrue(unstaged.contains("+worktree line"))
        XCTAssertFalse(unstaged.contains("+staged line"), "未暂存的差异只比工作区和索引")
    }

    func testAStagedOnlyFileHasAStagedDiff() throws {
        let repo = try makeRepo(commit: ["a.txt": "base\n"])
        try write("base\nmore\n", "a.txt", in: repo)
        try git(["add", "a.txt"], in: repo)

        XCTAssertTrue(try GitWorkingTree.diff("a.txt", staged: true, in: repo.path).contains("+more"),
                      "只暂存的文件以前显示“没有可显示差异”")
        XCTAssertEqual(try GitWorkingTree.diff("a.txt", staged: false, in: repo.path), "")
    }

    func testAnUntrackedFileDiffsAsANewFile() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        try write("hello\nworld\n", "新 文件.txt", in: repo)

        let diff = try GitWorkingTree.diff("新 文件.txt", staged: false, in: repo.path)

        XCTAssertTrue(diff.contains("+hello"))
        XCTAssertTrue(diff.contains("+world"))
        XCTAssertTrue(diff.contains("新 文件.txt"), "路径原样，不转义")
    }

    // MARK: Commit

    func testCommitRefusesABlankMessage() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        try write("2\n", "a.txt", in: repo)
        try git(["add", "a.txt"], in: repo)
        let before = try head(repo)

        XCTAssertThrowsError(try GitWorkingTree.commit(message: " \n\t ", in: repo.path)) { error in
            XCTAssertEqual(error as? GitWorkingTree.Failure, .emptyMessage)
        }
        XCTAssertEqual(try head(repo), before)
        XCTAssertEqual(try GitWorkingTree.status(in: repo.path).staged.map(\.path), ["a.txt"], "暂存保持不变")
    }

    func testCommitRefusesWhenNothingIsStaged() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        try write("2\n", "a.txt", in: repo)
        let before = try head(repo)

        XCTAssertThrowsError(try GitWorkingTree.commit(message: "改了", in: repo.path)) { error in
            XCTAssertEqual(error as? GitWorkingTree.Failure, .nothingStaged,
                           "在 git commit 之前就拒绝，不是 git 的 nothing to commit")
        }
        XCTAssertEqual(try head(repo), before)
    }

    func testCommitReturnsAHashThatTheLogShows() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        try write("2\n", "a.txt", in: repo)
        try GitWorkingTree.stage(["a.txt"], in: repo.path)

        let hash = try GitWorkingTree.commit(message: "第二次提交", in: repo.path)

        let log = try git(["log", "--format=%H %s", "-1"], in: repo)
        XCTAssertFalse(hash.isEmpty)
        XCTAssertTrue(log.hasPrefix(hash), "\(log) 应以 \(hash) 开头")
        XCTAssertTrue(log.contains("第二次提交"))
        XCTAssertTrue(try GitWorkingTree.status(in: repo.path).staged.isEmpty)
    }

    func testCommitWorksBeforeTheFirstCommit() throws {
        let repo = try makeRepo()
        try write("1\n", "a.txt", in: repo)
        try GitWorkingTree.stage(["a.txt"], in: repo.path)

        let hash = try GitWorkingTree.commit(message: "init", in: repo.path)

        XCTAssertTrue(try head(repo).hasPrefix(hash))
    }

    func testChineseNameWithASpaceSurvivesStageAndCommit() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        let name = "设计 稿/需求 说明.md"
        try write("内容\n", name, in: repo)

        let found = try GitWorkingTree.status(in: repo.path).unstaged.map(\.path)
        XCTAssertEqual(found, [name], "不能出现 \\344… 转义或引号")
        try GitWorkingTree.stage(found, in: repo.path)
        XCTAssertEqual(try GitWorkingTree.status(in: repo.path).staged.map(\.path), [name])
        try GitWorkingTree.commit(message: "加需求说明", in: repo.path)

        let committed = try git(["ls-tree", "-r", "-z", "--name-only", "HEAD"], in: repo)
            .split(separator: "\0").map(String.init)
        XCTAssertTrue(committed.contains(name))
        XCTAssertTrue(try GitWorkingTree.status(in: repo.path).staged.isEmpty)
        XCTAssertTrue(try GitWorkingTree.status(in: repo.path).unstaged.isEmpty)
    }

    // MARK: Branch and push

    func testPushUpdatesTheUpstreamAndClearsAhead() throws {
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", "-b", "main"], in: remote)
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        try git(["remote", "add", "origin", remote.path], in: repo)
        try git(["push", "-q", "-u", "origin", "main"], in: repo)

        try write("2\n", "a.txt", in: repo)
        try GitWorkingTree.stage(["a.txt"], in: repo.path)
        try GitWorkingTree.commit(message: "ahead", in: repo.path)
        var info = try GitWorkingTree.branchInfo(in: repo.path)
        XCTAssertEqual(info, .init(name: "main", upstream: "origin/main", ahead: 1, behind: 0))

        XCTAssertEqual(try GitWorkingTree.push(in: repo.path), "origin/main")

        info = try GitWorkingTree.branchInfo(in: repo.path)
        XCTAssertEqual(info.ahead, 0)
        XCTAssertEqual(info.behind, 0)
        let remoteHead = try git(["rev-parse", "main"], in: remote).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteHead, try head(repo), "远端的 main 指向刚推上去的提交")
    }

    func testPushWithoutUpstreamIsRefused() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])

        XCTAssertEqual(try GitWorkingTree.branchInfo(in: repo.path), .init(name: "main"))
        XCTAssertThrowsError(try GitWorkingTree.push(in: repo.path)) { error in
            XCTAssertEqual(error as? GitWorkingTree.Failure, .noUpstream)
        }
        let config = try git(["config", "--list", "--local"], in: repo)
        XCTAssertFalse(config.contains("branch.main.remote"), "不能顺手设置上游")
    }

    func testGitFailuresCarryGitsOwnText() throws {
        let repo = try makeRepo(commit: ["a.txt": "1\n"])
        XCTAssertThrowsError(try GitWorkingTree.unstage(["missing.txt"], in: repo.path)) { error in
            guard case .git(let text) = error as? GitWorkingTree.Failure else {
                return XCTFail("expected git's stderr, got \(error)")
            }
            XCTAssertTrue(text.contains("missing.txt"), text)
        }
    }
}
