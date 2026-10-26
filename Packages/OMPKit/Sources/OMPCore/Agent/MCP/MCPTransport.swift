import Foundation

/// What a transport delivers to the client, in arrival order.
public enum MCPTransportEvent: Equatable, Sendable {
    /// One frame: a JSON-RPC message (or batch) as received.
    case message(Data)
    /// The connection ended; the stream finishes after this. `reason` is
    /// shown to the user.
    case closed(reason: String)
}

/// Moves JSON-RPC frames between the client and one server. The client owns
/// the protocol; a transport only knows bytes and connection lifetime.
public protocol MCPTransport: AnyObject, Sendable {
    /// Opens the connection. Events arrive on the returned stream.
    func connect() async throws -> AsyncStream<MCPTransportEvent>
    /// Sends one encoded message. For HTTP, replies to it arrive as events.
    func send(_ message: Data) async throws
    /// The handshake finished with `protocolVersion`.
    func didInitialize(protocolVersion: String) async
    /// Ends the connection; the stream still delivers `.closed`. Safe to call twice.
    func close() async
    /// Recent diagnostic output (a stdio server's stderr), oldest first.
    func diagnostics() -> [String]
}

public extension MCPTransport {
    func didInitialize(protocolVersion: String) async {}
    func diagnostics() -> [String] { [] }
}

public enum MCPError: Error, Equatable, Sendable, LocalizedError {
    case timedOut(method: String, seconds: Int)
    case closed(String)
    /// A JSON-RPC error the server answered with.
    case server(code: Int, message: String)
    case unsupportedProtocolVersion(String)
    case badResponse(String)
    case http(status: Int, body: String)
    case commandNotFound(String)
    case unknownTool(String)
    case badArguments(String)
    case notConnected(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let method, let seconds): "\(method) 在 \(seconds) 秒内没有响应"
        case .closed(let reason): "连接已断开：\(reason)"
        case .server(let code, let message): "服务器返回错误 \(code)：\(message)"
        case .unsupportedProtocolVersion(let version): "服务器使用的协议版本「\(version)」不受支持"
        case .badResponse(let detail): "服务器响应无法解析：\(detail)"
        case .http(let status, let body): body.isEmpty ? "HTTP \(status)" : "HTTP \(status)：\(body)"
        case .commandNotFound(let command): "找不到命令「\(command)」"
        case .unknownTool(let name): "没有名为「\(name)」的 MCP 工具（可能已停用或服务器未连接）"
        case .badArguments(let detail): "参数不是合法的 JSON 对象：\(detail)"
        case .notConnected(let detail): detail
        }
    }

    /// Restarting cannot fix these; the user has to change something first.
    var isPermanent: Bool {
        switch self {
        case .commandNotFound, .unsupportedProtocolVersion: true
        default: false
        }
    }
}
