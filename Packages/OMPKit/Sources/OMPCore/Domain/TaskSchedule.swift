import Foundation

/// A day of the week, numbered like `Calendar`'s `.weekday` (1 = Sunday).
public enum Weekday: Int, Codable, CaseIterable, Comparable, Sendable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    /// Monday first: the order Chinese calendars, summaries and the editor use.
    public static let mondayFirst: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    public static let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: Set<Weekday> = [.saturday, .sunday]

    /// 「周一」…「周日」.
    public var shortTitle: String {
        "周" + ["日", "一", "二", "三", "四", "五", "六"][rawValue - 1]
    }

    /// Orders Monday first, Sunday last.
    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.mondayFirstIndex < rhs.mondayFirstIndex
    }

    private var mondayFirstIndex: Int { (rawValue + 5) % 7 }
}

/// A wall-clock time of day, minute precision.
public struct TimeOfDay: Codable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }

    /// 「09:00」.
    public var label: String { TaskSchedule.twoDigits(hour) + ":" + TaskSchedule.twoDigits(minute) }
}

/// When a scheduled task runs (Codex `settings.automations.scheduleSummary.*`).
///
/// Calendar kinds are local wall-clock times: 「每天 09:00」 means 09:00 on the
/// clock of the time zone `nextRun` is given, so a summer and a winter run
/// both start at 09:00. Interval kinds count elapsed time from the moment
/// they are measured from, so a DST shift neither shortens nor stretches them.
public enum TaskSchedule: Hashable, Sendable {
    case once(Date)
    case daily(TimeOfDay)
    case weekdays(TimeOfDay)
    case weekends(TimeOfDay)
    case weekly(Set<Weekday>, TimeOfDay)
    case everyHours(Int)
    case everyMinutes(Int)

    /// The shortest interval. Every run is a whole agent reply, which often
    /// takes minutes and costs tokens: below five minutes the next slot would
    /// routinely arrive while the previous reply is still streaming (and be
    /// skipped), so a shorter interval would promise runs it cannot deliver.
    public static let minimumMinutes = 5

    /// The editor's kinds, in menu order.
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case once, daily, weekdays, weekends, weekly, everyHours, everyMinutes

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .once: "一次"
            case .daily: "每天"
            case .weekdays: "工作日"
            case .weekends: "周末"
            case .weekly: "每周"
            case .everyHours: "每 N 小时"
            case .everyMinutes: "每 N 分钟"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .once: .once
        case .daily: .daily
        case .weekdays: .weekdays
        case .weekends: .weekends
        case .weekly: .weekly
        case .everyHours: .everyHours
        case .everyMinutes: .everyMinutes
        }
    }

    /// The first slot strictly after `date`, or nil when there is none (a
    /// one-time schedule whose moment has passed, or an invalid schedule).
    ///
    /// Wall-clock slots are resolved per calendar day in `calendar`'s time
    /// zone. A time the clock skips (spring forward: 02:30 in New York in
    /// March) runs at the first moment after the gap; a time the clock shows
    /// twice (fall back: 01:30 in November) runs only at its first showing, so
    /// a daily task never runs twice on one day.
    public func nextRun(after date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .once(let moment):
            return moment > date ? moment : nil
        case .daily(let time):
            return Self.nextSlot(after: date, at: time, on: Set(Weekday.allCases), calendar: calendar)
        case .weekdays(let time):
            return Self.nextSlot(after: date, at: time, on: Weekday.workdays, calendar: calendar)
        case .weekends(let time):
            return Self.nextSlot(after: date, at: time, on: Weekday.weekend, calendar: calendar)
        case .weekly(let days, let time):
            return Self.nextSlot(after: date, at: time, on: days, calendar: calendar)
        case .everyHours(let hours):
            guard hours >= 1 else { return nil }
            return date.addingTimeInterval(TimeInterval(hours) * 3600)
        case .everyMinutes(let minutes):
            guard minutes >= Self.minimumMinutes else { return nil }
            return date.addingTimeInterval(TimeInterval(minutes) * 60)
        }
    }

    /// Why this schedule cannot be saved, or nil. `now` is only consulted for
    /// a one-time schedule, which must lie in the future.
    public func validationError(now: Date) -> String? {
        switch self {
        case .once(let moment):
            return moment > now ? nil : "时间已过，请选一个将来的时间"
        case .daily(let time), .weekdays(let time), .weekends(let time):
            return time.isValid ? nil : "时间无效"
        case .weekly(let days, let time):
            if days.isEmpty { return "至少选一天" }
            return time.isValid ? nil : "时间无效"
        case .everyHours(let hours):
            return hours >= 1 ? nil : "间隔至少 1 小时"
        case .everyMinutes(let minutes):
            return minutes >= Self.minimumMinutes ? nil : "间隔至少 \(Self.minimumMinutes) 分钟"
        }
    }

    /// 「每天 09:00」「工作日 09:00」「周一、周三 09:00」「每 3 小时」「一次 · 10月28日 09:00」.
    /// `now` only decides whether a one-time date needs its year.
    public func summary(now: Date, calendar: Calendar) -> String {
        switch self {
        case .once(let moment):
            return "一次 · " + Self.dateLabel(moment, now: now, calendar: calendar)
        case .daily(let time):
            return "每天 \(time.label)"
        case .weekdays(let time):
            return "工作日 \(time.label)"
        case .weekends(let time):
            return "周末 \(time.label)"
        case .weekly(let days, let time):
            if days.count == Weekday.allCases.count { return "每天 \(time.label)" }
            if days == Weekday.workdays { return "工作日 \(time.label)" }
            if days == Weekday.weekend { return "周末 \(time.label)" }
            if days.isEmpty { return "未选日期" }
            let sorted = days.sorted()
            if sorted.count == 1 { return "每\(sorted[0].shortTitle) \(time.label)" }
            return sorted.map(\.shortTitle).joined(separator: "、") + " " + time.label
        case .everyHours(let hours):
            return hours == 1 ? "每小时" : "每 \(hours) 小时"
        case .everyMinutes(let minutes):
            return "每 \(minutes) 分钟"
        }
    }

    /// The relative next-run label (Codex `inbox.automations.relativeDate.*`):
    /// 「今天 09:00」「明天 09:00」「周三 09:00」 within the coming week, else
    /// 「10月30日 09:00」, and 「未安排」 for no date.
    public static func nextRunLabel(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "未安排" }
        let time = timeLabel(date, calendar: calendar)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? Int.max
        switch days {
        case 0:
            return "今天 \(time)"
        case 1:
            return "明天 \(time)"
        case 2...6:
            let weekday = Weekday(rawValue: calendar.component(.weekday, from: date)) ?? .monday
            return "\(weekday.shortTitle) \(time)"
        default:
            return dateLabel(date, now: now, calendar: calendar)
        }
    }

    /// 「10月28日 09:00」, with the year when it is not `now`'s.
    public static func dateLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let prefix = year == calendar.component(.year, from: now) ? "" : "\(year)年"
        return "\(prefix)\(parts.month ?? 0)月\(parts.day ?? 0)日 " + timeLabel(date, calendar: calendar)
    }

    static func timeLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return twoDigits(parts.hour ?? 0) + ":" + twoDigits(parts.minute ?? 0)
    }

    static func twoDigits(_ value: Int) -> String {
        value < 10 && value >= 0 ? "0\(value)" : "\(value)"
    }

    // MARK: Wall-clock slots

    /// The first `time` on an allowed weekday strictly after `date`. Eight
    /// days cover the rest of today plus a whole week, which holds a slot for
    /// any non-empty weekday set; the loop is bounded by that range.
    private static func nextSlot(after date: Date, at time: TimeOfDay, on days: Set<Weekday>, calendar: Calendar) -> Date? {
        guard !days.isEmpty, time.isValid else { return nil }
        let today = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let shifted = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let dayStart = calendar.startOfDay(for: shifted)
            guard let weekday = Weekday(rawValue: calendar.component(.weekday, from: dayStart)),
                  days.contains(weekday),
                  let slot = firstShowing(of: time, onDayStarting: dayStart, calendar: calendar) else { continue }
            if slot > date { return slot }
        }
        return nil
    }

    /// The first moment the wall clock shows `time` on the day starting at
    /// `dayStart`. Searching forward from just before the day starts finds
    /// the first showing of a repeated time; `.nextTime` moves a skipped time
    /// to the end of the gap.
    private static func firstShowing(of time: TimeOfDay, onDayStarting dayStart: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(
            after: dayStart.addingTimeInterval(-1),
            matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

// MARK: - Coding

extension TaskSchedule: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, date, hour, minute, weekdays, interval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown schedule kind \(raw)")
        }
        func time() throws -> TimeOfDay {
            TimeOfDay(
                hour: try container.decodeIfPresent(Int.self, forKey: .hour) ?? 9,
                minute: try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
            )
        }
        func interval() throws -> Int {
            try container.decode(Int.self, forKey: .interval)
        }
        switch kind {
        case .once:
            self = .once(try container.decode(Date.self, forKey: .date))
        case .daily:
            self = .daily(try time())
        case .weekdays:
            self = .weekdays(try time())
        case .weekends:
            self = .weekends(try time())
        case .weekly:
            let days = try container.decodeIfPresent([Int].self, forKey: .weekdays) ?? []
            self = .weekly(Set(days.compactMap(Weekday.init(rawValue:))), try time())
        case .everyHours:
            self = .everyHours(try interval())
        case .everyMinutes:
            self = .everyMinutes(try interval())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .once(let date):
            try container.encode(date, forKey: .date)
        case .daily(let time), .weekdays(let time), .weekends(let time):
            try container.encode(time.hour, forKey: .hour)
            try container.encode(time.minute, forKey: .minute)
        case .weekly(let days, let time):
            try container.encode(days.map(\.rawValue).sorted(), forKey: .weekdays)
            try container.encode(time.hour, forKey: .hour)
            try container.encode(time.minute, forKey: .minute)
        case .everyHours(let value), .everyMinutes(let value):
            try container.encode(value, forKey: .interval)
        }
    }
}
