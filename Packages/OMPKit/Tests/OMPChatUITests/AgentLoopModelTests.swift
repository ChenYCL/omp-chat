import XCTest
import OMPCore
@testable import OMPChatUI

/// Answers each streamed request with the next scripted SSE body and keeps
/// every request body. Never touches the network.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String]
    private let repeatLast: Bool
    private var bodies: [Data] = []

    init(_ script: [String], repeatLast: Bool = false) {
        self.script = script
        self.repeatLast = repeatLast
    }

    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return bodies.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"object":"list","data":[{"id":"mock-model","object":"model"}]}"#.utf8))
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        bodies.append(request.httpBody ?? Data())
        let body: String
        if script.count > 1 || (!repeatLast && !script.isEmpty) {
            body = script.removeFirst()
        } else {
            body = script.first ?? SSE.answer("（脚本已结束）")
        }
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(Data(body.utf8))
            continuation.finish()
        }
    }
}

private enum SSE {
    static func event(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    static func answer(_ text: String) -> String {
        event(["choices": [["delta": ["content": text], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
    }

    /// One turn calling `calls` in order, arguments streamed in two pieces.
    static func calls(_ calls: [(id: String, name: String, arguments: String)]) -> String {
        var body = ""
        for (index, call) in calls.enumerated() {
            let half = call.arguments.index(call.arguments.startIndex, offsetBy: call.arguments.count / 2)
            body += event(["choices": [["delta": ["tool_calls": [[
                "index": index, "id": call.id, "type": "function",
                "function": ["name": call.name, "arguments": String(call.arguments[..<half])],
            ]]]]]])
            body += event(["choices": [["delta": ["tool_calls": [[
                "index": index, "function": ["arguments": String(call.arguments[half...])],
            ]]]]]])
        }
        return body + event(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]) + "data: [DONE]\n\n"
    }

    static func call(_ id: String, _ name: String, _ arguments: String = "{}") -> String {
        calls([(id, name, arguments)])
    }
}

/// A scripted tool provider registered beside the built-ins.
private final class ProbeProvider: AgentToolProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    let image: AgentToolImage?

    init(image: AgentToolImage? = nil) {
        self.image = image
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func tools() async -> [AgentToolSpec] {
        [
            AgentToolSpec(name: "probe", description: "读点东西", parametersJSON: #"{"type":"object","properties":{"q":{"type":"string"}}}"#, risk: .read, source: "测试"),
            AgentToolSpec(name: "poke", description: "改点东西", parametersJSON: #"{"type":"object"}"#, risk: .write, source: "测试"),
            AgentToolSpec(name: "slow_probe", description: "很慢", parametersJSON: #"{"type":"object"}"#, risk: .read, source: "测试"),
        ]
    }

    func call(_ name: String, argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolOutput {
        lock.lock()
        recorded.append(name)
        lock.unlock()
        if name == "slow_probe" { try await Task.sleep(for: .seconds(30)) }
        return AgentToolOutput(text: "\(name) 输出 \(argumentsJSON)", images: image.map { [$0] } ?? [])
    }
}

@MainActor
final class AgentLoopModelTests: XCTestCase {
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("agent-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    private func makeModel(
        _ transport: ScriptedTransport,
        probe: ProbeProvider = ProbeProvider(),
        store: InMemoryConversationStore = InMemoryConversationStore(),
        mode: PermissionMode = .ask,
        tools: Bool? = true
    ) async throws -> (ChatAppModel, UUID) {
        let model = ChatAppModel(
            store: store,
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

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }

    private func results(_ model: ChatAppModel) -> [ToolResult] {
        (model.selectedConversation?.messages ?? []).flatMap(\.parts).compactMap { part in
            if case .toolResult(let result) = part { result } else { nil }
        }
    }

    private func toolMessages(_ request: [String: Any]) -> [[String: Any]] {
        ((request["messages"] as? [[String: Any]]) ?? []).filter { $0["role"] as? String == "tool" }
    }

    func testToolCallThenAnswerOverTheWire() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "probe", #"{"q":"swift"}"#), SSE.answer("完成了")])
        let probe = ProbeProvider()
        let (model, _) = try await makeModel(transport, probe: probe)
        await model.sendNow(text: "查一下", attachments: [])
        try await waitUntil { !model.isStreaming }

        XCTAssertEqual(probe.calls, ["probe"])
        let messages = try XCTUnwrap(model.selectedConversation?.messages)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .assistant])
        XCTAssertEqual(messages[1].parts.compactMap { if case .toolResult(let r) = $0 { r.callID } else { nil } }, ["c1"],
                       "结果和调用放在同一条助手消息里")
        XCTAssertEqual(messages[2].concatenatedText, "完成了")
        XCTAssertEqual(messages[2].status, .complete)

        let requests = transport.requests
        XCTAssertEqual(requests.count, 2)
        let offered = (requests[0]["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(offered.contains("probe"))
        let system = (requests[0]["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        XCTAssertTrue(system.contains("【工具】"), "提供工具时系统提示带工具说明")
        XCTAssertTrue(toolMessages(requests[0]).isEmpty)

        let second = try XCTUnwrap(requests[1]["messages"] as? [[String: Any]])
        let assistantIndex = try XCTUnwrap(second.firstIndex { $0["tool_calls"] != nil })
        let calls = try XCTUnwrap(second[assistantIndex]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "c1")
        XCTAssertEqual((calls.first?["function"] as? [String: Any])?["arguments"] as? String, #"{"q":"swift"}"#)
        XCTAssertEqual(second[assistantIndex + 1]["role"] as? String, "tool")
        XCTAssertEqual(second[assistantIndex + 1]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(second[assistantIndex + 1]["content"] as? String, #"probe 输出 {"q":"swift"}"#)
    }

    func testApprovalHoldsTheLoopWithStopButtonShowing() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "poke"), SSE.answer("改好了")])
        let probe = ProbeProvider()
        let (model, id) = try await makeModel(transport, probe: probe)
        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }

        XCTAssertTrue(model.isStreaming, "等待批准时停止按钮仍在")
        let card = try XCTUnwrap(model.pendingApprovals.first)
        XCTAssertEqual(card.toolName, "poke")
        XCTAssertEqual(card.callID, "c1")
        XCTAssertEqual(card.conversationID, id)
        XCTAssertEqual(card.risk, .write)
        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)

        model.resolveApproval(card.id, .allowOnce)
        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(probe.calls, ["poke"])
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertFalse(model.alwaysAllowedTools.contains("poke"))
        XCTAssertEqual(model.selectedConversation?.messages.last?.concatenatedText, "改好了")
    }

    func testDenyIsReportedToTheModelAndTheLoopContinues() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "poke"), SSE.answer("那我不改了")])
        let probe = ProbeProvider()
        let (model, _) = try await makeModel(transport, probe: probe)
        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        model.resolveApproval(try XCTUnwrap(model.pendingApprovals.first).id, .deny)
        try await waitUntil { !model.isStreaming }

        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertEqual(results(model).first?.outputText, AgentLoop.deniedText)
        XCTAssertEqual(toolMessages(transport.requests[1]).first?["content"] as? String, AgentLoop.deniedText)
        XCTAssertEqual(model.selectedConversation?.messages.last?.concatenatedText, "那我不改了")
    }

    func testAllowAlwaysSkipsLaterCardsForThatTool() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "poke"), SSE.call("c2", "poke"), SSE.answer("都好了")])
        let probe = ProbeProvider()
        let (model, _) = try await makeModel(transport, probe: probe)
        await model.sendNow(text: "改两次", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        model.resolveApproval(try XCTUnwrap(model.pendingApprovals.first).id, .allowAlways)
        try await waitUntil { !model.isStreaming }

        XCTAssertEqual(probe.calls, ["poke", "poke"])
        XCTAssertTrue(model.alwaysAllowedTools.contains("poke"))
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testStopDuringApprovalRefusesItAndEndsTheReply() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "poke"), SSE.answer("不该出现")])
        let probe = ProbeProvider()
        let (model, _) = try await makeModel(transport, probe: probe)
        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        model.stop()
        try await waitUntil { !model.isStreaming }

        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertEqual(results(model).map(\.outputText), [AgentLoop.stoppedText])
        XCTAssertEqual(transport.requests.count, 1, "停止后不再请求模型")
    }

    func testStopDuringToolCancelsIt() async throws {
        let transport = ScriptedTransport([SSE.calls([("c1", "slow_probe", "{}"), ("c2", "probe", "{}")]), SSE.answer("不该出现")])
        let probe = ProbeProvider()
        let (model, _) = try await makeModel(transport, probe: probe)
        await model.sendNow(text: "慢慢查", attachments: [])
        try await waitUntil { model.runningToolCallIDs.contains("c1") }
        XCTAssertTrue(model.isStreaming)
        let started = Date()
        model.stop()
        try await waitUntil { !model.isStreaming }

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(probe.calls, ["slow_probe"])
        XCTAssertEqual(results(model).map(\.callID), ["c1", "c2"], "每个调用都有结果，界面不会一直转圈")
        XCTAssertEqual(results(model).map(\.outputText), [AgentLoop.stoppedText, AgentLoop.stoppedText])
        XCTAssertTrue(model.runningToolCallIDs.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)
    }

    #if os(macOS)
    func testStopKillsARunningShellCommand() async throws {
        let directory = libraryRoot.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let marker = "39.\(Int.random(in: 100...999))"
        let transport = ScriptedTransport([SSE.call("c1", "shell", #"{"command":"sleep \#(marker)"}"#), SSE.answer("不该出现")])
        let (model, id) = try await makeModel(transport, mode: .full)
        model.updateWorkingDirectory(id, directory)
        await model.sendNow(text: "跑个命令", attachments: [])
        try await waitUntil { model.runningToolCallIDs.contains("c1") }
        try await Task.sleep(for: .milliseconds(300))
        model.stop()
        try await waitUntil(5) { !model.isStreaming }

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "sleep \(marker)"]
        pgrep.standardOutput = Pipe()
        try pgrep.run()
        pgrep.waitUntilExit()
        XCTAssertNotEqual(pgrep.terminationStatus, 0, "命令的进程已被终止")
        XCTAssertEqual(transport.requests.count, 1)
    }
    #endif

    func testInvalidArgumentsAndUnknownToolsComeBackAsErrors() async throws {
        let transport = ScriptedTransport([
            SSE.calls([("c1", "probe", #"{"q": "#), ("c2", "no_such_tool", "{}")]),
            SSE.answer("重试一下"),
        ])
        let probe = ProbeProvider()
        let (model, _) = try await makeModel(transport, probe: probe)
        await model.sendNow(text: "查", attachments: [])
        try await waitUntil { !model.isStreaming }

        XCTAssertTrue(probe.calls.isEmpty)
        let sent = toolMessages(transport.requests[1])
        XCTAssertEqual(sent.map { $0["tool_call_id"] as? String }, ["c1", "c2"])
        XCTAssertEqual(sent.first?["content"] as? String, AgentLoop.invalidArgumentsText)
        XCTAssertTrue((sent.last?["content"] as? String ?? "").contains("no_such_tool"))
        XCTAssertTrue(results(model).allSatisfy(\.isError))
    }

    func testTurnCapStopsWithAVisibleNote() async throws {
        let transport = ScriptedTransport([SSE.call("c", "probe")], repeatLast: true)
        let (model, _) = try await makeModel(transport)
        await model.sendNow(text: "一直查", attachments: [])
        try await waitUntil(15) { !model.isStreaming }

        XCTAssertEqual(transport.requests.count, AgentLoop.maxModelTurns)
        let last = try XCTUnwrap(model.selectedConversation?.messages.last)
        XCTAssertTrue(last.errorText?.contains("\(AgentLoop.maxModelTurns) 轮") ?? false, last.errorText ?? "")
        XCTAssertEqual(results(model).last?.outputText, AgentLoop.turnLimitText)
    }

    func testToolImagesAreStoredAndSentAsUserMedia() async throws {
        let image = AgentToolImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        let transport = ScriptedTransport([SSE.call("c1", "probe"), SSE.answer("看到了")])
        let (model, _) = try await makeModel(transport, probe: ProbeProvider(image: image))
        await model.sendNow(text: "截个图", attachments: [])
        try await waitUntil { !model.isStreaming }

        let ref = try XCTUnwrap(results(model).first?.media.first)
        XCTAssertEqual(ref.kind, .image)
        XCTAssertEqual(try Data(contentsOf: model.mediaLibrary.url(for: ref)), image.data)
        let messages = try XCTUnwrap(transport.requests[1]["messages"] as? [[String: Any]])
        let toolIndex = try XCTUnwrap(messages.lastIndex { $0["role"] as? String == "tool" })
        let media = try XCTUnwrap(messages[toolIndex + 1]["content"] as? [[String: Any]])
        XCTAssertEqual(messages[toolIndex + 1]["role"] as? String, "user")
        XCTAssertEqual((media.last?["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,iVBORw==")
        XCTAssertEqual(model.selectedConversation?.messages.filter { $0.role == .user }.count, 1, "合成的图片消息不进入对话记录")
    }

    func testToolsFollowTheWorkingDirectoryByDefault() async throws {
        let transport = ScriptedTransport([SSE.answer("好")])
        let (model, id) = try await makeModel(transport, tools: nil)
        XCTAssertFalse(model.toolsEnabled(for: id))
        let unbound = await model.offeredToolSpecs(for: id)
        XCTAssertTrue(unbound.isEmpty)
        await model.sendNow(text: "你好", attachments: [])
        try await waitUntil { !model.isStreaming }
        XCTAssertNil(transport.requests.first?["tools"], "没有工作目录时不提供工具")
        let system = (transport.requests.first?["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        XCTAssertFalse(system.contains("【工具】"))

        model.updateWorkingDirectory(id, libraryRoot.path)
        XCTAssertTrue(model.toolsEnabled(for: id))
        let bound = await model.offeredToolSpecs(for: id)
        XCTAssertTrue(bound.map(\.name).contains("probe"))
        model.setToolsEnabled(false, for: id)
        let disabled = await model.offeredToolSpecs(for: id)
        XCTAssertTrue(disabled.isEmpty)
    }

    func testPermissionModePersistsAndFallsBackToTheDefault() async throws {
        let store = InMemoryConversationStore()
        let (model, id) = try await makeModel(ScriptedTransport([]), store: store, mode: .ask)
        model.setPermissionMode(.full, for: id)
        XCTAssertEqual(model.permissionMode(for: id), .full)
        try await Task.sleep(for: .milliseconds(50))
        let saved = try await store.loadAll().first { $0.id == id }
        XCTAssertEqual(saved?.permissionMode, "full")

        model.setPermissionMode(nil, for: id)
        var settings = model.settings
        settings.defaultPermissionMode = "auto"
        await model.saveSettings(settings)
        XCTAssertEqual(model.permissionMode(for: id), .auto)
    }

    func testOldDocumentsOpenWithoutAgentFields() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"旧对话","messages":[]}"#
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertNil(conversation.permissionMode)
        XCTAssertNil(conversation.toolsEnabled)
    }

    // MARK: - Replies started from a phone

    func testPhoneStartedReplyAsksEvenInFullModeWhileThePhoneIsNotTrusted() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "poke"), SSE.answer("没改")])
        let probe = ProbeProvider()
        let (model, id) = try await makeModel(transport, probe: probe, mode: .full)
        XCTAssertFalse(model.settings.relayAllowShell, "手机访问默认关闭")

        await model.handleRelayCommand(.input(conversationID: id.uuidString, text: "改一下"))
        try await waitUntil { model.pendingApprovals.count == 1 }
        XCTAssertTrue(probe.calls.isEmpty, "手机发起的写操作不能在没问的情况下执行")
        let card = try XCTUnwrap(model.pendingApprovals.first)
        XCTAssertFalse(RelayApproval.phoneMayAllow(card.risk, allowShell: false), "手机也批不了，只能在 Mac 上批")

        model.resolveApproval(card.id, .deny)
        try await waitUntil { !model.isStreaming }
        XCTAssertTrue(probe.calls.isEmpty)
    }

    func testPhoneStartedReplyRunsUnaskedOnceThePhoneIsTrusted() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "poke"), SSE.answer("改好了")])
        let probe = ProbeProvider()
        let (model, id) = try await makeModel(transport, probe: probe, mode: .full)
        var settings = model.settings
        settings.relayAllowShell = true
        await model.saveSettings(settings)

        await model.handleRelayCommand(.input(conversationID: id.uuidString, text: "改一下"))
        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(probe.calls, ["poke"], "用户打开了手机访问，就按对话自己的模式走")
        XCTAssertTrue(model.pendingApprovals.isEmpty)
    }

    func testTheLimitEndsWhenTheNextReplyStartsOnTheMac() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "poke"), SSE.answer("没改"), SSE.call("c2", "poke"), SSE.answer("改好了")])
        let probe = ProbeProvider()
        let (model, id) = try await makeModel(transport, probe: probe, mode: .full)

        await model.handleRelayCommand(.input(conversationID: id.uuidString, text: "手机发的"))
        try await waitUntil { model.pendingApprovals.count == 1 }
        model.resolveApproval(try XCTUnwrap(model.pendingApprovals.first).id, .deny)
        try await waitUntil { !model.isStreaming }
        XCTAssertTrue(probe.calls.isEmpty)

        await model.sendNow(text: "Mac 上发的", attachments: [])
        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(probe.calls, ["poke"], "Mac 自己发起的回复不再受手机限制")
        XCTAssertTrue(model.pendingApprovals.isEmpty)
    }

    // MARK: - Reply ownership

    /// A message arriving while a reply waits on a card (the phone can send
    /// at any time) waits in the queue and leaves the card alone. 立即发送
    /// then cancels the old reply, as sending used to. The old loop used to
    /// clear the new reply's state as it wound down, so 停止 could no longer
    /// reach the new reply and its card waited forever.
    func testAMessageWhileACardWaitsQueuesAndSendNowLeavesTheNewReplyStoppable() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "poke"), SSE.call("c2", "poke")])
        let probe = ProbeProvider()
        let (model, id) = try await makeModel(transport, probe: probe)

        await model.sendNow(text: "第一条", attachments: [])
        try await waitUntil { model.pendingApprovals.map(\.callID) == ["c1"] }
        await model.sendNow(text: "第二条", attachments: [])
        XCTAssertEqual(model.pendingApprovals.map(\.callID), ["c1"], "排队不取消正在等的卡片")
        XCTAssertEqual(model.queuedMessages(for: id).map(\.text), ["第二条"])

        await model.sendQueuedNow(try XCTUnwrap(model.queuedMessages(for: id).first).id, in: id)
        try await waitUntil { model.pendingApprovals.map(\.callID) == ["c2"] }
        // Give the cancelled first loop time to wind down.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.isStreaming, "旧回复收尾不能把新回复的停止按钮关掉")
        XCTAssertEqual(model.pendingApprovals.map(\.callID), ["c2"], "旧卡片被取消，新卡片还在")
        XCTAssertTrue(model.queuedMessages(for: id).isEmpty)

        model.stop()
        try await waitUntil { !model.isStreaming && model.pendingApprovals.isEmpty }
        XCTAssertTrue(probe.calls.isEmpty, "两张卡片都没被批准，什么都不该执行")
    }

    func testDeletingAConversationStopsItsReplyAndCards() async throws {
        let transport = ScriptedTransport([SSE.call("c1", "poke")])
        let probe = ProbeProvider()
        let (model, id) = try await makeModel(transport, probe: probe)

        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        model.deleteConversation(id)
        try await waitUntil { !model.isStreaming && model.pendingApprovals.isEmpty }
        XCTAssertNil(model.streamingConversationID)
        XCTAssertTrue(probe.calls.isEmpty)
    }
}
