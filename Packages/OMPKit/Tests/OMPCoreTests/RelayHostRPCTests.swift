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
}
