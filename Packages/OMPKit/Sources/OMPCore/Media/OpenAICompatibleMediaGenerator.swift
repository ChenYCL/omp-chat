import Foundation

/// OpenAI-compatible image generation / editing (`/v1/images/*`).
///
/// Mirrors the wire shape every relay (OpenAI, ccLoad, one-api, …) accepts:
/// JSON for generation, multipart for editing.
public struct OpenAICompatibleMediaGenerator: MediaGenerating {
    private let profile: ProviderProfile
    private let apiKey: String
    private let transport: HTTPTransport
    private let library: MediaLibrary
    private let imagesPath: String

    public init(
        profile: ProviderProfile,
        apiKey: String,
        transport: HTTPTransport = URLSessionTransport(),
        library: MediaLibrary = .default(),
        imagesPath: String = "/v1/images/generations"
    ) {
        self.profile = profile
        self.apiKey = apiKey
        self.transport = transport
        self.library = library
        self.imagesPath = imagesPath
    }

    public func generateImage(_ request: ImageGenerationRequest) async throws -> MediaRef {
        var body: [String: JSONValue] = [
            "model": .string(request.modelID),
            "prompt": .string(request.prompt),
            "n": .number(Double(max(1, request.count))),
            "response_format": .string("b64_json"),
        ]
        if let size = request.size, !size.isEmpty { body["size"] = .string(size) }

        var urlRequest = URLRequest(url: profile.resolvedURL(path: imagesPath))
        urlRequest.httpMethod = "POST"
        applyHeaders(to: &urlRequest, contentType: "application/json")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let response = try await transport.send(urlRequest)
        try Self.validate(response)
        return try await materialize(response.body)
    }

    public func editImage(_ request: ImageEditRequest) async throws -> MediaRef {
        let sourceData = try Data(contentsOf: library.url(for: request.source))
        var fields: [MultipartBuilder.Field] = [
            .text(name: "model", value: request.modelID),
            .text(name: "prompt", value: request.prompt),
            .text(name: "response_format", value: "b64_json"),
        ]
        if let size = request.size, !size.isEmpty {
            fields.append(.text(name: "size", value: size))
        }
        fields.append(.file(
            name: "image",
            filename: request.source.originalName ?? "image.png",
            mimeType: request.source.mimeType,
            data: sourceData
        ))
        if let mask = request.mask {
            fields.append(.file(
                name: "mask",
                filename: mask.originalName ?? "mask.png",
                mimeType: mask.mimeType,
                data: try Data(contentsOf: library.url(for: mask))
            ))
        }

        let builder = MultipartBuilder(boundary: "OMPChat-\(UUID().uuidString)")
        var urlRequest = URLRequest(url: profile.resolvedURL(path: "/v1/images/edits"))
        urlRequest.httpMethod = "POST"
        applyHeaders(to: &urlRequest, contentType: "multipart/form-data; boundary=\(builder.boundary)")
        urlRequest.httpBody = builder.encode(fields)

        let response = try await transport.send(urlRequest)
        try Self.validate(response)
        return try await materialize(response.body)
    }

    public func generateVideo(_ request: VideoGenerationRequest) async throws -> AsyncThrowingStream<MediaJobEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderError.unsupported("当前供应商未配置视频生成接口"))
        }
    }

    // MARK: - Internals

    private func applyHeaders(to request: inout URLRequest, contentType: String) {
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in profile.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
    }

    private static func validate(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.http(status: response.statusCode, body: String(decoding: response.body, as: UTF8.self))
        }
    }

    private struct ImagesResponse: Decodable {
        struct Item: Decodable {
            var b64JSON: String?
            var url: String?
            enum CodingKeys: String, CodingKey {
                case b64JSON = "b64_json"
                case url
            }
        }
        var data: [Item]
    }

    private func materialize(_ body: Data) async throws -> MediaRef {
        guard let payload = try? JSONDecoder().decode(ImagesResponse.self, from: body),
              let item = payload.data.first else {
            throw ProviderError.decoding("图片接口未返回数据")
        }
        let data: Data
        if let base64 = item.b64JSON, let decoded = Data(base64Encoded: base64) {
            data = decoded
        } else if let urlString = item.url, let url = URL(string: urlString) {
            var download = URLRequest(url: url)
            download.httpMethod = "GET"
            let response = try await transport.send(download)
            try Self.validate(response)
            data = response.body
        } else {
            throw ProviderError.decoding("图片接口缺少 b64_json / url")
        }
        return try library.write(data: data, fileExtension: "png", kind: .image, mimeType: "image/png")
    }
}

// MARK: - Attachments

public struct MultipartBuilder {
    public enum Field {
        case text(name: String, value: String)
        case file(name: String, filename: String, mimeType: String, data: Data)
    }

    public let boundary: String

    public init(boundary: String) {
        self.boundary = boundary
    }

    public func encode(_ fields: [Field]) -> Data {
        var data = Data()
        for field in fields {
            data.append(Data("--\(boundary)\r\n".utf8))
            switch field {
            case .text(let name, let value):
                data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                data.append(Data(value.utf8))
                data.append(Data("\r\n".utf8))
            case .file(let name, let filename, let mimeType, let payload):
                data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
                data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
                data.append(payload)
                data.append(Data("\r\n".utf8))
            }
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }
}

public extension MediaLibrary {
    func loadData(for ref: MediaRef) throws -> Data {
        try Data(contentsOf: url(for: ref))
    }

    func loadPayload(for ref: MediaRef) -> MediaPayload? {
        guard let data = try? loadData(for: ref) else { return nil }
        return MediaPayload(mimeType: ref.mimeType, base64: data.base64EncodedString())
    }

    /// Copies a user-picked file into the sandbox and returns its reference.
    func importFile(at sourceURL: URL) throws -> MediaRef {
        let data = try Data(contentsOf: sourceURL)
        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension.lowercased()
        let kind: MediaKind
        let mime: String
        switch ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp":
            kind = .image
            mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/\(ext == "heic" ? "heic" : ext)"
        case "mp4", "mov":
            kind = .video
            mime = "video/\(ext)"
        case "mp3", "wav", "m4a":
            kind = .audio
            mime = "audio/\(ext)"
        default:
            kind = .file
            mime = "application/octet-stream"
        }
        var ref = try write(data: data, fileExtension: ext, kind: kind, mimeType: mime)
        ref.originalName = sourceURL.lastPathComponent
        return ref
    }
}
