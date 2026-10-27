import XCTest
import OMPCore
@testable import OMPChatUI

/// Answers streamed requests from a script and records their bodies. A
/// `nil` entry holds its stream open until the reply is cancelled, so a
/// test can keep a conversation streaming. Never touches the network.
private final class ScheduledRunTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String?]
    private var bodies: [String] = []
    /// Streams held open stay referenced until the test ends.
    private var held: [AsyncThrowingStream<Data, Error>.Continuation] = []

    init(_ script: [String?]) {
        self.script = script
    }

    /// Every streamed request body, as sent.
    var requests: [String] {
        lock.withLock { bodies }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"object":"list","data":[{"id":"mock-model","object":"model"}]}"#.utf8))
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let next: String? = lock.withLock {
            bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            return script.isEmpty ? Self.answer("（脚本已结束）") : script.removeFirst()
        }
        guard let body = next else {
            // Held open: ends only when the reply is cancelled.
            return AsyncThrowingStream { continuation in
                lock.withLock { held.append(continuation) }
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(Data(body.utf8))
            continuation.finish()
        }
    }

    static func answer(_ text: String) -> String {
        let object: [String: Any] = ["choices": [["delta": ["content": text], "finish_reason": "stop"]]]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return "data: \(String(decoding: data, as: UTF8.self))\n\ndata: [DONE]\n\n"
    }
}

@MainActor
final class ScheduledTaskRunTests: XCTestCase {
    private var libraryRoot: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("scheduled-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    private func makeModel(_ transport: ScheduledRunTransport, store: InMemoryConversationStore = InMemoryConversationStore(), apiKey: String = "sk-test") async throws -> (ChatAppModel, UUID) {
        let model = ChatAppModel(
            store: store,
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: libraryRoot),
            transport: transport
        )
        await model.bootstrap()
        await model.addProvider(ProviderProfile(name: "Mock", kind: .openAICompatible, baseURL: URL(string: "https://mock.test")!), apiKey: apiKey)
        model.scheduleCalendar = Calendar(identifier: .gregorian)
        return (model, try XCTUnwrap(model.selectedConversationID))
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }

    func testADueTaskStartsANewConversationWithThePromptAndTheReply() async throws {
        let transport = ScheduledRunTransport([ScheduledRunTransport.answer("日报：三次提交")])
        let store = InMemoryConversationStore()
        let (model, selected) = try await makeModel(transport, store: store)
        let task = model.addScheduledTask(
            ScheduledTask(title: "日报", prompt: "总结今天的提交", schedule: .everyHours(1)), now: start
        )
        XCTAssertEqual(task.nextRunAt, start.addingTimeInterval(3600))

        // Two slots were missed; the pass runs the task once.
        let now = start.addingTimeInterval(2.5 * 3600)
        let outcomes = await model.scheduledTaskScheduler.runDue(now: now)
        guard case .started(let runID)? = outcomes[task.id] else { return XCTFail("not started: \(outcomes)") }
        try await waitUntil { !model.isStreaming }

        let run = try XCTUnwrap(model.conversations.first { $0.id == runID })
        XCTAssertNotEqual(runID, selected)
        XCTAssertTrue(run.title.hasPrefix("日报 · "), run.title)
        XCTAssertEqual(run.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(run.messages.first?.concatenatedText, "总结今天的提交")
        XCTAssertEqual(run.messages.last?.concatenatedText, "日报：三次提交")
        XCTAssertTrue(run.hasUnread, "a run nobody is looking at is marked unread")
        XCTAssertEqual(model.selectedConversationID, selected, "a run does not take over the window")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(transport.requests[0].contains("总结今天的提交"), "the prompt went to the model")

        let booked = try XCTUnwrap(model.scheduledTasks.first)
        XCTAssertEqual(booked.runCount, 1)
        XCTAssertEqual(booked.lastRunAt, now)
        XCTAssertEqual(booked.lastRunConversationID, runID)
        XCTAssertEqual(booked.nextRunAt, now.addingTimeInterval(3600))
        try await waitUntil { (try? await store.loadScheduledTasks().first?.runCount) == 1 }

        // The same moment again: the slot is spent, nothing runs twice.
        let again = await model.scheduledTaskScheduler.runDue(now: now)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(model.openScheduledTaskRun(task.id))
        XCTAssertEqual(model.selectedConversationID, runID)
    }

    func testAnAttachedTaskSendsIntoTheSameConversation() async throws {
        let transport = ScheduledRunTransport([ScheduledRunTransport.answer("第一次"), ScheduledRunTransport.answer("第二次")])
        let (model, selected) = try await makeModel(transport)
        let task = model.addScheduledTask(
            ScheduledTask(title: "心跳", prompt: "继续推进", schedule: .everyMinutes(30), target: .attached(selected)), now: start
        )
        let count = model.conversations.count

        _ = await model.scheduledTaskScheduler.runDue(now: start.addingTimeInterval(1800))
        try await waitUntil { !model.isStreaming }
        _ = await model.scheduledTaskScheduler.runDue(now: start.addingTimeInterval(3600))
        try await waitUntil { !model.isStreaming }

        XCTAssertEqual(model.conversations.count, count, "no new conversation")
        let conversation = try XCTUnwrap(model.conversations.first { $0.id == selected })
        XCTAssertEqual(conversation.messages.map(\.concatenatedText), ["继续推进", "第一次", "继续推进", "第二次"])
        XCTAssertEqual(model.scheduledTasks.first?.runCount, 2)
        XCTAssertEqual(model.scheduledTasks.first?.lastRunConversationID, selected)
        XCTAssertEqual(model.scheduledTasks.first?.id, task.id)
    }

    func testARunIsSkippedWhileItsConversationIsStillReplying() async throws {
        let transport = ScheduledRunTransport([nil])
        let (model, selected) = try await makeModel(transport)
        let task = model.addScheduledTask(
            ScheduledTask(title: "心跳", prompt: "继续推进", schedule: .everyHours(1), target: .attached(selected)), now: start
        )
        await model.sendNow(text: "先回答这个", attachments: [])
        XCTAssertTrue(model.isStreaming)
        XCTAssertEqual(model.streamingConversationID, selected)
        try await waitUntil { transport.requests.count == 1 }

        let now = start.addingTimeInterval(3600)
        let outcomes = await model.scheduledTaskScheduler.runDue(now: now)
        XCTAssertEqual(outcomes[task.id], .skipped("对话仍在回复"))
        let booked = try XCTUnwrap(model.scheduledTasks.first)
        XCTAssertEqual(booked.runCount, 0)
        XCTAssertEqual(booked.lastSkipReason, "对话仍在回复")
        XCTAssertEqual(booked.lastSkippedAt, now)
        XCTAssertEqual(booked.nextRunAt, now.addingTimeInterval(3600), "the slot is spent, not retried in a loop")
        let messages = model.conversations.first { $0.id == selected }?.messages ?? []
        XCTAssertFalse(messages.contains { $0.concatenatedText == "继续推进" }, "nothing was queued into the running reply")
        XCTAssertTrue(model.isStreaming, "the running reply was left alone")
        XCTAssertEqual(transport.requests.count, 1, "the run sent nothing")
        model.stop()
        try await waitUntil { !model.isStreaming }
    }

    func testARunWaitsWhileAnotherConversationReplies() async throws {
        let transport = ScheduledRunTransport([nil, ScheduledRunTransport.answer("日报")])
        let (model, selected) = try await makeModel(transport)
        let task = model.addScheduledTask(ScheduledTask(title: "日报", prompt: "总结", schedule: .everyHours(1)), now: start)
        await model.sendNow(text: "长任务", attachments: [])
        XCTAssertEqual(model.streamingConversationID, selected)

        let now = start.addingTimeInterval(3600)
        let outcomes = await model.scheduledTaskScheduler.runDue(now: now)
        XCTAssertEqual(outcomes[task.id], .waiting)
        XCTAssertEqual(model.streamingConversationID, selected, "the other reply is not cut off")
        XCTAssertEqual(model.scheduledTasks.first?.nextRunAt, task.nextRunAt, "nothing booked")
        XCTAssertTrue(model.scheduledTasks.first?.isDue(at: now) ?? false)

        model.stop()
        try await waitUntil { !model.isStreaming }
        let retry = await model.scheduledTaskScheduler.runDue(now: now.addingTimeInterval(15))
        guard case .started? = retry[task.id] else { return XCTFail("not started: \(retry)") }
        try await waitUntil { !model.isStreaming }
        XCTAssertEqual(model.scheduledTasks.first?.runCount, 1)
    }

    func testADeletedAttachedConversationFallsBackToANewThread() async throws {
        let transport = ScheduledRunTransport([ScheduledRunTransport.answer("好")])
        let (model, selected) = try await makeModel(transport)
        let other = model.newConversation()
        let task = model.addScheduledTask(
            ScheduledTask(title: "心跳", prompt: "继续", schedule: .everyHours(1), target: .attached(other.id)), now: start
        )
        model.deleteConversation(other.id)
        XCTAssertTrue(model.scheduledTaskTargetMissing(model.scheduledTasks[0]))

        let outcomes = await model.scheduledTaskScheduler.runDue(now: start.addingTimeInterval(3600))
        guard case .started(let runID)? = outcomes[task.id] else { return XCTFail("not started: \(outcomes)") }
        try await waitUntil { !model.isStreaming }
        XCTAssertNotEqual(runID, other.id)
        XCTAssertNotEqual(runID, selected)
        XCTAssertEqual(model.conversations.first { $0.id == runID }?.messages.first?.concatenatedText, "继续")
    }

    func testATaskThatCannotStartIsSkippedWithTheReasonAndRunNowSaysWhy() async throws {
        // Without a key the catalog never loads, so no model can answer.
        let transport = ScheduledRunTransport([])
        let (model, _) = try await makeModel(transport, apiKey: "")
        let task = model.addScheduledTask(ScheduledTask(title: "日报", prompt: "总结", schedule: .everyHours(1)), now: start)

        let manual = await model.runScheduledTaskNow(task.id, now: start)
        XCTAssertEqual(manual, "无法启动定时任务：先在设置中添加供应商并选择模型")
        XCTAssertEqual(model.scheduledTasks.first?.nextRunAt, task.nextRunAt, "a failed manual run books nothing")
        XCTAssertNil(model.scheduledTasks.first?.lastSkipReason)

        let now = start.addingTimeInterval(3600)
        let outcomes = await model.scheduledTaskScheduler.runDue(now: now)
        XCTAssertEqual(outcomes[task.id], .skipped("先在设置中添加供应商并选择模型"))
        XCTAssertEqual(model.scheduledTasks.first?.nextRunAt, now.addingTimeInterval(3600), "no hot retry loop")
        XCTAssertEqual(model.scheduledTasks.first?.runCount, 0)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testPauseResumeAndRunNow() async throws {
        let transport = ScheduledRunTransport([ScheduledRunTransport.answer("手动")])
        let (model, _) = try await makeModel(transport)
        let once = model.addScheduledTask(
            ScheduledTask(title: "提醒", prompt: "提醒我开会", schedule: .once(start.addingTimeInterval(600))), now: start
        )
        model.pauseScheduledTask(once.id)
        XCTAssertEqual(model.scheduledTasks.first?.status, .paused)
        let paused = await model.scheduledTaskScheduler.runDue(now: start.addingTimeInterval(700))
        XCTAssertTrue(paused.isEmpty, "a paused task does not run")
        XCTAssertEqual(model.resumeScheduledTask(once.id, now: start.addingTimeInterval(700)), ScheduledTask.expiredResumeMessage)

        let manual = await model.runScheduledTaskNow(once.id, now: start.addingTimeInterval(800))
        XCTAssertNil(manual)
        XCTAssertTrue(model.isScheduledTaskRunning(once.id))
        try await waitUntil { !model.isStreaming }
        XCTAssertFalse(model.isScheduledTaskRunning(once.id))
        XCTAssertEqual(model.scheduledTasks.first?.runCount, 1)
        XCTAssertEqual(model.scheduledTasks.first?.status, .paused, "running by hand does not resume it")

        model.deleteScheduledTask(once.id)
        XCTAssertTrue(model.scheduledTasks.isEmpty)
    }
}
