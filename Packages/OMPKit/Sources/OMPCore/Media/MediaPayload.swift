import Foundation

/// A media file resolved into a wire-ready payload for providers.
public struct MediaPayload: Hashable, Sendable {
    public var mimeType: String
    public var base64: String

    public init(mimeType: String, base64: String) {
        self.mimeType = mimeType
        self.base64 = base64
    }

    public var dataURL: String { "data:\(mimeType);base64,\(base64)" }
}

/// Loads the bytes behind a `MediaRef` so request builders can inline them.
public typealias MediaPayloadProvider = @Sendable (MediaRef) -> MediaPayload?

public enum MediaPayloadResolver {
    /// Collects every image referenced by a request into `[MediaRef.id: payload]`,
    /// including images a tool returned (`ToolResult.media`).
    public static func resolve(
        messages: [ChatMessage],
        using provider: MediaPayloadProvider?
    ) -> [UUID: MediaPayload] {
        guard let provider else { return [:] }
        var result: [UUID: MediaPayload] = [:]
        for message in messages {
            for part in message.parts {
                let refs: [MediaRef]
                switch part {
                case .media(let ref): refs = [ref]
                case .toolResult(let tool): refs = tool.media
                default: refs = []
                }
                for ref in refs where ref.kind == .image && result[ref.id] == nil {
                    if let payload = provider(ref) { result[ref.id] = payload }
                }
            }
        }
        return result
    }
}
