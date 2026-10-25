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

/// Executes host RPC on the Mac: `info`, `fs.list`, `fs.read`, and `exec`.
///
/// `info` always runs. Everything else answers `shell_disabled` unless
/// [`shellAllowed`] (backed by `AppSettings.relayAllowShell`) is true.
/// `exec` runs `/bin/zsh -c` and reports the resulting working directory, so
/// a `cd` survives into the next call when the client sends `cwd` back.
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
    public init(
        shellAllowed: Bool,
        homeDirectory: String? = nil,
        log: RemoteOperationLog? = nil
    ) {
        self.shellAllowed = shellAllowed
        self.homeDirectory = homeDirectory ?? Self.realHomeDirectory()
        self.log = log ?? RemoteOperationLog()
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
        guard op == "info" || op == "fs.list" || op == "fs.read" || op == "exec" else {
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

        let finished = await Self.wait(process, timeout: timeout)
        if !finished {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let stdout = await stdoutData
        let stderr = await stderrData

        if !finished {
            return HostRPCResponse(
                id: request.id, ok: false, error: "timeout",
                truncated: (stdout.truncated || stderr.truncated) ? true : nil,
                stdout: stdout.text, stderr: stderr.text, cwd: cwd
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
