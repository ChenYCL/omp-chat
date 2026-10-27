import Foundation

#if os(macOS)
/// The git side of snapshot / restore / delete for managed worktrees, and the
/// primitives the Local ⇄ Worktree handoff is built from (official Codex
/// "Before deleting a Codex-managed worktree, Codex saves a snapshot of the
/// work on it").
///
/// Everything is synchronous and spawns git, so callers keep it off the main
/// actor. Nothing here mutates a branch: snapshots become ref objects under
/// `refs/omp/snapshots/`, worktrees are added detached and reset with
/// `reset --mixed` (HEAD stays wherever it was). All git runs go through
/// `GitWorkingTree`'s runner with an explicit environment, so paths and
/// identity are decided here instead of by the user's config.
public enum WorktreeGit {

    // MARK: Snapshot

    /// What one snapshot recorded.
    public struct Snapshot: Equatable {
        /// Full working-tree state of the worktree at snapshot time (tracked
        /// edits, staged edits and untracked files committed together).
        public var commit: String
        /// HEAD the worktree pointed at; parents of `commit` include it.
        public var head: String
        /// The worktree's branch, nil when detached.
        public var branch: String?
        /// Where the objects and the ref live: the source repository.
        public var repositoryRoot: String
    }

    public enum GitError: Error, Equatable {
        case gitMissing
        case notARepository
        case failed(String)

        public var message: String {
            switch self {
            case .gitMissing: return "这台 Mac 上没有可用的 git"
            case .notARepository: return "这个 worktree 已经不在 git 仓库里"
            case .failed(let stderr): return stderr
            }
        }
    }

    /// Fixed identity for snapshot commits; nothing of the user's is used or
    /// changed.
    static let snapshotIdentity = [
        "GIT_AUTHOR_NAME": "OMP Chat",
        "GIT_AUTHOR_EMAIL": "omp-chat@snapshot.invalid",
        "GIT_COMMITTER_NAME": "OMP Chat",
        "GIT_COMMITTER_EMAIL": "omp-chat@snapshot.invalid",
    ]

    /// Commits everything the worktree currently holds — tracked edits,
    /// staged edits, untracked files, removals — into one commit object in
    /// the source repository, reachable as `refs/omp/snapshots/<id>`. The
    /// worktree itself is not touched: no branch moves, HEAD stays, files
    /// stay.
    public static func snapshot(worktreeRoot: String, id: UUID) throws -> Snapshot {
        guard GitBinary.resolve() != nil else { throw GitError.gitMissing }
        let root = try repositoryRoot(of: worktreeRoot)
        // No GIT_DIR override: run from the worktree, git resolves its own
        // per-worktree index and the shared object store, so `write-tree`
        // reads THIS checkout's staged state and the commit objects land in
        // the common store where `refs/omp/snapshots/*` lives anyway (refs
        // are shared across worktrees).
        // An unborn HEAD (no commit yet) has no parent at all.
        let head = try run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).status == 0
            ? checked(["rev-parse", "HEAD"], in: root).trimmed
            : ""
        do {
            // The worktree's staged state as its own commit (`commit-tree`
            // only accepts commits as `-p` parents, so the index tree gets
            // wrapped), letting restore put the index back the way it was,
            // staged files included. No HEAD yet → no parents.
            let indexTree = try checked(["write-tree"], in: root).trimmed
            var parentArgs: [String] = []
            if !head.isEmpty { parentArgs += ["-p", head] }
            let indexCommit = try checked(
                ["commit-tree", indexTree] + parentArgs + ["-m", "OMP Chat snapshot index"],
                in: root,
                environment: snapshotIdentity
            ).trimmed
            let snapshotTree = try tempIndexTree(root: root)
            let commit = try checked(
                ["commit-tree", snapshotTree, "-p", indexCommit, "-m", "OMP Chat worktree snapshot"],
                in: root,
                environment: snapshotIdentity
            ).trimmed
            try checked(["update-ref", "refs/omp/snapshots/\(id.uuidString)", commit], in: root)
            // GitInfo names detached HEADs with a short sha; a "(… detached)"
            // label (bare-repo syntax) reads as no branch.
            let branch = GitInfo.branch(at: URL(fileURLWithPath: worktreeRoot))
            var branchName: String? = branch
            if let name = branch, name.hasPrefix("(") { branchName = nil }
            return Snapshot(commit: commit, head: head, branch: branchName, repositoryRoot: root)
        }
    }

    /// `git add -A` into a temporary index, then `write-tree`: the full
    /// working state as one tree object. The worktree's own index file is
    /// never replaced (`GIT_INDEX_FILE` points elsewhere), so staging state
    /// and stat cache survive the snapshot.
    public static func tempIndexTree(root: String, environment: [String: String] = [:]) throws -> String {
        let temporary = NSTemporaryDirectory() + "omp-snapshot-\(UUID().uuidString)"
        var environment = environment
        environment["GIT_INDEX_FILE"] = temporary
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        _ = try run(["read-tree", "--empty"], in: root, environment: environment)
        try checked(["add", "-A", "--"], in: root, environment: environment)
        return try checked(["write-tree"], in: root, environment: environment).trimmed
    }

    // MARK: Restore

    /// Re-creates the worktree at `path` (or the nearest free suffixed path)
    /// detached at the snapshot's HEAD, then lays the snapshot's working
    /// state on top: the tree of `commit` becomes the files on disk, the
    /// index goes back to `indexCommit` when one was recorded, so staged
    /// files stage again and snapshot-only files read as untracked. Returns
    /// the path actually used.
    public static func restore(
        repositoryRoot: String,
        head: String,
        commit: String,
        indexCommit: String?,
        to preferredPath: String
    ) throws -> String {
        let path = availablePath(preferred: preferredPath, near: repositoryRoot)
        try checked(["worktree", "add", "--detach", path, head], in: repositoryRoot)
        do {
            // -u --reset: the worktree files follow the snapshot tree, extra
            // HEAD files go away, conflicting untracked files are replaced.
            try checked(["read-tree", "-u", "--reset", commit], in: path)
            if let indexCommit {
                try checked(["read-tree", indexCommit], in: path)
            }
            // Stat cache: the freshly written files must not read as modified.
            try checked(["update-index", "--refresh"], in: path)
            try checked(["clean", "-fdq"], in: path)
        } catch {
            try? run(["worktree", "remove", "--force", path], in: repositoryRoot)
            throw error
        }
        return path
    }

    /// `path` itself when free, otherwise `path-2`, `-3`, … up to 99, so a
    /// restored worktree never lands on an existing checkout.
    public static func availablePath(preferred: String, near repositoryRoot: String) -> String {
        let manager = FileManager.default
        if !manager.fileExists(atPath: preferred) { return preferred }
        for index in 2...99 {
            let candidate = "\(preferred)-\(index)"
            if !manager.fileExists(atPath: candidate) { return candidate }
        }
        return preferred + "-\(UUID().uuidString.prefix(8))"
    }

    // MARK: Deletion

    /// Removes the worktree (its uncommitted work is expected to be under a
    /// snapshot ref already) and prunes the admin entry. A worktree whose
    /// directory is already gone prunes silently.
    public static func remove(worktreePath: String, repositoryRoot: String) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: worktreePath, isDirectory: &isDirectory), isDirectory.boolValue {
            try checked(["worktree", "remove", "--force", worktreePath], in: repositoryRoot)
        }
        try checked(["worktree", "prune"], in: repositoryRoot)
    }

    // MARK: Shared plumbing

    public static func repositoryRoot(of directory: String) throws -> String {
        let output = try run(["rev-parse", "--show-toplevel"], in: directory)
        guard output.status == 0 else {
            if output.stderr.contains("not a git repository") { throw GitError.notARepository }
            throw GitError.failed(output.failureText)
        }
        return output.trimmed
    }

    @discardableResult
    public static func checked(
        _ arguments: [String], in directory: String, environment: [String: String] = [:], stdin: Data? = nil
    ) throws -> GitWorkingTree.Output {
        let output = try run(arguments, in: directory, environment: environment, stdin: stdin)
        guard output.status == 0 else { throw GitError.failed(output.failureText) }
        return output
    }

    public static func run(
        _ arguments: [String], in directory: String, environment: [String: String] = [:], stdin: Data? = nil
    ) throws -> GitWorkingTree.Output {
        try GitWorkingTree.run(arguments, in: directory, environment: environment, stdin: stdin)
    }
}
#endif
