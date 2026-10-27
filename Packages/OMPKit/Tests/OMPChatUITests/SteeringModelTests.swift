import XCTest
import OMPCore
@testable import OMPChatUI

/// Follow-ups sent while a reply runs: queued instead of cancelling, then
/// delivered at the loop's next safe point or as the next reply.
@MainActor
final class SteeringModelTests: XCTestCase {
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("steer-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    private func makeModel(
        _ transport: FollowUpTransport, probe: GateProbe = GateProbe(), mode: PermissionMode = .ask
    ) async throws -> (ChatAppModel, UUID) {
        try await FollowUpHarness.makeModel(transport, probe: probe, libraryRoot: libraryRoot, mode: mode)
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async throws {
        try await FollowUpHarness.waitUntil(timeout, condition)
    }

    private func texts(_ model: ChatAppModel) -> [String] {
        (model.selectedConversation?.messages ?? []).map { "\($0.role.rawValue):\($0.concatenatedText)" }
    }

    func testAFollowUpSentDuringAToolCallRidesInTheNextRequestWithoutCancelling() async throws {
        let probe = GateProbe()
        let transport = FollowUpTransport([.body(FollowUpSSE.call("c1", "wait_probe")), .body(FollowUpSSE.answer("都看过了"))])
        let (model, id) = try await makeModel(transport, probe: probe)

        await model.sendNow(text: "先查一下", attachments: [])
        try await waitUntil { probe.calls == ["wait_probe"] }
        await model.sendNow(text: "顺便看看测试", attachments: [])
        XCTAssertEqual(model.queuedMessages(for: id).map(\.text), ["顺便看看测试"], "回复在跑：消息排队，不打断")
        XCTAssertTrue(model.isStreaming)
        XCTAssertEqual(transport.requestCount, 1)

        probe.gate.release()
        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(transport.requestCount, 2, "同一个回复的下一轮带上追问，没有另起回复")
        let next = FollowUpHarness.transcript(transport.requests[1])
        XCTAssertEqual(Array(next.suffix(3)), [["assistant", "tool_calls"], ["tool", "wait_probe 输出"], ["user", "顺便看看测试"]],
                       "追问紧跟在本轮工具结果后面")
        XCTAssertEqual(texts(model), ["user:先查一下", "assistant:", "user:顺便看看测试", "assistant:都看过了"])
        XCTAssertTrue(model.queuedMessages(for: id).isEmpty)
        XCTAssertNil(model.selectedConversation?.messages[2].errorText)
    }

    func testAFollowUpSentDuringAPlainAnswerStartsTheNextReplyAfterIt() async throws {
        let gate = TestGate()
        let transport = FollowUpTransport([.gated(gate, FollowUpSSE.answer("第一条的回答")), .body(FollowUpSSE.answer("第二条的回答"))])
        let (model, id) = try await makeModel(transport)

        await model.sendNow(text: "第一条", attachments: [])
        try await waitUntil { transport.requestCount == 1 }
        await model.sendNow(text: "第二条", attachments: [])
        XCTAssertEqual(model.queuedMessages(for: id).count, 1)

        gate.release()
        try await waitUntil { transport.requestCount == 2 && !model.isStreaming }
        XCTAssertEqual(texts(model), ["user:第一条", "assistant:第一条的回答", "user:第二条", "assistant:第二条的回答"],
                       "回答完了没有下一轮，排队的消息自动开始下一次回复")
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[1]).last, ["user", "第二条"])
        XCTAssertTrue(model.queuedMessages(for: id).isEmpty)
    }

    func testAFollowUpSentWhileACardWaitsGoesOutOnceTheCardIsAnswered() async throws {
        let probe = GateProbe()
        let transport = FollowUpTransport([.body(FollowUpSSE.call("c1", "poke")), .body(FollowUpSSE.answer("改好了，也跑了测试"))])
        let (model, id) = try await makeModel(transport, probe: probe)

        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        let card = try XCTUnwrap(model.pendingApprovals.first)
        await model.sendNow(text: "改完顺便跑测试", attachments: [])
        XCTAssertEqual(model.pendingApprovals.map(\.id), [card.id], "卡片还在等，没有被取消")
        XCTAssertEqual(model.queuedMessages(for: id).map(\.text), ["改完顺便跑测试"])

        model.resolveApproval(card.id, .allowOnce)
        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(probe.calls, ["poke"])
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(Array(FollowUpHarness.transcript(transport.requests[1]).suffix(2)),
                       [["tool", "poke 输出"], ["user", "改完顺便跑测试"]])
    }

    func testSendNowInterruptsWithTheChosenMessageAndTheRestFollowIt() async throws {
        let probe = GateProbe()
        let transport = FollowUpTransport([
            .body(FollowUpSSE.call("c1", "poke")),
            .body(FollowUpSSE.answer("B 的回答")),
            .body(FollowUpSSE.answer("A 的回答")),
        ])
        let (model, id) = try await makeModel(transport, probe: probe)

        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        await model.sendNow(text: "A", attachments: [])
        await model.sendNow(text: "B", attachments: [])
        let chosen = try XCTUnwrap(model.queuedMessages(for: id).last)

        await model.sendQueuedNow(chosen.id, in: id)
        try await waitUntil { transport.requestCount == 3 && !model.isStreaming }
        XCTAssertTrue(probe.calls.isEmpty, "立即发送打断了等批准的调用")
        XCTAssertEqual(Array(texts(model).suffix(4)), ["user:B", "assistant:B 的回答", "user:A", "assistant:A 的回答"])
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[1]).last, ["user", "B"])
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertTrue(model.queuedMessages(for: id).isEmpty)
    }

    func testStopKeepsTheQueueHeldAndSendsNothingUntilTheUserDoes() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.call("c1", "poke")), .body(FollowUpSSE.answer("追问的回答"))])
        let (model, id) = try await makeModel(transport)

        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        await model.sendNow(text: "追问", attachments: [])
        model.stop()
        try await waitUntil { !model.isStreaming && model.pendingApprovals.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.requestCount, 1, "停止后队列不自动发出")
        XCTAssertEqual(model.queuedMessages(for: id).map(\.isHeld), [true])
        XCTAssertFalse(texts(model).contains("user:追问"))

        // A new message does not carry a held one along.
        await model.sendNow(text: "新问题", attachments: [])
        try await waitUntil { transport.requestCount == 2 && !model.isStreaming }
        XCTAssertFalse(FollowUpHarness.transcript(transport.requests[1]).contains(["user", "追问"]))
        XCTAssertEqual(model.queuedMessages(for: id).count, 1)

        await model.sendQueuedNow(try XCTUnwrap(model.queuedMessages(for: id).first).id, in: id)
        try await waitUntil { transport.requestCount == 3 && !model.isStreaming }
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[2]).last, ["user", "追问"], "用户点了立即发送才发")
        XCTAssertTrue(model.queuedMessages(for: id).isEmpty)
    }

    func testEditMovesAQueuedMessageBackIntoTheDraftAndDeleteDropsIt() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.call("c1", "poke"))])
        let (model, id) = try await makeModel(transport)

        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        await model.sendNow(text: "看这个", attachments: [], pastes: [PastedTextAttachment(text: "第一行\n第二行")])
        await model.sendNow(text: "不要了", attachments: [])
        let queued = model.queuedMessages(for: id)
        XCTAssertEqual(queued.map(\.text), ["看这个", "不要了"])

        model.draft = "草稿"
        model.editQueued(queued[0].id, in: id)
        XCTAssertEqual(model.draft, "草稿\n看这个", "编辑接在已有草稿后面")
        XCTAssertEqual(model.pastedTexts.map(\.text), ["第一行\n第二行"], "折叠的粘贴回到输入框的卡片")
        model.removeQueued(queued[1].id, in: id)
        XCTAssertTrue(model.queuedMessages(for: id).isEmpty)

        model.stop()
        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testAFollowUpTheReplyEndedWithoutAnsweringIsMarkedUntilAnswered() async throws {
        let probe = GateProbe()
        let transport = FollowUpTransport([
            .body(FollowUpSSE.call("c1", "wait_probe")),
            .fail,
            .body(FollowUpSSE.answer("补上了")),
        ])
        let (model, _) = try await makeModel(transport, probe: probe)

        await model.sendNow(text: "先查", attachments: [])
        try await waitUntil { probe.calls == ["wait_probe"] }
        await model.sendNow(text: "追问", attachments: [])
        probe.gate.release()
        try await waitUntil { !model.isStreaming && transport.requestCount == 2 }
        let followUp = try XCTUnwrap(model.selectedConversation?.messages.first { $0.concatenatedText == "追问" })
        XCTAssertEqual(followUp.errorText, ChatAppModel.unansweredFollowUpText, "追问进了回复，但下一轮失败了")

        model.regenerateLast()
        try await waitUntil { !model.isStreaming && transport.requestCount == 3 }
        let answered = try XCTUnwrap(model.selectedConversation?.messages.first { $0.concatenatedText == "追问" })
        XCTAssertNil(answered.errorText, "之后有一轮读到它，提示就去掉")
        XCTAssertEqual(model.selectedConversation?.messages.last?.concatenatedText, "补上了")
    }

    func testAPhoneFollowUpHoldsTheRestOfTheReplyToThePhonesLimit() async throws {
        let probe = GateProbe()
        let transport = FollowUpTransport([
            .body(FollowUpSSE.call("c1", "wait_probe")),
            .body(FollowUpSSE.call("c2", "poke")),
            .body(FollowUpSSE.answer("不该出现")),
        ])
        let (model, id) = try await makeModel(transport, probe: probe, mode: .full)
        XCTAssertFalse(model.settings.relayAllowShell)

        await model.sendNow(text: "Mac 上发的", attachments: [])
        try await waitUntil { probe.calls == ["wait_probe"] }
        await model.handleRelayCommand(.input(conversationID: id.uuidString, text: "手机追问：改一下"))
        XCTAssertEqual(model.queuedMessages(for: id).map(\.remote), [true])
        probe.gate.release()

        try await waitUntil { model.pendingApprovals.count == 1 }
        XCTAssertEqual(model.pendingApprovals.first?.toolName, "poke", "手机的追问进来后，写操作要在 Mac 上批准")
        XCTAssertEqual(probe.calls, ["wait_probe"])
        model.stop()
        try await waitUntil { !model.isStreaming }
    }

    func testThePhoneSeesTheQueueAndActsOnIt() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.call("c1", "poke")), .body(FollowUpSSE.answer("手机让我现在答"))])
        let (model, id) = try await makeModel(transport)

        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        await model.sendNow(text: "删掉这条", attachments: [])
        await model.sendNow(text: "现在就发", attachments: [])
        let mirrored = try XCTUnwrap(model.relaySnapshot().conversations.first { $0.id == id.uuidString })
        XCTAssertEqual(mirrored.queued.map(\.text), ["删掉这条", "现在就发"])
        XCTAssertTrue(mirrored.isStreaming)

        await model.handleRelayCommand(.removeQueued(conversationID: id.uuidString, queuedID: mirrored.queued[0].id))
        XCTAssertEqual(model.queuedMessages(for: id).map(\.text), ["现在就发"])
        await model.handleRelayCommand(.sendQueuedNow(conversationID: id.uuidString, queuedID: mirrored.queued[1].id))
        try await waitUntil { transport.requestCount == 2 && !model.isStreaming }
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[1]).last, ["user", "现在就发"])
        XCTAssertNil(model.relaySnapshot().conversations.first { $0.id == id.uuidString }?.queued.first)
    }

    func testTheComposerQueuesForTheReplyingConversationAndCompactsOnSlashCompact() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.call("c1", "poke"))])
        let (model, id) = try await makeModel(transport)

        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        model.draft = "输入框里的追问"
        model.send()
        try await waitUntil { model.queuedMessages(for: id).count == 1 }
        XCTAssertEqual(model.draft, "")

        model.draft = ChatAppModel.compactCommand
        model.send()
        try await waitUntil { model.errorMessage != nil }
        XCTAssertEqual(model.errorMessage, "回复进行中，结束后再压缩", "/compact 走压缩，不当成消息发出")
        XCTAssertEqual(model.queuedMessages(for: id).count, 1)
        model.stop()
        try await waitUntil { !model.isStreaming }
    }
}
