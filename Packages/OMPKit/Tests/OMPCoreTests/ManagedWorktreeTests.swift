import XCTest
@testable import OMPCore

/// `.worktreeinclude` matching and the managed path layout, pure: no git, no
/// repository.
final class ManagedWorktreeTests: XCTestCase {
    private let ignored = [
        ".env",
        ".env.local",
        "config/secrets.json",
        "build/output.bin",
        "build/logs/a.log",
        "AGENTS.override.md",
        "notes/scratch.txt",
        "vendor/lib/a.o",
    ]

    func testBasicPatterns() {
        let selected = WorktreeInclude.select(
            patterns: [".env", "config/secrets.json"],
            amongIgnoredFiles: ignored
        )
        XCTAssertEqual(selected, [".env", "config/secrets.json", "AGENTS.override.md"])
    }

    func testNegationAndGlobsAndAnchoring() {
        let selected = WorktreeInclude.select(
            patterns: ["build/**", "!build/logs/", "*.o", "/.env", "!.env.local"],
            amongIgnoredFiles: ignored
        )
        // `build/**` takes the directory wholesale, so the negation below it
        // cannot opt a file out; `/.env` is anchored at the root; `*.o` is a
        // bare name and matches at any depth.
        XCTAssertEqual(
            selected,
            [".env", "build/output.bin", "build/logs/a.log", "AGENTS.override.md", "vendor/lib/a.o"]
        )
    }

    func testNegationOfTheAutomaticOverride() {
        let selected = WorktreeInclude.select(
            patterns: ["!AGENTS.override.md"],
            amongIgnoredFiles: ignored
        )
        XCTAssertFalse(selected.contains("AGENTS.override.md"), "显式否定应覆盖自动规则")
        XCTAssertTrue(selected.isEmpty)
    }

    func testCommentsAndBlankLinesAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-wti-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        # comment
        .env

        \\#literal.md
        """.write(to: root.appendingPathComponent(".worktreeinclude"), atomically: true, encoding: .utf8)

        XCTAssertEqual(WorktreeInclude.patterns(inRepositoryRoot: root.path), [".env", "#literal.md"])
        XCTAssertEqual(WorktreeInclude.patterns(inRepositoryRoot: root.path + "/missing"), [])
    }

    func testCopySkipsSymlinksAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-wtc-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "secret".write(to: source.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "nested".write(to: source.appendingPathComponent("dir/a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("link.env"),
            withDestinationURL: source.appendingPathComponent(".env")
        )
        // Already in the checkout: must survive untouched.
        try "kept".write(to: destination.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let copied = try WorktreeInclude.copy(
            relativePaths: [".env", "dir/a.txt", "link.env", "absent.txt"],
            from: source.path,
            to: destination.path
        )
        XCTAssertEqual(copied, ["dir/a.txt"], "符号链接、已存在的文件和缺失的文件都不复制")
        let kept = try String(contentsOf: destination.appendingPathComponent(".env"), encoding: .utf8)
        XCTAssertEqual(kept, "kept", "已存在的文件不能被覆盖")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path + "/dir/a.txt"))
    }

    func testManagedPathLayout() {
        XCTAssertEqual(
            ManagedWorktreeLayout.managedPath(root: "/base/", sourceRoot: "/repos/app/", slug: "fix-1"),
            "/base/app/fix-1"
        )
        XCTAssertTrue(ManagedWorktreeLayout.defaultRoot().path.hasSuffix("/OMPChat/worktrees"))
    }

    func testRegistryDecodesOldDocuments() throws {
        let old = #"{"version":1,"conversations":[]}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(FileConversationStore.Snapshot.self, from: old)
        XCTAssertTrue(snapshot.managedWorktrees.isEmpty, "旧文档没有 managedWorktrees 也应能打开")

        let partial = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","path":"/wt","sourceRoot":"/repo","baseCommit":"abc"}"#
            .data(using: .utf8)!
        let worktree = try decoder.decode(ManagedWorktree.self, from: partial)
        XCTAssertNil(worktree.branch, "缺省分支表示 detached")
        XCTAssertNil(worktree.snapshot)
        XCTAssertNil(worktree.deletedAt)
        XCTAssertTrue(worktree.conversationIDs.isEmpty)

        let damaged = #"{"managedWorktrees":[null,{"path":1},\#(String(decoding: partial, as: UTF8.self))]}"#.data(using: .utf8)!
        let recovered = try decoder.decode(FileConversationStore.Snapshot.self, from: damaged)
        XCTAssertEqual(recovered.managedWorktrees.count, 1, "损坏的条目应被跳过而不是阻断打开")
        XCTAssertEqual(recovered.managedWorktrees.first?.path, "/wt")
    }

    func testRegistryRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-wts-\(UUID().uuidString)", isDirectory: true)
        let store = FileConversationStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let record = ManagedWorktree(
            path: "/wt/app/fix",
            sourceRoot: "/repo/app",
            baseCommit: "abc123",
            branch: nil,
            conversationIDs: [id],
            snapshot: ManagedWorktreeSnapshot(ref: "refs/omp/snapshots/\(id.uuidString)", commit: "def", head: "abc123")
        )
        _ = try awaitStore { try await store.saveManagedWorktrees([record]) }
        let loaded = try awaitStore { try await store.loadManagedWorktrees() }
        XCTAssertEqual(loaded, [record])
    }

    /// Bridges an actor call into XCTest without a new test target helper.
    private func awaitStore<T>(_ work: @escaping () async throws -> T) throws -> T {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { box.value = .success(try await work()) }
            catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.value! {
        case .success(let value): return value as! T
        case .failure(let error): throw error
        }
    }

    private final class Box: @unchecked Sendable {
        var value: Result<Any, Error>?
    }
}
