import Foundation

/// MCP Streamable HTTP (protocol revisions 2025-03-26 and 2025-06-18).
///
/// Every message is its own POST. A request is answered either with one JSON
/// body or with an SSE stream that may carry server requests and
/// notifications before the response; both end up as `.message` events. The
/// session id the server hands out on initialization goes on every later
/// request and is ended with DELETE. After the handshake a GET stream listens
/// for messages the server sends on its own (e.g. `tools/list_changed`).
public final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    public let endpoint: URL
    private let http: HTTPTransport
    /// Longest wait for one POST. A tool call may legitimately take minutes.
    private let requestTimeout: TimeInterval
    private let listenRetryDelay: Duration

    private let lock = NSLock()
    private var sessionID: String?
    private var protocolVersion: String?
    private var continuation: AsyncStream<MCPTransportEvent>.Continuation?
    private var listener: Task<Void, Never>?
    private var isClosed = false

    public init(
        endpoint: URL, http: HTTPTransport,
        requestTimeout: TimeInterval = 330, listenRetryDelay: Duration = .seconds(5)
    ) {
        self.endpoint = endpoint
        self.http = http
        self.requestTimeout = requestTimeout
        self.listenRetryDelay = listenRetryDelay
    }

    /// The session the server assigned, if any.
    public var currentSessionID: String? { lock.withLock { sessionID } }

    public func connect() async throws -> AsyncStream<MCPTransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MCPTransportEvent.self)
        lock.withLock { self.continuation = continuation }
        return stream
    }

    public func send(_ message: Data) async throws {
        if lock.withLock({ isClosed }) { throw MCPError.closed("连接已关闭") }
        var request = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let hadSession = applySessionHeaders(&request)

        let response = try await http.send(request)
        if let assigned = Self.header("Mcp-Session-Id", in: response.headers), !assigned.isEmpty {
            lock.withLock { sessionID = assigned }
        }
        switch response.statusCode {
        case 200..<300:
            deliver(response)
        case 404 where hadSession:
            // The session is gone; the spec requires a fresh initialize, which
            // the connection's restart does.
            finish(reason: "服务器结束了会话")
            throw MCPError.closed("服务器结束了会话")
        default:
            let body = String(decoding: response.body.prefix(300), as: UTF8.self)
            throw MCPError.http(status: response.statusCode, body: body)
        }
    }

    public func didInitialize(protocolVersion: String) async {
        let previous = lock.withLock {
            self.protocolVersion = protocolVersion
            return listener
        }
        previous?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.listen()
        }
        lock.withLock { listener = task }
    }

    public func close() async {
        let (session, task, alreadyClosed): (String?, Task<Void, Never>?, Bool) = lock.withLock {
            defer { isClosed = true }
            return (sessionID, listener, isClosed)
        }
        task?.cancel()
        if !alreadyClosed, let session {
            var request = URLRequest(url: endpoint, timeoutInterval: 5)
            request.httpMethod = "DELETE"
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
            if let version = lock.withLock({ protocolVersion }) {
                request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
            }
            // 405 means the server does not let clients end sessions; either
            // way there is nothing left to do.
            _ = try? await http.send(request)
        }
        finish(reason: "已断开")
    }

    // MARK: Internals

    /// Adds the session and version headers; true when a session id was sent.
    @discardableResult
    private func applySessionHeaders(_ request: inout URLRequest) -> Bool {
        let (session, version) = lock.withLock { (sessionID, protocolVersion) }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        return session != nil
    }

    private func deliver(_ response: HTTPResponse) {
        guard !response.body.isEmpty else { return }
        let type = Self.header("Content-Type", in: response.headers)?.lowercased() ?? ""
        if type.contains("text/event-stream") {
            var parser = SSEParser()
            var events = parser.consume(response.body)
            if let last = parser.finish() { events.append(last) }
            for event in events { yieldEvent(event) }
        } else {
            yield(.message(response.body))
        }
    }

    private func yieldEvent(_ event: SSEEvent) {
        // Only the default event type carries JSON-RPC messages.
        guard event.event == nil || event.event == "message", !event.data.isEmpty else { return }
        yield(.message(Data(event.data.utf8)))
    }

    private func yield(_ event: MCPTransportEvent) {
        let continuation = lock.withLock { isClosed ? nil : self.continuation }
        continuation?.yield(event)
    }

    /// Ends the event stream; later sends fail instead of posting into a
    /// session nobody listens to.
    private func finish(reason: String) {
        let (continuation, task): (AsyncStream<MCPTransportEvent>.Continuation?, Task<Void, Never>?) = lock.withLock {
            defer {
                self.continuation = nil
                isClosed = true
            }
            return (self.continuation, listener)
        }
        task?.cancel()
        continuation?.yield(.closed(reason: reason))
        continuation?.finish()
    }

    /// The optional GET stream for server-initiated messages. A server that
    /// does not offer one answers 405 (any HTTP error ends listening). Streams
    /// that drop are reopened, but three in a row that delivered nothing end
    /// it, so an endpoint that closes at once is not polled forever.
    private func listen() async {
        var idleStreams = 0
        while !Task.isCancelled, !lock.withLock({ isClosed }) {
            var request = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            applySessionHeaders(&request)
            var delivered = false
            do {
                let stream = try await http.stream(request)
                var parser = SSEParser()
                for try await chunk in stream {
                    for event in parser.consume(chunk) {
                        yieldEvent(event)
                        delivered = true
                    }
                }
            } catch ProviderError.http {
                return
            } catch MCPError.http {
                return
            } catch {
                if Task.isCancelled { return }
            }
            idleStreams = delivered ? 0 : idleStreams + 1
            if idleStreams >= 3 { return }
            try? await Task.sleep(for: listenRetryDelay)
        }
    }

    static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
