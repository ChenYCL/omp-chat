import Foundation
import Network

/// Commands the host app consumes from a paired remote controller.
public enum RelayCommand: Sendable {
    /// Remote text submission; `nil` conversationID means "create a new
    /// conversation on the host, then send".
    case input(conversationID: String?, text: String)
    /// Ask the host to stop generating in the given conversation.
    case stop(conversationID: String)
}

/// Errors thrown by [`RelayServer.start(port:token:)`].
public enum RelayServerError: Error, Sendable {
    /// The requested port could not be bound.
    case cannotBind
}

/// Minimal LAN HTTP server mirroring structured chat state to a remote
/// controller. Hand-rolled HTTP/1.1 (request line + headers +
/// `Content-Length` body) on top of `NWListener` — no third-party code.
///
/// Routes (all require `X-OMP-Token`, else `401`):
///
/// - `GET /pair` → `200 {"ok":true,"host":...,"rev":N}`
/// - `GET /snapshot` → `200` JSON [`RelaySnapshot`]
/// - `GET /state` → `text/event-stream`; sends `event: hello` on connect,
///   `event: rev` on every [`update(_:)`], and a `: ping` comment when the
///   state has been idle for 15 seconds.
/// - `POST /input` / `POST /stop` → forwarded through `onInput`, serially.
public final class RelayServer: @unchecked Sendable {
    /// Host app hook. Commands are delivered one at a time, in arrival order;
    /// the next command waits for the previous handler to return.
    public var onInput: (@Sendable (RelayCommand) async -> Void)?


    /// Internal: the bound listener, exposed so `RelayAdvertiser` can attach
    /// the Bonjour service to it (macOS refuses a second listener on the
    /// same port). Returns `nil` while the server is not running.
    func bonjourListener() -> NWListener? {
        queue.sync { listener }
    }
    /// All server state and connection I/O is confined to this serial queue.
    private let queue = DispatchQueue(label: "com.ompchat.relay.server")
    private var listener: NWListener?
    private var token = ""
    private var snapshot = RelaySnapshot(rev: 0, host: "", selectedID: nil, conversations: [])
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var pingTimer: DispatchSourceTimer?
    private var lastBroadcastAt = Date.distantPast
    private var boundPort: UInt16 = 0
    /// Tail of the serialized command chain; each command awaits its value.
    private var lastCommandTask: Task<Void, Never>?

    private struct Connection {
        let connection: NWConnection
        var isSSE: Bool
        var buffer: Data
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    public init() {}

    /// The port the server listens on; when started with `0` this is the port
    /// the OS picked. Valid after `start(port:token:)` returns.
    public var port: UInt16 { queue.sync { boundPort } }

    /// Starts listening. Throws when the port cannot be bound; call `stop()`
    /// to release the listener and every open connection.
    public func start(port requested: UInt16, token: String) throws {
        let ready = DispatchSemaphore(value: 0)
        let box = FailureBox()
        queue.sync {
            stopLocked()
            self.token = token
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let endpointPort = NWEndpoint.Port(rawValue: requested) else {
                box.failure = URLError(.badURL)
                ready.signal()
                return
            }
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters, on: endpointPort)
            } catch {
                box.failure = error
                ready.signal()
                return
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.failure = nil
                    ready.signal()
                case .failed(let error):
                    box.failure = error
                    ready.signal()
                case .cancelled:
                    break
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
        ready.wait()
        if let failure = box.failure {
            queue.sync {
                listener?.stateUpdateHandler = nil
                listener?.newConnectionHandler = nil
                listener?.cancel()
                listener = nil
            }
            throw failure
        }
        queue.sync {
            boundPort = listener?.port?.rawValue ?? requested
            lastBroadcastAt = Date()
            startPingTimerLocked()
        }
    }

    /// Stops the listener, closes every connection, and cancels the ping
    /// timer. Safe to call twice; `start` may be called again afterwards.
    public func stop() {
        queue.sync { stopLocked() }
    }

    /// Installs `snapshot` as the new state with `rev` incremented by one and
    /// broadcasts a `rev` event to every connected SSE client.
    public func update(_ snapshot: RelaySnapshot) {
        queue.async {
            var snapshot = snapshot
            snapshot.rev = self.snapshot.rev + 1
            self.snapshot = snapshot
            self.broadcast("event: rev\ndata: {\"rev\":\(snapshot.rev)}\n\n")
        }
    }

    // MARK: - Listener

    private func stopLocked() {
        pingTimer?.cancel()
        pingTimer = nil
        for (_, connection) in connections {
            connection.connection.stateUpdateHandler = nil
            connection.connection.cancel()
        }
        connections.removeAll()
        lastCommandTask = nil
        boundPort = 0
        guard let listener else {
            self.listener = nil
            return
        }
        self.listener = nil
        // Wait for the port to actually be released so an immediate
        // `start` rebind succeeds (the `.cancelled` state fires before the
        // kernel releases the socket on some paths).
        let released = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { released.signal() }
        }
        listener.newConnectionHandler = nil
        listener.cancel()
        _ = released.wait(timeout: .now() + 2)
        listener.stateUpdateHandler = nil
    }

    private func startPingTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = Date().timeIntervalSince(self.lastBroadcastAt)
            if idle >= Self.pingInterval {
                self.broadcast(": ping\n\n")
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private static let pingInterval: TimeInterval = 15

    // MARK: - Connection lifecycle

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        queue.async {
            self.connections[id] = Connection(connection: connection, isSSE: false, buffer: Data())
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLoop(id: id, connection: connection)
            case .failed, .waiting:
                self.drop(id)
            case .cancelled:
                self.drop(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(id: ObjectIdentifier, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.connections[id] != nil else { return }
                if let data, !data.isEmpty {
                    self.ingest(data, id: id)
                }
                if isComplete || error != nil {
                    self.drop(id)
                    return
                }
                guard self.connections[id] != nil else { return }
                self.receiveLoop(id: id, connection: connection)
            }
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.connection.stateUpdateHandler = nil
        connection.connection.cancel()
    }

    // MARK: - HTTP parsing

    private func ingest(_ data: Data, id: ObjectIdentifier) {
        guard connections[id] != nil else { return }
        connections[id]?.buffer.append(data)
        if connections[id]!.buffer.count > Self.maxRequestBytes {
            drop(id)
            return
        }
        if let request = parseRequest(&connections[id]!.buffer) {
            handle(request, id: id)
        }
    }

    private static let maxRequestBytes = 1 << 20

    /// Removes one complete request from `buffer` and returns it, or `nil`
    /// while the request is still incomplete.
    private func parseRequest(_ buffer: inout Data) -> Request? {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines {
            let keyAndValue = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyAndValue.count == 2 else { continue }
            let key = keyAndValue[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = keyAndValue[1].trimmingCharacters(in: .whitespaces)
            headers[key] = value
            if key == "content-length", let length = Int(value) {
                contentLength = max(0, length)
            }
        }
        guard contentLength <= Self.maxRequestBytes else { return nil }
        let bodyStart = headerEnd.upperBound
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength, limitedBy: buffer.endIndex) ?? nil
        guard let bodyEnd, buffer.distance(from: bodyStart, to: bodyEnd) == contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return Request(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - Routing

    private func handle(_ request: Request, id: ObjectIdentifier) {
        guard let connection = connections[id] else { return }
        guard request.headers["x-omp-token"] == token, !token.isEmpty else {
            send(httpResponse(status: "401 Unauthorized", contentType: "application/json",
                              body: Data("{\"error\":\"unauthorized\"}".utf8)),
                 id: id)
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/pair"):
            let payload = PairBody(ok: true, host: snapshot.host, rev: snapshot.rev)
            send(json(payload, status: "200 OK"), id: id)
        case ("GET", "/snapshot"):
            send(json(snapshot, status: "200 OK"), id: id)
        case ("GET", "/state"):
            connections[id]?.isSSE = true
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            lastBroadcastAt = Date()
            send(Data(head.utf8), id: id)
            send(Data("event: hello\ndata: {\"rev\":\(snapshot.rev)}\n\n".utf8), id: id)
        case ("POST", "/input"):
            guard let body = decode(InputBody.self, from: request.body),
                  !body.text.isEmpty else {
                send(json(ErrorBody(ok: false), status: "400 Bad Request"), id: id)
                return
            }
            dispatch(.input(conversationID: body.conversationID, text: body.text))
            send(json(InputAck(ok: true, conversationID: body.conversationID), status: "200 OK"), id: id)
        case ("POST", "/stop"):
            guard let body = decode(StopBody.self, from: request.body) else {
                send(json(ErrorBody(ok: false), status: "400 Bad Request"), id: id)
                return
            }
            dispatch(.stop(conversationID: body.conversationID))
            send(json(ErrorBody(ok: true), status: "200 OK"), id: id)
        default:
            send(json(ErrorBody(ok: false), status: "404 Not Found"), id: id)
        }
    }

    // MARK: - Command dispatch

    /// Enqueues a command onto the serial command chain; each command awaits
    /// the previous handler before running.
    private func dispatch(_ command: RelayCommand) {
        let handler = onInput
        queue.async {
            let previous = self.lastCommandTask
            let task = Task.detached(priority: .userInitiated) {
                _ = await previous?.value
                await handler?(command)
            }
            self.lastCommandTask = task
        }
    }

    // MARK: - Writing

    private func broadcast(_ text: String) {
        lastBroadcastAt = Date()
        let payload = Data(text.utf8)
        for (id, connection) in connections where connection.isSSE {
            send(payload, id: id)
        }
    }

    private func send(_ data: Data, id: ObjectIdentifier) {
        guard let connection = connections[id] else { return }
        connection.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.queue.async { self.drop(id) }
            }
        })
    }

    // MARK: - Encoding helpers

    private struct PairBody: Encodable {
        let ok: Bool
        let host: String
        let rev: Int
    }

    private struct InputBody: Decodable {
        let conversationID: String?
        let text: String
    }

    private struct StopBody: Decodable {
        let conversationID: String
    }

    private struct InputAck: Encodable {
        let ok: Bool
        let conversationID: String?
    }

    private struct ErrorBody: Encodable {
        let ok: Bool
    }

    private func json<T: Encodable>(_ value: T, status: String) -> Data {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return httpResponse(status: status, contentType: "application/json", body: body)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    private func httpResponse(status: String, contentType: String, body: Data) -> Data {
        var response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        return data
    }
}

/// Thread-safe box for the listener startup failure, signalled through a
/// semaphore whose waiter runs on a different thread than the listener queue.
private final class FailureBox: @unchecked Sendable {
    var failure: Error?
}
