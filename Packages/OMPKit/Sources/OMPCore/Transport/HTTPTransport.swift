import Foundation

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error>
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 3600
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.transport("非 HTTP 响应")
            }
            return HTTPResponse(statusCode: http.statusCode, headers: Self.headers(from: http), body: data)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }

    public func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transport("非 HTTP 响应")
        }
        if http.statusCode >= 400 {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64 * 1024 { break }
            }
            throw ProviderError.http(status: http.statusCode, body: String(decoding: body, as: UTF8.self))
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var chunk = Data()
                chunk.reserveCapacity(512)
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 256 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish(throwing: ProviderError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key)] = String(describing: value)
        }
        return result
    }
}
