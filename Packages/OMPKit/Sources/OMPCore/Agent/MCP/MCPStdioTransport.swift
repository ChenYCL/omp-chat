#if os(macOS)
import Darwin
import Foundation

/// MCP stdio: the server is a child process speaking newline-delimited
/// JSON-RPC on stdin/stdout, with free-form logging on stderr.
///
/// Pipes are read on dedicated threads with blocking `read`, which returns as
/// soon as bytes exist; `FileHandle.readabilityHandler` never fires without a
/// run loop. stderr goes into a ring of the last 200 lines for the settings
/// log and failure messages.
public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    public struct Launch: Equatable, Sendable {
        /// Absolute path; the sandbox can only spawn binaries by full path.
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: String?

        public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String? = nil) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
        }
    }

    /// Signals a process and its descendants; `escalated` means SIGKILL.
    /// The app passes `HostExecutor.stopTree` so there is one copy of it.
    public typealias TreeStopper = @Sendable (Process, _ escalated: Bool) -> Void

    public static let stderrLines = 200
    /// Grace period after closing stdin, and again after terminating.
    public static let shutdownGrace: Double = 2

    private let launch: Launch
    private let stopTree: TreeStopper
    private let maxLineBytes: Int
    private let writeQueue = DispatchQueue(label: "omp.mcp.stdio.write")

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var log = MCPLogRing(capacity: MCPStdioTransport.stderrLines)
    private var stopping = false

    public init(launch: Launch, stopTree: @escaping TreeStopper, maxLineBytes: Int = MCPLineFramer.defaultMaxLineBytes) {
        self.launch = launch
        self.stopTree = stopTree
        self.maxLineBytes = maxLineBytes
    }

    public func connect() async throws -> AsyncStream<MCPTransportEvent> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        if let directory = launch.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw MCPError.notConnected("无法启动 \(launch.executable)：\(error.localizedDescription)")
        }
        // A server that exits without reading must not SIGPIPE the app.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        lock.withLock {
            self.process = process
            self.input = stdinPipe.fileHandleForWriting
        }

        let (stream, continuation) = AsyncStream.makeStream(of: MCPTransportEvent.self)
        let stderrDone = DispatchSemaphore(value: 0)
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [self] in
            Self.pump(errFD) { chunk in self.lock.withLock { self.log.append(chunk) } }
            stderrDone.signal()
        }
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let cap = maxLineBytes
        Thread.detachNewThread { [self] in
            var framer = MCPLineFramer(maxLineBytes: cap)
            let deliver: ([MCPLineFramer.Output]) -> Void = { outputs in
                for output in outputs {
                    switch output {
                    case .line(let line):
                        continuation.yield(.message(line))
                    case .oversize(let bytes):
                        self.lock.withLock { self.log.note("[OMPChat] 丢弃了一条 \(bytes) 字节的超长消息") }
                    }
                }
            }
            Self.pump(outFD) { deliver(framer.push($0)) }
            deliver(framer.finish())
            // stdout is closed. Let stderr drain so the failure message has
            // the last words, then report how the process ended.
            _ = stderrDone.wait(timeout: .now() + 1)
            let reason = self.exitReason(of: process)
            continuation.yield(.closed(reason: reason))
            continuation.finish()
        }
        return stream
    }

    public func send(_ message: Data) async throws {
        guard let input = lock.withLock({ self.input }) else { throw MCPError.closed("服务器进程已退出") }
        var payload = message
        payload.append(0x0A)
        let fd = input.fileDescriptor
        // A serial queue keeps frames whole and in order, and a server that
        // stops reading blocks this queue instead of a concurrency thread.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                if Self.writeAll(fd, payload) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MCPError.closed("服务器进程已退出"))
                }
            }
        }
    }

    /// Close stdin, give the server 2 s to exit, terminate the tree, give it
    /// 2 s more, then kill the tree.
    public func close() async {
        let (process, input): (Process?, FileHandle?) = lock.withLock {
            stopping = true
            defer { self.input = nil }
            return (self.process, self.input)
        }
        guard let process else { return }
        // Wait for queued writes so closing cannot race a write on the fd.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async { continuation.resume() }
        }
        try? input?.close()
        if await Self.exited(process, within: Self.shutdownGrace) { return }
        stopTree(process, false)
        if await Self.exited(process, within: Self.shutdownGrace) { return }
        stopTree(process, true)
    }

    public func diagnostics() -> [String] {
        lock.withLock { log.tail }
    }

    /// The child's pid while it runs (tests use it to simulate crashes).
    public var processIdentifier: Int32? {
        lock.withLock { process?.isRunning == true ? process?.processIdentifier : nil }
    }

    // MARK: Internals

    private func exitReason(of process: Process) -> String {
        // stdout can close a moment before the exit status is reaped.
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if lock.withLock({ stopping }) { return "已停止" }
        if process.isRunning {
            // It closed stdout but kept running; it cannot talk to us anymore.
            stopTree(process, true)
            return "服务器关闭了输出"
        }
        let status = process.terminationStatus
        switch process.terminationReason {
        case .uncaughtSignal: return "服务器进程被信号 \(status) 终止"
        default: return "服务器进程已退出（状态码 \(status)）"
        }
    }

    /// Reads `fd` until EOF, handing each chunk to `body`.
    private static func pump(_ fd: Int32, _ body: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            body(Data(buffer[0..<count]))
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }

    private static func exited(_ process: Process, within seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }
}
#endif
