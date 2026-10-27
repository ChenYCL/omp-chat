import XCTest
@testable import OMPCore

/// Snapshot / restore / handoff primitives against real temporary
/// repositories: what a snapshot captures, what restore brings back, and
/// that a failing move never loses either side's work.
#if os(macOS)
@MainActor
final class WorktreeSnapshotTests: XCTestCase {
    private var root: URL!
    private let git = GitBinary.resolve()

    override func setUpWithError() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-wtgit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: helpers

    @discardableResult
    private func run(_ arguments: [String], in directory: URL? = nil, stdin: Data? = nil) throws -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git!)
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? root
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            XCTFail("git \(arguments.first ?? "") failed: \(String(decoding: error, as: UTF8.self))")
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func write(_ text: String, _ path: String, in directory: URL? = nil) throws {
        let target = (directory ?? root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
    }

    /// One commit, then a source checkout with a managed-style worktree.
    private func makeWorktree(id: UUID) throws -> (source: URL, worktree: URL) {
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"], in: source)
        try run(["config", "user.email", "t@t"], in: source)
        try run(["config", "user.name", "t"], in: source)
        try write("let a = 1\n", "a.swift", in: source)
        try run(["add", "-A"], in: source)
        try run(["commit", "-qm", "init"], in: source)
        let worktree = root.appendingPathComponent("wt", isDirectory: true)
        try run(["worktree", "add", "--detach", worktree.path, "HEAD"], in: source)
        return (source, worktree)
    }

    // MARK: Snapshot

    func testSnapshotCapturesTrackedStagedAndUntrackedWithoutTouchingTheTree() throws {
        let (source, worktree) = try makeWorktree(id: UUID())
        try write("let a = 2\n", "a.swift", in: worktree)         // unstaged edit
        try write("let b = 9\n", "b.swift", in: worktree)          // staged new file
        try run(["add", "b.swift"], in: worktree)
        try write("let c = 3\n", "nested/c.swift", in: worktree)   // untracked

        let id = UUID()
        let snapshot = try WorktreeGit.snapshot(worktreeRoot: worktree.path, id: id)

        // Nothing moved in the worktree.
        XCTAssertEqual(try read("a.swift", in: worktree), "let a = 2\n")
        let status = try run(["status", "--porcelain"], in: worktree)
        XCTAssertTrue(status.out.contains("M  a.swift") || status.out.contains(" M a.swift"), "快照不改变状态：\(status.out)")

        // The ref lives in the source repo and the commit exists.
        let shown = try run(["show", "--stat", "--format=%s", snapshot.commit], in: source)
        XCTAssertEqual(shown.out.split(separator: "\n").first, "OMP Chat worktree snapshot")
        let ref = try run(["rev-parse", "refs/omp/snapshots/\(id.uuidString)"], in: source)
        XCTAssertEqual(ref.out.trimmingCharacters(in: .whitespacesAndNewlines), snapshot.commit)
        XCTAssertEqual(snapshot.head, try run(["rev-parse", "HEAD"], in: worktree).out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSnapshotIndexTreeDistinguishesStagedFromUnstaged() throws {
        let (_, worktree) = try makeWorktree(id: UUID())
        try write("let a = 2\n", "a.swift", in: worktree)
        try run(["add", "a.swift"], in: worktree)
        try write("let a = 3\n", "a.swift", in: worktree)
        _ = try WorktreeGit.tempIndexTree(root: worktree.path)
        // The real index file still reports the staged state, not the temp one.
        let status = try run(["status", "--porcelain"], in: worktree)
        XCTAssertTrue(status.out.contains("MM a.swift"), "临时索引不碰真索引：\(status.out)")
    }

    func testSnapshotInRepoWithoutCommitsYet() throws {
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try run(["init", "-q"], in: fresh)
        try run(["config", "user.email", "t@t"], in: fresh)
        try run(["config", "user.name", "t"], in: fresh)
        try write("hello\n", "f.txt", in: fresh)
        let snapshot = try WorktreeGit.snapshot(worktreeRoot: fresh.path, id: UUID())
        XCTAssertEqual(snapshot.head, "", "空仓库没有 HEAD，快照记录为空")
        let shown = try run(["cat-file", "-t", snapshot.commit], in: fresh)
        XCTAssertEqual(shown.out.trimmingCharacters(in: .whitespacesAndNewlines), "commit")
    }

    // MARK: Restore

    func testRestoreReproducesTheWholeWorkingState() throws {
        let (source, worktree) = try makeWorktree(id: UUID())
        try write("let a = 2\n", "a.swift", in: worktree)
        try write("let b = 9\n", "b.swift", in: worktree)
        try run(["add", "b.swift"], in: worktree)
        try write("let c = 3\n", "c.swift", in: worktree)
        let id = UUID()
        let snapshot = try WorktreeGit.snapshot(worktreeRoot: worktree.path, id: id)

        try WorktreeGit.remove(worktreePath: worktree.path, repositoryRoot: source.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))

        let restoredPath = try WorktreeGit.restore(
            repositoryRoot: source.path,
            head: snapshot.head,
            commit: snapshot.commit,
            indexCommit: nil,
            to: worktree.path
        )
        XCTAssertEqual(restoredPath, worktree.path, "原路径空着时应原样重建")
        let restored = URL(fileURLWithPath: restoredPath)
        XCTAssertEqual(try read("a.swift", in: restored), "let a = 2\n", "未暂存的改动回来")
        XCTAssertEqual(try read("b.swift", in: restored), "let b = 9\n", "已暂存的新文件回来")
        XCTAssertEqual(try read("c.swift", in: restored), "let c = 3\n", "未跟踪的文件回来")
        // Staged state: b.swift is in the index, a.swift's edit present.
        // (git read-tree -u --reset <snapshot> + read-tree <indexCommit>
        // keeps b.swift staged; a.swift's index entry already contains the
        // snapshot content, so git may report it clean-staged or modified
        // depending on stat — either way the FILE content is right, which
        // the reads above assert.)
        let status = try run(["status", "--porcelain"], in: restored)
        XCTAssertTrue(status.out.contains("b.swift"), "b.swift 在暂存区或列表里：\(status.out)")
        // HEAD is where the worktree was, detached.
        let head = try run(["rev-parse", "HEAD"], in: restored).out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, snapshot.head)
    }

    func testRestoreFindsAFreePathWhenThePreferredIsTaken() throws {
        let (source, worktree) = try makeWorktree(id: UUID())
        let snapshot = try WorktreeGit.snapshot(worktreeRoot: worktree.path, id: UUID())
        try WorktreeGit.remove(worktreePath: worktree.path, repositoryRoot: source.path)
        try write("占用\n", "keep.txt", in: worktree) // recreate something at the old path
        let used = try WorktreeGit.restore(
            repositoryRoot: source.path, head: snapshot.head, commit: snapshot.commit,
            indexCommit: nil, to: worktree.path
        )
        XCTAssertEqual(used, worktree.path + "-2", "旧路径被占时落到 -2")
    }

    func testAvailablePathBoundsItsSearch() throws {
        let (source, worktree) = try makeWorktree(id: UUID())
        // The worktree itself exists, so `preferred` is taken and -2 is free.
        XCTAssertEqual(WorktreeGit.availablePath(preferred: worktree.path, near: source.path), worktree.path + "-2")
        // A preferred path that does not exist returns as-is.
        let unused = source.appendingPathComponent("never-created").path
        XCTAssertEqual(WorktreeGit.availablePath(preferred: unused, near: source.path), unused)
    }

    // MARK: Handoff primitives

    func testHandoffWorktreeToLocalAndBack() throws {
        let (source, worktree) = try makeWorktree(id: UUID())
        let id = UUID()
        // Work on the worktree: edit + new untracked file.
        try write("let a = 2\n", "a.swift", in: worktree)
        try write("new file\n", "n.txt", in: worktree)
        let move = try WorktreeHandoff.buildMove(root: worktree.path, base: snapshotHead(source), id: id)

        // Local is clean: no conflicts.
        let conflicts = try WorktreeHandoff.conflictingPaths(move, destination: source.path)
        XCTAssertTrue(conflicts.isEmpty)
        try WorktreeHandoff.apply(move, to: source.path)
        XCTAssertEqual(try read("a.swift", in: source), "let a = 2\n")
        XCTAssertEqual(try read("n.txt", in: source), "new file\n")
        // Index knows the applied change (git apply --index).
        let statusAfterApply = try run(["status", "--porcelain"], in: source)
        XCTAssertTrue(statusAfterApply.out.contains("a.swift"), statusAfterApply.out)

        // Clean the source side (here: the worktree) only after the apply.
        try WorktreeHandoff.cleanSource(root: worktree.path, paths: move.paths)
        let statusWorktree = try run(["status", "--porcelain"], in: worktree)
        XCTAssertTrue(statusWorktree.out.isEmpty, "worktree 交出改动后干净：\(statusWorktree.out)")
        // HEAD untouched (detached at the same commit), commits reachable via ref.
        let head = try run(["rev-parse", "HEAD"], in: worktree).out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, try snapshotHead(worktree))
        let reachable = try run(["cat-file", "-e", "refs/omp/snapshots/\(id.uuidString)"], in: source)
        XCTAssertEqual(reachable.status, 0)

        // And back: the moved work in Local goes to the worktree again.
        let back = try WorktreeHandoff.buildMove(root: source.path, base: snapshotHead(source), id: UUID())
        try WorktreeHandoff.apply(back, to: worktree.path)
        XCTAssertEqual(try read("a.swift", in: worktree), "let a = 2\n")
        try WorktreeHandoff.cleanSource(root: source.path, paths: back.paths)
        let statusSource = try run(["status", "--porcelain"], in: source)
        XCTAssertTrue(statusSource.out.isEmpty, "本地交出改动后干净：\(statusSource.out)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("n.txt").path), "带走的未跟踪文件在本地删除")
    }

    func testHandoffRefusesWhenDestinationConflicts() throws {
        let (source, worktree) = try makeWorktree(id: UUID())
        try write("let a = 2\n", "a.swift", in: worktree)
        let move = try WorktreeHandoff.buildMove(root: worktree.path, base: snapshotHead(source), id: UUID())
        try write("let a = 本地改动\n", "a.swift", in: source)
        let conflicts = try WorktreeHandoff.conflictingPaths(move, destination: source.path)
        XCTAssertEqual(conflicts, ["a.swift"], "冲突要报出文件名")
        // Applying onto a conflicting file fails atomically, leaving Local
        // untouched. The staged-vs-worktree mismatch is what the model layer
        // must prevent (it refuses on `conflictingPaths` before applying).
        try run(["add", "a.swift"], in: source) // index holds the local edit
        XCTAssertThrowsError(try WorktreeHandoff.apply(move, to: source.path))
        XCTAssertEqual(try read("a.swift", in: source), "let a = 本地改动\n", "失败不动目标")
        try run(["reset", "-q"], in: source)
    }

    func testHandoffMoveIncludesWorktreeCommits() throws {
        let (source, worktree) = try makeWorktree(id: UUID())
        try write("let a = 2\n", "a.swift", in: worktree)
        try run(["commit", "-aqm", "worktree commit"], in: worktree)
        let move = try WorktreeHandoff.buildMove(root: worktree.path, base: snapshotHead(source), id: UUID())
        try WorktreeHandoff.apply(move, to: source.path)
        XCTAssertEqual(try read("a.swift", in: source), "let a = 2\n", "worktree 上的提交以 diff 形式搬到本地")
        // Local status shows it as a local (uncommitted) change to review.
        let status = try run(["status", "--porcelain"], in: source)
        XCTAssertTrue(status.out.contains("a.swift"), status.out)
    }

    func testFastForwardRefusesADirtyWorktree() throws {
        let (source, worktree) = try makeWorktree(id: UUID())
        try write("dirty\n", "d.txt", in: worktree)
        // Parent the advanced commit on HEAD, so it is a fast-forward of the
        // worktree (an unrelated root commit would not be an ancestor).
        let advanced = try run(["commit-tree", try run(["hash-object", "-t", "tree", "/dev/null", "-w"], in: source).out.trimmingCharacters(in: .whitespacesAndNewlines), "-p", "HEAD", "-m", "x"], in: source).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = try WorktreeHandoff.fastForwardWorktree(root: worktree.path, to: advanced)
        XCTAssertFalse(allowed, "脏 worktree 不快进")
        let clean = try WorktreeGit.run(["clean", "-fdq"], in: worktree.path)
        XCTAssertEqual(clean.status, 0)
        let allowedNow = try WorktreeHandoff.fastForwardWorktree(root: worktree.path, to: advanced)
        XCTAssertTrue(allowedNow)
        let head = try run(["rev-parse", "HEAD"], in: worktree).out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, advanced, "干净时快进到目标提交")
    }

    func testChangedPathsReadsPorcelain() throws {
        let (source, worktree) = try makeWorktree(id: UUID())
        try write("let a = 2\n", "a.swift", in: worktree)
        try write("x\n", "sub/n.txt", in: worktree)
        try run(["add", "a.swift"], in: worktree)
        let paths = try WorktreeHandoff.changedPaths(in: worktree.path)
        XCTAssertEqual(paths, ["a.swift", "sub/n.txt"], "暂存与未跟踪都算：\(paths)")
        _ = source
    }

    private func snapshotHead(_ directory: URL) throws -> String {
        try run(["rev-parse", "HEAD"], in: directory).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
