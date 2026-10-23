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
}
