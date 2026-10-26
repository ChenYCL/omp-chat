import XCTest
import OMPCore
@testable import OMPChatUI

/// The MCP client against a real child process: a small Python server the
/// test writes to a temporary folder. It runs through the same stdio
/// transport, child environment and process-tree stop the app uses, so a
/// framing, lifecycle or restart bug shows up here as it would with npx.
final class MCPStdioEndToEndTests: XCTestCase {
    private var directory: URL!
    private var python: String!

    private static let server = #"""
    import base64, json, os, sys, time

    with open(os.environ["MOCK_STARTS"], "a") as f:
        f.write("start\n")
    if os.environ.get("MOCK_CRASH_ON_START"):
        sys.stderr.write("startup failure: missing config\n")
        sys.stderr.flush()
        sys.exit(7)

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    def result(mid, value):
        send({"jsonrpc": "2.0", "id": mid, "result": value})

    def text(mid, value, is_error=False):
        result(mid, {"content": [{"type": "text", "text": value}], "isError": is_error})

    schema = {"type": "object", "properties": {"text": {"type": "string"}}}
    page1 = [{"name": "echo", "description": "Echo text", "inputSchema": schema}]
    page2 = [{"name": n, "inputSchema": {"type": "object"}} for n in
             ["fail", "image", "add_tool", "ping_me", "crash", "hang", "cancelled_log", "env"]]
    extra = []
    cancelled = []
    asking = None

    while True:
        line = sys.stdin.readline()
        if not line:
            break
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        if method == "initialize":
            version = os.environ.get("MOCK_VERSION") or msg["params"]["protocolVersion"]
            result(mid, {"protocolVersion": version, "capabilities": {"tools": {"listChanged": True}},
                         "serverInfo": {"name": "mock", "version": "1"}})
        elif method == "tools/list":
            if not (msg.get("params") or {}).get("cursor"):
                result(mid, {"tools": page1, "nextCursor": "page-2"})
            else:
                # One message written in two halves: the client must buffer.
                body = json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"tools": page2 + extra}})
                half = len(body) // 2
                sys.stdout.write(body[:half]); sys.stdout.flush()
                time.sleep(0.05)
                sys.stdout.write(body[half:] + "\n"); sys.stdout.flush()
        elif method == "tools/call":
            name, args = msg["params"]["name"], msg["params"].get("arguments") or {}
            if name == "echo":
                text(mid, args.get("text", ""))
            elif name == "fail":
                text(mid, "it broke", True)
            elif name == "image":
                result(mid, {"content": [
                    {"type": "image", "data": base64.b64encode(b"\x89PNG-mock").decode(), "mimeType": "image/png"},
                    {"type": "resource", "resource": {"uri": "file:///a.txt", "mimeType": "text/plain", "text": "inside"}},
                    {"type": "resource_link", "uri": "file:///b.txt", "name": "b.txt"}]})
            elif name == "add_tool":
                extra.append({"name": "added", "inputSchema": {"type": "object"}})
                # Notification and response in a single write.
                note = {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}
                reply = {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "ok"}]}}
                sys.stdout.write(json.dumps(note) + "\n" + json.dumps(reply) + "\n"); sys.stdout.flush()
            elif name == "ping_me":
                asking = {"call": mid, "answers": {}}
                send({"jsonrpc": "2.0", "id": "srv-ping", "method": "ping"})
                send({"jsonrpc": "2.0", "id": 99, "method": "sampling/createMessage", "params": {}})
            elif name == "crash":
                sys.stderr.write("boom: simulated crash\n"); sys.stderr.flush()
                os._exit(3)
            elif name == "hang":
                pass
            elif name == "cancelled_log":
                text(mid, json.dumps(cancelled))
            elif name == "env":
                text(mid, os.environ.get(args["name"], "<unset>"))
        elif method == "notifications/cancelled":
            cancelled.append(msg["params"]["requestId"])
        elif method is None and mid is not None and asking is not None:
            asking["answers"][mid] = msg
            if len(asking["answers"]) == 2:
                ping = asking["answers"]["srv-ping"].get("result")
                code = asking["answers"][99].get("error", {}).get("code")
                text(asking["call"], "ping=%s sampling=%s" % ("ok" if ping == {} else ping, code))
                asking = None
    """#

    override func setUpWithError() throws {
        let environment = HostExecutor.childEnvironment(home: HostExecutor.realHomeDirectory())
        guard let found = MCPLaunchPlanner.locate("python3", path: environment["PATH"] ?? "", home: HostExecutor.realHomeDirectory()) else {
            throw XCTSkip("python3 is not installed")
        }
        python = found
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.server.write(to: directory.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var startsFile: URL { directory.appendingPathComponent("starts.log") }

    private func startCount() -> Int {
        ((try? String(contentsOf: startsFile, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    /// A connection to the mock server, launched exactly as `MCPManager` does.
    private func makeConnection(
        env: [String: String] = [:], vault: [String: String] = [:],
        timeouts: MCPClient.Timeouts = MCPClient.Timeouts(initialize: .seconds(15), list: .seconds(10), call: .seconds(10)),
        policy: MCPRestartPolicy = MCPRestartPolicy(maxRestarts: 3, backoff: [.milliseconds(200)])
    ) -> (MCPServerConnection, SnapshotLog) {
        var config = MCPServerConfig(id: "mock", name: "Mock", command: python, args: ["-u", "-I", directory.appendingPathComponent("server.py").path])
        config.env = env.merging(["MOCK_STARTS": startsFile.path]) { a, _ in a }
        let home = HostExecutor.realHomeDirectory()
        let environment = MCPLaunchPlanner.environment(
            base: HostExecutor.childEnvironment(home: home), config: config, secret: { vault[$0] }
        )
        let launch = MCPStdioTransport.Launch(executable: python, arguments: config.args, environment: environment,
                                              workingDirectory: MCPLaunchPlanner.workingDirectory(for: config, home: home))
        let log = SnapshotLog()
        let connection = MCPServerConnection(config: config, timeouts: timeouts, policy: policy, makeTransport: {
            MCPStdioTransport(launch: launch, stopTree: { HostExecutor.stopTree(of: $0, escalated: $1) })
        }, onChange: { log.append($0) })
        return (connection, log)
    }

    private func waitForState(
        _ connection: MCPServerConnection, timeout: Double = 20,
        _ predicate: (MCPConnectionState) -> Bool
    ) async throws -> MCPConnectionState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await connection.state
            if predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(20))
        }
        let state = await connection.state
        XCTFail("timed out waiting; state is \(state)")
        return state
    }

    private func isReady(_ state: MCPConnectionState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    private func call(_ connection: MCPServerConnection, _ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> AgentToolOutput {
        try await connection.callTool(name, arguments: .object(arguments)).agentOutput
    }

    func testHandshakePaginationCallsListChangedAndServerRequests() async throws {
        let (connection, _) = makeConnection(env: ["MOCK_SECRET": "", "MOCK_PLAIN": "plain"], vault: ["MOCK_SECRET": "from-vault"])
        await connection.start()
        let ready = await connection.state
        XCTAssertEqual(ready, .ready(toolCount: 9), "both pages, the second split across writes")
        let names = await connection.tools.map(\.name)
        XCTAssertEqual(names, ["echo", "fail", "image", "add_tool", "ping_me", "crash", "hang", "cancelled_log", "env"])

        let echo = try await call(connection, "echo", ["text": .string("hi 你好\nline two")])
        XCTAssertEqual(echo, AgentToolOutput(text: "hi 你好\nline two"))

        let failed = try await call(connection, "fail")
        XCTAssertTrue(failed.isError, "isError is a result, not a thrown error")
        XCTAssertEqual(failed.text, "it broke")

        let image = try await call(connection, "image")
        XCTAssertEqual(image.images, [AgentToolImage(data: Data([0x89]) + Data("PNG-mock".utf8), mimeType: "image/png")])
        XCTAssertTrue(image.text.contains("inside"))
        XCTAssertTrue(image.text.contains("b.txt"))

        _ = try await call(connection, "add_tool")
        _ = try await waitForState(connection) { $0 == .ready(toolCount: 10) }
        let refreshed = await connection.tools
        XCTAssertEqual(refreshed.last?.name, "added", "the list was fetched again after list_changed")

        let pinged = try await call(connection, "ping_me")
        XCTAssertEqual(pinged.text, "ping=ok sampling=-32601", "ping answered, other server requests refused")

        let secret = try await call(connection, "env", ["name": .string("MOCK_SECRET")])
        XCTAssertEqual(secret.text, "from-vault", "the vault value reaches the process")
        let plain = try await call(connection, "env", ["name": .string("MOCK_PLAIN")])
        XCTAssertEqual(plain.text, "plain")
        let home = try await call(connection, "env", ["name": .string("HOME")])
        XCTAssertEqual(home.text, HostExecutor.realHomeDirectory())

        await connection.stop()
        let stopped = await connection.state
        XCTAssertEqual(stopped, .stopped)
        XCTAssertEqual(startCount(), 1)
    }

    func testCrashFailsTheCallKeepsStderrAndRestarts() async throws {
        let (connection, log) = makeConnection()
        await connection.start()
        let first = await connection.state
        XCTAssertTrue(isReady(first))

        do {
            _ = try await call(connection, "crash")
            XCTFail("a crash must fail the pending call")
        } catch let error as MCPError {
            guard case .closed(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(reason.contains("3"), reason)
        }
        // The call fails as soon as the pipe closes; the connection reports
        // the crash a moment later, then restarts.
        _ = try await waitForState(connection) { _ in self.startCount() == 2 }
        _ = try await waitForState(connection) { self.isReady($0) }
        let failure = log.snapshots.compactMap { snapshot -> (String, [String])? in
            if case .failed(let reason, let lines) = snapshot.state { return (reason, lines) }
            return nil
        }.first
        XCTAssertEqual(failure?.0, "服务器进程已退出（状态码 3）")
        XCTAssertTrue(failure?.1.contains("boom: simulated crash") ?? false, "stderr tail: \(failure?.1 ?? [])")

        let echo = try await call(connection, "echo", ["text": .string("back")])
        XCTAssertEqual(echo.text, "back")
        XCTAssertEqual(startCount(), 2)
        let restarts = await connection.restarts
        XCTAssertEqual(restarts, 1)
        await connection.stop()
    }

    func testAServerThatKeepsCrashingIsGivenUpOnAfterThreeRestarts() async throws {
        let (connection, _) = makeConnection(env: ["MOCK_CRASH_ON_START": "1"],
                                             policy: MCPRestartPolicy(maxRestarts: 3, backoff: [.milliseconds(50)]))
        await connection.start()
        let deadline = Date().addingTimeInterval(20)
        while startCount() < 4, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        // Leave room for a (wrong) fifth attempt before checking.
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(startCount(), 4, "one start and three restarts")
        guard case .failed(let reason, let lines) = await connection.state else {
            return XCTFail("still failed after the last restart")
        }
        XCTAssertTrue(reason.contains("7"), reason)
        XCTAssertTrue(lines.contains("startup failure: missing config"), "\(lines)")
        await connection.stop()
    }

    func testTimeoutAndCancellationTellTheServer() async throws {
        let (connection, _) = makeConnection(
            timeouts: MCPClient.Timeouts(initialize: .seconds(15), list: .seconds(10), call: .milliseconds(500))
        )
        await connection.start()

        let started = Date()
        do {
            _ = try await call(connection, "hang")
            XCTFail("a call with no answer must time out")
        } catch let error as MCPError {
            guard case .timedOut(let method, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(method, "tools/call")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let task = Task { try await self.call(connection, "hang") }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled call must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        // The server got notifications/cancelled for both, and is still usable.
        let deadline = Date().addingTimeInterval(5)
        var logged: [Int] = []
        while logged.count < 2, Date() < deadline {
            let output = try await call(connection, "cancelled_log")
            logged = (try? JSONDecoder().decode([Int].self, from: Data(output.text.utf8))) ?? []
            if logged.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(logged.count, 2, "cancelled ids: \(logged)")
        XCTAssertEqual(Set(logged).count, 2)
        let after = await connection.state
        XCTAssertTrue(isReady(after), "a timeout does not drop the connection")
        await connection.stop()
    }

    func testCounterOfferedVersionIsAcceptedAndAnUnknownOneRejectedWithoutRestart() async throws {
        let (older, _) = makeConnection(env: ["MOCK_VERSION": "2025-03-26"])
        await older.start()
        let olderState = await older.state
        XCTAssertTrue(isReady(olderState))
        await older.stop()

        let (unknown, _) = makeConnection(env: ["MOCK_VERSION": "1999-01-01"])
        await unknown.start()
        guard case .failed(let reason, _) = await unknown.state else { return XCTFail("an unknown version must fail") }
        XCTAssertTrue(reason.contains("1999-01-01"), reason)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(startCount(), 2, "a version mismatch is not retried")
        await unknown.stop()
    }
}

/// Every snapshot a connection reported, in order.
final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MCPServerConnection.Snapshot] = []

    func append(_ snapshot: MCPServerConnection.Snapshot) {
        lock.withLock { items.append(snapshot) }
    }

    var snapshots: [MCPServerConnection.Snapshot] { lock.withLock { items } }
}
