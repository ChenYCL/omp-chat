import Foundation

/// One tool as a server describes it in `tools/list`.
public struct MCPTool: Hashable, Sendable {
    public var name: String
    public var title: String?
    public var description: String
    /// JSON Schema of the arguments.
    public var inputSchema: JSONValue
    /// Behaviour hints from `annotations`. Self-reported by the server, so
    /// only trusted for catalog servers (see `MCPToolProvider.risk`).
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var openWorldHint: Bool?

    public init(
        name: String, title: String? = nil, description: String = "",
        inputSchema: JSONValue = .object(["type": .string("object")]),
        readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, openWorldHint: Bool? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.openWorldHint = openWorldHint
    }

    init?(json: JSONValue) {
        guard let name = json.mcpField("name")?.mcpString, !name.isEmpty else { return nil }
        let annotations = json.mcpField("annotations")
        self.init(
            name: name,
            title: json.mcpField("title")?.mcpString ?? annotations?.mcpField("title")?.mcpString,
            description: json.mcpField("description")?.mcpString ?? "",
            inputSchema: json.mcpField("inputSchema") ?? .object(["type": .string("object")]),
            readOnlyHint: annotations?.mcpField("readOnlyHint")?.mcpBool,
            destructiveHint: annotations?.mcpField("destructiveHint")?.mcpBool,
            openWorldHint: annotations?.mcpField("openWorldHint")?.mcpBool
        )
    }

    public var displayName: String { title ?? name }
}

/// The result of `tools/call`.
public struct MCPToolResult: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case text(String)
        case image(data: Data, mimeType: String)
        case audio(mimeType: String, byteCount: Int)
        /// An embedded resource; `text` is nil for a binary blob.
        case resource(uri: String, mimeType: String?, text: String?)
        case resourceLink(uri: String, name: String?, description: String?)
    }

    public var blocks: [Block]
    public var structuredContent: JSONValue?
    public var isError: Bool

    public init(blocks: [Block], structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.blocks = blocks
        self.structuredContent = structuredContent
        self.isError = isError
    }

    init(json: JSONValue) {
        var blocks: [Block] = []
        for item in json.mcpField("content")?.mcpArray ?? [] {
            switch item.mcpField("type")?.mcpString {
            case "text":
                blocks.append(.text(item.mcpField("text")?.mcpString ?? ""))
            case "image":
                let mime = item.mcpField("mimeType")?.mcpString ?? "image/png"
                if let base64 = item.mcpField("data")?.mcpString,
                   let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                    blocks.append(.image(data: data, mimeType: mime))
                } else {
                    blocks.append(.text("[图片数据无法解码]"))
                }
            case "audio":
                let base64 = item.mcpField("data")?.mcpString ?? ""
                let size = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)?.count ?? 0
                blocks.append(.audio(mimeType: item.mcpField("mimeType")?.mcpString ?? "audio", byteCount: size))
            case "resource":
                let resource = item.mcpField("resource")
                blocks.append(.resource(
                    uri: resource?.mcpField("uri")?.mcpString ?? "",
                    mimeType: resource?.mcpField("mimeType")?.mcpString,
                    text: resource?.mcpField("text")?.mcpString
                ))
            case "resource_link":
                blocks.append(.resourceLink(
                    uri: item.mcpField("uri")?.mcpString ?? "",
                    name: item.mcpField("name")?.mcpString,
                    description: item.mcpField("description")?.mcpString
                ))
            default:
                blocks.append(.text(item.mcpJSONText()))
            }
        }
        self.init(
            blocks: blocks,
            structuredContent: json.mcpField("structuredContent"),
            isError: json.mcpField("isError")?.mcpBool ?? false
        )
    }

    /// What the model sees: text blocks in order, images attached. Structured
    /// content is only sent when there is no text (servers SHOULD mirror it
    /// as text already).
    public var agentOutput: AgentToolOutput {
        var lines: [String] = []
        var images: [AgentToolImage] = []
        for block in blocks {
            switch block {
            case .text(let text):
                lines.append(text)
            case .image(let data, let mimeType):
                images.append(AgentToolImage(data: data, mimeType: mimeType))
            case .audio(let mimeType, let byteCount):
                lines.append("[音频 \(mimeType)，\(byteCount) 字节，未转给模型]")
            case .resource(let uri, let mimeType, let text):
                if let text {
                    lines.append("资源 \(uri)：\n\(text)")
                } else {
                    lines.append("[二进制资源 \(uri)\(mimeType.map { "（\($0)）" } ?? "")]")
                }
            case .resourceLink(let uri, let name, let description):
                var line = "链接 \(name.map { "\($0) " } ?? "")<\(uri)>"
                if let description, !description.isEmpty { line += "：\(description)" }
                lines.append(line)
            }
        }
        if lines.isEmpty, let structuredContent {
            lines.append(structuredContent.mcpJSONText())
        }
        if lines.isEmpty, images.isEmpty {
            lines.append(isError ? "工具报告失败，没有说明原因" : "工具没有返回内容")
        }
        return AgentToolOutput(text: lines.joined(separator: "\n"), isError: isError, images: images)
    }
}

/// An MCP client over any transport: the `initialize` handshake, `tools/list`
/// and `tools/call`, request timeouts and cancellation, and the server
/// requests a client must answer.
public actor MCPClient {
    public struct Timeouts: Sendable {
        /// First launch of an `npx`/`uvx` server includes the package download.
        public var initialize: Duration
        public var list: Duration
        public var call: Duration

        public init(initialize: Duration = .seconds(120), list: Duration = .seconds(30), call: Duration = .seconds(300)) {
            self.initialize = initialize
            self.list = list
            self.call = call
        }
    }

    public struct ServerInfo: Equatable, Sendable {
        public var name: String
        public var version: String
        public var protocolVersion: String
        public var instructions: String?
    }

    public enum Event: Sendable {
        /// The server announced a new tool list and it has been fetched.
        case toolsChanged([MCPTool])
        case closed(reason: String)
    }

    /// The version proposed in `initialize`.
    public static let protocolVersion = "2025-06-18"
    /// Versions accepted when the server counter-offers.
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private struct Pending {
        var method: String
        var continuation: CheckedContinuation<JSONValue, Error>
        var timer: Task<Void, Never>?
        /// `initialize` must never be cancelled (spec).
        var cancellable: Bool
    }

    private let transport: any MCPTransport
    private let timeouts: Timeouts
    private let onEvent: @Sendable (Event) -> Void
    private var pending: [MCPRequestID: Pending] = [:]
    private var nextID = 1
    private var reader: Task<Void, Never>?
    private var closedReason: String?

    public private(set) var serverInfo: ServerInfo?
    public private(set) var tools: [MCPTool] = []

    public init(transport: any MCPTransport, timeouts: Timeouts = Timeouts(), onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.transport = transport
        self.timeouts = timeouts
        self.onEvent = onEvent
    }

    /// Opens the transport, runs the handshake and fetches the tools. On
    /// failure the caller closes the client.
    public func connect() async throws {
        let stream = try await transport.connect()
        reader = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
        let params: JSONValue = .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("OMPChat"), "title": .string("OMPChat"), "version": .string("1.0")]),
        ])
        let result = try await request("initialize", params: params, timeout: timeouts.initialize, cancellable: false)
        guard let version = result.mcpField("protocolVersion")?.mcpString else {
            throw MCPError.badResponse("initialize 的结果里没有 protocolVersion")
        }
        guard Self.supportedProtocolVersions.contains(version) else {
            throw MCPError.unsupportedProtocolVersion(version)
        }
        let info = result.mcpField("serverInfo")
        serverInfo = ServerInfo(
            name: info?.mcpField("name")?.mcpString ?? "",
            version: info?.mcpField("version")?.mcpString ?? "",
            protocolVersion: version,
            instructions: result.mcpField("instructions")?.mcpString
        )
        try await transport.send(MCPMessage.notification(method: "notifications/initialized", params: nil).encoded())
        await transport.didInitialize(protocolVersion: version)
        tools = try await listTools()
    }

    /// Every tool, following `nextCursor` until the server stops paging.
    public func listTools() async throws -> [MCPTool] {
        var collected: [MCPTool] = []
        var names = Set<String>()
        var cursor: String?
        var seenCursors = Set<String>()
        // A server that hands back the same cursor would loop forever.
        for _ in 0..<100 {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request("tools/list", params: .object(params), timeout: timeouts.list)
            for item in result.mcpField("tools")?.mcpArray ?? [] {
                if let tool = MCPTool(json: item), names.insert(tool.name).inserted {
                    collected.append(tool)
                }
            }
            guard let next = result.mcpField("nextCursor")?.mcpString, !next.isEmpty,
                  seenCursors.insert(next).inserted else { break }
            cursor = next
        }
        return collected
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> MCPToolResult {
        let params: JSONValue = .object(["name": .string(name), "arguments": arguments])
        let result = try await request("tools/call", params: params, timeout: timeouts.call)
        return MCPToolResult(json: result)
    }

    /// Ends the connection; outstanding requests fail with `.closed`.
    public func close() async {
        if closedReason == nil { closedReason = "已断开" }
        failAll(MCPError.closed(closedReason ?? "已断开"))
        await transport.close()
    }

    // MARK: Requests

    /// Sends a request and waits for its response. Throws `.timedOut` after
    /// `timeout`, and `CancellationError` when the calling task is cancelled;
    /// both tell the server with `notifications/cancelled`.
    func request(_ method: String, params: JSONValue?, timeout: Duration, cancellable: Bool = true) async throws -> JSONValue {
        if let closedReason { throw MCPError.closed(closedReason) }
        let id = MCPRequestID.int(nextID)
        nextID += 1
        let message = MCPMessage.request(id: id, method: method, params: params).encoded()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.abandon(id, error: MCPError.timedOut(method: method, seconds: Int(timeout.components.seconds)), reason: "timed out")
                }
                pending[id] = Pending(method: method, continuation: continuation, timer: timer, cancellable: cancellable)
                let transport = self.transport
                Task { [weak self] in
                    do {
                        try await transport.send(message)
                    } catch {
                        await self?.sendFailed(id, error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.abandon(id, error: CancellationError(), reason: "cancelled by the client") }
        }
    }

    /// Stops waiting for `id` and, when allowed, tells the server to stop too.
    private func abandon(_ id: MCPRequestID, error: Error, reason: String) async {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        entry.continuation.resume(throwing: error)
        guard entry.cancellable, closedReason == nil else { return }
        let notice = MCPMessage.notification(method: "notifications/cancelled", params: .object([
            "requestId": id.json, "reason": .string(reason),
        ]))
        try? await transport.send(notice.encoded())
    }

    /// A write to a server that just died fails before the transport reports
    /// how it died. Give the reader a moment so the call fails with the real
    /// reason (exit status) instead of a bare broken pipe.
    private func sendFailed(_ id: MCPRequestID, _ error: Error) async {
        if case MCPError.closed = error, closedReason == nil {
            try? await Task.sleep(for: .seconds(1))
        }
        resolve(id, with: .failure(error))
    }

    private func resolve(_ id: MCPRequestID, with result: Result<JSONValue, Error>) {
        // A response that arrives after a timeout or cancellation is ignored.
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        entry.continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let entries = pending.values
        pending.removeAll()
        for entry in entries {
            entry.timer?.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    // MARK: Incoming

    private func handle(_ event: MCPTransportEvent) {
        switch event {
        case .message(let data):
            for message in MCPMessage.decodeAll(data) { dispatch(message) }
        case .closed(let reason):
            guard closedReason == nil else { return }
            closedReason = reason
            failAll(MCPError.closed(reason))
            onEvent(.closed(reason: reason))
        }
    }

    /// Never awaits a response itself: the reader delivers responses, so
    /// waiting here would deadlock. Follow-up work runs in its own task.
    private func dispatch(_ message: MCPMessage) {
        switch message {
        case .response(let id, let result):
            resolve(id, with: .success(result))
        case .error(let id?, let code, let text):
            resolve(id, with: .failure(MCPError.server(code: code, message: text)))
        case .error(nil, _, _):
            break
        case .request(let id, let method, _):
            let reply: MCPMessage = method == "ping"
                ? .response(id: id, result: .object([:]))
                : .error(id: id, code: MCPMessage.methodNotFound, message: "Method not found: \(method)")
            let transport = self.transport
            Task { try? await transport.send(reply.encoded()) }
        case .notification(let method, _):
            if method == "notifications/tools/list_changed" {
                Task { [weak self] in await self?.refreshTools() }
            }
        }
    }

    private func refreshTools() async {
        guard closedReason == nil, let fresh = try? await listTools() else { return }
        tools = fresh
        onEvent(.toolsChanged(fresh))
    }
}
