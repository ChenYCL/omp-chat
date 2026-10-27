import Foundation

/// Decides, from the last time the main thread answered, when it counts as
/// stuck and when it is back. One `.stalled` per episode, then one
/// `.recovered` with how long it lasted; nothing in between, so a minute-long
/// hang is two log lines, not sixty.
public struct MainThreadStallTracker: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// No answer for `seconds`; the episode began at `since`.
        case stalled(since: Date, seconds: TimeInterval)
        case recovered(seconds: TimeInterval)
    }

    public let threshold: TimeInterval
    /// Start of the episode being reported, while one is open.
    public private(set) var stalledSince: Date?

    public init(threshold: TimeInterval = 5) {
        self.threshold = threshold
    }

    /// `lastAnswer` is when the main thread last ran a ping.
    public mutating func check(now: Date, lastAnswer: Date) -> Event? {
        let silence = now.timeIntervalSince(lastAnswer)
        if let since = stalledSince {
            // A ping that ran after the episode began ends it.
            guard lastAnswer > since else { return nil }
            stalledSince = nil
            return .recovered(seconds: lastAnswer.timeIntervalSince(since))
        }
        guard silence >= threshold else { return nil }
        stalledSince = lastAnswer
        return .stalled(since: lastAnswer, seconds: silence)
    }
}
