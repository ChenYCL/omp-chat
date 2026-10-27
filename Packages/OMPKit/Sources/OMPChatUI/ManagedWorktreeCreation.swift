import Foundation
import OMPCore

/// Phases of a managed worktree creation, shown as a card over the
/// transcript (official `worktreeInitV2.progress.*`).
public enum ManagedWorktreePhase: Equatable, Sendable {
    /// 正在获取最新改动 (only with 获取上游 setting on).
    case fetching
    /// 正在检出文件
    case checkingOut
    /// 正在运行初始化脚本
    case settingUp
    /// Worktree 初始化失败 — the detail carries git or script output.
    case failed
}

public struct ManagedWorktreeProgress: Equatable, Sendable {
    public var conversationID: UUID
    public var phase: ManagedWorktreePhase
    /// Second line: script or git output when a step failed.
    public var detail: String?
    /// 「跳过更新」 shows only while the fetch runs.
    public var canSkipFetch: Bool

    public init(conversationID: UUID, phase: ManagedWorktreePhase, detail: String? = nil, canSkipFetch: Bool = false) {
        self.conversationID = conversationID
        self.phase = phase
        self.detail = detail
        self.canSkipFetch = canSkipFetch
    }
}

/// Lets 「跳过更新」 stop the running `git fetch`; creation then continues
/// with the refs the repository already has (official
/// `worktreeInitV2.progress.continueWithoutUpdating`).
public final class ManagedWorktreeFetchHandle: @unchecked Sendable {
    private let lock = NSLock()
    #if os(macOS)
    private var process: Process?
    #endif
    private var skipped = false

    #if os(macOS)
    /// Called right after spawn; a skip that arrived first terminates at once.
    func attach(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if skipped {
            process.terminate()
            return
        }
        self.process = process
    }
    #endif

    public func skip() {
        lock.lock()
        defer { lock.unlock() }
        skipped = true
        #if os(macOS)
        process?.terminate()
        #endif
    }
}

#if os(macOS)
/// One git invocation's observation.
struct GitRun: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String

    var ok: Bool { status == 0 }
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    /// What to show when git failed: stderr, else whatever it printed.
    var failureText: String {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }
        return stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "git 退出码 \(status)" : stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ManagedWorktreeGit {
    /// Collects the three async results of one git run and resumes the
    /// awaiting task exactly once, so no cooperative thread blocks on a pipe.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<GitRun, Never>?
        var stdout: Data?
        var stderr: Data?
        var status: Int32?
        private var terminated = false

        init(continuation: CheckedContinuation<GitRun, Never>) {
            self.continuation = continuation
        }

        func finish(_ part: () -> Void) {
            lock.lock()
            part()
            guard stdout != nil, stderr != nil, status != nil, let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()
            let run = GitRun(
                status: status!,
                stdout: stdout!,
                stderr: String(decoding: stderr!, as: UTF8.self)
            )
            continuation.resume(returning: run)
        }

        /// The timeout fires only while the process is still running, so a
        /// stale pid can never receive the SIGTERM.
        func terminateIfRunning(_ process: Process) {
            lock.lock()
            defer { lock.unlock() }
            if status == nil, !terminated {
                terminated = true
                process.terminate()
            }
        }
    }

    /// Runs git with the account's real HOME and no terminal prompts. Output
    /// drains on dedicated threads (a readability handler never fires without
    /// a run loop), `stdin` closes after writing, and past `timeout` the
    /// process gets SIGTERM with whatever output arrived.
    static func run(
        _ arguments: [String],
        in directory: String,
        stdin: Data? = nil,
        timeout: TimeInterval = 300,
        handle: ManagedWorktreeFetchHandle? = nil
    ) async -> GitRun {
        guard let git = GitBinary.resolve() else {
            return GitRun(status: -1, stdout: Data(), stderr: "这台 Mac 上没有可用的 git")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        // Unescaped UTF-8 paths in every message git prints.
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment()
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        do {
            try process.run()
        } catch {
            return GitRun(status: -1, stdout: Data(), stderr: "git 启动失败：\(error.localizedDescription)")
        }
        handle?.attach(process)

        return await withCheckedContinuation { (continuation: CheckedContinuation<GitRun, Never>) in
            let state = RunState(continuation: continuation)
            // The timeout fires only while git still runs, so a stale pid can
            // never receive the SIGTERM.
            let timer = DispatchWorkItem { state.terminateIfRunning(process) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0.1), execute: timer)
            Thread.detachNewThread {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                state.finish { state.stdout = data }
            }
            Thread.detachNewThread {
                let data = err.fileHandleForReading.readDataToEndOfFile()
                state.finish { state.stderr = data }
            }
            Thread.detachNewThread {
                process.waitUntilExit()
                state.finish { state.status = process.terminationStatus }
                timer.cancel()
            }
            if let stdin {
                Thread.detachNewThread {
                    _ = try? input.fileHandleForWriting.write(contentsOf: stdin)
                    try? input.fileHandleForWriting.close()
                }
            } else {
                try? input.fileHandleForWriting.close()
            }
        }
    }

    /// Branch names of the repository, sorted for a picker.
    static func branches(in repository: String) async -> [String] {
        let run = await run(["branch", "--format=%(refname:short)"], in: repository)
        guard run.ok else { return [] }
        return run.stdoutText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Sandboxed, HOME is the app container; git needs the account's own
    /// ~/.gitconfig for user.email and credential helpers.
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            environment["HOME"] = String(cString: home)
        }
        // Fail instead of waiting on a username prompt nobody can answer.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }
}
#endif

/// The full creation path's failure: a Result needs a real Error.
public struct ManagedWorktreeCreationFailure: Error, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

/// Performs the git and file steps of managed worktree creation, off the main
/// actor. ChatAppModel wraps it: it resolves the inputs, hops the progress
/// callbacks to the main actor, runs the local environment setup and updates
/// the registry. Order mirrors Codex: fetch (optional) → `worktree add
/// --detach` at the branch's HEAD → carry uncommitted work → copy
/// `.worktreeinclude` files → setup script (run by the caller).
struct ManagedWorktreeCreation: Sendable {
    struct Outcome: Sendable {
        var worktreePath: String
        var baseCommit: String
        /// True when the source's uncommitted work was applied.
        var carriedChanges: Bool
        /// Relative paths copied because of `.worktreeinclude`.
        var copiedIncludes: [String]
        /// Non-fatal notes for the failure card, e.g. a failed fetch.
        var notes: [String]
    }

    /// Why a creation stopped: the message shown on the card and the output
    /// under it.
    struct Failure: Error, Sendable {
        var message: String
        var detail: String?
    }

    let sourceRoot: String
    let worktreePath: String
    /// The branch whose HEAD the worktree starts at; nil = HEAD.
    let baseBranch: String?
    let carryUncommittedChanges: Bool
    let fetchUpstream: Bool
    let fetchHandle: ManagedWorktreeFetchHandle?

    /// Failure message + the output shown under it.
    func perform(
        onProgress: @escaping @Sendable (ManagedWorktreePhase, String?, Bool) async -> Void
    ) async -> Result<Outcome, Failure> {
        #if os(macOS)
        var notes: [String] = []

        if fetchUpstream {
            await onProgress(.fetching, nil, true)
            let fetch = await ManagedWorktreeGit.run(
                ["fetch", "--all", "--quiet"], in: sourceRoot, timeout: 120, handle: fetchHandle
            )
            if !fetch.ok, !fetch.stderr.contains("No remote repository specified") {
                // Official `upstreamRefreshFailed`: keep going on local refs.
                notes.append("未能获取最新改动，继续使用本地已有的改动")
            }
        }

        await onProgress(.checkingOut, nil, false)
        // Resolve after the fetch so the worktree sees the fresh refs.
        let commitSpec = baseBranch.map { "\($0)^{commit}" } ?? "HEAD"
        let resolved = await ManagedWorktreeGit.run(["rev-parse", "--verify", "--quiet", commitSpec], in: sourceRoot)
        guard resolved.ok, let baseCommit = resolved.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init), !baseCommit.isEmpty else {
            return .failure(Failure(message: "没有可以检出的提交：分支 “\(baseBranch ?? "HEAD")” 还没有任何提交", detail: resolved.failureText))
        }

        let add = await ManagedWorktreeGit.run(["worktree", "add", "--detach", worktreePath, baseCommit], in: sourceRoot)
        guard add.ok else {
            return .failure(Failure(message: "创建 Worktree 失败", detail: add.failureText))
        }

        do {
            var carried = false
            if carryUncommittedChanges {
                carried = try await carryUncommitted(baseCommit: baseCommit)
            }
            let copiedIncludes = try await copyIncludedFiles()
            return .success(Outcome(
                worktreePath: worktreePath,
                baseCommit: baseCommit,
                carriedChanges: carried,
                copiedIncludes: copiedIncludes,
                notes: notes
            ))
        } catch {
            // A half-made checkout is worse than none: remove the directory
            // and git's worktree entry before reporting why.
            await rollbackAfterFailedSetup()
            return .failure(Failure(message: "创建 Worktree 失败", detail: error.localizedDescription))
        }
        #else
        _ = onProgress
        return .failure(Failure(message: "新建 Worktree 只能在 Mac 上做", detail: nil))
        #endif
    }

    /// Applies the source's tracked uncommitted changes (`diff --binary`
    /// against the base commit, applied in the worktree) and copies untracked
    /// non-ignored files. Returns true when anything was carried.
    private func carryUncommitted(baseCommit: String) async throws -> Bool {
        #if os(macOS)
        var carried = false
        let diff = await ManagedWorktreeGit.run(["diff", "--binary", baseCommit], in: sourceRoot)
        guard diff.ok else {
            throw CreationError(diff.failureText)
        }
        if !diff.stdout.isEmpty {
            let apply = await ManagedWorktreeGit.run(
                ["apply", "--binary", "--whitespace=nowarn"], in: worktreePath, stdin: diff.stdout
            )
            guard apply.ok else {
                throw CreationError(apply.failureText)
            }
            carried = true
        }
        let untracked = await ManagedWorktreeGit.run(
            ["ls-files", "-z", "--others", "--exclude-standard"], in: sourceRoot
        )
        guard untracked.ok else {
            throw CreationError(untracked.failureText)
        }
        let files = untracked.stdout.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        if !files.isEmpty {
            let copied = try WorktreeInclude.copy(relativePaths: files, from: sourceRoot, to: worktreePath)
            carried = carried || !copied.isEmpty
        }
        return carried
        #else
        return false
        #endif
    }

    /// `.worktreeinclude` selection plus the automatic
    /// `AGENTS.override.md`, copied into the fresh checkout.
    private func copyIncludedFiles() async throws -> [String] {
        #if os(macOS)
        let patterns = WorktreeInclude.patterns(inRepositoryRoot: sourceRoot)
        let overrideExists = FileManager.default.fileExists(
            atPath: (sourceRoot as NSString).appendingPathComponent(WorktreeInclude.automatic)
        )
        guard !patterns.isEmpty || overrideExists else { return [] }
        let ignored = await ManagedWorktreeGit.run(
            ["ls-files", "-z", "--others", "--ignored", "--exclude-standard"], in: sourceRoot
        )
        guard ignored.ok else {
            throw CreationError(ignored.failureText)
        }
        let files = ignored.stdout.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        let selected = WorktreeInclude.select(patterns: patterns, amongIgnoredFiles: files)
        // Relative paths only: git never reports absolute paths here, and a
        // stray absolute path would walk out of the checkout.
        for relative in selected where relative.hasPrefix("/") {
            throw CreationError("忽略文件路径异常：\(relative)")
        }
        return try WorktreeInclude.copy(relativePaths: selected, from: sourceRoot, to: worktreePath)
        #else
        return []
        #endif
    }

    /// Removes the half-made worktree: git's entry first, then whatever
    /// directory is left on disk. Awaited, so the failure is only reported
    /// once nothing of the checkout remains.
    private func rollbackAfterFailedSetup() async {
        #if os(macOS)
        _ = await ManagedWorktreeGit.run(["worktree", "remove", "--force", worktreePath], in: sourceRoot, timeout: 30)
        _ = await ManagedWorktreeGit.run(["worktree", "prune"], in: sourceRoot, timeout: 30)
        try? FileManager.default.removeItem(atPath: worktreePath)
        #endif
    }

    struct CreationError: Error, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        var localizedDescription: String { message }
    }
}
