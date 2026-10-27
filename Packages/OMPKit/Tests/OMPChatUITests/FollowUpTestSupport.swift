import XCTest
import OMPCore
@testable import OMPChatUI

/// Opens once; whatever waits on it then goes on.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func release() { lock.lock(); open = true; lock.unlock() }
}

/// Answers each streamed request with the next step and keeps every request
/// body. A gated step holds its stream open until the test releases it.
/// Never touches the network.
final class FollowUpTransport: HTTPTransport, @unchecked Sendable {
    enum Step {
        case body(String)
        case gated(TestGate, String)
        /// The stream fails, the way a dropped connection does.
        case fail
        case gatedFail(TestGate)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var bodies: [Data] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return bodies.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bodies.count
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"object":"list","data":[{"id":"mock-model","object":"model"}]}"#.utf8))
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        bodies.append(request.httpBody ?? Data())
        let step = steps.isEmpty ? .body(FollowUpSSE.answer("（脚本已结束）")) : steps.removeFirst()
        lock.unlock()
        switch step {
        case .body(let body):
            return AsyncThrowingStream { continuation in
                continuation.yield(Data(body.utf8))
                continuation.finish()
            }
        case .fail:
            throw URLError(.networkConnectionLost)
        case .gated(let gate, let body):
            return Self.held(by: gate) { continuation in
                continuation.yield(Data(body.utf8))
                continuation.finish()
            }
        case .gatedFail(let gate):
            return Self.held(by: gate) { continuation in
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
        }
    }

    private static func held(
        by gate: TestGate,
        then finish: @escaping @Sendable (AsyncThrowingStream<Data, Error>.Continuation) -> Void
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !gate.isOpen {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                finish(continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum FollowUpSSE {
    static func event(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    static func answer(_ text: String) -> String {
        event(["choices": [["delta": ["content": text], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
    }

    static func call(_ id: String, _ name: String, _ arguments: String = "{}") -> String {
        event(["choices": [["delta": ["tool_calls": [[
            "index": 0, "id": id, "type": "function",
            "function": ["name": name, "arguments": arguments],
        ]]]]]])
            + event(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]) + "data: [DONE]\n\n"
    }
}

/// `probe` reads, `poke` writes, `wait_probe` reads once its gate opens.
final class GateProbe: AgentToolProvider, @unchecked Sendable {
    let gate = TestGate()
    private let lock = NSLock()
    private var recorded: [String] = []

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func tools() async -> [AgentToolSpec] {
        [
            AgentToolSpec(name: "probe", description: "读点东西", parametersJSON: #"{"type":"object"}"#, risk: .read, source: "测试"),
            AgentToolSpec(name: "wait_probe", description: "慢慢读", parametersJSON: #"{"type":"object"}"#, risk: .read, source: "测试"),
            AgentToolSpec(name: "poke", description: "改点东西", parametersJSON: #"{"type":"object"}"#, risk: .write, source: "测试"),
        ]
    }

    func call(_ name: String, argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolOutput {
        lock.lock()
        recorded.append(name)
        lock.unlock()
        if name == "wait_probe" {
            while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
        }
        return AgentToolOutput(text: "\(name) 输出")
    }
}

@MainActor
enum FollowUpHarness {
    static func makeModel(
        _ transport: FollowUpTransport,
        probe: GateProbe = GateProbe(),
        libraryRoot: URL,
        mode: PermissionMode = .ask,
        tools: Bool? = true
    ) async throws -> (ChatAppModel, UUID) {
        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: libraryRoot),
            transport: transport
        )
        await model.bootstrap()
        await model.addProvider(ProviderProfile(name: "Mock", kind: .openAICompatible, baseURL: URL(string: "https://mock.test")!), apiKey: "sk-test")
        model.setToolProvider(id: "test", probe)
        let id = try XCTUnwrap(model.selectedConversationID)
        model.setToolsEnabled(tools, for: id)
        model.setPermissionMode(mode, for: id)
        return (model, id)
    }

    static func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }

    /// A request's messages as `[role, text]`; tool calls show as `tool_calls`.
    static func transcript(_ request: [String: Any]) -> [[String]] {
        ((request["messages"] as? [[String: Any]]) ?? []).map { message in
            let role = message["role"] as? String ?? "?"
            if message["tool_calls"] != nil { return [role, "tool_calls"] }
            if let text = message["content"] as? String { return [role, text] }
            let parts = (message["content"] as? [[String: Any]]) ?? []
            return [role, parts.compactMap { $0["text"] as? String }.joined()]
        }
    }
}
