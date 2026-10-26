import Foundation

// JSON-RPC 2.0 framing for MCP, independent of the transport that carries it.
// Spec: https://modelcontextprotocol.io/specification/2025-06-18/basic

/// A JSON-RPC request id. MCP allows strings and integers, and a reply must
/// echo the exact form the request used.
public enum MCPRequestID: Hashable, Sendable, CustomStringConvertible {
    case int(Int)
    case string(String)

    init?(_ value: JSONValue?) {
        switch value {
        case .number(let number) where number.rounded() == number && abs(number) < 9.0e15:
            self = .int(Int(number))
        case .string(let text):
            self = .string(text)
        default:
            return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .int(let value): .number(Double(value))
        case .string(let value): .string(value)
        }
    }

    public var description: String {
        switch self {
        case .int(let value): String(value)
        case .string(let value): value
        }
    }
}

/// One JSON-RPC message, classified the way the client dispatches it.
public enum MCPMessage: Equatable, Sendable {
    case request(id: MCPRequestID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: MCPRequestID, result: JSONValue)
    /// `id` is nil when the peer could not tell which request failed.
    case error(id: MCPRequestID?, code: Int, message: String)

    /// JSON-RPC "method not found", the answer to server requests the client
    /// does not implement (sampling, roots, elicitation).
    public static let methodNotFound = -32601

    /// Every message in one frame: a single object, or a batch array (allowed
    /// by protocol revision 2025-03-26). Anything that is not JSON-RPC is
    /// dropped.
    public static func decodeAll(_ data: Data) -> [MCPMessage] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        switch value {
        case .array(let items): return items.compactMap(Self.init(json:))
        default: return Self(json: value).map { [$0] } ?? []
        }
    }

    init?(json: JSONValue) {
        guard case .object(let object) = json else { return nil }
        if case .string(let method)? = object["method"] {
            let params = object["params"]
            if let id = MCPRequestID(object["id"]) {
                self = .request(id: id, method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
            return
        }
        let id = MCPRequestID(object["id"])
        if case .object(let error)? = object["error"] {
            var code = 0
            if case .number(let number)? = error["code"] { code = Int(number) }
            var message = ""
            if case .string(let text)? = error["message"] { message = text }
            self = .error(id: id, code: code, message: message)
            return
        }
        guard let id, let result = object["result"] else { return nil }
        self = .response(id: id, result: result)
    }

    /// One line of UTF-8 JSON. `JSONEncoder` escapes control characters, so
    /// the result never contains a raw newline (the stdio framing relies on it).
    public func encoded() -> Data {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = id.json
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .response(let id, let result):
            object["id"] = id.json
            object["result"] = result
        case .error(let id, let code, let message):
            object["id"] = id?.json ?? .null
            object["error"] = .object(["code": .number(Double(code)), "message": .string(message)])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(JSONValue.object(object))) ?? Data()
    }
}

// Prefixed so they cannot collide with helpers other agent code may add to
// the shared `JSONValue`.
extension JSONValue {
    func mcpField(_ key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var mcpString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var mcpBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var mcpArray: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Compact JSON text, keys sorted so equal values print the same.
    func mcpJSONText() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
