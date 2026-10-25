import Foundation
import XCTest
@testable import OMPCore

/// Wire round-trip for every Host RPC type, plus the LAN `POST /rpc` route:
/// 401 without a token, `unsupported` when `onRPC` is unset, and the success path.
final class RelayHostRPCTests: XCTestCase {
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

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Wire

    func testRequestRoundTripsEveryField() throws {
        let request = HostRPCRequest(
            id: "r1", op: "exec", path: "/tmp", command: "pwd",
            cwd: "/Users/me", maxBytes: 1024, timeout: 5
        )
        let decoded = try decoder().decode(HostRPCRequest.self, from: encoder().encode(request))
        XCTAssertEqual(decoded, request)
    }

    func testRequestOmitsNilFields() throws {
        let data = try encoder().encode(HostRPCRequest(id: "r2", op: "info"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "r2")
        XCTAssertEqual(object["op"] as? String, "info")
        XCTAssertNil(object["path"])
        XCTAssertNil(object["command"])
        XCTAssertNil(object["cwd"])
        XCTAssertNil(object["maxBytes"])
        XCTAssertNil(object["timeout"])
    }

    func testFSEntryDateIsISO8601() throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
        let entry = HostFSEntry(name: "README.md", isDirectory: false, size: 42, modified: date)
        let data = try JSONEncoder().encode(entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["modified"] as? String, "2026-10-25T12:00:00Z")
        let decoded = try JSONDecoder().decode(HostFSEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func testFSEntryAcceptsFractionalISO8601() throws {
        let raw = #"{"name":"a","isDirectory":true,"modified":"2026-10-25T12:00:00.123Z"}"#
        let decoded = try JSONDecoder().decode(HostFSEntry.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.name, "a")
        XCTAssertTrue(decoded.isDirectory)
        XCTAssertNotNil(decoded.modified)
    }

    func testInfoRoundTrips() throws {
        let info = HostInfo(
            hostName: "mini", user: "me", home: "/Users/me", cwd: "/Users/me/src",
            gitBranch: "main", gitDirty: 3
        )
        let decoded = try decoder().decode(HostInfo.self, from: encoder().encode(info))
        XCTAssertEqual(decoded, info)
    }

    func testResponseRoundTripsEveryField() throws {
        let response = HostRPCResponse(
            id: "r3", ok: true, error: nil,
            entries: [HostFSEntry(name: "src", isDirectory: true)],
            text: "hello", truncated: false,
            stdout: "out", stderr: "err", exitCode: 0,
            cwd: "/tmp",
            info: HostInfo(hostName: "mini", user: "me", home: "/Users/me", cwd: "/tmp")
        )
        let decoded = try decoder().decode(HostRPCResponse.self, from: encoder().encode(response))
        XCTAssertEqual(decoded, response)
    }

    func testFailureResponseKeepsErrorCode() throws {
        let response = HostRPCResponse(id: "r4", ok: false, error: "shell_disabled")
        let decoded = try decoder().decode(HostRPCResponse.self, from: encoder().encode(response))
        XCTAssertEqual(decoded, response)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "shell_disabled")
    }

    func testCancelRequestRoundTripsRequestID() throws {
        let request = HostRPCRequest(id: "c1", op: "exec.cancel", requestID: "exec-1")
        let data = try encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["op"] as? String, "exec.cancel")
        XCTAssertEqual(object["requestID"] as? String, "exec-1")
        XCTAssertNil(object["command"])
        let decoded = try decoder().decode(HostRPCRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testOldRequestWithoutRequestIDKeyDecodes() throws {
        // A client that predates exec.cancel sends no requestID; the field
        // must decode as nil instead of failing.
        let raw = #"{"id":"old","op":"exec","command":"pwd"}"#
        let decoded = try decoder().decode(HostRPCRequest.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.id, "old")
        XCTAssertEqual(decoded.op, "exec")
        XCTAssertNil(decoded.requestID)
    }

    func testCancelledResponseRoundTrips() throws {
        let response = HostRPCResponse(
            id: "exec-1", ok: false, error: "cancelled",
            stdout: "partial", stderr: "", exitCode: 130, cwd: "/tmp"
        )
        let decoded = try decoder().decode(HostRPCResponse.self, from: encoder().encode(response))
        XCTAssertEqual(decoded, response)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.exitCode, 130)
    }

    func testPollRequestRoundTripsOffset() throws {
        let request = HostRPCRequest(id: "p1", op: "exec.poll", requestID: "exec-1", offset: 4096)
        let data = try encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["op"] as? String, "exec.poll")
        XCTAssertEqual(object["requestID"] as? String, "exec-1")
        XCTAssertEqual(object["offset"] as? Int, 4096)
        XCTAssertNil(object["command"])
        let decoded = try decoder().decode(HostRPCRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testBackgroundRequestRoundTrips() throws {
        let request = HostRPCRequest(id: "b1", op: "exec", command: "swift build", background: true)
        let data = try encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["background"] as? Bool, true)
        let decoded = try decoder().decode(HostRPCRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testPollResponseRoundTripsCursorAndDone() throws {
        let response = HostRPCResponse(
            id: "p1", ok: true, text: "chunk", truncated: true,
            exitCode: 0, cwd: "/tmp", nextOffset: 8192, done: true
        )
        let data = try encoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "chunk")
        XCTAssertEqual(object["nextOffset"] as? Int, 8192)
        XCTAssertEqual(object["done"] as? Bool, true)
        let decoded = try decoder().decode(HostRPCResponse.self, from: data)
        XCTAssertEqual(decoded, response)
    }

    func testOldJSONWithoutPollKeysDecodes() throws {
        // A host that predates background exec answers without the new keys.
        let raw = #"{"id":"old","ok":true,"stdout":"hi","exitCode":0,"cwd":"/tmp"}"#
        let decoded = try decoder().decode(HostRPCResponse.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.stdout, "hi")
        XCTAssertNil(decoded.nextOffset)
        XCTAssertNil(decoded.done)
        let request = #"{"id":"old","op":"exec","command":"pwd"}"#
        let decodedRequest = try decoder().decode(HostRPCRequest.self, from: Data(request.utf8))
        XCTAssertNil(decodedRequest.background)
        XCTAssertNil(decodedRequest.offset)
    }

    // MARK: - LAN /rpc

    private func rpcRequest(_ body: HostRPCRequest, token: String? = "valid") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("rpc"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = try? encoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if token == "valid" {
            request.setValue(self.token, forHTTPHeaderField: "X-OMP-Token")
        } else if let token {
            request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
        }
        return request
    }

    func testRPCWithoutTokenReturns401() async throws {
        let body = HostRPCRequest(id: "a", op: "info")
        let (_, response) = try await URLSession.shared.data(for: rpcRequest(body, token: nil))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }

    func testRPCUnsetHandlerReturnsUnsupported() async throws {
        let (data, response) = try await URLSession.shared.data(
            for: rpcRequest(HostRPCRequest(id: "b", op: "info"))
        )
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let decoded = try decoder().decode(HostRPCResponse.self, from: data)
        XCTAssertEqual(decoded.id, "b")
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "unsupported")
    }

    func testRPCSuccessPath() async throws {
        server.onRPC = { request in
            HostRPCResponse(
                id: request.id, ok: true,
                info: HostInfo(hostName: "mini", user: "me", home: "/Users/me", cwd: request.cwd ?? "/Users/me")
            )
        }
        let (data, response) = try await URLSession.shared.data(
            for: rpcRequest(HostRPCRequest(id: "c", op: "info", cwd: "/tmp"))
        )
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let decoded = try decoder().decode(HostRPCResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.id, "c")
        XCTAssertEqual(decoded.info?.hostName, "mini")
        XCTAssertEqual(decoded.info?.cwd, "/tmp")
    }

    func testRPCBadJSONIs200BadRequest() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("rpc"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = Data("not json".utf8)
        request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let decoded = try decoder().decode(HostRPCResponse.self, from: data)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "bad_request")
    }

    func testRPCCancelRoundTripOverLAN() async throws {
        server.onRPC = { request in
            HostRPCResponse(id: request.requestID ?? request.id, ok: false, error: "cancelled", exitCode: 130)
        }
        let (data, response) = try await URLSession.shared.data(
            for: rpcRequest(HostRPCRequest(id: "cancel-op", op: "exec.cancel", requestID: "exec-9"))
        )
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let decoded = try decoder().decode(HostRPCResponse.self, from: data)
        XCTAssertEqual(decoded.id, "exec-9")
        XCTAssertEqual(decoded.error, "cancelled")
        XCTAssertEqual(decoded.exitCode, 130)
    }

    func testCommitMessageIsQuotedAndBlankCancels() {
        let command = "git add -A && git commit -m {{message}}"
        XCTAssertNil(HostCommandTemplate.fill(command, message: "   "), "空白说明等于取消")
        XCTAssertEqual(HostCommandTemplate.fill(command, message: "fix: a bug"),
            "git add -A && git commit -m 'fix: a bug'", "普通说明也要加引号，避免被 shell 拆开")
        XCTAssertEqual(HostCommandTemplate.fill(command, message: "it's a fix"),
            "git add -A && git commit -m 'it'\\''s a fix'")
        XCTAssertEqual(HostCommandTemplate.fill("git status -sb", message: nil), "git status -sb",
            "没有占位符的命令原样返回")
    }
}
