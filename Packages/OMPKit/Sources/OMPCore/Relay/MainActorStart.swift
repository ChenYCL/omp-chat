import Foundation

/// Runs work on the main actor only if it can start within a deadline.
///
/// The relay's automation routes read and change UI state, so they run on the
/// main actor. When the main thread is stuck (once it stayed inside a SwiftUI
/// update for minutes) those requests used to wait forever while the other
/// routes still answered, and a script could not even tell why. With this, the
/// request gives up after `seconds` and says the main thread is busy.
///
/// Work that has not started by then is abandoned for good: when the main
/// actor frees up it returns without running, so a timed-out `send` or
/// `approve` can never land minutes later. Work that did start is never cut
/// short, however long it takes.
public enum MainActorStart {
    public enum Outcome<Value: Sendable & Equatable>: Sendable, Equatable {
        case done(Value)
        case busy
    }


    public static func run<Value: Sendable & Equatable>(
        startWithin seconds: Double,
        _ work: @escaping @MainActor @Sendable () async -> Value
    ) async -> Outcome<Value> {
        let gate = Gate()
        return await withCheckedContinuation { continuation in
            let reply = ResumeOnce(continuation)
            // Unstructured on purpose: a task group would wait for the main
            // actor child before returning, which is exactly what must not
            // block the caller.
            Task { @MainActor in
                guard gate.start() else { return }
                reply.resume(.done(await work()))
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.abandon() { reply.resume(.busy) }
            }
        }
    }

    /// Decides once between starting and abandoning.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var state = 0 // 0 pending, 1 started, 2 abandoned

        func start() -> Bool { settle(as: 1) }
        func abandon() -> Bool { settle(as: 2) }

        private func settle(as next: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state == 0 else { return false }
            state = next
            return true
        }
    }

    private final class ResumeOnce<Value: Sendable & Equatable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome<Value>, Never>?

        init(_ continuation: CheckedContinuation<Outcome<Value>, Never>) {
            self.continuation = continuation
        }

        func resume(_ outcome: Outcome<Value>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }
}
