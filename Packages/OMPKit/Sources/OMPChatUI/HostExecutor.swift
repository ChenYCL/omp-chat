#if os(macOS)
import Darwin
#endif
import Foundation
import OMPCore

/// One line of the in-memory remote-operation log shown in Settings.
public struct RemoteOperationRecord: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let at: Date
    public let summary: String

    public init(at: Date = Date(), summary: String) {
        self.at = at
        self.summary = summary
    }
}

/// Executes host RPC on the Mac: `info`, `fs.list`, `fs.read`, `exec`, and
/// `exec.cancel`.
///
/// `info` always runs. Everything else answers `shell_disabled` unless
/// [`shellAllowed`] (backed by `AppSettings.relayAllowShell`) is true.
/// `exec` runs `/bin/zsh -c` and reports the resulting working directory, so
/// a `cd` survives into the next call when the client sends `cwd` back.
/// While an `exec` runs, the executor keeps it in a registry keyed by request
/// id; `exec.cancel` with that id stops the process tree — SIGINT to the
/// descendants first (the wrapper shell itself ignores it), then SIGINT to
/// the wrapper, then SIGKILL after 2 s — and the exec answers
/// `ok: false, error: "cancelled"` with its partial output and exit code 130.
public struct HostExecutor: Sendable {
    /// Hard cap on a single stdout or stderr capture.
    public static let outputCap = 256 * 1024
    /// Hard cap on directory entries returned by `fs.list`.
    public static let entryCap = 2000
    /// Default and maximum `exec` runtime.
    public static let defaultTimeout: Double = 30
    public static let maxTimeout: Double = 120

    /// Whether file and shell operations are permitted. `info` ignores this.
    public var shellAllowed: Bool
    /// Real user home from the passwd database, used to expand `~` and as the
    /// default root. `NSHomeDirectory()` is wrong here: inside the app sandbox
    /// it returns the container, not the account's home.
    public var homeDirectory: String
    /// Append-only ring of the last operations, for the Settings disclosure.
    private let log: RemoteOperationLog
    /// In-flight `exec` processes by request id, so `exec.cancel` can stop
    /// them. Only meaningful on macOS; iOS never populates it.
    private let running: RunningExecRegistry
    public init(
        shellAllowed: Bool,
        homeDirectory: String? = nil,
        log: RemoteOperationLog? = nil,
        running: RunningExecRegistry? = nil
    ) {
        self.shellAllowed = shellAllowed
        self.homeDirectory = homeDirectory ?? Self.realHomeDirectory()
        self.log = log ?? RemoteOperationLog()
        self.running = running ?? RunningExecRegistry()
    }

    /// Account home from `getpwuid`, falling back to `NSHomeDirectory()` only
    /// when the passwd entry is missing.
    public static func realHomeDirectory() -> String {
        #if os(macOS)
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        #endif
        return NSHomeDirectory()
    }

    /// The most recent operations, newest last, capped at 20.
    public func recentOperations() -> [RemoteOperationRecord] {
        log.snapshot()
    }

    public func handle(_ request: HostRPCRequest) async -> HostRPCResponse {
        let op = request.op
        guard op == "info" || op == "fs.list" || op == "fs.read" || op == "exec" || op == "exec.cancel" else {
            return HostRPCResponse(id: request.id, ok: false, error: "bad_request")
        }
        if op != "info", !shellAllowed {
            log.record("\(Self.describe(request)) 已拒绝（未开启文件与终端访问）")
            return HostRPCResponse(id: request.id, ok: false, error: "shell_disabled")
        }
        log.record(Self.describe(request))
        switch op {
        case "info": return info(request)
        case "fs.list": return list(request)
        case "fs.read": return read(request)
        case "exec.cancel": return await cancel(request)
        default: return await exec(request)
        }
    }

    // MARK: Operations

    private func info(_ request: HostRPCRequest) -> HostRPCResponse {
        let cwd = resolve(request.cwd ?? request.path, base: homeDirectory)
        #if os(macOS)
        let git = gitStatus(cwd: cwd)
        #else
        let git: (branch: String, dirty: Int)? = nil
        #endif
        let hostName = ProcessInfo.processInfo.hostName
        let user = NSUserName()
        return HostRPCResponse(
            id: request.id,
            ok: true,
            info: HostInfo(
                hostName: hostName,
                user: user,
                home: homeDirectory,
                cwd: cwd,
                gitBranch: git?.branch,
                gitDirty: git?.dirty
            )
        )
    }

    private func list(_ request: HostRPCRequest) -> HostRPCResponse {
        let directory = resolve(request.path, base: resolve(request.cwd, base: homeDirectory))
        let url = URL(fileURLWithPath: directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return HostRPCResponse(id: request.id, ok: false, error: "not_found")
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            return HostRPCResponse(id: request.id, ok: false, error: "not_found")
        }
        var entries: [HostFSEntry] = []
        var truncated = false
        for name in names {
            guard entries.count < Self.entryCap else { truncated = true; break }
            let child = url.appendingPathComponent(name)
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            entries.append(HostFSEntry(
                name: name,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize,
                modified: values?.contentModificationDate
            ))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return HostRPCResponse(id: request.id, ok: true, entries: entries, truncated: truncated ? true : nil, cwd: directory)
    }

    private func read(_ request: HostRPCRequest) -> HostRPCResponse {
        guard let raw = request.path, !raw.isEmpty else {
            return HostRPCResponse(id: request.id, ok: false, error: "bad_request")
        }
        let path = resolve(raw, base: resolve(request.cwd, base: homeDirectory))
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return HostRPCResponse(id: request.id, ok: false, error: "not_found")
        }
        let cap = min(max(request.maxBytes ?? Self.outputCap, 1), Self.outputCap)
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return HostRPCResponse(id: request.id, ok: false, error: "not_found")
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: cap + 1)
        let truncated = data.count > cap
        let kept = truncated ? data.prefix(cap) : data[...]
        let text = String(decoding: kept, as: UTF8.self)
        return HostRPCResponse(id: request.id, ok: true, text: text, truncated: truncated ? true : nil)
    }

    #if os(macOS)
    private func exec(_ request: HostRPCRequest) async -> HostRPCResponse {
        guard let command = request.command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return HostRPCResponse(id: request.id, ok: false, error: "bad_request")
        }
        let cwd = resolve(request.cwd, base: homeDirectory)
        guard FileManager.default.fileExists(atPath: cwd) else {
            return HostRPCResponse(id: request.id, ok: false, error: "not_found", cwd: cwd)
        }
        let timeout = min(max(request.timeout ?? Self.defaultTimeout, 0.1), Self.maxTimeout)
        let marker = "OMPHOST_CWD_\(UUID().uuidString)"
        let wrapped = "{ \(command)\n }\n__omp_rc=$?\nprintf '\\n\(marker)%s\\n' \"$(pwd)\"\nexit $__omp_rc"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", wrapped]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = Self.childEnvironment(home: homeDirectory)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return HostRPCResponse(id: request.id, ok: false, error: error.localizedDescription, cwd: cwd)
        }

        let cap = Self.outputCap
        async let stdoutData = Self.collect(outPipe.fileHandleForReading, cap: cap)
        async let stderrData = Self.collect(errPipe.fileHandleForReading, cap: cap)

        running.insert(
            RunningExec(process: process, outPipe: outPipe, errPipe: errPipe),
            id: request.id
        )
        defer { running.remove(id: request.id) }

        let finished = await Self.wait(process, timeout: timeout)
        let cancelled = running.wasCancelled(id: request.id)
        if !finished {
            Self.stopTree(of: process, escalated: false)
            if await !Self.finished(process, within: 2) {
                Self.stopTree(of: process, escalated: true)
            }
        }
        let stdout = await stdoutData
        let stderr = await stderrData

        // A cancel kills the tree, so the process ends "normally" as far as
        // `wait` is concerned; report the cancelled outcome — partial output
        // and exit 130 — whichever way the death arrived.
        if cancelled {
            return HostRPCResponse(
                id: request.id, ok: false, error: "cancelled",
                truncated: (stdout.truncated || stderr.truncated) ? true : nil,
                stdout: stdout.text, stderr: stderr.text,
                exitCode: 130, cwd: cwd
            )
        }

        if !finished {
            return HostRPCResponse(
                id: request.id, ok: false,
                error: "timeout",
                truncated: (stdout.truncated || stderr.truncated) ? true : nil,
                stdout: stdout.text, stderr: stderr.text,
                cwd: cwd
            )
        }

        let (clean, resulting) = Self.stripCWDMarker(stdout.text, marker: marker)
        let reported = resulting.map { self.resolve($0, base: cwd) } ?? cwd
        return HostRPCResponse(
            id: request.id,
            ok: true,
            truncated: (stdout.truncated || stderr.truncated) ? true : nil,
            stdout: clean,
            stderr: stderr.text,
            exitCode: Int(process.terminationStatus),
            cwd: reported
        )
    }
    #else
    private func exec(_ request: HostRPCRequest) async -> HostRPCResponse {
        HostRPCResponse(id: request.id, ok: false, error: "unsupported")
    }
    #endif

    /// `exec.cancel`: stop the in-flight exec whose request id is
    /// `requestID`. Unknown or already-finished ids answer `ok: true,
    /// text: "not_running"`, so retries are harmless.
    private func cancel(_ request: HostRPCRequest) async -> HostRPCResponse {
        #if os(macOS)
        guard let target = request.requestID, !target.isEmpty else {
            return HostRPCResponse(id: request.id, ok: false, error: "bad_request")
        }
        guard let run = running.lookup(id: target) else {
            return HostRPCResponse(id: request.id, ok: true, text: "not_running")
        }
        run.markCancelled()
        Self.stopTree(of: run.process, escalated: false)
        return HostRPCResponse(id: request.id, ok: true, text: "cancelling")
        #else
        _ = request
        return HostRPCResponse(id: request.id, ok: false, error: "unsupported")
        #endif
    }

    // MARK: Helpers

    /// Expands `~` and resolves relative paths against `base`. `nil` or empty
    /// input resolves to `base` itself.
    func resolve(_ raw: String?, base: String) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        let expanded: String
        if trimmed.isEmpty {
            expanded = base
        } else if trimmed == "~" {
            expanded = homeDirectory
        } else if trimmed.hasPrefix("~/") {
            expanded = homeDirectory + trimmed.dropFirst(1)
        } else if trimmed.hasPrefix("/") {
            expanded = trimmed
        } else {
            expanded = (base as NSString).appendingPathComponent(trimmed)
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Branch name and dirty-file count for `cwd`, or `nil` outside a repo.
    #if os(macOS)
    private func gitStatus(cwd: String) -> (branch: String, dirty: Int)? {
        let result = Self.runSync("/bin/zsh", arguments: ["-c", "git -C \(Self.shellQuote(cwd)) status --porcelain=v1 -b"], timeout: 5)
        guard result.exitCode == 0 else { return nil }
        var branch: String?
        var dirty = 0
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                let rest = line.dropFirst(3)
                branch = String(rest.prefix(while: { $0 != " " })).split(separator: "...").first.map(String.init)
                if branch?.isEmpty == true { branch = String(rest) }
            } else if !line.isEmpty {
                dirty += 1
            }
        }
        guard let branch else { return nil }
        return (branch, dirty)
    }

    private struct SyncResult { var stdout: String; var exitCode: Int32 }

    /// Bounded synchronous helper for short host-side probes (git status).
    private static func runSync(_ launch: String, arguments: [String], timeout: Double) -> SyncResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        process.environment = childEnvironment(home: realHomeDirectory())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return SyncResult(stdout: "", exitCode: -1) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return SyncResult(stdout: "", exitCode: -1)
        }
        let data = output.fileHandleForReading.readData(ofLength: outputCap)
        return SyncResult(stdout: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus)
    }

    private struct Captured { var text: String; var truncated: Bool }

    /// Reads a pipe until EOF, keeping at most `cap` bytes.
    private static func collect(_ handle: FileHandle, cap: Int) async -> Captured {
        var kept = Data()
        var truncated = false
        let chunk = 64 * 1024
        while true {
            let piece = handle.readData(ofLength: chunk)
            if piece.isEmpty { break }
            if kept.count < cap {
                kept.append(piece.prefix(cap - kept.count))
            }
            if kept.count >= cap { truncated = true }
        }
        return Captured(text: String(decoding: kept, as: UTF8.self), truncated: truncated)
    }

    /// Waits for `process` to exit, returning false when `timeout` elapses first.
    private static func wait(_ process: Process, timeout: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            let box = ResumeBox()
            process.terminationHandler = { _ in
                guard box.claim() else { return }
                continuation.resume(returning: true)
            }
            if !process.isRunning {
                guard box.claim() else { return }
                continuation.resume(returning: true)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard box.claim() else { return }
                continuation.resume(returning: false)
            }
        }
    }
    #endif

    /// Splits the trailing working-directory marker off captured stdout.
    static func stripCWDMarker(_ stdout: String, marker: String) -> (String, String?) {
        guard let range = stdout.range(of: marker, options: .backwards) else { return (stdout, nil) }
        let path = stdout[range.upperBound...].prefix(while: { $0 != "\n" })
        var head = String(stdout[..<range.lowerBound])
        if head.hasSuffix("\n") { head.removeLast() }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, trimmed.isEmpty ? nil : trimmed)
    }

    #if os(macOS)
    /// Single-quotes a path for `zsh -c`, so spaces and quotes survive.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Environment for a child shell: the real home, and a PATH that can see
    /// Homebrew git both on Apple silicon and Intel.
    static func childEnvironment(home: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        let extras = ["/opt/homebrew/bin", "/usr/local/bin"]
        let current = environment["PATH"] ?? "/usr/bin:/bin"
        let missing = extras.filter { !current.split(separator: ":").contains(Substring($0)) }
        if !missing.isEmpty {
            environment["PATH"] = (missing + [current]).joined(separator: ":")
        }
        return environment
    }
    #endif

    /// One log line: operation plus a truncated path or command, never secrets.
    private static func describe(_ request: HostRPCRequest) -> String {
        let detail: String
        if request.op == "exec" {
            detail = String((request.command ?? "").prefix(80))
        } else {
            detail = String((request.path ?? request.cwd ?? "").prefix(120))
        }
        return detail.isEmpty ? request.op : "\(request.op) \(detail)"
    }
}

#if os(macOS)
/// One in-flight `exec`: the process plus what cancel needs to reach it.
final class RunningExec: @unchecked Sendable {
    let process: Process
    let outPipe: Pipe
    let errPipe: Pipe
    private let lock = NSLock()
    private var cancelled = false

    init(process: Process, outPipe: Pipe, errPipe: Pipe) {
        self.process = process
        self.outPipe = outPipe
        self.errPipe = errPipe
    }

    /// Records that a cancel was requested, so the exec answers
    /// `cancelled` instead of `timeout` when it unwinds.
    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Thread-safe map of request id to running exec, shared by `exec` and
/// `exec.cancel`.
public final class RunningExecRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: RunningExec] = [:]

    public init() {}

    func insert(_ run: RunningExec, id: String) {
        lock.lock()
        items[id] = run
        lock.unlock()
    }

    func lookup(id: String) -> RunningExec? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }

    func remove(id: String) {
        lock.lock()
        items.removeValue(forKey: id)
        lock.unlock()
    }

    func wasCancelled(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return items[id]?.isCancelled ?? false
    }
}
#else
/// iOS never runs `exec`, so there is nothing to register; the type exists so
/// `HostExecutor` keeps one initialiser on both platforms.
public final class RunningExecRegistry: @unchecked Sendable {
    public init() {}
}
#endif

// MARK: - Cancel plumbing

extension HostExecutor {
    #if os(macOS)
    /// Signals `process` and every descendant. SIGINT goes to the
    /// descendants first: the wrapper zsh ignores SIGINT aimed at itself,
    /// but dies when its children do (verified: the tree exits 130 with
    /// partial output intact). `escalated` switches to SIGKILL.
    static func stopTree(of process: Process, escalated: Bool) {
        let signal = escalated ? SIGKILL : SIGINT
        for pid in Self.descendants(of: process.processIdentifier) {
            kill(pid, signal)
        }
        if process.isRunning {
            if escalated {
                kill(process.processIdentifier, signal)
            } else {
                process.terminate()
            }
        }
    }

    /// Resolves once `process` is gone or `timeout` elapses. A grace-period
    /// poller, unlike the termination-handler based `wait`.
    static func finished(_ process: Process, within timeout: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }

    /// Every live descendant of `pid`, deepest paths included. One
    /// `sysctl` snapshot; no subprocesses.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        let entries = buffer[..<count]
        var result: [pid_t] = []
        var frontier = [pid]
        while let current = frontier.popLast() {
            for entry in entries where entry.kp_eproc.e_ppid == current {
                result.append(entry.kp_proc.p_pid)
                frontier.append(entry.kp_proc.p_pid)
            }
        }
        return result
    }
    #endif
}

#if os(macOS)
/// One-shot flag so a process's termination handler and the timeout cannot
/// both resume the same continuation.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
#endif

/// Fixed-capacity log of recent remote operations. Shared by the executor and
/// the Settings screen; safe to touch from any thread.
public final class RemoteOperationLog: @unchecked Sendable {
    public static let capacity = 20
    private let lock = NSLock()
    private var records: [RemoteOperationRecord] = []

    public init() {}

    public func record(_ summary: String) {
        lock.lock()
        defer { lock.unlock() }
        records.append(RemoteOperationRecord(summary: summary))
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
    }

    public func snapshot() -> [RemoteOperationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
