import XCTest
@testable import OMPCore

final class GitInfoTests: XCTestCase {
    func testReadsBranchFromGitHead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-git-\(UUID().uuidString)", isDirectory: true)
        let gitDir = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/feature/align\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(GitInfo.branch(at: root), "feature/align")
    }

    func testNilOutsideRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(GitInfo.branch(at: root))
    }

    func testTildifiesHome() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        XCTAssertEqual(GitInfo.tildified(home.path), "~")
        XCTAssertTrue(GitInfo.tildified(home.appendingPathComponent("x").path).hasPrefix("~/x"))
    }

    // MARK: - Worktrees and subdirectories

    private func git(_ args: [String], in directory: URL) throws {
        let git = try XCTUnwrap(GitBinary.resolve())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }

    func testReadsBranchInsideALinkedWorktree() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-wt-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "i"], in: repo)
        let linked = root.appendingPathComponent("分叉-abcd1234", isDirectory: true)
        try git(["worktree", "add", "-q", "-b", "omp/fork", linked.path], in: repo)

        XCTAssertEqual(GitInfo.branch(at: linked), "omp/fork", "worktree 里 .git 是文件，也要读出分支")
        XCTAssertEqual(GitInfo.branch(at: repo), "main", "主仓库不受影响")
    }

    func testReadsBranchFromASubdirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-git-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/dev\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(GitInfo.branch(at: nested), "dev", "绑定的是仓库里的子目录时也要找到仓库")
    }

    // MARK: - Workspace name

    func testBoundFolderNameWinsOverProject() {
        XCTAssertEqual(ThreadWorkspace.name(workingDirectory: "/Users/a/code/omp-chat", projectName: "备份项目"), "omp-chat")
        XCTAssertEqual(ThreadWorkspace.name(workingDirectory: "/Users/a/code/omp-chat/", projectName: nil), "omp-chat",
                       "结尾斜杠不影响")
    }

    func testFallsBackToProjectThenDefault() {
        XCTAssertEqual(ThreadWorkspace.name(workingDirectory: nil, projectName: "备份项目"), "备份项目")
        XCTAssertEqual(ThreadWorkspace.name(workingDirectory: "  ", projectName: nil), "默认工作区", "空白目录等于没绑定")
        XCTAssertEqual(ThreadWorkspace.name(workingDirectory: nil, projectName: ""), "默认工作区")
        XCTAssertEqual(ThreadWorkspace.name(workingDirectory: "/", projectName: nil), "/", "根目录显示为 /")
    }
}
