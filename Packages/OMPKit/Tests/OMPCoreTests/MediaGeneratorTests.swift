import XCTest
@testable import OMPCore

private final class CaptureBox: @unchecked Sendable {
    var request: URLRequest?
}

private struct StubTransport: HTTPTransport {
    var body: Data
    var statusCode: Int = 200
    var streamFailure: Error?
    var captured: CaptureBox?

    init(body: Data, statusCode: Int = 200, streamFailure: Error? = nil, captured: CaptureBox? = nil) {
        self.body = body
        self.statusCode = statusCode
        self.streamFailure = streamFailure
        self.captured = captured
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        captured?.request = request
        return HTTPResponse(statusCode: statusCode, headers: [:], body: body)
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        if let streamFailure { throw streamFailure }
        return AsyncThrowingStream { continuation in
            continuation.yield(Data())
            continuation.finish()
        }
    }
}

final class MediaGeneratorTests: XCTestCase {
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("omp-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    func testGenerateImageMaterializesBase64Payload() async throws {
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let payload = ["data": [["b64_json": onePixelPNG.base64EncodedString()]]]
        let body = try JSONSerialization.data(withJSONObject: payload)

        let box = CaptureBox()
        let transport = StubTransport(body: body, captured: box)
        let library = MediaLibrary(rootURL: libraryRoot)
        let provider = ProviderProfile(name: "p", kind: .openAICompatible, baseURL: URL(string: "https://img.test")!)
        let generator = OpenAICompatibleMediaGenerator(profile: provider, apiKey: "k", transport: transport, library: library)

        let ref = try await generator.generateImage(ImageGenerationRequest(modelID: "img-1", prompt: "a cat", size: "1024x1024"))

        XCTAssertEqual(ref.mimeType, "image/png")
        XCTAssertEqual(ref.kind, .image)
        let url = library.url(for: ref)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, onePixelPNG)

        let request = try XCTUnwrap(box.request)
        XCTAssertEqual(request.url?.absoluteString, "https://img.test/v1/images/generations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testHTTPErrorSurfaces() async throws {
        let transport = StubTransport(
            body: Data("nope".utf8),
            statusCode: 500
        )
        let library = MediaLibrary(rootURL: libraryRoot)
        let provider = ProviderProfile(name: "p", kind: .openAICompatible, baseURL: URL(string: "https://img.test")!)
        let generator = OpenAICompatibleMediaGenerator(profile: provider, apiKey: "k", transport: transport, library: library)

        do {
            _ = try await generator.generateImage(ImageGenerationRequest(modelID: "img-1", prompt: "x"))
            XCTFail("expected failure")
        } catch let error as ProviderError {
            guard case .http(let status, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(status, 500)
        }
    }

    func testMultipartEncodingProducesWellFormedBody() {
        let builder = MultipartBuilder(boundary: "BOUND")
        let data = builder.encode([
            .text(name: "model", value: "img"),
            .file(name: "image", filename: "a.png", mimeType: "image/png", data: Data([0x89, 0x50])),
        ])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--BOUND\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"model\"\r\n\r\nimg\r\n"))
        XCTAssertTrue(text.contains("filename=\"a.png\""))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
    }
}
