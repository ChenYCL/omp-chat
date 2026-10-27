import Foundation
import OMPCore
#if os(macOS)
import AppKit
#endif

/// What one attempt to run a scheduled task did.
public enum ScheduledRunOutcome: Equatable, Sendable {
    /// The prompt was sent; the reply streams in this conversation.
    case started(conversationID: UUID)
    /// The slot was consumed without a run, for this reason.
    case skipped(String)
    /// Another conversation's reply holds the app (one reply streams at a
    /// time); the slot stays due and is retried.
    case waiting
    /// A manual run could not start, for this reason. Nothing was booked.
    case failed(String)
    /// The task is not due at that moment.
    case notDue
}

/// Fires due scheduled tasks while OMPChat runs on the Mac.
///
/// One timer waits for the earliest `nextRunAt` of an active task. It is
/// re-armed after every task change, when the Mac wakes and when the clock
/// or time zone changes; whatever came due in the meantime runs once. On
/// iOS `start()` does nothing: tasks run on the Mac.
@MainActor
public final class ScheduledTaskScheduler {
    /// How long a due run waits before looking again while another
    /// conversation's reply streams: starting would cut that reply off.
    static let busyRetry: TimeInterval = 15
    /// The longest single wait, so a missed wake or clock notification costs
    /// at most this much lateness.
    static let longestWait: TimeInterval = 15 * 60

    private weak var model: ChatAppModel?
    private var timer: Task<Void, Never>?
    #if os(macOS)
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    #endif
    public private(set) var isStarted = false
    /// True while `runDue` works through the due tasks; re-arming waits for it.
    private var isRunning = false
    /// Set when the last pass left a due task waiting for another reply.
    private var waitingForReply = false

    init(model: ChatAppModel) {
        self.model = model
    }

    /// Starts the timer and the wake / clock observers. Later calls do nothing.
    public func start() {
        #if os(macOS)
        guard !isStarted else { return }
        isStarted = true
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.rearm() }
        observe(.default, .NSSystemClockDidChange) { $0.rearm() }
        observe(.default, .NSSystemTimeZoneDidChange) { scheduler in
            // Rescheduling saves the tasks, which re-arms the timer.
            scheduler.model?.rescheduleScheduledTasksForTimeZoneChange()
        }
        rearm()
        #endif
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        #if os(macOS)
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
        #endif
        isStarted = false
    }

    /// Points the timer at the earliest slot. The model calls this after
    /// every change to its tasks; a pass in progress re-arms when it ends.
    func rearm() {
        guard isStarted, !isRunning, let model else { return }
        timer?.cancel()
        timer = nil
        let slots = model.scheduledTasks.compactMap { $0.status == .active ? $0.nextRunAt : nil }
        guard let next = slots.min() else { return }
        var delay = min(max(0, next.timeIntervalSinceNow), Self.longestWait)
        if waitingForReply { delay = max(delay, Self.busyRetry) }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    private func fire() async {
        await runDue(now: Date())
        rearm()
    }

    /// Runs every task due at `now`, earliest slot first: the timer's entry
    /// point. A run that has to wait for another conversation's reply stops
    /// the pass; the remaining tasks stay due for the retry.
    @discardableResult
    public func runDue(now: Date) async -> [UUID: ScheduledRunOutcome] {
        guard !isRunning, let model else { return [:] }
        isRunning = true
        defer { isRunning = false }
        waitingForReply = false
        let due = model.scheduledTasks
            .filter { $0.isDue(at: now) }
            .sorted { ($0.nextRunAt ?? now) < ($1.nextRunAt ?? now) }
        var outcomes: [UUID: ScheduledRunOutcome] = [:]
        for task in due {
            let outcome = await model.startScheduledRun(task.id, now: now)
            outcomes[task.id] = outcome
            if outcome == .waiting {
                waitingForReply = true
                break
            }
        }
        return outcomes
    }

    #if os(macOS)
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (ScheduledTaskScheduler) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
    #endif
}
