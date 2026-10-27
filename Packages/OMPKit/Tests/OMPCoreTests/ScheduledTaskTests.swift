import XCTest
@testable import OMPCore

final class ScheduledTaskTests: XCTestCase {
    private var directory: URL!
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("omp-tasks-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func task(_ schedule: TaskSchedule, created: Date) -> ScheduledTask {
        var task = ScheduledTask(title: "日报", prompt: "总结今天的提交", schedule: schedule, createdAt: created)
        task.activate(now: created, calendar: calendar)
        return task
    }

    // MARK: Catch-up and slots

    func testSeveralMissedSlotsRunOnceThenTheNextSlotIsAfterNow() {
        var daily = task(.daily(TimeOfDay(hour: 9, minute: 0)), created: at(10, 23, 12))
        XCTAssertEqual(daily.nextRunAt, at(10, 24, 9))
        // The app was closed from the 24th to the 27th at noon: four slots passed.
        let launch = at(10, 27, 12)
        XCTAssertTrue(daily.isDue(at: launch))
        daily.recordRun(at: launch, conversationID: UUID(), calendar: calendar)
        XCTAssertEqual(daily.runCount, 1)
        XCTAssertEqual(daily.lastRunAt, launch)
        XCTAssertEqual(daily.nextRunAt, at(10, 28, 9))
        XCTAssertFalse(daily.isDue(at: launch), "the missed slots went with the one run")
    }

    func testIntervalCatchUpRestartsFromTheRun() {
        var every = task(.everyMinutes(15), created: at(10, 27, 8))
        let wake = at(10, 27, 10, 7)
        XCTAssertTrue(every.isDue(at: wake))
        every.recordRun(at: wake, conversationID: UUID(), calendar: calendar)
        XCTAssertEqual(every.nextRunAt, wake.addingTimeInterval(15 * 60))
    }

    func testASlotIsNeverRunTwice() {
        var daily = task(.daily(TimeOfDay(hour: 9, minute: 0)), created: at(10, 26, 12))
        let slot = at(10, 27, 9)
        XCTAssertTrue(daily.isDue(at: slot))
        daily.recordRun(at: slot, conversationID: UUID(), calendar: calendar)
        // Exactly at the slot: the next slot is tomorrow's, so the same slot is not due again.
        XCTAssertFalse(daily.isDue(at: slot))
        XCTAssertFalse(daily.isDue(at: at(10, 27, 23, 59)))
        XCTAssertTrue(daily.isDue(at: at(10, 28, 9)))
    }

    func testAOneTimeTaskCompletesAfterItsRun() {
        var once = task(.once(at(10, 28, 9)), created: at(10, 27, 12))
        XCTAssertFalse(once.isDue(at: at(10, 28, 8, 59)))
        once.recordRun(at: at(10, 28, 9), conversationID: UUID(), calendar: calendar)
        XCTAssertEqual(once.status, .completed)
        XCTAssertNil(once.nextRunAt)
        XCTAssertFalse(once.isDue(at: at(10, 29, 9)))
    }

    func testAManualRunBeforeTheSlotLeavesTheScheduleAlone() {
        var daily = task(.daily(TimeOfDay(hour: 9, minute: 0)), created: at(10, 27, 12))
        let conversation = UUID()
        daily.recordRun(at: at(10, 27, 15), conversationID: conversation, calendar: calendar)
        XCTAssertEqual(daily.runCount, 1)
        XCTAssertEqual(daily.lastRunConversationID, conversation)
        XCTAssertEqual(daily.nextRunAt, at(10, 28, 9))
        // A manual run of a one-time task before its time does not complete it.
        var once = task(.once(at(10, 30, 9)), created: at(10, 27, 12))
        once.recordRun(at: at(10, 27, 15), conversationID: conversation, calendar: calendar)
        XCTAssertEqual(once.status, .active)
        XCTAssertEqual(once.nextRunAt, at(10, 30, 9))
    }

    func testASkippedSlotIsConsumedAndRecorded() {
        var hourly = task(.everyHours(1), created: at(10, 27, 8))
        let due = at(10, 27, 9, 30)
        hourly.recordSkip(at: due, reason: "对话仍在回复", calendar: calendar)
        XCTAssertEqual(hourly.lastSkipReason, "对话仍在回复")
        XCTAssertEqual(hourly.lastSkippedAt, due)
        XCTAssertEqual(hourly.runCount, 0)
        XCTAssertEqual(hourly.nextRunAt, due.addingTimeInterval(3600))
        // The next run that goes through clears the skip.
        hourly.recordRun(at: at(10, 27, 10, 30), conversationID: UUID(), calendar: calendar)
        XCTAssertNil(hourly.lastSkipReason)
        // A one-time task has no other slot: skipping pauses it instead of calling it completed.
        var once = task(.once(at(10, 28, 9)), created: at(10, 27, 12))
        once.recordSkip(at: at(10, 28, 9), reason: "对话仍在回复", calendar: calendar)
        XCTAssertEqual(once.status, .paused)
        XCTAssertNil(once.nextRunAt)
        // A task that is not due books nothing.
        var notDue = task(.everyHours(1), created: at(10, 27, 8))
        notDue.recordSkip(at: at(10, 27, 8, 30), reason: "x", calendar: calendar)
        XCTAssertNil(notDue.lastSkipReason)
        XCTAssertEqual(notDue.nextRunAt, at(10, 27, 9))
    }

    // MARK: Pause and resume

    func testAnExpiredOneTimeTaskCannotResumeWithoutANewTime() {
        var once = task(.once(at(10, 28, 9)), created: at(10, 27, 12))
        once.pause()
        XCTAssertEqual(once.status, .paused)
        XCTAssertNil(once.nextRunAt)
        XCTAssertEqual(once.resume(now: at(10, 28, 10), calendar: calendar), ScheduledTask.expiredResumeMessage)
        XCTAssertEqual(once.status, .paused)
        // Before its time it resumes onto that time.
        XCTAssertNil(once.resume(now: at(10, 27, 18), calendar: calendar))
        XCTAssertEqual(once.status, .active)
        XCTAssertEqual(once.nextRunAt, at(10, 28, 9))
    }

    func testResumeContinuesFromTheNextSlotAfterNow() {
        var daily = task(.daily(TimeOfDay(hour: 9, minute: 0)), created: at(10, 20, 12))
        daily.pause()
        XCTAssertNil(daily.resume(now: at(10, 27, 10), calendar: calendar))
        XCTAssertEqual(daily.nextRunAt, at(10, 28, 9), "slots missed while paused are not run")
    }

    // MARK: Editing

    func testEditingTheScheduleRecomputesTheSlotButATitleEditKeepsADueOne() {
        var daily = task(.daily(TimeOfDay(hour: 9, minute: 0)), created: at(10, 26, 12))
        let now = at(10, 27, 10)
        var renamed = daily
        renamed.title = "早报"
        daily.applyEdit(renamed, now: now, calendar: calendar)
        XCTAssertEqual(daily.title, "早报")
        XCTAssertTrue(daily.isDue(at: now), "the 09:00 slot that is still waiting stays due")

        var moved = daily
        moved.schedule = .daily(TimeOfDay(hour: 18, minute: 0))
        daily.applyEdit(moved, now: now, calendar: calendar)
        XCTAssertEqual(daily.nextRunAt, at(10, 27, 18))
    }

    func testEditingKeepsHistoryAndRevivesACompletedTaskWithANewTime() {
        var once = task(.once(at(10, 28, 9)), created: at(10, 27, 12))
        let conversation = UUID()
        once.recordRun(at: at(10, 28, 9), conversationID: conversation, calendar: calendar)
        var edited = once
        edited.schedule = .once(at(10, 30, 9))
        edited.runCount = 99
        once.applyEdit(edited, now: at(10, 29, 9), calendar: calendar)
        XCTAssertEqual(once.status, .active)
        XCTAssertEqual(once.nextRunAt, at(10, 30, 9))
        XCTAssertEqual(once.runCount, 1, "history is not the editor's to change")
        XCTAssertEqual(once.lastRunConversationID, conversation)
        // A paused task stays paused after an edit.
        var paused = task(.daily(TimeOfDay(hour: 9, minute: 0)), created: at(10, 27, 12))
        paused.pause()
        var changed = paused
        changed.schedule = .everyHours(2)
        paused.applyEdit(changed, now: at(10, 27, 13), calendar: calendar)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertNil(paused.nextRunAt)
    }

    func testValidation() {
        let now = at(10, 27, 12)
        var draft = ScheduledTask(title: " ", prompt: "", schedule: .everyMinutes(3))
        var errors = draft.validationErrors(now: now)
        XCTAssertEqual(errors[.title], "请填写标题")
        XCTAssertEqual(errors[.prompt], "请填写提示词")
        XCTAssertEqual(errors[.schedule], "间隔至少 5 分钟")
        draft.title = "日报"
        draft.prompt = "总结"
        draft.schedule = .weekly([], TimeOfDay(hour: 9, minute: 0))
        XCTAssertEqual(draft.validationErrors(now: now), [.schedule: "至少选一天"])
        draft.schedule = .once(at(10, 27, 11))
        XCTAssertEqual(draft.validationErrors(now: now), [.schedule: "时间已过，请选一个将来的时间"])
        // A finished one-time task can still be renamed without a new time.
        var finished = task(.once(at(10, 27, 11)), created: at(10, 26, 12))
        finished.recordRun(at: at(10, 27, 11), conversationID: UUID(), calendar: calendar)
        var renamed = finished
        renamed.title = "新名字"
        errors = renamed.validationErrors(now: now, previous: finished)
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: Target and time zones

    func testAnAttachedTaskWhoseConversationIsGoneFallsBackToANewThread() {
        let kept = UUID()
        var attached = ScheduledTask(title: "心跳", prompt: "继续", schedule: .everyHours(1), target: .attached(kept))
        XCTAssertEqual(attached.resolvedTarget { $0 == kept }, .attached(kept))
        attached.target = .attached(UUID())
        XCTAssertEqual(attached.resolvedTarget { $0 == kept }, .newThread)
    }

    func testATimeZoneChangeReReadsFutureWallClockSlotsOnly() {
        var daily = task(.daily(TimeOfDay(hour: 9, minute: 0)), created: at(10, 27, 12))
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        daily.followTimeZoneChange(now: at(10, 27, 13), calendar: tokyo)
        XCTAssertEqual(daily.nextRunAt, tokyo.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9)))

        var due = task(.daily(TimeOfDay(hour: 9, minute: 0)), created: at(10, 26, 12))
        due.followTimeZoneChange(now: at(10, 27, 10), calendar: tokyo)
        XCTAssertEqual(due.nextRunAt, at(10, 27, 9), "a due slot stays for the scheduler")

        var hourly = task(.everyHours(2), created: at(10, 27, 12))
        hourly.followTimeZoneChange(now: at(10, 27, 13), calendar: tokyo)
        XCTAssertEqual(hourly.nextRunAt, at(10, 27, 14))
    }

    // MARK: Persistence

    func testTasksRoundTripThroughTheWorkspaceDocument() async throws {
        let store = FileConversationStore(directoryURL: directory)
        var weekly = task(.weekly([.monday, .wednesday], TimeOfDay(hour: 8, minute: 30)), created: at(10, 27, 12))
        weekly.recordRun(at: at(10, 27, 13), conversationID: UUID(), calendar: calendar)
        let attached = ScheduledTask(
            title: "心跳", prompt: "继续推进", schedule: .everyMinutes(30), target: .attached(UUID()),
            workingDirectory: "/tmp/repo", projectID: UUID(), permissionMode: PermissionMode.auto.rawValue,
            status: .paused, createdAt: at(10, 1, 9), lastSkippedAt: at(10, 2, 9), lastSkipReason: "对话仍在回复"
        )
        try await store.saveScheduledTasks([weekly, attached])
        let reopened = FileConversationStore(directoryURL: directory)
        let loaded = try await reopened.loadScheduledTasks()
        XCTAssertEqual(loaded, [weekly, attached])
    }

    func testAnOldDocumentWithoutTasksStillOpens() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"{"version":1,"conversations":[{"id":"6F1C2C1E-3F43-4C55-9E8B-1B5B7C8D9E01","title":"旧对话","messages":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}],"providers":[],"models":[]}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("workspace.json"))
        let store = FileConversationStore(directoryURL: directory)
        let tasks = try await store.loadScheduledTasks()
        XCTAssertEqual(tasks, [])
        let conversations = try await store.loadAll()
        XCTAssertEqual(conversations.map(\.title), ["旧对话"])
    }

    func testADamagedTaskIsDroppedAndTheRestOpen() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = task(.daily(TimeOfDay(hour: 9, minute: 0)), created: at(10, 27, 12))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goodJSON = String(decoding: try encoder.encode(good), as: UTF8.self)
        let document = #"{"version":1,"conversations":[],"scheduledTasks":[{"id":"not-a-uuid","schedule":{"kind":"monthly"}},null,"#
            + goodJSON + "]}"
        try Data(document.utf8).write(to: directory.appendingPathComponent("workspace.json"))
        let store = FileConversationStore(directoryURL: directory)
        let tasks = try await store.loadScheduledTasks()
        XCTAssertEqual(tasks, [good])
    }
}
