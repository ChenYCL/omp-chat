import XCTest
@testable import OMPCore

/// The relay's automation hooks give up when the main actor cannot start them.
/// A wrong decision here means a hung UI eats requests forever, or a timed-out
/// `send` lands minutes after its caller gave up.
final class MainActorStartTests: XCTestCase {
    func testAFreeMainActorRunsTheWork() async {
        let outcome = await MainActorStart.run(startWithin: 2) { 41 + 1 }
        XCTAssertEqual(outcome, .done(42))
    }

    func testLongWorkThatStartedIsNotCutShort() async {
        let start = Date()
        let outcome = await MainActorStart.run(startWithin: 0.05) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return "late but complete"
        }
        XCTAssertEqual(outcome, .done("late but complete"))
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.14)
    }

    func testABlockedMainActorAnswersBusyAndNeverRunsTheWork() async {
        // Occupy the main actor, the way a stuck SwiftUI update does.
        let release = DispatchSemaphore(value: 0)
        let blocker = Task { @MainActor in
            _ = release.wait(timeout: .now() + 3)
        }
        // Let the blocker take the main actor first.
        try? await Task.sleep(nanoseconds: 150_000_000)

        var ran = false
        let outcome = await MainActorStart.run(startWithin: 0.2) {
            ran = true
            return true
        }
        XCTAssertEqual(outcome, .busy)
        // Give a late start every chance to happen before checking.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(ran, "放弃的钩子不能等主线程空出来又跑一遍")

        release.signal()
        await blocker.value
    }

    func testTheDeadlineGivesTheMainActorAFairChance() async {
        // A free main actor but a zero deadline: either outcome is fine, what
        // matters is that nothing hangs and nothing crashes.
        let outcome = await MainActorStart.run(startWithin: 0) { true }
        XCTAssertTrue(outcome == .busy || outcome == .done(true))
    }
}

/// One `.stalled` per episode and one `.recovered`, from the last answered ping.
final class MainThreadStallTrackerTests: XCTestCase {
    private func seconds(_ value: Double) -> TimeInterval { value }

    func testSilenceBeyondTheThresholdOpensAnEpisodeOnce() {
        var tracker = MainThreadStallTracker(threshold: 5)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(tracker.check(now: start.addingTimeInterval(4), lastAnswer: start))
        XCTAssertEqual(tracker.check(now: start.addingTimeInterval(5), lastAnswer: start),
                       .stalled(since: start, seconds: 5))
        XCTAssertNil(tracker.check(now: start.addingTimeInterval(30), lastAnswer: start),
                     "卡住期间不再刷屏")
        XCTAssertNil(tracker.check(now: start.addingTimeInterval(31), lastAnswer: start))
    }

    func testAnAnswerAfterTheEpisodeClosesIt() {
        var tracker = MainThreadStallTracker(threshold: 5)
        let start = Date(timeIntervalSince1970: 1_000)
        _ = tracker.check(now: start.addingTimeInterval(6), lastAnswer: start)
        let answered = start.addingTimeInterval(42)
        XCTAssertEqual(tracker.check(now: answered.addingTimeInterval(1), lastAnswer: answered),
                       .recovered(seconds: 42))
        // Back to normal: nothing until it stalls again.
        XCTAssertNil(tracker.check(now: answered.addingTimeInterval(2), lastAnswer: answered))
        XCTAssertEqual(tracker.check(now: answered.addingTimeInterval(8), lastAnswer: answered),
                       .stalled(since: answered, seconds: 8), "第二次卡住要重新报告")
    }

    func testAnAnswerDuringTheOpeningPingClosesTheEpisodeImmediately() {
        var tracker = MainThreadStallTracker(threshold: 5)
        let start = Date(timeIntervalSince1970: 1_000)
        _ = tracker.check(now: start.addingTimeInterval(6), lastAnswer: start)
        let answered = start.addingTimeInterval(6.5)
        XCTAssertEqual(tracker.check(now: answered.addingTimeInterval(1), lastAnswer: answered),
                       .recovered(seconds: 6.5))
    }
}
