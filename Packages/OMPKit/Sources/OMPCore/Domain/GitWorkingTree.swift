import Foundation

/// Review, stage, commit and push against a real working tree — the side
/// panel's 改动 tab (Codex's changes panel).
///
/// Every function is synchronous and spawns git, so callers keep it off the
/// main actor. `directory` may be anywhere inside the checkout; paths are
/// relative to the repository root, exactly as `status` reports them, and go
/// to git as literal pathspecs so a `*` or `[` in a name matches only that
/// file. A failing git surfaces its own stderr. iOS has no `Process`, so there
/// every git call throws `.unsupported`.
public enum GitWorkingTree {
    /// One row of the panel: a path on one side of the index.
    public struct Change: Equatable, Sendable, Identifiable {
        /// This side's letter: `M`, `A`, `D`, `R`, `C`, `T`; `??` for an
        /// untracked file; both letters (`UU`, `AA`, …) for a conflict.
        public var code: String
        public var path: String
        /// Source of a rename or copy.
        public var originalPath: String?
        /// True in 已暂存 (index against HEAD), false in 未暂存 (working tree
        /// against the index).
        public var staged: Bool

        public init(code: String, path: String, originalPath: String? = nil, staged: Bool) {
            self.code = code
            self.path = path
            self.originalPath = originalPath
            self.staged = staged
        }

        public var id: String { (staged ? "staged:" : "unstaged:") + path }
        public var isUntracked: Bool { code == "??" }
        /// Every path this row touches: a rename is undone on both ends.
        public var paths: [String] { [path] + (originalPath.map { [$0] } ?? []) }
    }

    public struct Status: Equatable, Sendable {
        public var staged: [Change]
        public var unstaged: [Change]

        public init(staged: [Change], unstaged: [Change]) {
            self.staged = staged
            self.unstaged = unstaged
        }

        public var isClean: Bool { staged.isEmpty && unstaged.isEmpty }
    }

    public struct BranchInfo: Equatable, Sendable {
        /// The branch, or the short commit when HEAD is detached.
        public var name: String
        public var detached: Bool
        /// `origin/main`; nil when the branch tracks nothing.
        public var upstream: String?
        /// Commits on HEAD the upstream lacks, and the reverse. Zero without
        /// an upstream.
        public var ahead: Int
        public var behind: Int

        public init(name: String, detached: Bool = false, upstream: String? = nil, ahead: Int = 0, behind: Int = 0) {
            self.name = name
            self.detached = detached
            self.upstream = upstream
            self.ahead = ahead
            self.behind = behind
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case gitMissing
        case unsupported
        case notARepository
        /// Refused before git ran: a blank message.
        case emptyMessage
        /// Refused before `git commit` ran: the index matches HEAD.
        case nothingStaged
        /// Refused before `git push` ran: the branch tracks nothing.
        case noUpstream
        /// `discard` of a path git neither tracks nor lists as untracked.
        case notAChange(String)
        /// git ran and failed: its stderr, verbatim.
        case git(String)

        public var message: String {
            switch self {
            case .gitMissing: return "这台 Mac 上没有可用的 git"
            case .unsupported: return "这台设备不能运行 git"
            case .notARepository: return "当前目录不在 git 仓库里"
            case .emptyMessage: return "提交信息不能为空"
            case .nothingStaged: return "没有已暂存的改动可以提交"
            case .noUpstream: return "当前分支没有上游分支，不能推送"
            case .notAChange(let path): return "“\(path)”没有可丢弃的改动"
            case .git(let stderr): return stderr
            }
        }
    }

    // MARK: Reading

    public static func status(in directory: String) throws -> Status {
        let root = try repositoryRoot(of: directory)
        // No optional locks: a refresh must not take index.lock out from under
        // whatever git the user is running in the terminal at the same time.
        let output = try checked(["--no-optional-locks"] + GitStatus.arguments, in: root)
        return split(GitStatus.parse(output.text))
    }

    /// Splits porcelain entries into the panel's two groups. X (the index
    /// column) feeds 已暂存 and Y (the worktree column) feeds 未暂存, so `MM`
    /// is in both. Untracked counts as unstaged; a conflict stays unstaged with
    /// both letters until staging marks it resolved.
    static func split(_ entries: [GitStatus.Entry]) -> Status {
        let conflicts: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        var staged: [Change] = []
        var unstaged: [Change] = []
        for entry in entries {
            if entry.xy == "??" || conflicts.contains(entry.xy) {
                unstaged.append(Change(code: entry.xy, path: entry.path, staged: false))
                continue
            }
            if entry.xy == "!!" { continue }
            if entry.index != " " {
                staged.append(Change(
                    code: String(entry.index), path: entry.path,
                    originalPath: entry.originalPath, staged: true
                ))
            }
            if entry.worktree != " " {
                // The rename belongs to the index; the worktree only edited the new path.
                let original = entry.index == " " ? entry.originalPath : nil
                unstaged.append(Change(
                    code: String(entry.worktree), path: entry.path,
                    originalPath: original, staged: false
                ))
            }
        }
        return Status(staged: staged, unstaged: unstaged)
    }

    /// Unified diff of one path: `staged` compares the index with HEAD,
    /// otherwise the working tree with the index. Pass a rename's source as
    /// `originalPath` so git pairs the two ends instead of showing a whole new
    /// file. An untracked file is compared with nothing, so it reads as a new
    /// file. Empty when git has nothing to show on that side.
    public static func diff(_ path: String, originalPath: String? = nil, staged: Bool, in directory: String) throws -> String {
        let root = try repositoryRoot(of: directory)
        let base = ["diff", "--no-color", "--no-ext-diff"]
        let paths = [path] + (originalPath.map { [$0] } ?? [])
        if staged {
            return try checked(base + ["-M", "--cached", "--"] + paths, in: root, literalPaths: true).text
        }
        let output = try checked(base + ["--"] + paths, in: root, literalPaths: true)
        guard output.stdout.isEmpty, try isUntracked(path, root: root) else { return output.text }
        let created = try run(base + ["--no-index", "--", "/dev/null", path], in: root)
        // --no-index exits 1 when the two sides differ, which they always do here.
        guard created.status <= 1 else { throw Failure.git(created.failureText) }
        return created.text
    }

    public static func branchInfo(in directory: String) throws -> BranchInfo {
        let root = try repositoryRoot(of: directory)
        guard let name = try currentBranch(root) else {
            let commit = try checked(["rev-parse", "--short", "HEAD"], in: root).trimmed
            return BranchInfo(name: commit, detached: true)
        }
        guard let upstream = try trackedUpstream(root) else { return BranchInfo(name: name) }
        // Left is the upstream's side (behind), right is HEAD's (ahead).
        let counts = try checked(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: root)
            .trimmed.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { throw Failure.git("无法读取与 \(upstream) 的差距") }
        return BranchInfo(name: name, upstream: upstream, ahead: counts[1], behind: counts[0])
    }

    // MARK: Staging

    public static func stage(_ paths: [String], in directory: String) throws {
        guard !paths.isEmpty else { return }
        let root = try repositoryRoot(of: directory)
        // --all: a path deleted from disk is staged as a deletion.
        try checked(["add", "--all", "--"] + paths, in: root, literalPaths: true)
    }

    public static func unstage(_ paths: [String], in directory: String) throws {
        guard !paths.isEmpty else { return }
        let root = try repositoryRoot(of: directory)
        if try hasHead(root) {
            try checked(["restore", "--staged", "--"] + paths, in: root, literalPaths: true)
        } else {
            // Before the first commit there is no HEAD to restore from, so
            // unstaging means leaving the index. -f because the staged copy may
            // differ from the file; the file on disk is not touched.
            try checked(["rm", "--cached", "-r", "-f", "-q", "--"] + paths, in: root, literalPaths: true)
        }
    }

    public static func stageAll(in directory: String) throws {
        let root = try repositoryRoot(of: directory)
        try checked(["add", "--all"], in: root)
    }

    /// Resets the index to HEAD, or to empty before the first commit; the
    /// working tree keeps every edit.
    public static func unstageAll(in directory: String) throws {
        let root = try repositoryRoot(of: directory)
        try checked(["reset", "-q"], in: root)
    }

    /// Throws away every change to `path`. A tracked path goes back to HEAD in
    /// both the index and the working tree (a path HEAD does not have, such as
    /// a newly added file, leaves both). An untracked file is deleted. Nothing
    /// to undo afterwards.
    public static func discard(_ path: String, in directory: String) throws {
        let root = try repositoryRoot(of: directory)
        let indexed = try !checked(["ls-files", "-z", "--", path], in: root, literalPaths: true).stdout.isEmpty
        if try hasHead(root) {
            // `HEAD:<path>` is root-relative and never a pattern.
            let committed = try run(["cat-file", "-e", "HEAD:" + path], in: root).status == 0
            if indexed || committed {
                try checked(
                    ["restore", "--source=HEAD", "--staged", "--worktree", "--", path],
                    in: root, literalPaths: true
                )
                return
            }
        } else if indexed {
            // Nothing committed yet: the last commit is the empty tree.
            try checked(["rm", "-r", "-f", "-q", "--", path], in: root, literalPaths: true)
            return
        }
        guard try isUntracked(path, root: root) else { throw Failure.notAChange(path) }
        try FileManager.default.removeItem(atPath: (root as NSString).appendingPathComponent(path))
    }

    // MARK: Committing

    /// Commits what is staged and returns the new commit's short hash.
    @discardableResult
    public static func commit(message: String, in directory: String) throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyMessage
        }
        let root = try repositoryRoot(of: directory)
        // Exits 1 when the index differs from HEAD (or from nothing, before
        // the first commit), 0 when there is nothing to commit.
        let pending = try run(["diff", "--cached", "--quiet"], in: root)
        switch pending.status {
        case 0: throw Failure.nothingStaged
        case 1: break
        default: throw Failure.git(pending.failureText)
        }
        try checked(["commit", "-q", "-m", message], in: root)
        return try checked(["rev-parse", "--short", "HEAD"], in: root).trimmed
    }

    /// Pushes HEAD to the branch's configured upstream and returns its name
    /// (`origin/main`). Never forces and never sets an upstream: without one
    /// it refuses before git runs.
    @discardableResult
    public static func push(in directory: String) throws -> String {
        let root = try repositoryRoot(of: directory)
        guard let branch = try currentBranch(root), let upstream = try trackedUpstream(root) else {
            throw Failure.noUpstream
        }
        let remote = try run(["config", "--get", "branch.\(branch).remote"], in: root).trimmed
        let merge = try run(["config", "--get", "branch.\(branch).merge"], in: root).trimmed
        guard !remote.isEmpty, !merge.isEmpty else { throw Failure.noUpstream }
        // An explicit HEAD:<ref> goes exactly where the branch tracks, whatever
        // push.default or a pushRemote would pick.
        try checked(["push", remote, "HEAD:" + merge], in: root)
        return upstream
    }

    // MARK: Plumbing

    /// The checkout's root, which every root-relative path resolves against.
    public static func repositoryRoot(of directory: String) throws -> String {
        let output = try run(["rev-parse", "--show-toplevel"], in: directory)
        guard output.status == 0 else {
            if output.stderr.contains("not a git repository") { throw Failure.notARepository }
            throw Failure.git(output.failureText)
        }
        return output.trimmed
    }

    private static func hasHead(_ root: String) throws -> Bool {
        try run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).status == 0
    }

    /// Nil when HEAD is detached; the unborn branch's name before a first commit.
    private static func currentBranch(_ root: String) throws -> String? {
        let output = try run(["symbolic-ref", "--short", "-q", "HEAD"], in: root)
        switch output.status {
        case 0: return output.trimmed
        case 1: return nil
        default: throw Failure.git(output.failureText)
        }
    }

    private static func trackedUpstream(_ root: String) throws -> String? {
        let output = try run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root)
        return output.status == 0 && !output.trimmed.isEmpty ? output.trimmed : nil
    }

    private static func isUntracked(_ path: String, root: String) throws -> Bool {
        let output = try checked(
            ["ls-files", "-z", "--others", "--exclude-standard", "--", path],
            in: root, literalPaths: true
        )
        return !output.stdout.isEmpty
    }

    private struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String

        var text: String { String(decoding: stdout, as: UTF8.self) }
        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        /// What to show when git failed: its stderr, else whatever it printed.
        var failureText: String {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return message }
            return trimmed.isEmpty ? "git 退出码 \(status)" : trimmed
        }
    }

    @discardableResult
    private static func checked(_ arguments: [String], in directory: String, literalPaths: Bool = false) throws -> Output {
        let output = try run(arguments, in: directory, literalPaths: literalPaths)
        guard output.status == 0 else { throw Failure.git(output.failureText) }
        return output
    }

    /// Runs git and returns whatever happened; a non-zero exit is the caller's
    /// to judge.
    private static func run(_ arguments: [String], in directory: String, literalPaths: Bool = false) throws -> Output {
        #if os(macOS)
        guard let git = GitBinary.resolve() else { throw Failure.gitMissing }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.notARepository
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        // Unescaped UTF-8 paths in every message git prints.
        process.arguments = ["-c", "core.quotePath=false"]
            + (literalPaths ? ["--literal-pathspecs"] : [])
            + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw Failure.git("git 启动失败：\(error.localizedDescription)")
        }
        // stderr drains on its own thread: a hook that fills one pipe while
        // this thread blocks on the other would deadlock both processes.
        let stderr = Drain()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            stderr.data = err.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: String(decoding: stderr.data, as: UTF8.self)
        )
        #else
        throw Failure.unsupported
        #endif
    }

    #if os(macOS)
    /// Written once by the draining thread, read after the semaphore.
    private final class Drain: @unchecked Sendable {
        var data = Data()
    }

    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Sandboxed, HOME is the app container; git needs the account's own
        // ~/.gitconfig for user.email and credential helpers.
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            environment["HOME"] = String(cString: home)
        }
        // Fail instead of waiting on a username prompt nobody can answer.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }
    #endif
}

extension GitWorkingTree.Failure: LocalizedError {
    public var errorDescription: String? { message }
}
