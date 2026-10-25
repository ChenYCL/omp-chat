import Foundation
import Network

/// Cross-network relay client: both the Mac host and the iOS controller dial
/// *out* to a public relay hub and meet by room code, so neither side needs a
/// public IP or a port forward. See `docs/relay-hub.md`.
///
/// The hub only forwards: host pushes whole [`RelaySnapshot`]s and receives
/// `command` events; the controller receives `rev` pokes and fetches snapshots.
public final class RelayHubClient: @unchecked Sendable {
    private let hubURL: URL
    private let roomCode: String
    private let session: URLSession

    private let lock = NSLock()
    private var hostConnection: NWConnection?
    private var commandHandler: (@Sendable (RelayCommand) async -> Void)?
    private var rpcHandler: (@Sendable (HostRPCRequest) async -> HostRPCResponse)?
    private var hostLineBuffer = Data()
    private var pendingEventName = "message"
    private var pendingEventData = ""

    public init(hubURL: URL, roomCode: String) {
        self.hubURL = hubURL
        self.roomCode = roomCode.uppercased()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - Host side

    /// Opens the host upstream stream and delivers relay commands as they
    /// arrive. Safe to call again; an existing connection is closed first.
    public func startHost(
        onCommand: @escaping @Sendable (RelayCommand) async -> Void,
        onRPC: (@Sendable (HostRPCRequest) async -> HostRPCResponse)? = nil
    ) throws {
        stopHost()
        lock.lock()
        commandHandler = onCommand
        rpcHandler = onRPC
        lock.unlock()

        guard let url = streamURL(path: "/v1/host/stream") else {
            throw RelayHubError.badHubURL
        }
        let host = url.host ?? "127.0.0.1"
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 8899)) ?? 8899

        let parameters = NWParameters.tcp
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: parameters
        )
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.sendHostRequest(path: url.path, query: url.query, on: connection)
            }
        }
        connection.start(queue: DispatchQueue(label: "com.ompchat.relayhub.host"))
        readHostLoop(connection)

        lock.lock()
        hostConnection = connection
        lock.unlock()
    }

    /// Pushes one full snapshot to the hub (host side).
    public func publish(_ snapshot: RelaySnapshot) async throws {
        guard let url = URL(string: "\(hubURL.absoluteString)/v1/host/state?room=\(roomCode)") else {
            throw RelayHubError.badHubURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.snapshotEncoder().encode(snapshot)
        let (data, response) = try await session.data(for: request)
        try Self.assertOK(data: data, response: response)
    }

    public func stopHost() {
        lock.lock()
        let connection = hostConnection
        hostConnection = nil
        hostLineBuffer.removeAll()
        pendingEventName = "message"
        pendingEventData = ""
        lock.unlock()
        connection?.cancel()
    }

    // MARK: - Controller side

    /// Connects as a controller and returns the first available snapshot.
    public func connectClient() async throws -> RelaySnapshot {
        try await snapshot()
    }

    public func snapshot() async throws -> RelaySnapshot {
        guard let url = URL(string: "\(hubURL.absoluteString)/v1/client/state?room=\(roomCode)") else {
            throw RelayHubError.badHubURL
        }
        let (data, response) = try await session.data(for: URLRequest(url: url))
        try Self.assertOK(data: data, response: response)
        return try Self.snapshotDecoder().decode(RelaySnapshot.self, from: data)
    }

    /// rev-poke stream from the hub; reconnects with 1s→5s backoff.
    public func revisions() -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    guard let url = self.streamURL(path: "/v1/client/stream") else { break }
                    do {
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 3600
                        let (bytes, _) = try await self.session.bytes(for: request)
                        var name = "message"
                        var payload = ""
                        for try await line in bytes.lines {
                            if line.isEmpty {
                                if name == "rev" || name == "hello",
                                   let data = Data(payload.utf8) as Data?,
                                   let decoded = try? JSONDecoder().decode([String: Int].self, from: data),
                                   let rev = decoded["rev"] {
                                    continuation.yield(rev)
                                }
                                name = "message"
                                payload = ""
                            } else if line.hasPrefix("event:") {
                                name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                var value = String(line.dropFirst(5))
                                if value.hasPrefix(" ") { value.removeFirst() }
                                payload += value
                            }
                        }
                    } catch {
                        // hub unreachable; retry with backoff
                    }
                    let backoff = UInt64(5_000_000_000)
                    try? await Task.sleep(nanoseconds: backoff)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ command: RelayCommand) async throws {
        guard let url = URL(string: "\(hubURL.absoluteString)/v1/client/command?room=\(roomCode)") else {
            throw RelayHubError.badHubURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(RelayCommandWire(command))
        let (data, response) = try await session.data(for: request)
        try Self.assertOK(data: data, response: response)
    }

    public func stop() {
        stopHost()
        session.invalidateAndCancel()
    }

    // MARK: - Room codes

    /// Generates a 6-character room code from the same alphabet the hub uses
    /// (`ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, no look-alike characters).
    public static func newRoomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    public static func isValidRoomCode(_ code: String) -> Bool {
        let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let trimmed = code.trimmingCharacters(in: .whitespaces).uppercased()
        return trimmed.count == 6 && trimmed.allSatisfy { alphabet.contains($0) }
    }

    // MARK: - Private

    private func streamURL(path: String) -> URL? {
        guard var components = URLComponents(url: hubURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.query = "room=\(roomCode)"
        return components.url
    }

    private func sendHostRequest(path: String, query: String?, on connection: NWConnection) {
        var raw = "GET \(path)\(query.map { "?\($0)" } ?? "") HTTP/1.1\r\n"
        raw += "Host: \(hubURL.host ?? "hub")\r\n"
        raw += "Accept: text/event-stream\r\n"
        raw += "Connection: keep-alive\r\n\r\n"
        connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
    }

    private func readHostLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consumeHostData(data)
            }
            if isComplete || error != nil { return }
            self.readHostLoop(connection)
        }
    }

    private func consumeHostData(_ data: Data) {
        lock.lock()
        hostLineBuffer.append(data)
        let newline = Data([0x0A])
        var events: [(String, String)] = []
        while let range = hostLineBuffer.firstRange(of: newline) {
            let lineData = hostLineBuffer.subdata(in: hostLineBuffer.startIndex..<range.lowerBound)
            hostLineBuffer.removeSubrange(hostLineBuffer.startIndex...range.lowerBound)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                if !pendingEventData.isEmpty {
                    events.append((pendingEventName, pendingEventData))
                }
                pendingEventName = "message"
                pendingEventData = ""
            } else if line.hasPrefix("event:") {
                pendingEventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                pendingEventData += value
            }
        }
        lock.unlock()

        for (name, payload) in events where name == "command" {
            guard let wire = try? JSONDecoder().decode(RelayCommandWire.self, from: Data(payload.utf8)),
                  let command = wire.command else {
                continue
            }
            lock.lock()
            let handler = commandHandler
            lock.unlock()
            if let handler {
                Task { await handler(command) }
            }
        }
        for (name, payload) in events where name == "rpc" {
            guard let rpcRequest = try? JSONDecoder().decode(HostRPCRequest.self, from: Data(payload.utf8)) else {
                continue
            }
            lock.lock()
            let handler = rpcHandler
            lock.unlock()
            guard let handler else { continue }
            let hubURL = self.hubURL
            let roomCode = self.roomCode
            let session = self.session
            Task {
                let rpcResponse = await handler(rpcRequest)
                await Self.postRPCResult(rpcResponse, hubURL: hubURL, roomCode: roomCode, session: session)
            }
        }
    }

    private static func assertOK(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RelayHubError.badResponse }
        switch http.statusCode {
        case 200...299: return
        case 404: throw RelayHubError.roomNotFound
        case 409: throw RelayHubError.hostOffline
        case 429: throw RelayHubError.rateLimited
        default: throw RelayHubError.http(http.statusCode)
        }
    }

    private static func snapshotDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func snapshotEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Controller-side RPC. The hub holds the request open (≤ 130s) until the
    /// host posts a matching result. `409` is host offline; `504` is timeout.
    public func rpc(_ request: HostRPCRequest) async throws -> HostRPCResponse {
        guard let url = URL(string: "\(hubURL.absoluteString)/v1/client/rpc?room=\(roomCode)") else {
            throw RelayHubError.badHubURL
        }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.timeoutInterval = 140
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        http.httpBody = try encoder.encode(request)
        let (data, response) = try await session.data(for: http)
        try Self.assertOK(data: data, response: response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HostRPCResponse.self, from: data)
    }

    private static func postRPCResult(
        _ response: HostRPCResponse,
        hubURL: URL,
        roomCode: String,
        session: URLSession
    ) async {
        guard let url = URL(string: "\(hubURL.absoluteString)/v1/host/rpc-result?room=\(roomCode)") else { return }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        http.httpBody = try? encoder.encode(response)
        _ = try? await session.data(for: http)
    }
}

/// Transport-agnostic way to push a command at the Mac, so the remote screens
/// work identically over LAN (`RemoteRelayClient`) and the hub (`RelayHubClient`).
public protocol RelayCommandSink: Sendable {
    func submit(_ command: RelayCommand) async throws
}

extension RelayHubClient: RelayCommandSink {
    public func submit(_ command: RelayCommand) async throws {
        try await send(command)
    }
}

extension RelayHubClient: RelayRPCSink {
    public func call(_ request: HostRPCRequest) async throws -> HostRPCResponse {
        try await rpc(request)
    }
}

public enum RelayHubError: LocalizedError, Sendable {
    case badHubURL
    case badResponse
    case roomNotFound
    case hostOffline
    case rateLimited
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .badHubURL: "中继地址无效"
        case .badResponse: "中继返回了无法解析的响应"
        case .roomNotFound: "房间码不存在或主机未上线"
        case .hostOffline: "Mac 主机已离线"
        case .rateLimited: "尝试次数过多，请稍后再试"
        case .http(let code): "中继返回 HTTP \(code)"
        }
    }
}
