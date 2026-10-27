import XCTest
@testable import OMPCore

/// A provider whose tools, per-call risk and behaviour the test scripts.
private final class FakeProvider: AgentToolProvider, @unchecked Sendable {
    let specs: [AgentToolSpec]
    let handler: @Sendable (String, String) async throws -> AgentToolOutput
    private let lock = NSLock()
    private var recorded: [(name: String, arguments: String)] = []

    init(
        _ tools: [(String, ToolRisk)],
        handler: @escaping @Sendable (String, String) async throws -> AgentToolOutput = { name, arguments in
            AgentToolOutput(text: "\(name) ran with \(arguments)")
        }
    ) {
        specs = tools.map { AgentToolSpec(name: $0.0, description: "", parametersJSON: "{}", risk: $0.1, source: "测试") }
        self.handler = handler
    }

    var calls: [(name: String, arguments: String)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func tools() async -> [AgentToolSpec] { specs }

    func call(_ name: String, argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolOutput {
        lock.lock()
        recorded.append((name, argumentsJSON))
        lock.unlock()
        return try await handler(name, argumentsJSON)
    }
}

/// Plays a scripted model: turn n returns `script[n-1]`, then answers.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _turns = 0
    private var _approvals: [ToolApprovalRequest] = []
    private var _results: [ToolResult] = []
    private var _started: [String] = []
    var alwaysAllowed: Set<String> = []

    func turn() -> Int { lock.lock(); defer { lock.unlock() }; _turns += 1; return _turns }
    var turns: Int { lock.lock(); defer { lock.unlock() }; return _turns }
    func approval(_ request: ToolApprovalRequest) { lock.lock(); _approvals.append(request); lock.unlock() }
    var approvals: [ToolApprovalRequest] { lock.lock(); defer { lock.unlock() }; return _approvals }
    func result(_ result: ToolResult) { lock.lock(); _results.append(result); lock.unlock() }
    var results: [ToolResult] { lock.lock(); defer { lock.unlock() }; return _results }
    func start(_ id: String) { lock.lock(); _started.append(id); lock.unlock() }
    var started: [String] { lock.lock(); defer { lock.unlock() }; return _started }
    func allow(_ name: String) { lock.lock(); alwaysAllowed.insert(name); lock.unlock() }
    func isAllowed(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return alwaysAllowed.contains(name) }
}

/// What the loop did, in order.
private final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func add(_ event: String) { lock.lock(); _events.append(event); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
}

final class AgentLoopTests: XCTestCase {
    private let conversationID = UUID()

    private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> ToolCall {
        ToolCall(id: id, name: name, argumentsJSON: arguments)
    }

    private func host(
        script: [[ToolCall]],
        provider: FakeProvider,
        recorder: Recorder,
        mode: PermissionMode = .ask,
        repeatLast: Bool = false,
        hooks: AgentToolHooks? = nil,
        approve: @escaping @Sendable (ToolApprovalRequest) async -> ToolApprovalDecision = { _ in .allowOnce }
    ) async -> AgentLoop.Host {
        let registry = await AgentToolRegistry.build(["fake": provider])
        let context = AgentToolContext(conversationID: conversationID, workingDirectory: "/w")
        return AgentLoop.Host(
            modelTurn: { _ in
                let turn = recorder.turn()
                let calls = turn <= script.count ? script[turn - 1] : (repeatLast ? script.last ?? [] : [])
                return .finished(calls: calls, registry: registry)
            },
            environment: { AgentLoop.Environment(mode: mode, context: context) },
            isAlwaysAllowed: { recorder.isAllowed($0) },
            requestApproval: { request in
                recorder.approval(request)
                let decision = await approve(request)
                if decision == .allowAlways { recorder.allow(request.toolName) }
                return decision
            },
            willRun: { recorder.start($0.id) },
            didRun: { _, execution in recorder.result(execution.result) },
            hooks: hooks
        )
    }

    func testOneCallThenAnswer() async {
        let provider = FakeProvider([("lookup", .read)])
        let recorder = Recorder()
        let ending = await AgentLoop().run(host(script: [[call("c1", "lookup", #"{"q":"swift"}"#)]], provider: provider, recorder: recorder))
        XCTAssertEqual(ending, .answered)
        XCTAssertEqual(recorder.turns, 2, "结果交回模型后再调用一轮")
        XCTAssertEqual(provider.calls.map(\.arguments), [#"{"q":"swift"}"#])
        XCTAssertEqual(recorder.results.map(\.callID), ["c1"])
        XCTAssertEqual(recorder.results.first?.outputText, #"lookup ran with {"q":"swift"}"#)
        XCTAssertEqual(recorder.results.first?.isError, false)
        XCTAssertTrue(recorder.approvals.isEmpty, "读取不需要批准")
    }

    func testCallsRunInOrderAndEachGetsOneResult() async {
        let provider = FakeProvider([("a", .read), ("b", .read)])
        let recorder = Recorder()
        _ = await AgentLoop().run(host(script: [[call("1", "b"), call("2", "a"), call("3", "b")]], provider: provider, recorder: recorder))
        XCTAssertEqual(provider.calls.map(\.name), ["b", "a", "b"])
        XCTAssertEqual(recorder.results.map(\.callID), ["1", "2", "3"])
    }

    func testDeniedCallContinuesWithRefusal() async {
        let provider = FakeProvider([("write", .write)])
        let recorder = Recorder()
        let ending = await AgentLoop().run(host(
            script: [[call("c1", "write")]], provider: provider, recorder: recorder, approve: { _ in .deny }
        ))
        XCTAssertEqual(ending, .answered)
        XCTAssertTrue(provider.calls.isEmpty)
        XCTAssertEqual(recorder.results.first?.outputText, AgentLoop.deniedText)
        XCTAssertEqual(recorder.results.first?.isError, true)
        XCTAssertEqual(recorder.turns, 2, "拒绝后模型继续")
    }

    func testApprovalCardCarriesWhatWillRun() async throws {
        let provider = FakeProvider([("shell", .execute)])
        let recorder = Recorder()
        _ = await AgentLoop().run(host(script: [[call("c9", "shell", #"{"command":"ls"}"#)]], provider: provider, recorder: recorder))
        let card = try XCTUnwrap(recorder.approvals.first)
        XCTAssertEqual(card.callID, "c9")
        XCTAssertEqual(card.toolName, "shell")
        XCTAssertEqual(card.risk, .execute)
        XCTAssertEqual(card.source, "测试")
        XCTAssertEqual(card.conversationID, conversationID)
        XCTAssertEqual(card.argumentsJSON, #"{"command":"ls"}"#)
    }

    func testAllowOnceAsksAgainNextTime() async {
        let provider = FakeProvider([("write", .write)])
        let recorder = Recorder()
        _ = await AgentLoop().run(host(
            script: [[call("1", "write")], [call("2", "write")]], provider: provider, recorder: recorder,
            approve: { _ in .allowOnce }
        ))
        XCTAssertEqual(recorder.approvals.count, 2)
        XCTAssertEqual(provider.calls.count, 2)
    }

    func testAllowAlwaysStopsAskingForThatTool() async {
        let provider = FakeProvider([("write", .write), ("shell", .execute)])
        let recorder = Recorder()
        _ = await AgentLoop().run(host(
            script: [[call("1", "write"), call("2", "write"), call("3", "shell")], [call("4", "write")]],
            provider: provider, recorder: recorder, approve: { _ in .allowAlways }
        ))
        XCTAssertEqual(recorder.approvals.map(\.callID), ["1", "3"], "同一工具不再询问，其他工具仍询问")
        XCTAssertEqual(provider.calls.count, 4)
    }

    func testReadOnlyRefusesWithoutAsking() async {
        let provider = FakeProvider([("write", .write), ("look", .read)])
        let recorder = Recorder()
        recorder.alwaysAllowed = ["write"]
        let ending = await AgentLoop().run(host(
            script: [[call("1", "write"), call("2", "look")]], provider: provider, recorder: recorder, mode: .readOnly
        ))
        XCTAssertEqual(ending, .answered)
        XCTAssertTrue(recorder.approvals.isEmpty)
        XCTAssertEqual(provider.calls.map(\.name), ["look"], "始终允许也不能越过只读")
        XCTAssertTrue(recorder.results[0].outputText.contains("只读"))
        XCTAssertTrue(recorder.results[0].isError)
        XCTAssertFalse(recorder.results[1].isError)
    }

    func testFullModeRunsCommandsButStillAsksForControl() async {
        let provider = FakeProvider([("shell", .execute), ("click", .control)])
        let recorder = Recorder()
        _ = await AgentLoop().run(host(script: [[call("1", "shell"), call("2", "click")]], provider: provider, recorder: recorder, mode: .full))
        XCTAssertEqual(recorder.approvals.map(\.toolName), ["click"])
    }

    func testInvalidJSONIsAnErrorTheModelSees() async {
        let provider = FakeProvider([("lookup", .read)])
        let recorder = Recorder()
        let ending = await AgentLoop().run(host(
            script: [[call("1", "lookup", #"{"q": "#)], [call("2", "lookup", "[1,2]")], [call("3", "lookup", "  ")]],
            provider: provider, recorder: recorder
        ))
        XCTAssertEqual(ending, .answered)
        XCTAssertEqual(recorder.results[0].outputText, AgentLoop.invalidArgumentsText)
        XCTAssertEqual(recorder.results[1].outputText, AgentLoop.invalidArgumentsText, "参数必须是 JSON 对象")
        XCTAssertTrue(recorder.results[0].isError)
        XCTAssertEqual(provider.calls.map(\.arguments), ["{}"], "空参数按 {} 处理")
        XCTAssertEqual(recorder.turns, 4)
    }

    func testUnknownToolIsAnErrorAndTheLoopGoesOn() async {
        let provider = FakeProvider([("lookup", .read)])
        let recorder = Recorder()
        let ending = await AgentLoop().run(host(script: [[call("1", "nope"), call("2", "lookup")]], provider: provider, recorder: recorder))
        XCTAssertEqual(ending, .answered)
        XCTAssertTrue(recorder.results[0].isError)
        XCTAssertTrue(recorder.results[0].outputText.contains("nope"))
        XCTAssertEqual(provider.calls.map(\.name), ["lookup"])
    }

    func testThrownErrorBecomesResult() async {
        struct Boom: LocalizedError { var errorDescription: String? { "连接断开" } }
        let provider = FakeProvider([("mcp_tool", .read)]) { _, _ in throw Boom() }
        let recorder = Recorder()
        let ending = await AgentLoop().run(host(script: [[call("1", "mcp_tool")]], provider: provider, recorder: recorder))
        XCTAssertEqual(ending, .answered)
        XCTAssertEqual(recorder.results.first?.outputText, "工具执行失败：连接断开")
        XCTAssertEqual(recorder.results.first?.isError, true)
    }

    func testTurnCapStopsAfterTwentyFiveModelTurns() async {
        let provider = FakeProvider([("lookup", .read)])
        let recorder = Recorder()
        let ending = await AgentLoop().run(host(script: [[call("x", "lookup")]], provider: provider, recorder: recorder, repeatLast: true))
        XCTAssertEqual(ending, .turnLimit)
        XCTAssertEqual(recorder.turns, AgentLoop.maxModelTurns)
        XCTAssertEqual(provider.calls.count, AgentLoop.maxModelTurns - 1, "最后一轮的调用不再执行")
        XCTAssertEqual(recorder.results.count, AgentLoop.maxModelTurns, "每个调用都有结果")
        XCTAssertEqual(recorder.results.last?.outputText, AgentLoop.turnLimitText)
    }

    // MARK: Follow-ups

    func testFollowUpsAreAddedAfterTheTurnsResultsAndBeforeTheNextTurn() async {
        let provider = FakeProvider([("lookup", .read)])
        let recorder = Recorder()
        let timeline = Timeline()
        var host = await host(script: [[call("c1", "lookup"), call("c2", "lookup")]], provider: provider, recorder: recorder)
        let modelTurn = host.modelTurn
        let didRun = host.didRun
        host.modelTurn = { turn in
            timeline.add("turn \(turn)")
            return await modelTurn(turn)
        }
        host.didRun = { call, execution in
            timeline.add("result \(call.id)")
            await didRun(call, execution)
        }
        host.betweenTurns = {
            timeline.add("follow-ups")
            return true
        }
        let ending = await AgentLoop().run(host)
        XCTAssertEqual(ending, .answered)
        XCTAssertEqual(timeline.events, ["turn 1", "result c1", "result c2", "follow-ups", "turn 2"],
                       "追问在本轮结果都写回之后、下一轮请求之前加入；回答之后不再调用")
    }

    func testADeliveredFollowUpGetsItsOwnTurnBudget() async {
        let provider = FakeProvider([("lookup", .read)])
        let recorder = Recorder()
        let timeline = Timeline()
        var host = await host(script: [[call("x", "lookup")]], provider: provider, recorder: recorder, repeatLast: true)
        // One follow-up arrives after turn 2.
        host.betweenTurns = {
            timeline.add("between")
            return timeline.events.count == 2
        }
        let ending = await AgentLoop(maxTurns: 3).run(host)
        XCTAssertEqual(ending, .turnLimit)
        XCTAssertEqual(recorder.turns, 5, "上限按每条用户消息算：第 2 轮后的追问再给 3 轮")
        XCTAssertEqual(timeline.events.count, 4, "最后一轮的调用没执行，也就不再收追问")
    }

    func testWithoutFollowUpsTheTurnCapIsUnchanged() async {
        let provider = FakeProvider([("lookup", .read)])
        let recorder = Recorder()
        var host = await host(script: [[call("x", "lookup")]], provider: provider, recorder: recorder, repeatLast: true)
        host.betweenTurns = { false }
        let ending = await AgentLoop(maxTurns: 3).run(host)
        XCTAssertEqual(ending, .turnLimit)
        XCTAssertEqual(recorder.turns, 3)
    }

    func testNoToolsOfferedEndsAfterOneTurn() async {
        let recorder = Recorder()
        let ending = await AgentLoop().run(AgentLoop.Host(
            modelTurn: { _ in _ = recorder.turn(); return .finished(calls: [ToolCall(id: "1", name: "x", argumentsJSON: "{}")], registry: .empty) },
            environment: { AgentLoop.Environment(mode: .full, context: .init(conversationID: UUID(), workingDirectory: nil)) },
            isAlwaysAllowed: { _ in false },
            requestApproval: { _ in .deny },
            didRun: { _, execution in recorder.result(execution.result) }
        ))
        XCTAssertEqual(ending, .answered)
        XCTAssertEqual(recorder.turns, 1)
        XCTAssertTrue(recorder.results.isEmpty)
    }

    func testFailedTurnStops() async {
        let ending = await AgentLoop().run(AgentLoop.Host(
            modelTurn: { _ in .stopped },
            environment: { AgentLoop.Environment(mode: .full, context: .init(conversationID: UUID(), workingDirectory: nil)) },
            isAlwaysAllowed: { _ in false },
            requestApproval: { _ in .deny },
            didRun: { _, _ in XCTFail("nothing runs") }
        ))
        XCTAssertEqual(ending, .stopped)
    }

    func testCancelDuringToolStopsTheLoop() async throws {
        let provider = FakeProvider([("slow", .read), ("lookup", .read)]) { name, _ in
            if name == "slow" { try await Task.sleep(for: .seconds(30)) }
            return AgentToolOutput(text: "done")
        }
        let recorder = Recorder()
        let loopHost = await host(script: [[call("1", "slow"), call("2", "lookup")]], provider: provider, recorder: recorder)
        let task = Task { await AgentLoop().run(loopHost) }
        try await waitUntil { recorder.started == ["1"] }
        let started = Date()
        task.cancel()
        let ending = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(ending, .cancelled)
        XCTAssertEqual(recorder.results.map(\.callID), ["1", "2"], "未执行的调用也得到结果")
        XCTAssertEqual(recorder.results.map(\.outputText), [AgentLoop.stoppedText, AgentLoop.stoppedText])
        XCTAssertEqual(provider.calls.map(\.name), ["slow"])
        XCTAssertEqual(recorder.turns, 1, "停止后不再请求模型")
    }

    func testCancelDuringApprovalRefusesIt() async throws {
        let provider = FakeProvider([("write", .write)])
        let recorder = Recorder()
        let loopHost = await host(script: [[call("1", "write")]], provider: provider, recorder: recorder) { _ in
            // A card the user never answers; cancellation answers it.
            await withTaskCancellationHandler {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return .deny
            } onCancel: {}
        }
        let task = Task { await AgentLoop().run(loopHost) }
        try await waitUntil { recorder.approvals.count == 1 }
        task.cancel()
        let ending = await task.value
        XCTAssertEqual(ending, .cancelled)
        XCTAssertTrue(provider.calls.isEmpty)
        XCTAssertEqual(recorder.results.map(\.outputText), [AgentLoop.stoppedText])
        XCTAssertEqual(recorder.turns, 1)
    }

    // MARK: Hooks

    private func hooks(
        pre: @escaping @Sendable (ToolCall) -> PreToolUseDecision = { _ in .proceed },
        permission: @escaping @Sendable (ToolCall) -> PermissionHookDecision = { _ in .undecided },
        post: @escaping @Sendable (ToolResult) -> PostToolUseDecision = { _ in .keep }
    ) -> AgentToolHooks {
        AgentToolHooks(
            preToolUse: { call, _, _ in pre(call) },
            permissionRequest: { call, _, _ in permission(call) },
            postToolUse: { _, _, result, _ in post(result) }
        )
    }

    func testPreToolUseBlockAndRewrite() async {
        let provider = FakeProvider([("shell", .execute)])
        let recorder = Recorder()
        _ = await AgentLoop().run(host(
            script: [[call("1", "shell", #"{"command":"rm -rf /"}"#), call("2", "shell", #"{"command":"ls"}"#)]],
            provider: provider, recorder: recorder, mode: .full,
            hooks: hooks(pre: { call in
                call.id == "1" ? .block("不允许删除根目录") : .rewrite(argumentsJSON: #"{"command":"ls -la"}"#)
            })
        ))
        XCTAssertEqual(recorder.results[0].outputText, "不允许删除根目录")
        XCTAssertTrue(recorder.results[0].isError)
        XCTAssertEqual(provider.calls.map(\.arguments), [#"{"command":"ls -la"}"#])
    }

    func testRewrittenArgumentsAreWhatTheCardShows() async {
        let provider = FakeProvider([("write", .write)])
        let recorder = Recorder()
        _ = await AgentLoop().run(host(
            script: [[call("1", "write", #"{"path":"a"}"#)]], provider: provider, recorder: recorder,
            hooks: hooks(pre: { _ in .rewrite(argumentsJSON: #"{"path":"b"}"#) })
        ))
        XCTAssertEqual(recorder.approvals.first?.argumentsJSON, #"{"path":"b"}"#)
    }

    func testPermissionHookOnlyRunsWhenACardWouldShow() async {
        let provider = FakeProvider([("write", .write), ("look", .read), ("shell", .execute)])
        let recorder = Recorder()
        let consulted = Recorder()
        _ = await AgentLoop().run(host(
            script: [[call("1", "write"), call("2", "look"), call("3", "shell")]], provider: provider, recorder: recorder,
            hooks: hooks(permission: { call in
                consulted.start(call.id)
                return call.name == "write" ? .allow : .deny("钩子拒绝")
            })
        ))
        XCTAssertEqual(consulted.started, ["1", "3"], "读取不会弹卡，也不问钩子")
        XCTAssertTrue(recorder.approvals.isEmpty, "钩子作出决定后不再弹卡")
        XCTAssertEqual(provider.calls.map(\.name), ["write", "look"])
        XCTAssertEqual(recorder.results[2].outputText, "钩子拒绝")
    }

    func testDesktopControlAlwaysShowsItsCard() async {
        let provider = FakeProvider([("click", .control)])
        let recorder = Recorder()
        recorder.alwaysAllowed = ["click"]
        _ = await AgentLoop().run(host(
            script: [[call("1", "click")]], provider: provider, recorder: recorder, mode: .full,
            hooks: hooks(permission: { _ in .allow })
        ))
        XCTAssertEqual(recorder.approvals.map(\.callID), ["1"], "始终允许和钩子都不能跳过桌面控制的确认")
        XCTAssertEqual(provider.calls.count, 1)
    }

    func testPermissionHookCannotLiftReadOnly() async {
        let provider = FakeProvider([("write", .write)])
        let recorder = Recorder()
        _ = await AgentLoop().run(host(
            script: [[call("1", "write")]], provider: provider, recorder: recorder, mode: .readOnly,
            hooks: hooks(permission: { _ in .allow })
        ))
        XCTAssertTrue(provider.calls.isEmpty)
    }

    func testPostToolUseAppendsOrReplaces() async {
        let provider = FakeProvider([("look", .read)])
        let recorder = Recorder()
        _ = await AgentLoop().run(host(
            script: [[call("1", "look"), call("2", "look")]], provider: provider, recorder: recorder,
            hooks: hooks(post: { result in result.callID == "1" ? .append("注意：已记录") : .replace("输出含密钥，已隐藏") })
        ))
        XCTAssertEqual(recorder.results[0].outputText, "look ran with {}\n\n注意：已记录")
        XCTAssertFalse(recorder.results[0].isError)
        XCTAssertEqual(recorder.results[1].outputText, "输出含密钥，已隐藏")
        XCTAssertTrue(recorder.results[1].isError)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }
}
