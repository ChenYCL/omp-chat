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

/// Executes host RPC on the Mac: `info`, `fs.list`, `fs.read`, `exec`,
/// `exec.cancel`, and `exec.poll`.
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
/// `exec` with `background: true` answers `ok: true, text: "started"`
/// immediately and keeps running under its request id; `exec.poll` with that
/// id returns the output appended since the caller's byte `offset` (stdout
/// and stderr merged in arrival order) as `text`, the cursor as
/// `nextOffset`, and `done` — with the final `exitCode` and cd-tracked
/// `cwd` — once the run has ended.
public struct HostExecutor: Sendable {
    /// Hard cap on a single stdout or stderr capture.
    public static let outputCap = 256 * 1024
    /// Hard cap on one background run's combined output ring. Beyond it the
    /// oldest bytes are dropped and polls answer `truncated: true`.
    public static let streamCap = 1024 * 1024
    /// Finished background runs stay pollable for this long, then are evicted.
    public static let pollRetention: TimeInterval = 60
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
    /// How long a finished background run stays pollable. Tests inject a
    /// short window; production uses [`pollRetention`].
    private let pollRetention: TimeInterval

    public init(
        shellAllowed: Bool,
        homeDirectory: String? = nil,
        log: RemoteOperationLog? = nil,
        running: RunningExecRegistry? = nil,
        pollRetention: TimeInterval? = nil
    ) {
        self.shellAllowed = shellAllowed
        self.homeDirectory = homeDirectory ?? Self.realHomeDirectory()
        self.log = log ?? RemoteOperationLog()
        self.running = running ?? RunningExecRegistry()
        self.pollRetention = pollRetention ?? Self.pollRetention
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

    /// - Parameter allowingShell: overrides `shellAllowed` for this call. The
    ///   desktop's own windows use it: the person at the keyboard should not
    ///   have to enable the phone's access switch to see their own sessions.
    public func handle(_ request: HostRPCRequest, allowingShell: Bool? = nil) async -> HostRPCResponse {
        let op = request.op
        guard op == "info" || op == "fs.list" || op == "fs.read" || op == "fs.write" || op == "exec"
            || op == "exec.cancel" || op == "exec.poll" || op == "cli.sessions" || op == "cli.control" else {
            return HostRPCResponse(id: request.id, ok: false, error: "bad_request")
        }
        if op != "info", !(allowingShell ?? shellAllowed) {
            log.record("\(Self.describe(request)) 已拒绝（未开启文件与终端访问）")
            return HostRPCResponse(id: request.id, ok: false, error: "shell_disabled")
        }
        if op == "exec.poll" {
            guard let target = request.requestID, !target.isEmpty, request.offset ?? 0 >= 0 else {
                return HostRPCResponse(id: request.id, ok: false, error: "bad_request")
            }
            log.record(Self.describe(request))
            return await poll(request, id: target, offset: request.offset ?? 0)
        }
        log.record(Self.describe(request))
        switch op {
        case "info": return info(request)
        case "fs.list": return list(request)
        case "fs.read": return read(request)
        case "fs.write": return write(request)
        case "exec.cancel": return await cancel(request)
        case "cli.sessions": return await cliSessions(request)
        case "cli.control": return await cliControl(request)
        default: return await exec(request)
        }
    }

    /// `fs.write`: replaces a file's contents. Refuses directories and
    /// paths that do not exist, so the phone can only edit a file it could
    /// already read. Capped at the same 256 KB as `fs.read`.
    private func write(_ request: HostRPCRequest) -> HostRPCResponse {
        let target = resolve(request.path, base: resolve(request.cwd, base: homeDirectory))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else {
            return HostRPCResponse(id: request.id, ok: false, error: "not_found")
        }
        guard !isDir.boolValue else {
            return HostRPCResponse(id: request.id, ok: false, error: "bad_request")
        }
        let text = request.prompt ?? ""
        guard text.utf8.count <= Self.outputCap else {
            return HostRPCResponse(id: request.id, ok: false, error: "too_large")
        }
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: target), options: .atomic)
        } catch {
            return HostRPCResponse(id: request.id, ok: false, error: error.localizedDescription)
        }
        return HostRPCResponse(id: request.id, ok: true)
    }

    /// `cli.sessions`: lists the coding-agent sessions the Mac is running, by
    /// asking each agent's own CLI and parsing its machine-readable output.
    /// Agents the binary cannot reach come back as an error string in `text`,
    /// not as invented sessions.
    private func cliSessions(_ request: HostRPCRequest) async -> HostRPCResponse {
        #if os(macOS)
        let agent = request.command ?? "claude"
        guard agent == "claude" else {
            return HostRPCResponse(id: request.id, ok: false, error: "unsupported", text: "暂不支持 \(agent)")
        }
        let listed = await exec(HostRPCRequest(
            id: "\(request.id)-list", op: "exec",
            command: "claude agents --json", cwd: homeDirectory, timeout: 20
        ))
        guard listed.ok, let stdout = listed.stdout else {
            return HostRPCResponse(id: request.id, ok: false, error: listed.error ?? "exec_failed", text: listed.stderr)
        }
        // `exec` already strips its cwd marker, so stdout is the CLI's own JSON.
        let sessions = CLISessionListing.claude(json: Data(stdout.utf8))
        return HostRPCResponse(id: request.id, ok: true, sessions: sessions)
        #else
        return HostRPCResponse(id: request.id, ok: false, error: "unsupported")
        #endif
    }

    /// `cli.control`: acts on one coding-agent session. Argv comes from
    /// `CLISessionListing.command` (so the phone can only reach the exact verbs
    /// listed there), the session id is checked against a strict charset, and
    /// every argument is single-quoted before it reaches the shell.
    private func cliControl(_ request: HostRPCRequest) async -> HostRPCResponse {
        #if os(macOS)
        let agent = request.command ?? "claude"
        guard let action = request.path.flatMap(CLISessionAction.init(rawValue:)) else {
            return HostRPCResponse(id: request.id, ok: false, error: "bad_request", text: "未知操作")
        }
        let sessionID = request.requestID
        if let sessionID {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard !sessionID.isEmpty, sessionID.count <= 64,
                  sessionID.unicodeScalars.allSatisfy(allowed.contains) else {
                return HostRPCResponse(id: request.id, ok: false, error: "bad_request", text: "会话 id 不合法")
            }
        }
        guard let argv = CLISessionListing.command(agent: agent, action: action, id: sessionID, prompt: request.prompt) else {
            let known = agent == "claude"
            return HostRPCResponse(
                id: request.id, ok: false,
                error: known ? "bad_request" : "unsupported",
                text: known ? "缺少必要参数" : "暂不支持 \(agent)"
            )
        }
        let result = await exec(HostRPCRequest(
            id: "\(request.id)-ctl", op: "exec",
            command: argv.map(Self.shellQuote).joined(separator: " "),
            cwd: request.cwd ?? homeDirectory, timeout: 30
        ))
        let output = [result.stdout, result.stderr].compactMap { $0 }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // The CLI refuses to run in a folder whose trust prompt was never
        // accepted, and still exits 0 — surface that instead of "success".
        if output.localizedCaseInsensitiveContains("not trusted") {
            return HostRPCResponse(id: request.id, ok: false, error: "workspace_not_trusted", text: output, cwd: result.cwd)
        }
        guard result.ok else {
            return HostRPCResponse(id: request.id, ok: false, error: result.error ?? "exec_failed", text: output)
        }
        let failed = (result.exitCode ?? 0) != 0
        return HostRPCResponse(
            id: request.id, ok: !failed, error: failed ? "command_failed" : nil,
            text: output, truncated: result.truncated, exitCode: result.exitCode
        )
        #else
        return HostRPCResponse(id: request.id, ok: false, error: "unsupported")
        #endif
    }

    // MARK: Operations

    /// "arm64" reads better as "Apple 芯片" on Apple Silicon; anything else
    /// (Intel) is shown as reported.
    static func chipName() -> String {
        #if arch(arm64)
        return "Apple 芯片"
        #else
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #endif
    }

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
                gitDirty: git?.dirty,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                chip: Self.chipName(),
                memoryBytes: Int(ProcessInfo.processInfo.physicalMemory)
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
        if request.background == true {
            return startBackground(request, command: command, cwd: cwd)
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
        if running.cancelRun(id: target) {
            if let run = running.lookupRun(id: target) {
                Self.stopTree(of: run.process, escalated: false)
            }
            return HostRPCResponse(id: request.id, ok: true, text: "cancelling")
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

    #if os(macOS)
    /// `background: true` exec: launch and answer `started` at once. The
    /// drain task appends output into the run's ring and marks the run done
    /// when the pipes close and the process exits.
    private func startBackground(_ request: HostRPCRequest, command: String, cwd: String) -> HostRPCResponse {
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
        let run = BackgroundRun(
            process: process,
            startCwd: cwd,
            marker: marker,
            cap: Self.streamCap,
            timeout: min(max(request.timeout ?? Self.maxTimeout, 0.1), Self.maxTimeout)
        )
        guard running.insertRun(run, id: request.id) else {
            // The id already fronts a run; do not leak this process.
            Self.stopTree(of: process, escalated: true)
            return HostRPCResponse(id: request.id, ok: false, error: "id_in_use", cwd: cwd)
        }
        Task.detached(priority: .utility) {
            await Self.drain(run: run, process: process)
        }
        return HostRPCResponse(id: request.id, ok: true, text: "started")
    }

    /// Pumps both pipes into the run's ring until EOF, then closes the run.
    ///
    /// One thread per pipe doing a blocking POSIX `read`: it returns as soon
    /// as any bytes are available, which is what makes polls incremental.
    /// `FileHandle.read(upToCount:)` and `readData(ofLength:)` both wait for
    /// their full length and would coalesce a slow command into one chunk,
    /// and a readability handler never fires from a task with no run loop.
    private static func drain(run: BackgroundRun, process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = PipeEOFBox()
            for handle in [run.outPipe.fileHandleForReading, run.errPipe.fileHandleForReading] {
                let fd = handle.fileDescriptor
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        if count <= 0 { break }
                        run.append(Data(buffer.prefix(count)))
                    }
                    if box.noteClosed() { continuation.resume() }
                }
            }
        }
        // Both pipes are at EOF; the process may still be reaping its exit
        // status. Wait for it so polls report the real exit code.
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        run.close(exitCode: process.isRunning ? nil : Int(process.terminationStatus))
    }
    #endif


    /// Longest `exec.poll` hold. Well under the hub's 130 s RPC timeout and the
    /// phone's request timeout, so a held poll never looks like a dead host.
    static let maxPollWait: Double = 25

    /// `exec.poll`: the appended slice since `offset`, cursor and state.
    private func poll(_ request: HostRPCRequest, id: String, offset: Int) async -> HostRPCResponse {
        running.evictFinished(olderThan: pollRetention)
        guard let run = running.lookupRun(id: id) else {
            return HostRPCResponse(id: request.id, ok: false, error: "not_found")
        }
        // Long-poll: hold an empty answer until bytes arrive, the run ends or
        // the wait elapses, so a caller sees output when it is written rather
        // than on its next poll tick.
        let wait = min(max(request.wait ?? 0, 0), Self.maxPollWait)
        if wait > 0 {
            let deadline = Date().addingTimeInterval(wait)
            // Wait on what the caller would see, not on raw bytes: the trailing
            // cwd marker lands before close() and is withheld from running
            // slices, so counting bytes released an empty, not-done answer.
            while run.state == .running, run.snapshot(after: offset).text.isEmpty, !run.isExpired(),
                  Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(15))
            }
        }
        let slice = run.snapshot(after: offset)
        if run.state == .running, run.isExpired() {
            // The caller polled past the run's timeout: kill the tree and
            // answer the failure on this same poll.
            #if os(macOS)
            Self.stopTree(of: run.process, escalated: false)
            if await !Self.finished(run.process, within: 2) {
                Self.stopTree(of: run.process, escalated: true)
            }
            #endif
            run.close(exitCode: nil)
            return HostRPCResponse(
                id: request.id, ok: false, error: "timeout",
                text: slice.text, truncated: slice.truncated ? true : nil,
                cwd: run.startCwd, nextOffset: slice.nextOffset, done: true
            )
        }
        if run.state != .running {
            let exitCode = run.cancelled ? 130 : run.exitCode
            let ok = exitCode != nil
            let cwd = run.finalCwd.map { resolve($0, base: run.startCwd) } ?? run.startCwd
            return HostRPCResponse(
                id: request.id, ok: ok, error: ok ? nil : "timeout",
                text: slice.text, truncated: slice.truncated ? true : nil,
                exitCode: exitCode, cwd: cwd,
                nextOffset: slice.nextOffset, done: true
            )
        }
        return HostRPCResponse(
            id: request.id, ok: true, text: slice.text,
            truncated: slice.truncated ? true : nil, nextOffset: slice.nextOffset,
            done: false
        )
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
        // A Finder-launched app inherits launchd's minimal PATH. Agent CLIs
        // install per user (claude → ~/.local/bin, omp → ~/.bun/bin), so look
        // in the account's real home, not the injected one tests use.
        let user = realHomeDirectory()
        let extras = ["\(user)/.local/bin", "\(user)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
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
/// `exec.cancel`. Background runs (`exec.poll`) live in a second map so the
/// foreground drain path never has to look at them.
public final class RunningExecRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: RunningExec] = [:]
    private var runs: [String: BackgroundRun] = [:]

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

    // MARK: Background runs

    /// Registers a background run unless its id is taken; false means the id
    /// already fronts a run (the caller answers `id_in_use`).
    func insertRun(_ run: BackgroundRun, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if runs[id] != nil { return false }
        runs[id] = run
        return true
    }

    func lookupRun(id: String) -> BackgroundRun? {
        lock.lock()
        defer { lock.unlock() }
        return runs[id]
    }

    func cancelRun(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let run = runs[id] else { return false }
        run.markCancelled()
        return true
    }

    /// Drops finished runs whose retention window has elapsed, so finished
    /// work cannot accumulate.
    func evictFinished(olderThan interval: TimeInterval) {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-interval)
        runs = runs.filter { _, run in
            if run.state == .running { return true }
            return run.finishedAt.map { $0 > cutoff } ?? true
        }
        lock.unlock()
    }
}
#else
/// iOS never runs `exec`, so there is nothing to register; the type exists so
/// `HostExecutor` keeps one initialiser on both platforms.
public final class RunningExecRegistry: @unchecked Sendable {
    public init() {}

    func lookupRun(id: String) -> BackgroundRun? { nil }
    func cancelRun(id: String) -> Bool { false }
    func evictFinished(olderThan interval: TimeInterval) {}
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

/// Counts the two background pipes closing, so the drain resumes exactly
/// once both have reached EOF.
private final class PipeEOFBox: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = 0

    func noteClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        closed += 1
        return closed == 2
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

// MARK: - Background runs

/// One background `exec`: the process, both pipes, and the output ring that
/// `exec.poll` slices. macOS-only; iOS gets the stubs below so every symbol
/// `HostExecutor` touches exists on both platforms.
#if os(macOS)
final class BackgroundRun: @unchecked Sendable {
    let process: Process
    let outPipe: Pipe
    let errPipe: Pipe
    let startCwd: String
    let marker: String
    let cap: Int
    let timeout: TimeInterval
    let startedAt = Date()

    private let lock = NSLock()
    private var ring = StreamRing()
    private var phase: Phase = .running
    private var endedAt: Date?
    private var cancelledFlag = false
    private var exitCodeValue: Int?
    private var finalCwdValue: String?

    enum Phase { case running, finished, timedOut }

    init(process: Process, startCwd: String, marker: String, cap: Int, timeout: TimeInterval) {
        self.process = process
        self.outPipe = process.standardOutput as! Pipe
        self.errPipe = process.standardError as! Pipe
        self.startCwd = startCwd
        self.marker = marker
        self.cap = cap
        self.timeout = timeout
    }

    /// The slice of combined output after `offset`, plus the cursor the next
    /// poll must pass.
    struct Slice { var text: String; var nextOffset: Int; var truncated: Bool }

    var state: Phase { lock.lock(); defer { lock.unlock() }; return phase }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }
    var exitCode: Int? { lock.lock(); defer { lock.unlock() }; return exitCodeValue }
    var finalCwd: String? { lock.lock(); defer { lock.unlock() }; return finalCwdValue }
    var finishedAt: Date? { lock.lock(); defer { lock.unlock() }; return endedAt }
    var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return ring.total }

    func markCancelled() {
        lock.lock(); cancelledFlag = true; lock.unlock()
    }

    func isExpired() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return phase == .running && Date().timeIntervalSince(startedAt) > timeout
    }

    /// Appends raw bytes from one pipe. Chunks from both pipes land here in
    /// arrival order.
    func append(_ data: Data) {
        lock.lock(); ring.append(data, cap: cap); lock.unlock()
    }

    /// Marks the run finished. `exitCode == nil` means it was killed for
    /// running past its timeout.
    func close(exitCode: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .running else { return }
        exitCodeValue = exitCode
        if let (clean, cwd) = ring.stripMarker(marker) {
            ring.replace(clean)
            finalCwdValue = cwd
        }
        phase = exitCode == nil ? .timedOut : .finished
        endedAt = Date()
    }

    func snapshot(after offset: Int) -> Slice {
        lock.lock(); defer { lock.unlock() }
        let slice = ring.slice(after: offset, cap: cap)
        guard phase == .running else { return slice }
        return Self.withholdingMarker(slice, tag: "\n" + marker)
    }

    /// While the run is still open, the wrapper's trailing `\n<marker><cwd>`
    /// can already be buffered before `close()` strips it. Cut the slice at
    /// the tag (or at a trailing partial tag) so a poll never shows it; the
    /// cursor stops there, and the next poll after close resumes cleanly.
    static func withholdingMarker(_ slice: Slice, tag: String) -> Slice {
        var slice = slice
        let text = slice.text
        var cut: String.Index?
        if let found = text.range(of: tag) {
            cut = found.lowerBound
        } else {
            for length in stride(from: min(tag.count, text.count), through: 1, by: -1) {
                if text.hasSuffix(tag.prefix(length)) {
                    cut = text.index(text.endIndex, offsetBy: -length)
                    break
                }
            }
        }
        guard let cut else { return slice }
        slice.nextOffset -= text[cut...].utf8.count
        slice.text = String(text[..<cut])
        return slice
    }
}
#else
/// iOS never runs shell commands, so a background run is only a shape the
/// poll path can type-check against.
final class BackgroundRun: @unchecked Sendable {
    enum Phase { case running, finished, timedOut }
    struct Slice { var text: String; var nextOffset: Int; var truncated: Bool }
    /// The poll path resolves a finished run's cwd against this on both
    /// platforms, so the stub must expose it too.
    let startCwd: String

    init(startCwd: String) { self.startCwd = startCwd }
    var state: Phase { .running }
    var cancelled: Bool { false }
    var exitCode: Int? { nil }
    var finalCwd: String? { nil }
    var finishedAt: Date? { nil }
    var totalBytes: Int { 0 }
    func isExpired() -> Bool { false }
    func markCancelled() {}
    func close(exitCode: Int?) {}
    func snapshot(after offset: Int) -> Slice { Slice(text: "", nextOffset: offset, truncated: false) }
}
#endif

/// Byte ring for one background run's combined output. Not thread-safe: the
/// owning `BackgroundRun` serialises every call under its own lock.
///
/// The buffer never grows past `cap`. When it would, the oldest bytes are
/// dropped and `base` (the logical index of byte 0) advances, so a caller's
/// offset keeps meaning "how many bytes I have seen".
private struct StreamRing {
    private var bytes = Data()
    private var base = 0

    /// Logical length of the stream so far, including dropped bytes.
    var total: Int { base + bytes.count }

    mutating func append(_ data: Data, cap: Int) {
        bytes.append(data)
        if bytes.count > cap {
            let drop = bytes.count - cap
            bytes.removeFirst(drop)
            base += drop
        }
    }

    /// Replaces the buffer wholesale when the cwd marker is stripped at
    /// close. The logical cursor is left where it is, so a caller who already
    /// read past the end gets nothing back rather than a replay.
    mutating func replace(_ data: Data) {
        bytes = data
    }

    func slice(after offset: Int, cap: Int) -> BackgroundRun.Slice {
        let start = max(offset, base)
        var from = start - base
        // A poll landing inside a multi-byte character skips its tail; the
        // previous poll already delivered the head.
        // A caller may pass an offset that is past the end (the ring was
        // replaced) or inside a dropped prefix; both must clamp instead of
        // trapping on bytes[from..<end].
        if from > bytes.count { from = bytes.count }
        if from > 0 {
            while from < bytes.count, Self.isContinuation(bytes[from]) { from += 1 }
        }
        // Hold back a trailing partial character so the next poll completes it.
        var end = bytes.count
        if end > from {
            var index = end - 1
            while index > from, Self.isContinuation(bytes[index]) { index -= 1 }
            if index >= from, end - index < Self.sequenceLength(bytes[index]) { end = index }
        }
        if end < from { end = from }
        let text = String(decoding: bytes[from..<end], as: UTF8.self)
        return BackgroundRun.Slice(text: text, nextOffset: base + end, truncated: base > 0)
    }

    private static func isContinuation(_ byte: UInt8) -> Bool { byte & 0b1100_0000 == 0b1000_0000 }

    private static func sequenceLength(_ lead: UInt8) -> Int {
        if lead & 0b1000_0000 == 0 { return 1 }
        if lead & 0b1110_0000 == 0b1100_0000 { return 2 }
        if lead & 0b1111_0000 == 0b1110_0000 { return 3 }
        if lead & 0b1111_1000 == 0b1111_0000 { return 4 }
        return 1
    }

    /// Pulls the trailing cwd marker out of the buffer, returning the output
    /// without it and the path it recorded. `nil` when the marker is absent.
    func stripMarker(_ marker: String) -> (Data, String)? {
        let text = String(decoding: bytes, as: UTF8.self)
        let (clean, cwd) = HostExecutor.stripCWDMarker(text, marker: marker)
        guard let cwd else { return nil }
        return (Data(clean.utf8), cwd)
    }
}
