import Foundation
import Network
import XCTest
@testable import OMPCore

/// Integration tests spinning up a real `RelayServer` on an ephemeral port
/// and talking to it over URLSession, mirroring the wire protocol in
/// `docs/relay-protocol.md`.
final class RelayServerTests: XCTestCase {
    private var server: RelayServer!
    private var token: String!
    private var baseURL: URL!

    override func setUp() {
        super.setUp()
        server = RelayServer()
        token = UUID().uuidString
        try? server.start(port: 0, token: token)
        baseURL = URL(string: "http://127.0.0.1:\(server.port)")
    }

    override func tearDown() {
        server.stop()
        server = nil
        token = nil
        baseURL = nil
        super.tearDown()
    }

    private func request(_ method: String, _ path: String, body: Data? = nil,
                         token: String? = "valid") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 10
        if token == "valid" {
            request.setValue(self.token, forHTTPHeaderField: "X-OMP-Token")
        } else if let token {
            request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: - Auth

    func testMissingTokenReturns401() async throws {
        let (data, response) = try await URLSession.shared.data(for: request("GET", "/snapshot", token: nil))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: data))
    }

    func testWrongTokenReturns401() async throws {
        let (_, response) = try await URLSession.shared.data(for: request("GET", "/snapshot", token: "wrong-token"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }

    func testAllRoutesRejectWithoutToken() async throws {
        for path in ["/pair", "/snapshot", "/state", "/debug/events", "/debug/report"] {
            let (_, response) = try await URLSession.shared.data(for: request("GET", path, token: nil))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401, path)
        }
        for path in ["/input", "/stop"] {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401, path)
        }
    }

    // MARK: - Pair

    func testPairReturnsHostAndRev() async throws {
        let (data, response) = try await URLSession.shared.data(for: request("GET", "/pair"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertNotNil(object["host"] as? String)
        XCTAssertNotNil(object["rev"] as? Int)
    }

    // MARK: - Snapshot

    func testSnapshotRoundTrips() async throws {
        let message = RelayMessage(
            id: "m1", role: "user", text: "你好",
            ts: ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!,
            streaming: false
        )
        let conversation = RelayConversation(
            id: "c1", title: "标题",
            updatedAt: ISO8601DateFormatter().date(from: "2026-10-25T12:00:01Z")!,
            project: nil, isStreaming: false, messages: [message]
        )
        server.update(RelaySnapshot(rev: 0, host: "TestMac", selectedID: "c1", conversations: [conversation]))

        let (data, response) = try await URLSession.shared.data(for: request("GET", "/snapshot"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let snapshot = try JSONDecoder().decode(RelaySnapshot.self, from: data)
        XCTAssertEqual(snapshot.rev, 1)
        XCTAssertEqual(snapshot.host, "TestMac")
        XCTAssertEqual(snapshot.selectedID, "c1")
        XCTAssertEqual(snapshot.conversations.count, 1)
        XCTAssertEqual(snapshot.conversations[0].title, "标题")
        XCTAssertEqual(snapshot.conversations[0].messages.count, 1)
        XCTAssertEqual(snapshot.conversations[0].messages[0].text, "你好")
        XCTAssertEqual(snapshot.conversations[0].messages[0].role, "user")

        // Raw wire format: ISO8601 strings.
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (raw?["conversations"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["updatedAt"] as? String, "2026-10-25T12:00:01Z")
    }

    // MARK: - Commands

    func testInputPOSTDeliversCommandToCallback() async throws {
        let box = CommandBox()
        let expectation = expectation(description: "input command")
        server.onInput = { command in
            await box.set(command)
            expectation.fulfill()
        }
        let body = try JSONSerialization.data(withJSONObject: ["conversationID": "c1", "text": "测试输入"])
        let (data, response) = try await URLSession.shared.data(for: request("POST", "/input", body: body))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let ack = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(ack["ok"] as? Bool, true)
        await fulfillment(of: [expectation], timeout: 5)
        guard case .input(let conversationID, let text)? = await box.value else {
            return XCTFail("expected .input command")
        }
        XCTAssertEqual(conversationID, "c1")
        XCTAssertEqual(text, "测试输入")
    }

    func testInputWithNullConversationDeliversNil() async throws {
        let box = CommandBox()
        let expectation = expectation(description: "input command")
        server.onInput = { command in
            await box.set(command)
            expectation.fulfill()
        }
        let body = try JSONSerialization.data(withJSONObject: ["conversationID": NSNull(), "text": "新对话"])
        let (_, response) = try await URLSession.shared.data(for: request("POST", "/input", body: body))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [expectation], timeout: 5)
        guard case .input(let conversationID, _)? = await box.value else {
            return XCTFail("expected .input command")
        }
        XCTAssertNil(conversationID)
    }

    func testStopPOSTDeliversCommandToCallback() async throws {
        let box = CommandBox()
        let expectation = expectation(description: "stop command")
        server.onInput = { command in
            await box.set(command)
            expectation.fulfill()
        }
        let body = try JSONSerialization.data(withJSONObject: ["conversationID": "c9"])
        let (data, response) = try await URLSession.shared.data(for: request("POST", "/stop", body: body))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let ack = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(ack["ok"] as? Bool, true)
        await fulfillment(of: [expectation], timeout: 5)
        guard case .stop(let conversationID)? = await box.value else {
            return XCTFail("expected .stop command")
        }
        XCTAssertEqual(conversationID, "c9")
    }

    func testCommandsRunSerially() async throws {
        actor Counter {
            var running = 0
            var maxConcurrent = 0
            func enter() async {
                running += 1
                maxConcurrent = max(maxConcurrent, running)
                try? await Task.sleep(nanoseconds: 100_000_000)
                running -= 1
            }
        }
        let counter = Counter()
        server.onInput = { _ in
            await counter.enter()
        }
        for index in 0..<4 {
            let body = try JSONSerialization.data(withJSONObject: ["conversationID": nil, "text": "n\(index)"])
            _ = try await URLSession.shared.data(for: request("POST", "/input", body: body))
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        let maxConcurrent = await counter.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1, "commands must execute serially")
    }

    // MARK: - SSE

    func testStateStreamSendsHelloAndRevEvents() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/state"))
        request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
        request.timeoutInterval = 10
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
            "text/event-stream"
        )

        // `AsyncBytes.lines` drops the blank lines that terminate an SSE event,
        // so read bytes and let `SSEParser` frame the events.
        var parser = SSEParser()
        var events: [SSEEvent] = []
        var bumpScheduled = false
        for try await byte in bytes {
            for event in parser.consume(Data([byte])) {
                events.append(event)
            }
            if !bumpScheduled {
                bumpScheduled = true
                server.update(RelaySnapshot(rev: 0, host: "TestMac", selectedID: nil, conversations: []))
            }
            if events.count >= 2 { break }
        }

        XCTAssertEqual(events.count, 2, "\(events)")
        XCTAssertEqual(events[0].event, "hello")
        XCTAssertTrue(events[0].data.contains("\"rev\":"), events[0].data)
        XCTAssertEqual(events[1].event, "rev")
        XCTAssertTrue(events[1].data.contains("\"rev\":1"), events[1].data)
    }

    func testUpdateBumpsRev() async throws {
        server.update(RelaySnapshot(rev: 100, host: "H", selectedID: nil, conversations: []))
        let (data, _) = try await URLSession.shared.data(for: request("GET", "/snapshot"))
        XCTAssertEqual(try JSONDecoder().decode(RelaySnapshot.self, from: data).rev, 1)
        server.update(RelaySnapshot(rev: 7, host: "H", selectedID: nil, conversations: []))
        let (data2, _) = try await URLSession.shared.data(for: request("GET", "/snapshot"))
        XCTAssertEqual(try JSONDecoder().decode(RelaySnapshot.self, from: data2).rev, 2)
    }

    // MARK: - Server lifecycle

    func testRestartWorks() throws {
        let port = server.port
        server.stop()
        try server.start(port: port, token: token)
        XCTAssertEqual(server.port, port)
    }

    func testUnknownRouteReturns404() async throws {
        let (_, response) = try await URLSession.shared.data(for: request("GET", "/nope"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    // MARK: - Helpers

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Thread-safe command carrier between the `onInput` callback and the
    /// test assertion.
    private final class CommandBox: @unchecked Sendable {
        private let lock = NSLock()
        private var command: RelayCommand?

        func set(_ command: RelayCommand) {
            lock.lock()
            self.command = command
            lock.unlock()
        }

        var value: RelayCommand? {
            lock.lock()
            defer { lock.unlock() }
            return command
        }

        func callAsFunction() async -> RelayCommand? { value }
    }
}
final class RelayDebugRouteTests: XCTestCase {
    private var server: RelayServer!
    private var token: String!
    private var baseURL: URL!

    override func setUp() {
        super.setUp()
        DiagnosticsCenter.shared.resetBuffer()
        DiagnosticsCenter.shared.setDiskEnabled(false)
        server = RelayServer()
        token = UUID().uuidString
        try? server.start(port: 0, token: token)
        baseURL = URL(string: "http://127.0.0.1:\(server.port)")
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    private func get(_ path: String, token: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        request.timeoutInterval = 10
        if let token { request.setValue(token, forHTTPHeaderField: "X-OMP-Token") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    func testDebugEventsFiltersBySince() async throws {
        DiagnosticsCenter.shared.record("test", .info, "one")
        DiagnosticsCenter.shared.record("test", .info, "two")
        let first = DiagnosticsCenter.shared.events(since: 0).first?.seq ?? 0
        let (data, response) = try await get("/debug/events?since=\(first)", token: token)
        XCTAssertEqual(response.statusCode, 200)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?.first?["message"] as? String, "two")
    }

    func testDebugReportWithoutHookReturns503() async throws {
        let (_, response) = try await get("/debug/report", token: token)
        XCTAssertEqual(response.statusCode, 503)
    }

    func testDebugRoutesRejectWithoutToken() async throws {
        for path in ["/debug/events", "/debug/report", "/debug/windows", "/debug/snapshot"] {
            let (_, response) = try await get(path, token: nil)
            XCTAssertEqual(response.statusCode, 401, path)
        }
    }

    // MARK: - Window snapshots

    /// Records which window each snapshot call asked for.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int?] = []
        func append(_ value: Int?) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Int?] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func testSnapshotRoutesWithoutHooksReturn503() async throws {
        for path in ["/debug/windows", "/debug/snapshot"] {
            let (_, response) = try await get(path, token: token)
            XCTAssertEqual(response.statusCode, 503, path)
        }
    }

    func testSnapshotReturnsThePNGForTheRequestedWindow() async throws {
        let calls = Calls()
        let png = fakePNG
        server.onDebugSnapshot = { window in
            calls.append(window)
            return png
        }
        let (data, response) = try await get("/debug/snapshot?window=42", token: token)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(data, png, "PNG 字节应原样返回")

        _ = try await get("/debug/snapshot", token: token)
        XCTAssertEqual(calls.all, [42, nil], "带 window 传编号，不带则交给宿主选默认窗口")
    }

    func testSnapshotRejectsANonNumericWindow() async throws {
        let calls = Calls()
        server.onDebugSnapshot = { window in
            calls.append(window)
            return Data()
        }
        let (_, response) = try await get("/debug/snapshot?window=main", token: token)
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(calls.all.isEmpty, "参数不合法时不应去截图")
    }

    func testSnapshotOfAMissingWindowReturns404() async throws {
        server.onDebugSnapshot = { _ in nil }
        let (_, response) = try await get("/debug/snapshot?window=7", token: token)
        XCTAssertEqual(response.statusCode, 404)
    }

    func testWindowsReturnsTheHostList() async throws {
        let list = Data(#"{"windows":[{"number":7,"title":"OMPChat"}]}"#.utf8)
        server.onDebugWindows = { list }
        let (data, response) = try await get("/debug/windows", token: token)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(data, list)
    }

    // MARK: - Debug actions + state

    private func post(_ path: String, json: String, token: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        if let token { request.setValue(token, forHTTPHeaderField: "X-OMP-Token") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    func testDebugActionWithoutTokenReturns401() async throws {
        let (_, response) = try await post("/debug/action", json: #"{"action":"newChat"}"#, token: nil)
        XCTAssertEqual(response.statusCode, 401)
    }

    func testDebugActionWithWrongTokenReturns401() async throws {
        let (_, response) = try await post("/debug/action", json: #"{"action":"newChat"}"#, token: "nope")
        XCTAssertEqual(response.statusCode, 401)
    }

    func testDebugActionWithoutHookReturns503() async throws {
        let (_, response) = try await post("/debug/action", json: #"{"action":"newChat"}"#, token: token)
        XCTAssertEqual(response.statusCode, 503)
    }

    func testDebugActionMalformedBodyReturns400EvenWithHook() async throws {
        server.onDebugAction = { _ in .success }
        for body in ["", "not json", "[]", #"{"action":"nope"}"#, #"{"action":"select"}"#] {
            let (_, response) = try await post("/debug/action", json: body, token: token)
            XCTAssertEqual(response.statusCode, 400, body)
        }
    }

    func testDebugActionDeliversEveryActionToTheHook() async throws {
        let box = ActionBox()
        server.onDebugAction = { action in
            box.append(action)
            return .success
        }
        let bodies: [String] = [
            #"{"action":"select","conversationID":"ABC"}"#,
            #"{"action":"newChat"}"#,
            #"{"action":"sidePanel","open":true,"tab":"browser"}"#,
            #"{"action":"sidePanel","open":false}"#,
            #"{"action":"openSettings"}"#,
            #"{"action":"closeSettings"}"#,
        ]
        for body in bodies {
            let (data, response) = try await post("/debug/action", json: body, token: token)
            XCTAssertEqual(response.statusCode, 200, body)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let reply = try JSONDecoder().decode(DebugActionOutcome.self, from: data)
            XCTAssertEqual(reply, .success, body)
        }
        XCTAssertEqual(box.all.count, 6)
        XCTAssertEqual(box.all[0], .select(conversationID: "ABC"))
        XCTAssertEqual(box.all[1], .newChat)
        XCTAssertEqual(box.all[2], .sidePanel(open: true, tab: .browser))
        XCTAssertEqual(box.all[3], .sidePanel(open: false, tab: nil))
        XCTAssertEqual(box.all[4], .openSettings)
        XCTAssertEqual(box.all[5], .closeSettings)
    }

    func testDebugActionReportsTheHostFailureVerbatim() async throws {
        server.onDebugAction = { _ in .failure("settings window did not open") }
        let (data, response) = try await post("/debug/action", json: #"{"action":"openSettings"}"#, token: token)
        XCTAssertEqual(response.statusCode, 200, "宿主没做到也是 200，错误在 JSON 里")
        let reply = try JSONDecoder().decode(DebugActionOutcome.self, from: data)
        XCTAssertEqual(reply, .failure("settings window did not open"))
    }

    func testDebugStateWithoutTokenReturns401() async throws {
        let (_, response) = try await get("/debug/state", token: nil)
        XCTAssertEqual(response.statusCode, 401)
    }

    func testDebugStateWithoutHookReturns503() async throws {
        let (_, response) = try await get("/debug/state", token: token)
        XCTAssertEqual(response.statusCode, 503)
    }

    func testDebugStateReturnsTheHostJSON() async throws {
        let state = Data(#"{"selectedID":null,"sidePanelOpen":false,"sidePanelTab":null,"settingsOpen":false,"windowTitles":["OMPChat"]}"#.utf8)
        server.onDebugState = { state }
        let (data, response) = try await get("/debug/state", token: token)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(data, state)
    }
}

/// Thread-safe action carrier between the `onDebugAction` hook and the test.
private final class ActionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DebugAction] = []
    func append(_ value: DebugAction) { lock.lock(); values.append(value); lock.unlock() }
    var all: [DebugAction] { lock.lock(); defer { lock.unlock() }; return values }
}
