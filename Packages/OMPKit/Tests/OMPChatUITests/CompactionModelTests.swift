import XCTest
import OMPCore
@testable import OMPChatUI

/// 压缩上下文: one summary request, then requests that send the summary in
/// place of the older turns; automatic near the window; failure and
/// follow-ups sent meanwhile.
@MainActor
final class CompactionModelTests: XCTestCase {
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("compaction-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    private func makeModel(_ transport: FollowUpTransport) async throws -> (ChatAppModel, UUID) {
        try await FollowUpHarness.makeModel(transport, libraryRoot: libraryRoot, tools: false)
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async throws {
        try await FollowUpHarness.waitUntil(timeout, condition)
    }

    private func send(_ model: ChatAppModel, _ text: String) async throws {
        await model.sendNow(text: text, attachments: [])
        try await waitUntil { !model.isStreaming }
    }

    /// The first turn is long enough that a summary of it is smaller: a
    /// summary longer than what it covers is not applied.
    private static let firstTurn = "一" + String(repeating: "这是一段很长的背景材料。", count: 20)

    /// Three answered turns: 一（长）/ 二 / 三.
    private func threeTurns(_ model: ChatAppModel) async throws {
        for text in [Self.firstTurn, "二", "三"] { try await send(model, text) }
    }

    private static let answers: [FollowUpTransport.Step] = ["答一", "答二", "答三"].map { .body(FollowUpSSE.answer($0)) }

    func testASummaryNoShorterThanWhatItCoversIsNotApplied() async throws {
        let wordy = "用户先说了一个字「一」，助手回答了「答一」，此外没有别的内容。"
        let transport = FollowUpTransport(Self.answers + [.body(FollowUpSSE.answer(wordy)), .body(FollowUpSSE.answer("答四"))])
        let (model, id) = try await makeModel(transport)
        for text in ["一", "二", "三"] { try await send(model, text) }

        let error = await model.compactConversation(id)
        XCTAssertEqual(error, ChatAppModel.compactionNotSmallerText)
        XCTAssertNil(model.compaction(for: id), "比原文还长的摘要不能用")
        XCTAssertNil(model.errorMessage, "这不是故障，不弹错误条")
        try await send(model, "四")
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[4]).dropFirst().first, ["user", "一"], "照发完整历史")
    }

    func testManualCompactionSummarisesTheOlderTurnsAndLaterRequestsSendTheSummary() async throws {
        let transport = FollowUpTransport(Self.answers + [.body(FollowUpSSE.answer("用户问了一，助手答了一")), .body(FollowUpSSE.answer("答四"))])
        let (model, id) = try await makeModel(transport)
        try await threeTurns(model)
        let before = try XCTUnwrap(model.selectedConversation.map { model.estimatedTokens($0) })

        let error = await model.compactConversation(id)
        XCTAssertNil(error)
        XCTAssertFalse(model.isStreaming)
        let summaryRequest = transport.requests[3]
        XCTAssertNil(summaryRequest["tools"], "摘要请求不带工具")
        let asked = FollowUpHarness.transcript(summaryRequest)
        XCTAssertEqual(asked.map(\.first), ["system", "user"])
        XCTAssertEqual(asked[0][1], ContextCompaction.instructions)
        XCTAssertTrue(asked[1][1].contains("【用户】一") && asked[1][1].contains("【助手】答一"))
        XCTAssertFalse(asked[1][1].contains("【用户】二"), "最近两轮原样保留，不进摘要")

        let messages = try XCTUnwrap(model.selectedConversation?.messages)
        XCTAssertEqual(messages.count, 6, "对话里的消息一条不少")
        let compaction = try XCTUnwrap(model.compaction(for: id))
        XCTAssertEqual(compaction.summary, "用户问了一，助手答了一")
        XCTAssertEqual(compaction.coveredThroughID, messages[1].id)
        XCTAssertEqual(compaction.tokensBefore, before, "分隔线上的「约 前 → 后」是压缩前后的请求估算")
        XCTAssertEqual(compaction.tokensAfter, model.selectedConversation.map { model.estimatedTokens($0) })

        try await send(model, "四")
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[4]).dropFirst().map { $0 }, [
            ["user", "以下是此前对话的摘要：\n\n用户问了一，助手答了一"],
            ["user", "二"], ["assistant", "答二"], ["user", "三"], ["assistant", "答三"], ["user", "四"],
        ])
    }

    func testCompactingAgainFoldsTheOlderSummaryIntoTheNewOne() async throws {
        let transport = FollowUpTransport(Self.answers + [
            .body(FollowUpSSE.answer("第一轮摘要")),
            .body(FollowUpSSE.answer("答四")),
            .body(FollowUpSSE.answer("一到二轮摘要")),
            .body(FollowUpSSE.answer("答五")),
        ])
        let (model, id) = try await makeModel(transport)
        try await threeTurns(model)
        let first = await model.compactConversation(id)
        XCTAssertNil(first)
        try await send(model, "四")

        let second = await model.compactConversation(id)
        XCTAssertNil(second)
        let asked = FollowUpHarness.transcript(transport.requests[5])[1][1]
        XCTAssertTrue(asked.contains("【此前的摘要】\n第一轮摘要"), "新摘要读旧摘要")
        XCTAssertTrue(asked.contains("【用户】二"))
        XCTAssertFalse(asked.contains("【用户】一"), "旧摘要覆盖过的消息不再重读")
        let messages = try XCTUnwrap(model.selectedConversation?.messages)
        XCTAssertEqual(model.compaction(for: id)?.coveredThroughID, messages[3].id, "新压缩取代旧的")

        try await send(model, "五")
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[6]).dropFirst().first,
                       ["user", "以下是此前对话的摘要：\n\n一到二轮摘要"])
    }

    func testNothingOldEnoughAsksNothing() async throws {
        let transport = FollowUpTransport(Self.answers)
        let (model, id) = try await makeModel(transport)
        try await send(model, "一")
        let error = await model.compactConversation(id)
        XCTAssertEqual(error, "还没有足够早的内容可以压缩")
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertNil(model.compaction(for: id))
    }

    func testAutoCompactionRunsBeforeTheReplyOnceTheThreadNearsTheWindow() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("长对话的摘要")), .body(FollowUpSSE.answer("新问题的回答"))])
        let (model, _) = try await makeModel(transport)
        // The mock model's window is 128k; six 20k-character CJK messages are
        // about 120k tokens, past 85%.
        let long = String(repeating: "字", count: 20_000)
        var seeded = Conversation(title: "长对话")
        for index in 1...3 {
            seeded.messages.append(ChatMessage(role: .user, parts: [.text("问\(index)" + long)]))
            seeded.messages.append(ChatMessage(role: .assistant, parts: [.text("答\(index)" + long)]))
        }
        let imported = try model.importConversation(from: String(decoding: JSONEncoder().encode(seeded), as: UTF8.self))
        let usage = try XCTUnwrap(model.contextUsage(imported))
        XCTAssertGreaterThanOrEqual(Double(usage.used), Double(usage.limit) * ContextCompaction.autoThreshold)

        try await send(model, "新问题")
        XCTAssertEqual(transport.requestCount, 2, "先压缩，再回复")
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[0])[0][1], ContextCompaction.instructions)
        let reply = FollowUpHarness.transcript(transport.requests[1])
        XCTAssertEqual(reply.map(\.first), ["system", "user", "user", "assistant", "user"])
        XCTAssertEqual(reply[1][1], "以下是此前对话的摘要：\n\n长对话的摘要")
        XCTAssertTrue(reply[2][1].hasPrefix("问3"))
        XCTAssertEqual(reply[4][1], "新问题")
        XCTAssertNotNil(model.compaction(for: imported.id))
        XCTAssertEqual(model.selectedConversation?.messages.last?.concatenatedText, "新问题的回答")
        let after = try XCTUnwrap(model.selectedConversation.flatMap { model.contextUsage($0) })
        XCTAssertLessThan(Double(after.used), Double(after.limit) * ContextCompaction.autoThreshold, "压缩后估算回落到阈值以下")
    }

    func testAMessageSentWhileCompactingWaitsThenGoesOutWithTheSummary() async throws {
        let gate = TestGate()
        let transport = FollowUpTransport(Self.answers + [.gated(gate, FollowUpSSE.answer("摘要")), .body(FollowUpSSE.answer("追问的回答"))])
        let (model, id) = try await makeModel(transport)
        try await threeTurns(model)

        let compacting = Task { await model.compactConversation(id) }
        try await waitUntil { model.isCompacting(id) && transport.requestCount == 4 }
        XCTAssertTrue(model.isStreaming, "压缩时停止按钮在")
        await model.sendNow(text: "压缩时发的", attachments: [])
        XCTAssertEqual(model.queuedMessages(for: id).map(\.text), ["压缩时发的"])
        XCTAssertEqual(model.statusMessage, ChatAppModel.queuedDuringCompactionText)
        XCTAssertEqual(model.relaySnapshot().conversations.first { $0.id == id.uuidString }?.isCompacting, true)
        XCTAssertEqual(transport.requestCount, 4, "压缩完成前不发")

        gate.release()
        let error = await compacting.value
        XCTAssertNil(error)
        try await waitUntil { transport.requestCount == 5 && !model.isStreaming }
        XCTAssertFalse(model.isCompacting(id))
        XCTAssertNil(model.statusMessage, "压缩结束后「压缩时不能插话」不能还挂着")
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[4]).dropFirst().map { $0 }, [
            ["user", "以下是此前对话的摘要：\n\n摘要"],
            ["user", "二"], ["assistant", "答二"], ["user", "三"], ["assistant", "答三"], ["user", "压缩时发的"],
        ])
        XCTAssertTrue(model.queuedMessages(for: id).isEmpty)
    }

    func testAFailedCompactionLeavesTheThreadAsItWasAndStillSendsTheQueuedMessage() async throws {
        let gate = TestGate()
        let transport = FollowUpTransport(Self.answers + [.gatedFail(gate), .body(FollowUpSSE.answer("追问的回答"))])
        let (model, id) = try await makeModel(transport)
        try await threeTurns(model)

        let compacting = Task { await model.compactConversation(id) }
        try await waitUntil { model.isCompacting(id) }
        await model.sendNow(text: "压缩时发的", attachments: [])
        gate.release()
        let returned = await compacting.value
        let error = try XCTUnwrap(returned)
        XCTAssertTrue(error.hasPrefix("压缩上下文失败："), error)
        try await waitUntil { transport.requestCount == 5 && !model.isStreaming }

        XCTAssertNil(model.compaction(for: id), "失败不留下摘要")
        XCTAssertEqual(model.errorMessage, error, "失败原因留在界面上")
        let reply = FollowUpHarness.transcript(transport.requests[4])
        XCTAssertEqual(reply.dropFirst().first, ["user", Self.firstTurn], "没压缩，整段历史照发")
        XCTAssertEqual(reply.last, ["user", "压缩时发的"], "排队的消息照样发出")
        XCTAssertEqual(model.selectedConversation?.messages.last?.concatenatedText, "追问的回答")
    }

    func testStopDuringCompactionKeepsTheThreadAndHoldsTheQueue() async throws {
        let gate = TestGate()
        let transport = FollowUpTransport(Self.answers + [.gated(gate, FollowUpSSE.answer("不该用上"))])
        let (model, id) = try await makeModel(transport)
        try await threeTurns(model)

        let compacting = Task { await model.compactConversation(id) }
        try await waitUntil { model.isCompacting(id) }
        await model.sendNow(text: "压缩时发的", attachments: [])
        model.stop()
        let error = await compacting.value
        XCTAssertEqual(error, "已停止压缩")
        try await waitUntil { !model.isStreaming && !model.isCompacting(id) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.compaction(for: id))
        XCTAssertEqual(transport.requestCount, 4)
        XCTAssertEqual(model.queuedMessages(for: id).map(\.isHeld), [true])
    }
}
