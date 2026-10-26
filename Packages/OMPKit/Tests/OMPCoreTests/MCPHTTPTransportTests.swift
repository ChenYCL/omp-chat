import XCTest
@testable import OMPCore

/// Remote servers answer a POST either with JSON or with an SSE stream, and
/// tie later requests to a session id. Getting any of it wrong means a remote
/// server connects and then fails every call.
final class MCPHTTPTransportTests: XCTestCase {
    /// An in-memory MCP server behind `HTTPTransport`.
    private final class FakeServer: HTTPTransport, @unchecked Sendable {
        struct Seen {
            var method: String
            var rpcMethod: String?
            var headers: [String: String]
            var body: JSONValue?
        }

        private let lock = NSLock()
        private var seen: [Seen] = []
        var useSSEForLists = true
        var expireSessionOnCall = false

        var requests: [Seen] { lock.withLock { seen } }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            let rpcMethod = body?.mcpField("method")?.mcpString
            lock.withLock {
                seen.append(Seen(method: request.httpMethod ?? "", rpcMethod: rpcMethod,
                                 headers: request.allHTTPHeaderFields ?? [:], body: body))
            }
            if request.httpMethod == "DELETE" { return HTTPResponse(statusCode: 200, headers: [:], body: Data()) }
            let id = body?.mcpField("id") ?? .null
            switch rpcMethod {
            case "initialize":
                return json(id: id, result: .object([
                    "protocolVersion": .string("2025-06-18"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("fake"), "version": .string("1")]),
                ]), headers: ["mcp-session-id": "session-123"])
            case "tools/list":
                let result: JSONValue = .object(["tools": .array([
                    .object(["name": .string("lookup"), "inputSchema": .object(["type": .string("object")])]),
                ])])
                guard useSSEForLists else { return json(id: id, result: result) }
                // A server request first, then the response, as SSE events.
                let ping = MCPMessage.request(id: .string("srv-ping"), method: "ping", params: nil).encoded()
                let response = MCPMessage.response(id: MCPRequestID(id)!, result: result).encoded()
                let stream = "event: message\ndata: \(String(decoding: ping, as: UTF8.self))\n\n"
                    + ": keep-alive comment\n\n"
                    + "data: \(String(decoding: response, as: UTF8.self))\n\n"
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: Data(stream.utf8))
            case "tools/call":
                if expireSessionOnCall { return HTTPResponse(statusCode: 404, headers: [:], body: Data()) }
                return json(id: id, result: .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("found it")])]),
                ]))
            default:
                // Notifications and the client's replies.
                return HTTPResponse(statusCode: 202, headers: [:], body: Data())
            }
        }

        func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
            lock.withLock {
                seen.append(Seen(method: request.httpMethod ?? "", rpcMethod: nil, headers: request.allHTTPHeaderFields ?? [:], body: nil))
            }
            // This server offers no standalone listening stream.
            throw ProviderError.http(status: 405, body: "")
        }

        private func json(id: JSONValue, result: JSONValue, headers: [String: String] = [:]) -> HTTPResponse {
            let body = MCPMessage.response(id: MCPRequestID(id)!, result: result).encoded()
            return HTTPResponse(statusCode: 200, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: body)
        }
    }

    private func connect(_ server: FakeServer) async throws -> (MCPClient, MCPHTTPTransport) {
        let transport = MCPHTTPTransport(endpoint: URL(string: "https://mcp.example.com/mcp")!, http: server, listenRetryDelay: .milliseconds(10))
        let client = MCPClient(transport: transport)
        try await client.connect()
        return (client, transport)
    }

    func testJSONAndSSEResponsesWithSessionAndVersionHeaders() async throws {
        let server = FakeServer()
        let (client, transport) = try await connect(server)

        let tools = await client.tools
        XCTAssertEqual(tools.map(\.name), ["lookup"], "the tool list came back inside an SSE stream")
        XCTAssertEqual(transport.currentSessionID, "session-123", "header name matched case-insensitively")

        let result = try await client.callTool("lookup", arguments: .object(["q": .string("x")]))
        XCTAssertEqual(result.agentOutput.text, "found it")

        let posts = server.requests.filter { $0.method == "POST" }
        XCTAssertTrue(posts.allSatisfy { $0.headers["Accept"] == "application/json, text/event-stream" })
        XCTAssertTrue(posts.allSatisfy { $0.headers["Content-Type"] == "application/json" })
        let initialize = try XCTUnwrap(posts.first { $0.rpcMethod == "initialize" })
        XCTAssertNil(initialize.headers["Mcp-Session-Id"], "no session before the server assigns one")
        for later in posts where later.rpcMethod != "initialize" {
            XCTAssertEqual(later.headers["Mcp-Session-Id"], "session-123", "\(later.rpcMethod ?? "reply") carries the session")
        }
        let call = try XCTUnwrap(posts.first { $0.rpcMethod == "tools/call" })
        XCTAssertEqual(call.headers["MCP-Protocol-Version"], "2025-06-18")

        // The ping inside the SSE stream was answered with an empty result.
        let pong = try XCTUnwrap(posts.first { $0.body?.mcpField("id") == .string("srv-ping") })
        XCTAssertEqual(pong.body?.mcpField("result"), .object([:]))
        XCTAssertTrue(posts.contains { $0.rpcMethod == "notifications/initialized" })

        await client.close()
        let delete = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(delete.method, "DELETE", "closing ends the session")
        XCTAssertEqual(delete.headers["Mcp-Session-Id"], "session-123")
        XCTAssertTrue(server.requests.contains { $0.method == "GET" && $0.headers["Accept"] == "text/event-stream" },
                      "after the handshake it tried to open the listening stream")
    }

    func testPlainJSONListAndExpiredSessionClosesTheConnection() async throws {
        let server = FakeServer()
        server.useSSEForLists = false
        let (client, _) = try await connect(server)
        let tools = await client.tools
        XCTAssertEqual(tools.map(\.name), ["lookup"])

        server.expireSessionOnCall = true
        do {
            _ = try await client.callTool("lookup", arguments: .object([:]))
            XCTFail("a 404 on a session must fail the call")
        } catch let error as MCPError {
            guard case .closed = error else { return XCTFail("unexpected \(error)") }
        }
        do {
            _ = try await client.listTools()
            XCTFail("the connection is gone after the session expired")
        } catch let error as MCPError {
            guard case .closed = error else { return XCTFail("unexpected \(error)") }
        }
    }
}
