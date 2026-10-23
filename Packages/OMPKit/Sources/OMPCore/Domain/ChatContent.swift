import Foundation

public enum MediaKind: String, Codable, Hashable, Sendable {
    case image
    case video
    case audio
    case file
}

/// A file that lives inside the app's media sandbox.
public struct MediaRef: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: MediaKind
    public var relativePath: String
    public var mimeType: String
    public var byteCount: Int?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var durationSeconds: Double?
    public var originalName: String?
    public var thumbnailRelativePath: String?

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        relativePath: String,
        mimeType: String,
        byteCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        durationSeconds: Double? = nil,
        originalName: String? = nil,
        thumbnailRelativePath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.originalName = originalName
        self.thumbnailRelativePath = thumbnailRelativePath
    }
}

public struct ToolCall: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ToolResult: Codable, Hashable, Sendable {
    public var callID: String
    public var name: String
    public var outputText: String
    public var media: [MediaRef]
    public var isError: Bool

    public init(callID: String, name: String, outputText: String, media: [MediaRef] = [], isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.outputText = outputText
        self.media = media
        self.isError = isError
    }
}

/// One renderable slice of a message.
///
/// Encoded as a single-key object `{"text": "…"}` / `{"toolCall": {…}}` so the
/// document stays readable and hand-editable. The synthesized encoding nests
/// associated values under `_0`, which made externally written documents fail
/// to decode and silently wipe the workspace.
public enum ContentPart: Codable, Hashable, Sendable {
    case text(String)
    case thinking(String)
    case media(MediaRef)
    case toolCall(ToolCall)
    case toolResult(ToolResult)

    public var plainText: String {
        switch self {
        case .text(let value): value
        case .thinking(let value): value
        case .media(let ref): ref.originalName ?? ref.relativePath
        case .toolCall(let call): "\(call.name)(\(call.argumentsJSON))"
        case .toolResult(let result): result.outputText
        }
    }

    private enum Key: String, CodingKey {
        case text, thinking, media, toolCall, toolResult
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .thinking) {
            self = .thinking(value)
        } else if let value = try container.decodeIfPresent(MediaRef.self, forKey: .media) {
            self = .media(value)
        } else if let value = try container.decodeIfPresent(ToolCall.self, forKey: .toolCall) {
            self = .toolCall(value)
        } else if let value = try container.decodeIfPresent(ToolResult.self, forKey: .toolResult) {
            self = .toolResult(value)
        } else {
            // Legacy synthesized encoding: {"text": {"_0": "…"}}.
            self = try ContentPart.decodeLegacy(container)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .text(let value): try container.encode(value, forKey: .text)
        case .thinking(let value): try container.encode(value, forKey: .thinking)
        case .media(let value): try container.encode(value, forKey: .media)
        case .toolCall(let value): try container.encode(value, forKey: .toolCall)
        case .toolResult(let value): try container.encode(value, forKey: .toolResult)
        }
    }

    private static func decodeLegacy(_ container: KeyedDecodingContainer<Key>) throws -> ContentPart {
        struct Wrapped<T: Decodable>: Decodable { let _0: T }
        if let wrapped = try container.decodeIfPresent(Wrapped<String>.self, forKey: .text) { return .text(wrapped._0) }
        if let wrapped = try container.decodeIfPresent(Wrapped<String>.self, forKey: .thinking) { return .thinking(wrapped._0) }
        if let wrapped = try container.decodeIfPresent(Wrapped<MediaRef>.self, forKey: .media) { return .media(wrapped._0) }
        if let wrapped = try container.decodeIfPresent(Wrapped<ToolCall>.self, forKey: .toolCall) { return .toolCall(wrapped._0) }
        if let wrapped = try container.decodeIfPresent(Wrapped<ToolResult>.self, forKey: .toolResult) { return .toolResult(wrapped._0) }
        throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "未知的消息片段"))
    }
}
