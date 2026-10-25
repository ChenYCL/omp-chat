import Foundation
import OMPCore

/// LAN remote client for the OMPChat relay protocol v1 (see docs/relay-protocol.md).
/// Used by the iOS app to pair with a Mac host, mirror its structured conversation
/// state, and send input/stop commands back.
public final class RemoteRelayClient: Sendable {
    private let host: String
    private let port: UInt16
    private let token: String

    public init(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    // MARK: - Endpoints

    /// `GET /pair` — first-time handshake; confirms the token and returns host name + rev.
    public func pair() async throws -> PairResult {
        let data = try await dataRequest(path: "/pair")
        return try jsonDecoder().decode(PairResult.self, from: data)
    }

    /// `GET /snapshot` — full structured state mirror.
    public func snapshot() async throws -> RelaySnapshot {
        let data = try await dataRequest(path: "/snapshot")
        return try jsonDecoder().decode(RelaySnapshot.self, from: data)
    }

    /// `GET /state` — SSE stream; yields every revision pushed by the host.
    /// Reconnects automatically with backoff 1s → 5s. A 401 finishes the stream
    /// (retrying cannot fix a wrong token). Ends immediately on task cancellation.
    public func revisions() -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task {
                var backoff: Double = 1
                while !Task.isCancelled {
                    do {
                        var request = URLRequest(url: url("/state"))
                        request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
                        request.timeoutInterval = 25
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        try assertOK(response)
                        backoff = 1
                        for try await event in sseEvents(bytes) {
                            guard event.name == "rev" || event.name == "hello" else { continue }
                            guard let rev = (try? jsonDecoder().decode([String: Int].self, from: Data(event.data.utf8)))?["rev"] else { continue }
                            continuation.yield(rev)
                        }
                        // Stream ended without error — host closed; retry after backoff.
                    } catch is CancellationError {
                        break
                    } catch RelayClientError.unauthorized {
                        break
                    } catch {
                        // connection dropped — backoff and reconnect
                    }
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 5)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `POST /input` — send a message; `conversationID == nil` creates a new conversation on the Mac.
    /// Returns the conversation ID reported by the host.
    @discardableResult
    public func send(text: String, conversationID: String?) async throws -> String {
        let body = try jsonEncoder().encode(InputBody(conversationID: conversationID, text: text))
        let data = try await dataRequest(path: "/input", method: "POST", body: body)
        return try jsonDecoder().decode(InputResult.self, from: data).conversationID
    }

    /// `POST /stop` — stop streaming on the Mac, equivalent to host `stop()`.
    public func stop(conversationID: String) async throws {
        let body = try jsonEncoder().encode(StopBody(conversationID: conversationID))
        _ = try await dataRequest(path: "/stop", method: "POST", body: body)
    }

    // MARK: - Payloads

    public struct PairResult: Decodable, Sendable {
        public let ok: Bool
        public let host: String
        public let rev: Int
    }

    private struct InputBody: Encodable, Sendable {
        let conversationID: String?
        let text: String
    }

    private struct InputResult: Decodable, Sendable {
        let conversationID: String
    }

    private struct StopBody: Encodable, Sendable {
        let conversationID: String
    }

    // MARK: - Plumbing

    private func url(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = path
        return components.url!
    }

    private func dataRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
        request.timeoutInterval = 10
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try assertOK(response)
        return data
    }

    private func assertOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RelayClientError.badResponse
        }
        switch http.statusCode {
        case 200 ... 299: return
        case 401: throw RelayClientError.unauthorized
        default: throw RelayClientError.http(http.statusCode)
        }
    }

    /// Streams SSE events off `URLSession.bytes`.
    ///
    /// `AsyncBytes.lines` cannot be used here: it swallows the blank lines that
    /// terminate an SSE event, so no event ever completes. Bytes are fed into
    /// `SSEParser`, which implements the blank-line framing per the spec.
    private func sseEvents(_ bytes: URLSession.AsyncBytes) -> AsyncStream<(name: String, data: String)> {
        AsyncStream { continuation in
            let task = Task {
                var parser = SSEParser()
                var chunk = Data()
                chunk.reserveCapacity(512)
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 256 {
                            for event in parser.consume(chunk) {
                                continuation.yield((event.event ?? "message", event.data))
                            }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        for event in parser.consume(chunk) {
                            continuation.yield((event.event ?? "message", event.data))
                        }
                    }
                    if let event = parser.finish() {
                        continuation.yield((event.event ?? "message", event.data))
                    }
                } catch {
                    // connection dropped; the revisions() loop handles reconnection
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // JSONDecoder/JSONEncoder are not Sendable, so build them per call instead of
    // storing them on this Sendable class.
    private func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension RemoteRelayClient: RelayCommandSink {
    /// LAN transport adapter so both connection modes share the remote screens.
    public func submit(_ command: RelayCommand) async throws {
        switch command {
        case .input(let conversationID, let text):
            _ = try await send(text: text, conversationID: conversationID)
        case .stop(let conversationID):
            try await stop(conversationID: conversationID)
        }
    }
}

public enum RelayClientError: LocalizedError, Sendable {
    case unauthorized
    case badResponse
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Token 不匹配（401）"
        case .badResponse: "无效的服务器响应"
        case .http(let code): "主机返回 HTTP \(code)"
        }
    }
}
