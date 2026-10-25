import XCTest
@testable import OMPCore

final class CLISessionTests: XCTestCase {
    private var captured: Data {
        Data("""
        [
          {"id":"4a8a6b79","cwd":"/Users/me/dtms-web-next","kind":"background",
           "startedAt":1786950847453,"sessionId":"4a8a6b79-8d28-4049-a8bd-0ca86fda13e1",
           "name":"修复 Select 组件","state":"blocked"},
          {"id":"","cwd":"/tmp","state":"running"},
          {"cwd":"/tmp","state":"running"},
          {"id":"5a9c3af1","cwd":"/Users/me/aide-ide","state":"idle","startedAt":1786951695423},
          {"cwd":"/Users/me/arb","kind":"interactive","name":"solana-arb","pid":80638,
           "sessionId":"b2b0110b-5eb7-4c11-9d2e-0a1b2c3d4e5f","startedAt":1792569449178,"status":"busy"}
        ]
        """.utf8)
    }

    func testParsesClaudeListingAndDropsBrokenRows() {
        let sessions = CLISessionListing.claude(json: captured)
        XCTAssertEqual(
            sessions.map(\.id), ["4a8a6b79", "5a9c3af1", "b2b0110b-5eb7-4c11-9d2e-0a1b2c3d4e5f"],
            "既无 id 也无 sessionId、或 id 为空的行应丢弃"
        )
        XCTAssertEqual(sessions[0].agent, "claude")
        XCTAssertEqual(sessions[0].name, "修复 Select 组件")
        XCTAssertEqual(sessions[0].state, "blocked")
        XCTAssertEqual(sessions[0].directoryName, "dtms-web-next")
        XCTAssertEqual(sessions[0].sessionID, "4a8a6b79-8d28-4049-a8bd-0ca86fda13e1")
        XCTAssertEqual(sessions[1].state, "idle")
        XCTAssertNil(sessions[1].name, "没有 name 字段时保持为空，不编造")
        XCTAssertTrue(sessions[0].isControllable, "后台会话可按 id 控制")
    }

    func testInteractiveSessionIsListedButNotControllable() {
        let session = CLISessionListing.claude(json: captured)[2]
        XCTAssertEqual(session.kind, "interactive")
        XCTAssertEqual(session.state, "busy", "交互会话的状态来自 status 字段")
        XCTAssertEqual(session.pid, 80638)
        XCTAssertFalse(session.isControllable, "终端里的会话只展示，不从手机停止")
    }

    func testStartedAtIsMillisecondsSinceEpoch() {
        let session = CLISessionListing.claude(json: captured)[0]
        let expected = Date(timeIntervalSince1970: 1_786_950_847.453)
        XCTAssertEqual(session.startedAt?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testBadJSONYieldsNothing() {
        XCTAssertEqual(CLISessionListing.claude(json: Data("not json".utf8)), [])
        XCTAssertEqual(CLISessionListing.claude(json: Data("{\"id\":\"x\"}".utf8)), [], "单个对象不是列表")
    }

    func testCommandsAreExactAndRejectMissingArguments() {
        XCTAssertEqual(
            CLISessionListing.command(agent: "claude", action: .start, id: nil, prompt: "修 bug"),
            ["claude", "--bg", "修 bug"]
        )
        XCTAssertNil(CLISessionListing.command(agent: "claude", action: .start, id: nil, prompt: "   "))
        XCTAssertEqual(
            CLISessionListing.command(agent: "claude", action: .stop, id: "4a8a6b79", prompt: nil),
            ["claude", "stop", "4a8a6b79"]
        )
        XCTAssertNil(CLISessionListing.command(agent: "claude", action: .stop, id: nil, prompt: nil))
        XCTAssertEqual(
            CLISessionListing.command(agent: "claude", action: .logs, id: "4a8a6b79", prompt: nil),
            ["claude", "logs", "4a8a6b79"]
        )
        XCTAssertNil(CLISessionListing.command(agent: "codex", action: .stop, id: "x", prompt: nil), "未接入的 agent 不返回猜测的命令")
    }

    /// The host RPC clients decode with `.iso8601`; a session crossing the wire
    /// must survive that (RelayDate keeps whole seconds) or the phone's whole
    /// `cli.sessions` answer fails to decode.
    func testSessionRoundTripsThroughIso8601RPCDecoder() throws {
        let original = CLISessionListing.claude(json: captured)[0]
        let response = HostRPCResponse(id: "r", ok: true, sessions: [original])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HostRPCResponse.self, from: data)
        let back = try XCTUnwrap(decoded.sessions?.first)
        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.kind, "background")
        XCTAssertEqual(
            back.startedAt?.timeIntervalSince1970 ?? 0,
            original.startedAt?.timeIntervalSince1970 ?? -1, accuracy: 1.0  // RelayDate is second-precision
        )
    }
}
