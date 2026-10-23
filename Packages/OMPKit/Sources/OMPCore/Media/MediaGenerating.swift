import Foundation

public protocol MediaGenerating: Sendable {
    func generateImage(_ request: ImageGenerationRequest) async throws -> MediaRef
    func editImage(_ request: ImageEditRequest) async throws -> MediaRef
    func generateVideo(_ request: VideoGenerationRequest) async throws -> AsyncThrowingStream<MediaJobEvent, Error>
}

/// Resolves on-disk locations for media owned by the app.
public struct MediaLibrary: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public static func `default`() -> MediaLibrary {
        let root = FileConversationStore.defaultDirectory().appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MediaLibrary(rootURL: root)
    }

    public func url(for ref: MediaRef) -> URL {
        rootURL.appendingPathComponent(ref.relativePath)
    }

    public func write(data: Data, fileExtension: String, kind: MediaKind, mimeType: String) throws -> MediaRef {
        let name = "\(UUID().uuidString).\(fileExtension)"
        let destination = rootURL.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        return MediaRef(kind: kind, relativePath: name, mimeType: mimeType, byteCount: data.count)
    }
}
