import Foundation
import OMPCore

/// Pings the main thread once a second from a background queue and writes a
/// diagnostics event when it stops answering for 5 seconds, then another when
/// it answers again.
///
/// The app cannot sample itself (the sandbox refuses `task_for_pid` even for
/// its own process, measured 2026-10-27), so the stack has to come from
/// outside; these events give the time window to look at, next to the stream
/// and relay events already in the log.
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "omp.main-thread-watchdog", qos: .utility)
    private let lock = NSLock()
    private var lastAnswer = Date()
    private var tracker = MainThreadStallTracker()
    private var timer: DispatchSourceTimer?

    /// Idempotent.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        lastAnswer = Date()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func tick() {
        lock.lock()
        let event = tracker.check(now: Date(), lastAnswer: lastAnswer)
        lock.unlock()
        switch event {
        case .stalled(let since, let seconds)?:
            DiagnosticsCenter.shared.record("watchdog", .warn, "main thread unresponsive",
                fields: ["since": ISO8601DateFormatter().string(from: since), "seconds": String(Int(seconds))])
        case .recovered(let seconds)?:
            DiagnosticsCenter.shared.record("watchdog", .warn, "main thread answered again",
                fields: ["stalledSeconds": String(Int(seconds))])
        case nil:
            break
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.lastAnswer = Date()
            self.lock.unlock()
        }
    }
}
