import Foundation

/// OpenAI `/v1/chat/completions` + `/v1/models` dialect.
public struct OpenAICompatibleProvider: ChatProvider {
    public let profile: ProviderProfile
    private let apiKey: String
    private let transport: HTTPTransport

    public init(profile: ProviderProfile, apiKey: String, transport: HTTPTransport = URLSessionTransport()) {
        self.profile = profile
        self.apiKey = apiKey
        self.transport = transport
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        var request = URLRequest(url: profile.resolvedURL(path: profile.modelsPath))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in profile.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }

        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.http(status: response.statusCode, body: String(decoding: response.body, as: UTF8.self))
        }
        let payload = try JSONDecoder().decode(OpenAIModelsResponse.self, from: response.body)
        return payload.data.map { entry in
            ModelDescriptor(
                id: entry.id,
                providerID: profile.id,
                displayName: entry.id,
                capabilities: ModelCapabilityInference.infer(modelID: entry.id, raw: entry.rawMetadata()),
                limits: ModelLimitInference.infer(modelID: entry.id),
                ownedBy: entry.ownedBy,
                createdAt: entry.created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                rawMetadata: entry.rawMetadata()
            )
        }
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeRequest(request)
                    let stream = try await transport.stream(urlRequest)
                    var parser = SSEParser()
                    var finishReason: FinishReason?
                    var usage: TokenUsage?
                    var sawTerminalMarker = false

                    for try await chunk in stream {
                        for event in parser.consume(chunk) {
                            if event.data == "[DONE]" {
                                sawTerminalMarker = true
                                continue
                            }
                            guard !event.data.isEmpty else { continue }
                            if let decoded = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: Data(event.data.utf8)) {
                                if let delta = decoded.choices?.first?.delta {
                                    if let reasoning = delta.reasoningContent ?? delta.reasoning, !reasoning.isEmpty {
                                        continuation.yield(.thinkingDelta(reasoning))
                                    }
                                    if let text = delta.content, !text.isEmpty {
                                        continuation.yield(.textDelta(text))
                                    }
                                    if let calls = delta.toolCalls {
                                        for call in calls {
                                            continuation.yield(.toolCallDelta(
                                                index: call.index ?? 0,
                                                id: call.id,
                                                name: call.function?.name,
                                                argumentsDelta: call.function?.arguments
                                            ))
                                        }
                                    }
                                }
                                if let reason = decoded.choices?.first?.finishReason {
                                    finishReason = FinishReason(rawWire: reason)
                                }
                                if let rawUsage = decoded.usage {
                                    usage = TokenUsage(
                                        inputTokens: rawUsage.promptTokens ?? 0,
                                        outputTokens: rawUsage.completionTokens ?? 0,
                                        reasoningTokens: rawUsage.completionTokensDetails?.reasoningTokens ?? 0
                                    )
                                }
                            }
                        }
                    }
                    if let flushed = parser.finish(), !flushed.data.isEmpty, flushed.data != "[DONE]" {
                        // Best effort: emit a trailing text payload from relays that omit a newline.
                        if let decoded = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: Data(flushed.data.utf8)),
                           let text = decoded.choices?.first?.delta?.content, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                    }
                    if let usage { continuation.yield(.usage(usage)) }
                    let terminal: FinishReason = finishReason ?? (sawTerminalMarker ? .stop : .stop)
                    continuation.yield(.finished(terminal))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(_ request: GenerationRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: profile.resolvedURL(path: profile.chatPath))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in profile.extraHeaders { urlRequest.setValue(value, forHTTPHeaderField: key) }

        let body = OpenAIRequestBuilder.build(request)
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }
}

enum FinishReasonWire {
    static func map(_ raw: String) -> FinishReason {
        switch raw {
        case "stop": .stop
        case "length": .length
        case "tool_calls", "function_call": .toolCalls
        case "content_filter": .contentFilter
        default: .stop
        }
    }
}

extension FinishReason {
    init(rawWire: String) { self = FinishReasonWire.map(rawWire) }
}
