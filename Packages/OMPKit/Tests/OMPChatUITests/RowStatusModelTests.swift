import XCTest
import OMPCore
@testable import OMPChatUI

/// Row tags from real model runs over a scripted transport: approval cards,
/// 停止 with a queue, failed replies and scheduled runs. Never touches the
/// network.
@MainActor
final class RowStatusModelTests: XCTestCase {
    private var libraryRoot: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("row-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    private func makeModel(_ transport: FollowUpTransport, tools: Bool? = true) async throws -> (ChatAppModel, UUID) {
        let (model, id) = try await FollowUpHarness.makeModel(transport, libraryRoot: libraryRoot, tools: tools)
        model.scheduleCalendar = Calendar(identifier: .gregorian)
        return (model, id)
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async throws {
        try await FollowUpHarness.waitUntil(timeout, condition)
    }

    private func relayStatus(_ model: ChatAppModel, _ id: UUID) -> String? {
        model.relaySnapshot().conversations.first { $0.id == id.uuidString }?.status
    }

    func testAnApprovalCardThenStopWithAQueueGoesFromAwaitingApprovalToNeedsInput() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.call("c1", "poke"))])
        let (model, id) = try await makeModel(transport)

        await model.sendNow(text: "改一下", attachments: [])
        try await waitUntil { model.pendingApprovals.count == 1 }
        XCTAssertEqual(model.rowStatus(for: id).tags, [.awaitingApproval])
        XCTAssertEqual(relayStatus(model, id), "awaitingApproval")
        XCTAssertTrue(model.priorityConversationIDs().contains(id))

        await model.sendNow(text: "追问", attachments: [])
        model.stop()
        try await waitUntil { !model.isStreaming && model.pendingApprovals.isEmpty }
        XCTAssertEqual(model.rowStatus(for: id).primary, .needsInput, "停止后排队的追问等用户决定")
        XCTAssertEqual(relayStatus(model, id), "needsInput")
        XCTAssertTrue(model.priorityConversationIDs().contains(id))

        await model.sendQueuedNow(try XCTUnwrap(model.queuedMessages(for: id).first).id, in: id)
        try await waitUntil { transport.requestCount == 2 && !model.isStreaming }
        XCTAssertEqual(model.rowStatus(for: id), .none, "发出并得到回答后不再需要处理")
        XCTAssertNil(relayStatus(model, id))
    }

    func testAFailedReplyIsASystemErrorUntilARetrySucceeds() async throws {
        let transport = FollowUpTransport([.fail, .body(FollowUpSSE.answer("这次好了"))])
        let (model, id) = try await makeModel(transport, tools: false)

        await model.sendNow(text: "查一下", attachments: [])
        try await waitUntil { transport.requestCount == 1 && !model.isStreaming }
        XCTAssertEqual(model.rowStatus(for: id).tags, [.systemError])
        XCTAssertEqual(relayStatus(model, id), "systemError")

        await model.sendNow(text: "重试", attachments: [])
        try await waitUntil { transport.requestCount == 2 && !model.isStreaming }
        XCTAssertEqual(model.rowStatus(for: id), .none)
    }

    func testANewThreadRunIsStampedWithItsTaskAndKeepsTheTagAfterTheTaskIsDeleted() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("日报：三次提交"))])
        let (model, selected) = try await makeModel(transport, tools: false)
        let task = model.addScheduledTask(
            ScheduledTask(title: "日报", prompt: "总结今天的提交", schedule: .everyHours(1)), now: start
        )

        let outcomes = await model.scheduledTaskScheduler.runDue(now: start.addingTimeInterval(3600))
        guard case .started(let runID)? = outcomes[task.id] else { return XCTFail("not started: \(outcomes)") }
        try await waitUntil { !model.isStreaming }

        XCTAssertEqual(model.conversations.first { $0.id == runID }?.scheduledTaskID, task.id)
        XCTAssertNil(model.conversations.first { $0.id == selected }?.scheduledTaskID)
        XCTAssertEqual(model.rowStatus(for: runID).tags, [.automation])
        XCTAssertEqual(model.rowStatus(for: runID).taskID, task.id)
        XCTAssertTrue(model.openLinkedScheduledTask(runID))
        XCTAssertEqual(model.rowStatus(for: selected), .none)

        model.deleteScheduledTask(task.id)
        XCTAssertEqual(model.rowStatus(for: runID).tags, [.automation], "来源是历史，任务删了标签还在")
        XCTAssertNil(model.rowStatus(for: runID).taskID)
        XCTAssertFalse(model.openLinkedScheduledTask(runID), "没有任务可打开")
    }

    func testAnAttachedTaskTagsItsTargetWithoutStampingAnOrigin() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("继续推进了"))])
        let (model, selected) = try await makeModel(transport, tools: false)
        let task = model.addScheduledTask(
            ScheduledTask(title: "心跳", prompt: "继续推进", schedule: .everyMinutes(30), target: .attached(selected)),
            now: start
        )
        XCTAssertEqual(model.rowStatus(for: selected).tags, [.attachedAutomation])
        XCTAssertEqual(model.rowStatus(for: selected).taskID, task.id)

        _ = await model.scheduledTaskScheduler.runDue(now: start.addingTimeInterval(1800))
        try await waitUntil { !model.isStreaming }
        XCTAssertNil(model.conversations.first { $0.id == selected }?.scheduledTaskID, "附加的运行不改写来源")
        XCTAssertEqual(model.rowStatus(for: selected).tags, [.attachedAutomation])

        var detached = try XCTUnwrap(model.scheduledTasks.first)
        detached.target = .newThread
        model.updateScheduledTask(detached, now: start.addingTimeInterval(1900))
        XCTAssertEqual(model.rowStatus(for: selected), .none, "改成新对话后不再附加")
    }

    func testStoppingBeforeAnyTextIsNotASystemError() async throws {
        let gate = TestGate()
        let transport = FollowUpTransport([.gated(gate, FollowUpSSE.answer("太晚了"))])
        let (model, id) = try await makeModel(transport, tools: false)

        await model.sendNow(text: "写一篇长文", attachments: [])
        try await waitUntil { transport.requestCount == 1 && model.isStreaming }
        model.stop()
        try await waitUntil { !model.isStreaming }
        XCTAssertNotEqual(model.rowStatus(for: id).primary, .systemError,
                          "用户自己停止不算系统错误: \(String(describing: model.conversations.first { $0.id == id }?.messages.last))")
    }
}
