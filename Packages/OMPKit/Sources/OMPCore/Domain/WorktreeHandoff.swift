import Foundation

/// The Local ⇄ Worktree handoff (official Codex `localConversation.moveTo*`,
/// "Handoff" in the worktrees docs) as pure git moves over `WorktreeGit`.
///
/// Invariants both directions keep:
/// - Nothing is applied non-atomically: `git apply` either lands whole or not
///   at all, so a failure leaves the destination exactly as it was.
/// - The source side is only cleaned after the destination apply succeeded,
///   and the source's prior state is always committed to a snapshot ref
///   first, so a later cleanup hiccup can be undone by hand.
/// - Worktree branches never move. A managed worktree is detached before its
///   working tree is reset; commits it made stay reachable under a snapshot
///   ref.
#if os(macOS)
public enum WorktreeHandoff {

    public struct Move: Equatable {
        /// Patch (git apply format) carrying every moved change.
        public var patch: String
        /// Repository-root-relative paths the patch touches, for the
        /// conflict check and the targeted cleanup.
        public var paths: [String]
        /// Base commit of the diff: HEAD of the source side.
        public var baseHead: String
        /// Safety snapshot ref of the source side before anything moved.
        public var snapshotRef: String
    }

    public enum GitError: Error, Equatable {
        case gitMissing
        case notARepository(String)
        case failed(String)

        public var message: String {
            switch self {
            case .gitMissing: return "这台 Mac 上没有可用的 git"
            case .notARepository(let path): return "“\(GitInfo.tildified(path))”不在 git 仓库里"
            case .failed(let stderr): return stderr
            }
        }
    }

    // MARK: Reading

    /// Working-tree status paths of one checkout: root-relative, both index
    /// and worktree sides, untracked included, unmerged listed once.
    public static func changedPaths(in root: String) throws -> [String] {
        let output = try WorktreeGit.run(["status", "--porcelain", "-z", "--untracked-files=all"], in: root)
        guard output.status == 0 else { throw GitError.failed(output.failureText) }
        var paths: Set<String> = []
        let fields = output.text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < fields.count {
            let field = fields[index]
            guard field.count >= 3 else { break }
            let entry = String(field.dropFirst(3))
            paths.insert(entry)
            // A rename entry carries the original path right after itself
            // (that one has no XY prefix, so it is shorter than three).
            if index + 1 < fields.count, !fields[index + 1].isEmpty, fields[index + 1].count < 3 {
                paths.insert(fields[index + 1])
                index += 1
            }
            index += 1
        }
        return paths.sorted()
    }

    /// Everything the source side would move: the combined diff of its
    /// commits (when it sits ahead of `base`) and its uncommitted work,
    /// including untracked files, as one `git apply` patch.
    public static func buildMove(root: String, base: String, id: UUID) throws -> Move {
        let head = try WorktreeGit.checked(["rev-parse", "HEAD"], in: root).trimmed
        let snapshot = try WorktreeGit.snapshot(worktreeRoot: root, id: id)
        let snapshotTree = try WorktreeGit.checked(["rev-parse", "\(snapshot.commit)^{tree}"], in: root).trimmed
        let output = try WorktreeGit.run(
            ["diff", "--binary", "--no-color", "--no-ext-diff", base, snapshotTree],
            in: root
        )
        guard output.status == 0 else { throw GitError.failed(output.failureText) }
        var paths = Set<String>()
        for line in output.text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git "), let tail = line.split(separator: " ").last {
                paths.insert(cleanPath(String(tail)))
            } else if line.hasPrefix("+++ b/") {
                paths.insert(String(line.dropFirst(6)))
            }
        }
        return Move(
            patch: output.text,
            paths: paths.sorted(),
            baseHead: base,
            snapshotRef: "refs/omp/snapshots/\(id.uuidString)"
        )
    }

    /// `b/…` tail of a diff header, unquoted.
    private static func cleanPath(_ tail: String) -> String {
        var path = tail
        if path.hasPrefix("a/") { path = String(path.dropFirst(2)) }
        if path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
        return path
    }

    // MARK: Checks

    /// Official `localConversation.moveToLocal.error.localDestinationHasTrackedChanges`:
    /// refuse when a destination file the move touches already differs from
    /// HEAD (tracked) or exists at all (untracked), and name the files.
    public static func conflictingPaths(_ move: Move, destination: String) throws -> [String] {
        let busy = Set(try changedPaths(in: destination))
        return move.paths.filter { busy.contains($0) }
    }

    /// True when the two checkouts share a repository (worktree or not):
    /// a move only makes sense inside one repository.
    public static func sameRepository(_ left: String, _ right: String) -> Bool {
        guard
            let leftRoot = try? WorktreeGit.repositoryRoot(of: left),
            let rightRoot = try? WorktreeGit.repositoryRoot(of: right)
        else { return false }
        guard
            let leftCommon = try? WorktreeGit.run(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: leftRoot
            ).trimmed,
            let rightCommon = try? WorktreeGit.run(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: rightRoot
            ).trimmed
        else { return false }
        return (leftCommon as NSString).standardizingPath == (rightCommon as NSString).standardizingPath
    }

    // MARK: Applying

    /// Applies the patch to `destination`'s working tree and index. Atomic:
    /// a failing hunk leaves git's apply with nothing written.
    public static func apply(_ move: Move, to destination: String) throws {
        _ = try WorktreeGit.checked(
            ["apply", "--index", "--whitespace=nowarn", "-"],
            in: destination,
            stdin: Data(move.patch.utf8)
        )
    }

    /// Puts the destination back the way it was: reverse the patch, then
    /// drop the files it created that no tracked commit knows.
    public static func revert(_ move: Move, on destination: String) throws {
        _ = try WorktreeGit.checked(
            ["apply", "--index", "--reverse", "--whitespace=nowarn", "-"],
            in: destination,
            stdin: Data(move.patch.utf8)
        )
    }

    /// The source side after a successful move: working tree back to its
    /// HEAD (staged and unstaged edits folded away), untracked files the
    /// move carried removed. A worktree branch is detached first so `reset`
    /// can never move it; the detached HEAD keeps pointing where it did, and
    /// commits made there stay reachable under the snapshot ref.
    public static func cleanSource(root: String, paths: [String]) throws {
        let symbolic = try WorktreeGit.run(["symbolic-ref", "--short", "-q", "HEAD"], in: root)
        if symbolic.status == 0 {
            // Detach first: `reset` then never moves a worktree branch, and
            // the detached HEAD keeps pointing where it did.
            _ = try WorktreeGit.checked(["checkout", "--detach"], in: root)
        }
        // The worktree tree follows HEAD without moving any branch ref:
        // `reset --hard` on a detached (or force-detached) HEAD folds the
        // moved tracked edits away; the moved commits stay reachable under
        // the move's snapshot ref.
        try WorktreeGit.checked(["reset", "--hard", "-q"], in: root)
        // Remove exactly the untracked files the move carried. `-f` without
        // `-x`: ignored files (node_modules, .env) stay, so a carried path
        // colliding with an ignored one surfaces as a failure the caller
        // rolls back from, instead of silently deleting ignored state.
        let carried = paths.filter { !$0.isEmpty }
        if !carried.isEmpty {
            let cleaned = try WorktreeGit.run(["clean", "-fq", "--"] + carried, in: root)
            guard cleaned.status == 0 else { throw GitError.failed(cleaned.failureText) }
        }
    }

    /// Moves a worktree onto `commit` when it sits on an older ancestor, so
    /// Local → Worktree patches land on files the worktree actually has.
    /// Refuses (returns nil-pass-through false) when the worktree is dirty;
    /// the caller reports that before touching anything.
    public static func fastForwardWorktree(root: String, to commit: String) throws -> Bool {
        let dirty = try changedPaths(in: root)
        guard dirty.isEmpty else { return false }
        let head = try WorktreeGit.checked(["rev-parse", "HEAD"], in: root).trimmed
        guard head != commit else { return true }
        let ancestry = try WorktreeGit.run(["merge-base", "--is-ancestor", head, commit], in: root)
        guard ancestry.status == 0 else { return true }
        try WorktreeGit.checked(["checkout", "--detach", commit], in: root)
        return true
    }

    /// The merge base of the two checkouts' HEADs, which a Worktree → Local
    /// move diffs from: worktree commits ahead of it ride along, and after
    /// earlier handoffs (which rebase the worktree onto Local's HEAD) it is
    /// simply Local's HEAD.
    public static func mergeBase(worktreeRoot: String, localRoot: String) throws -> String {
        let worktreeHead = try WorktreeGit.checked(["rev-parse", "HEAD"], in: worktreeRoot).trimmed
        let localHead = try WorktreeGit.checked(["rev-parse", "HEAD"], in: localRoot).trimmed
        if worktreeHead == localHead { return worktreeHead }
        let output = try WorktreeGit.run(["merge-base", worktreeHead, localHead], in: worktreeRoot)
        if output.status == 0, !output.trimmed.isEmpty { return output.trimmed }
        // Unrelated histories: take the worktree's own registered base.
        return worktreeHead
    }
}
#endif
