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
    /// Collects every image referenced by a request into `[MediaRef.id: payload]`.
    public static func resolve(
        messages: [ChatMessage],
        using provider: MediaPayloadProvider?
    ) -> [UUID: MediaPayload] {
        guard let provider else { return [:] }
        var result: [UUID: MediaPayload] = [:]
        for message in messages {
            for part in message.parts {
                guard case .media(let ref) = part, ref.kind == .image else { continue }
                if result[ref.id] == nil, let payload = provider(ref) {
                    result[ref.id] = payload
                }
            }
        }
        return result
    }
}
