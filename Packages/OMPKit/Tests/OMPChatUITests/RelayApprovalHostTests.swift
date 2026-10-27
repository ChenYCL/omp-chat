import XCTest
import OMPCore
@testable import OMPChatUI

/// The Mac's rules for answering its approval cards from a paired phone,
/// through a real `ChatAppModel` (and, for the revision, a real relay on
/// loopback). Cards are raised with `presentApproval`, the agent loop's own
/// suspension point, so every risk can be tried without a model.
@MainActor
final class RelayApprovalHostTests: XCTestCase {
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("relay-approval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    private func makeModel(allowShell: Bool = false) async throws -> (ChatAppModel, UUID) {
        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: libraryRoot),
            transport: NoNetworkTransport()
        )
        await model.bootstrap()
        let conversation = model.newConversation()
        if allowShell { await setAllowShell(true, on: model) }
        return (model, conversation.id)
    }

    private func setAllowShell(_ allowed: Bool, on model: ChatAppModel) async {
        var settings = model.settings
        settings.relayAllowShell = allowed
        await model.saveSettings(settings)
    }

    /// Raises a card the way the agent loop does; the task ends with the answer.
    private func raise(
        _ risk: ToolRisk, in conversationID: UUID, on model: ChatAppModel, tool: String = "shell"
    ) async throws -> (ToolApprovalRequest, Task<ToolApprovalDecision, Never>) {
        let request = ToolApprovalRequest(
            conversationID: conversationID, callID: "call-\(UUID().uuidString.prefix(6))", toolName: tool,
            source: "内置", risk: risk, argumentsJSON: #"{"command":"ls"}"#, summary: "运行命令：ls"
        )
        let answer = Task { await model.presentApproval(request) }
        try await waitUntil { model.pendingApprovals.contains { $0.id == request.id } }
        return (request, answer)
    }

    private func approve(
        _ request: ToolApprovalRequest, _ decision: RelayApprovalDecision, requestID: String?, on model: ChatAppModel
    ) async {
        await model.handleRelayCommand(.approve(approvalID: request.id.uuidString, decision: decision, requestID: requestID))
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }

    // MARK: Snapshot

    func testSnapshotMirrorsTheWaitingCardUntilItIsAnswered() async throws {
        let (model, id) = try await makeModel()
        XCTAssertNil(model.relaySnapshot().approvals)

        let (request, answer) = try await raise(.execute, in: id, on: model)
        let card = try XCTUnwrap(model.relaySnapshot().approvals?.first)
        XCTAssertEqual(card.id, request.id.uuidString)
        XCTAssertEqual(card.conversationID, id.uuidString)
        XCTAssertEqual(card.callID, request.callID)
        XCTAssertEqual(card.toolName, "shell")
        XCTAssertEqual(card.source, "内置")
        XCTAssertEqual(card.risk, "execute")
        XCTAssertEqual(card.summary, "运行命令：ls")
        XCTAssertEqual(card.argumentsJSON, #"{"command":"ls"}"#)
        XCTAssertFalse(card.canApprove, "开关关着时运行命令不能在手机上批准")

        await approve(request, .deny, requestID: "r1", on: model)
        let decision = await answer.value
        XCTAssertEqual(decision, .deny)
        XCTAssertNil(model.relaySnapshot().approvals, "答复后卡片从快照里消失")
        XCTAssertNil(model.relaySnapshot().commandFailures)
    }

    // MARK: Rules

    func testExecuteIsRefusedWithShellAccessOffAndAllowedOnceItIsOn() async throws {
        let (model, id) = try await makeModel()
        let (request, answer) = try await raise(.execute, in: id, on: model)

        await approve(request, .allowOnce, requestID: "r1", on: model)
        XCTAssertEqual(model.pendingApprovals.map(\.id), [request.id], "被拒的批准不动卡片")
        XCTAssertEqual(model.relaySnapshot().commandFailures, [RelayCommandFailure(requestID: "r1", error: "shell_disabled")])

        await setAllowShell(true, on: model)
        XCTAssertEqual(model.relaySnapshot().approvals?.first?.canApprove, true)
        await approve(request, .allowOnce, requestID: "r2", on: model)
        let decision = await answer.value
        XCTAssertEqual(decision, .allowOnce)
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertFalse(model.alwaysAllowedTools.contains("shell"), "手机的允许只算一次")
        XCTAssertEqual(model.relayCommandFailures.map(\.requestID), ["r1"])
    }

    func testDenyAlwaysWorksWithShellAccessOff() async throws {
        let (model, id) = try await makeModel()
        for risk in [ToolRisk.write, .execute, .control] {
            let (request, answer) = try await raise(risk, in: id, on: model)
            await approve(request, .deny, requestID: "deny-\(risk.rawValue)", on: model)
            let decision = await answer.value
            XCTAssertEqual(decision, .deny, risk.rawValue)
        }
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertNil(model.relaySnapshot().commandFailures)
    }

    func testWriteAndControlNeedShellAccessToo() async throws {
        let (model, id) = try await makeModel()
        for risk in [ToolRisk.write, .control] {
            let (request, answer) = try await raise(risk, in: id, on: model)
            XCTAssertEqual(model.answerRemoteApproval(request.id.uuidString, .allowOnce), "shell_disabled", risk.rawValue)
            model.resolveApproval(request.id, .deny)
            _ = await answer.value
        }
    }

    func testReadCardCanBeAllowedWithShellAccessOff() async throws {
        let (model, id) = try await makeModel()
        let (request, answer) = try await raise(.read, in: id, on: model, tool: "read_file")
        XCTAssertEqual(model.relaySnapshot().approvals?.first?.canApprove, true)

        await approve(request, .allowOnce, requestID: "r1", on: model)
        let decision = await answer.value
        XCTAssertEqual(decision, .allowOnce)
        XCTAssertNil(model.relaySnapshot().commandFailures)
    }

    func testUnknownCardIsReportedAndChangesNothing() async throws {
        let (model, id) = try await makeModel(allowShell: true)
        let (request, answer) = try await raise(.execute, in: id, on: model)

        await model.handleRelayCommand(.approve(approvalID: UUID().uuidString, decision: .allowOnce, requestID: "r1"))
        await model.handleRelayCommand(.approve(approvalID: "not-a-uuid", decision: .deny, requestID: "r2"))
        XCTAssertEqual(model.relaySnapshot().commandFailures, [
            RelayCommandFailure(requestID: "r1", error: "not_found"),
            RelayCommandFailure(requestID: "r2", error: "not_found"),
        ])
        XCTAssertEqual(model.pendingApprovals.map(\.id), [request.id])

        model.resolveApproval(request.id, .deny)
        _ = await answer.value
    }

    func testSecondAnswerToTheSameCardIsANoOp() async throws {
        let (model, id) = try await makeModel(allowShell: true)
        let (request, answer) = try await raise(.execute, in: id, on: model)

        await approve(request, .deny, requestID: "r1", on: model)
        await approve(request, .allowOnce, requestID: "r2", on: model)
        let decision = await answer.value
        XCTAssertEqual(decision, .deny, "第一次答复生效，第二次不改结果")
        XCTAssertEqual(model.relaySnapshot().commandFailures, [RelayCommandFailure(requestID: "r2", error: "not_found")])
    }

    func testCardsOfALockedChatStayOnTheMac() async throws {
        let (model, id) = try await makeModel(allowShell: true)
        let (request, answer) = try await raise(.execute, in: id, on: model)
        model.toggleLock(id)

        XCTAssertNil(model.relaySnapshot().approvals, "锁定的对话不把调用发给手机")
        await approve(request, .allowOnce, requestID: "r1", on: model)
        XCTAssertEqual(model.pendingApprovals.map(\.id), [request.id])
        XCTAssertEqual(model.relayCommandFailures, [RelayCommandFailure(requestID: "r1", error: "not_found")])

        model.resolveApproval(request.id, .deny)
        _ = await answer.value
    }

    func testRefusalsAreCappedNewestKept() async throws {
        let (model, _) = try await makeModel()
        for index in 0..<(RelayCommandFailure.maxKept + 5) {
            model.answerRemoteApproval(UUID().uuidString, .deny, requestID: "r\(index)")
        }
        let kept = model.relayCommandFailures.map(\.requestID)
        XCTAssertEqual(kept.count, RelayCommandFailure.maxKept)
        XCTAssertEqual(kept.first, "r5")
        XCTAssertEqual(kept.last, "r\(RelayCommandFailure.maxKept + 4)")
        model.answerRemoteApproval(UUID().uuidString, .deny)
        XCTAssertEqual(model.relayCommandFailures.count, RelayCommandFailure.maxKept, "没有 requestID 的拒绝无处回报，不记")
    }

    // MARK: Revision

    func testRelayRevisionMovesWhenACardAppearsAndWhenItIsAnswered() async throws {
        let (model, id) = try await makeModel()
        let probe = RelayServer()
        try probe.start(port: 0, token: "probe")
        let port = probe.port
        probe.stop()

        let token = UUID().uuidString
        let controller = RelayHostController(model: model, token: token)
        controller.start(port: port)
        defer { controller.stop() }
        guard controller.isRunning else {
            return XCTFail("relay did not start: \(controller.lastError ?? "")")
        }

        func snapshot() async throws -> RelaySnapshot {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/snapshot")!)
            request.timeoutInterval = 5
            request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(RelaySnapshot.self, from: data)
        }
        func snapshot(until condition: (RelaySnapshot) -> Bool) async throws -> RelaySnapshot {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let current = try await snapshot()
                if condition(current) { return current }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("the relay never served the expected snapshot")
            return try await snapshot()
        }

        let before = try await snapshot(until: { $0.rev > 0 })
        XCTAssertNil(before.approvals)

        let (request, answer) = try await raise(.execute, in: id, on: model)
        let waiting = try await snapshot(until: { $0.approvals != nil })
        XCTAssertGreaterThan(waiting.rev, before.rev)
        XCTAssertEqual(waiting.approvals?.map(\.id), [request.id.uuidString])

        model.resolveApproval(request.id, .deny)
        _ = await answer.value
        let answered = try await snapshot(until: { $0.approvals == nil })
        XCTAssertGreaterThan(answered.rev, waiting.rev)
    }
}

/// The phone's bookkeeping for its answers: buttons wait while an answer is
/// on its way, a refusal shows under the card, and nothing stays stuck.
final class RelayApprovalPhoneTests: XCTestCase {
    private func card(_ id: String = "A1") -> RelayApproval {
        RelayApproval(
            id: id, conversationID: "C1", callID: "c1", toolName: "shell", source: "内置",
            risk: "execute", summary: "运行命令：ls", argumentsJSON: "{}", canApprove: true
        )
    }

    func testAnswerWaitsUntilTheCardLeavesTheSnapshot() {
        var tracker = RemoteApprovalTracker()
        XCTAssertEqual(tracker.begin("A1", requestID: "r1"), "r1")
        XCTAssertNil(tracker.begin("A1", requestID: "r2"), "发送中再点不重复发")
        XCTAssertTrue(tracker.isSending("A1"))

        XCTAssertEqual(tracker.update(approvals: [card()], failures: []), [])
        XCTAssertTrue(tracker.isSending("A1"), "Mac 还没处理时卡片仍在")

        XCTAssertEqual(tracker.update(approvals: [], failures: []), [])
        XCTAssertFalse(tracker.isSending("A1"))
        XCTAssertNil(tracker.error(for: "A1"))
        XCTAssertNil(tracker.nextDeadline)
    }

    func testRefusalShowsUnderTheCardAndFreesItsButtons() {
        var tracker = RemoteApprovalTracker()
        _ = tracker.begin("A1", requestID: "r1")
        _ = tracker.update(approvals: [card()], failures: [RelayCommandFailure(requestID: "r1", error: "shell_disabled")])
        XCTAssertFalse(tracker.isSending("A1"))
        XCTAssertEqual(tracker.error(for: "A1"), RemoteApprovalTracker.shellDisabledMessage)

        XCTAssertEqual(tracker.begin("A1", requestID: "r2"), "r2")
        XCTAssertNil(tracker.error(for: "A1"), "重试时清掉旧错误")
    }

    func testAnOldRefusalDoesNotFailANewAnswer() {
        var tracker = RemoteApprovalTracker()
        _ = tracker.begin("A1", requestID: "r2")
        _ = tracker.update(approvals: [card()], failures: [RelayCommandFailure(requestID: "r1", error: "shell_disabled")])
        XCTAssertTrue(tracker.isSending("A1"))
        XCTAssertNil(tracker.error(for: "A1"))
    }

    func testRefusalOfACardAnsweredElsewhereIsANotice() {
        var tracker = RemoteApprovalTracker()
        _ = tracker.begin("A1", requestID: "r1")
        let notices = tracker.update(approvals: [], failures: [RelayCommandFailure(requestID: "r1", error: "not_found")])
        XCTAssertEqual(notices, [RemoteApprovalTracker.message(for: "not_found")])
        XCTAssertFalse(tracker.isSending("A1"))
        XCTAssertNil(tracker.error(for: "A1"))
    }

    func testUnconfirmedAnswerGivesUpAfterTheTimeout() {
        var tracker = RemoteApprovalTracker()
        let start = Date()
        _ = tracker.begin("A1", requestID: "r1", now: start)
        XCTAssertEqual(tracker.nextDeadline, start.addingTimeInterval(RemoteApprovalTracker.timeout))

        _ = tracker.update(approvals: [card()], failures: [], now: start.addingTimeInterval(RemoteApprovalTracker.timeout - 1))
        XCTAssertTrue(tracker.isSending("A1"))
        _ = tracker.update(approvals: [card()], failures: [], now: start.addingTimeInterval(RemoteApprovalTracker.timeout))
        XCTAssertFalse(tracker.isSending("A1"))
        XCTAssertNotNil(tracker.error(for: "A1"))
    }

    func testFailedSendFreesTheCardAndExplainsAnOldMac() {
        var tracker = RemoteApprovalTracker()
        _ = tracker.begin("A1", requestID: "r1")
        tracker.sendFailed("A1", message: RemoteApprovalTracker.sendFailureMessage(RelayClientError.http(400)))
        XCTAssertFalse(tracker.isSending("A1"))
        XCTAssertEqual(tracker.error(for: "A1"), "这台 Mac 还不支持在手机上批准，请先更新")
        XCTAssertEqual(RemoteApprovalTracker.sendFailureMessage(RelayHubError.http(400)), "这台 Mac 或中继还不支持在手机上批准，请先更新")
        XCTAssertEqual(RemoteApprovalTracker.sendFailureMessage(RelayHubError.hostOffline), "发送失败，稍后重试")

        _ = tracker.update(approvals: [], failures: [])
        XCTAssertNil(tracker.error(for: "A1"), "卡片没了，错误也清掉")
    }
}

private struct NoNetworkTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 599, headers: [:], body: Data())
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
