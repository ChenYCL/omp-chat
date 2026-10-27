import XCTest
@testable import OMPCore

final class TaskScheduleTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        date(year, month, day, hour, minute, in: calendar("UTC"))
    }

    private let nine = TimeOfDay(hour: 9, minute: 0)

    // 2026-10-27 is a Tuesday.

    func testDailyRunsTodayBeforeTheSlotAndTomorrowFromTheSlotOn() {
        let cal = calendar("Asia/Shanghai")
        let schedule = TaskSchedule.daily(nine)
        XCTAssertEqual(schedule.nextRun(after: date(2026, 10, 27, 8, 59, in: cal), calendar: cal), date(2026, 10, 27, 9, 0, in: cal))
        // Exactly at the slot is not "after" it: the next one is tomorrow's.
        XCTAssertEqual(schedule.nextRun(after: date(2026, 10, 27, 9, 0, in: cal), calendar: cal), date(2026, 10, 28, 9, 0, in: cal))
        XCTAssertEqual(schedule.nextRun(after: date(2026, 10, 27, 23, 59, in: cal), calendar: cal), date(2026, 10, 28, 9, 0, in: cal))
        // Shanghai has no DST: 09:00 local is 01:00 UTC all year.
        XCTAssertEqual(schedule.nextRun(after: date(2026, 10, 27, 8, 0, in: cal), calendar: cal), utc(2026, 10, 27, 1, 0))
    }

    func testWeekdaysSkipTheWeekendAndWeekendsSkipTheWeek() {
        let cal = calendar("Asia/Shanghai")
        let friday = date(2026, 10, 30, 10, 0, in: cal)
        let monday = date(2026, 11, 2, 9, 0, in: cal)
        XCTAssertEqual(TaskSchedule.weekdays(nine).nextRun(after: friday, calendar: cal), monday)
        XCTAssertEqual(TaskSchedule.weekdays(nine).nextRun(after: date(2026, 10, 31, 8, 0, in: cal), calendar: cal), monday)
        XCTAssertEqual(TaskSchedule.weekdays(nine).nextRun(after: date(2026, 10, 30, 8, 0, in: cal), calendar: cal), date(2026, 10, 30, 9, 0, in: cal))
        XCTAssertEqual(TaskSchedule.weekends(nine).nextRun(after: friday, calendar: cal), date(2026, 10, 31, 9, 0, in: cal))
        // Sunday after the slot: the next weekend's Saturday.
        XCTAssertEqual(TaskSchedule.weekends(nine).nextRun(after: date(2026, 11, 1, 9, 30, in: cal), calendar: cal), date(2026, 11, 7, 9, 0, in: cal))
    }

    func testWeeklyPicksTheNextChosenDayAcrossTheEndOfTheWeek() {
        let cal = calendar("Asia/Shanghai")
        let monWed = TaskSchedule.weekly([.monday, .wednesday], nine)
        // Tuesday → Wednesday.
        XCTAssertEqual(monWed.nextRun(after: date(2026, 10, 27, 12, 0, in: cal), calendar: cal), date(2026, 10, 28, 9, 0, in: cal))
        // Wednesday at the slot → next Monday.
        XCTAssertEqual(monWed.nextRun(after: date(2026, 10, 28, 9, 0, in: cal), calendar: cal), date(2026, 11, 2, 9, 0, in: cal))
        // Sunday night → Monday morning.
        XCTAssertEqual(monWed.nextRun(after: date(2026, 11, 1, 23, 59, in: cal), calendar: cal), date(2026, 11, 2, 9, 0, in: cal))
        // A single day after its slot waits a whole week.
        let tuesdays = TaskSchedule.weekly([.tuesday], nine)
        XCTAssertEqual(tuesdays.nextRun(after: date(2026, 10, 27, 9, 0, in: cal), calendar: cal), date(2026, 11, 3, 9, 0, in: cal))
        XCTAssertNil(TaskSchedule.weekly([], nine).nextRun(after: date(2026, 10, 27, 9, 0, in: cal), calendar: cal))
    }

    func testIntervalsCountElapsedTimeAndRespectTheirFloors() {
        let cal = calendar("Asia/Shanghai")
        let start = date(2026, 10, 27, 10, 17, in: cal)
        XCTAssertEqual(TaskSchedule.everyHours(3).nextRun(after: start, calendar: cal), start.addingTimeInterval(3 * 3600))
        XCTAssertEqual(TaskSchedule.everyMinutes(5).nextRun(after: start, calendar: cal), start.addingTimeInterval(300))
        XCTAssertNil(TaskSchedule.everyMinutes(4).nextRun(after: start, calendar: cal))
        XCTAssertNil(TaskSchedule.everyHours(0).nextRun(after: start, calendar: cal))
        XCTAssertEqual(TaskSchedule.everyMinutes(4).validationError(now: start), "间隔至少 5 分钟")
        XCTAssertNil(TaskSchedule.everyMinutes(5).validationError(now: start))
        XCTAssertEqual(TaskSchedule.everyHours(0).validationError(now: start), "间隔至少 1 小时")
    }

    func testOnceRunsOnlyWhileItsMomentIsAhead() {
        let cal = calendar("Asia/Shanghai")
        let moment = date(2026, 10, 28, 9, 0, in: cal)
        XCTAssertEqual(TaskSchedule.once(moment).nextRun(after: moment.addingTimeInterval(-1), calendar: cal), moment)
        XCTAssertNil(TaskSchedule.once(moment).nextRun(after: moment, calendar: cal))
        XCTAssertNil(TaskSchedule.once(moment).nextRun(after: moment.addingTimeInterval(3600), calendar: cal))
        XCTAssertEqual(TaskSchedule.once(moment).validationError(now: moment), "时间已过，请选一个将来的时间")
        XCTAssertNil(TaskSchedule.once(moment).validationError(now: moment.addingTimeInterval(-60)))
    }

    func testSpringForwardRunsASkippedTimeWhenTheGapEnds() {
        let ny = calendar("America/New_York")
        // 2026-03-08: 02:00 EST jumps to 03:00 EDT; 02:30 never happens.
        let early = date(2026, 3, 8, 0, 0, in: ny)
        let run = TaskSchedule.daily(TimeOfDay(hour: 2, minute: 30)).nextRun(after: early, calendar: ny)
        XCTAssertEqual(run, utc(2026, 3, 8, 7, 0), "03:00 EDT, the first moment after the gap")
        // The day after, 02:30 exists again (EDT).
        XCTAssertEqual(TaskSchedule.daily(TimeOfDay(hour: 2, minute: 30)).nextRun(after: run!, calendar: ny), utc(2026, 3, 9, 6, 30))
        // 09:00 stays 09:00 on the wall clock across the change.
        let saturdayNine = utc(2026, 3, 7, 14, 0) // 09:00 EST
        XCTAssertEqual(TaskSchedule.daily(nine).nextRun(after: saturdayNine, calendar: ny), utc(2026, 3, 8, 13, 0)) // 09:00 EDT
    }

    func testFallBackRunsARepeatedTimeOnlyOnce() {
        let ny = calendar("America/New_York")
        // 2026-11-01: 02:00 EDT falls back to 01:00 EST; 01:30 shows twice.
        let schedule = TaskSchedule.daily(TimeOfDay(hour: 1, minute: 30))
        let first = schedule.nextRun(after: date(2026, 11, 1, 0, 0, in: ny), calendar: ny)
        XCTAssertEqual(first, utc(2026, 11, 1, 5, 30), "01:30 EDT, the first showing")
        // After the first showing the next run is tomorrow's, not 01:30 EST an hour later.
        XCTAssertEqual(schedule.nextRun(after: first!, calendar: ny), utc(2026, 11, 2, 6, 30))
        // Even from inside the repeated hour (01:10 EST), today's slot has passed.
        XCTAssertEqual(schedule.nextRun(after: utc(2026, 11, 1, 6, 10), calendar: ny), utc(2026, 11, 2, 6, 30))
        // Intervals count real time through the change.
        XCTAssertEqual(TaskSchedule.everyHours(1).nextRun(after: first!, calendar: ny), utc(2026, 11, 1, 6, 30))
    }

    func testSummariesMirrorTheOfficialWording() {
        let cal = calendar("Asia/Shanghai")
        let now = date(2026, 10, 27, 12, 0, in: cal)
        XCTAssertEqual(TaskSchedule.daily(nine).summary(now: now, calendar: cal), "每天 09:00")
        XCTAssertEqual(TaskSchedule.weekdays(nine).summary(now: now, calendar: cal), "工作日 09:00")
        XCTAssertEqual(TaskSchedule.weekends(TimeOfDay(hour: 21, minute: 5)).summary(now: now, calendar: cal), "周末 21:05")
        XCTAssertEqual(TaskSchedule.weekly([.wednesday, .monday], nine).summary(now: now, calendar: cal), "周一、周三 09:00")
        XCTAssertEqual(TaskSchedule.weekly([.sunday, .saturday, .friday], nine).summary(now: now, calendar: cal), "周五、周六、周日 09:00")
        XCTAssertEqual(TaskSchedule.weekly([.friday], nine).summary(now: now, calendar: cal), "每周五 09:00")
        XCTAssertEqual(TaskSchedule.weekly(Weekday.workdays, nine).summary(now: now, calendar: cal), "工作日 09:00")
        XCTAssertEqual(TaskSchedule.weekly(Set(Weekday.allCases), nine).summary(now: now, calendar: cal), "每天 09:00")
        XCTAssertEqual(TaskSchedule.everyHours(3).summary(now: now, calendar: cal), "每 3 小时")
        XCTAssertEqual(TaskSchedule.everyHours(1).summary(now: now, calendar: cal), "每小时")
        XCTAssertEqual(TaskSchedule.everyMinutes(15).summary(now: now, calendar: cal), "每 15 分钟")
        XCTAssertEqual(TaskSchedule.once(date(2026, 10, 28, 9, 0, in: cal)).summary(now: now, calendar: cal), "一次 · 10月28日 09:00")
        XCTAssertEqual(TaskSchedule.once(date(2027, 1, 3, 7, 5, in: cal)).summary(now: now, calendar: cal), "一次 · 2027年1月3日 07:05")
    }

    func testRelativeNextRunLabels() {
        let cal = calendar("Asia/Shanghai")
        let now = date(2026, 10, 27, 12, 0, in: cal) // Tuesday
        XCTAssertEqual(TaskSchedule.nextRunLabel(nil, now: now, calendar: cal), "未安排")
        XCTAssertEqual(TaskSchedule.nextRunLabel(date(2026, 10, 27, 18, 30, in: cal), now: now, calendar: cal), "今天 18:30")
        XCTAssertEqual(TaskSchedule.nextRunLabel(date(2026, 10, 28, 0, 0, in: cal), now: now, calendar: cal), "明天 00:00")
        XCTAssertEqual(TaskSchedule.nextRunLabel(date(2026, 10, 29, 9, 0, in: cal), now: now, calendar: cal), "周四 09:00")
        XCTAssertEqual(TaskSchedule.nextRunLabel(date(2026, 11, 2, 9, 0, in: cal), now: now, calendar: cal), "周一 09:00")
        // A week or more ahead, or behind, gets the date.
        XCTAssertEqual(TaskSchedule.nextRunLabel(date(2026, 11, 3, 9, 0, in: cal), now: now, calendar: cal), "11月3日 09:00")
        XCTAssertEqual(TaskSchedule.nextRunLabel(date(2026, 10, 26, 9, 0, in: cal), now: now, calendar: cal), "10月26日 09:00")
        XCTAssertEqual(TaskSchedule.nextRunLabel(date(2027, 1, 3, 9, 0, in: cal), now: now, calendar: cal), "2027年1月3日 09:00")
        // Days are calendar days in the zone, not 24-hour spans.
        XCTAssertEqual(TaskSchedule.nextRunLabel(date(2026, 10, 28, 0, 1, in: cal), now: date(2026, 10, 27, 23, 59, in: cal), calendar: cal), "明天 00:01")
    }

    func testCodingRoundTripsEveryKind() throws {
        let schedules: [TaskSchedule] = [
            .once(Date(timeIntervalSince1970: 1_800_000_000)),
            .daily(nine),
            .weekdays(TimeOfDay(hour: 7, minute: 45)),
            .weekends(nine),
            .weekly([.monday, .sunday], TimeOfDay(hour: 23, minute: 59)),
            .everyHours(6),
            .everyMinutes(15),
        ]
        for schedule in schedules {
            let data = try JSONEncoder().encode(schedule)
            XCTAssertEqual(try JSONDecoder().decode(TaskSchedule.self, from: data), schedule)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(TaskSchedule.self, from: Data(#"{"kind":"monthly"}"#.utf8)))
    }
}
