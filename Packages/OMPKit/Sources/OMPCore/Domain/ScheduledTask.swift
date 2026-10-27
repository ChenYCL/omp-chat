import Foundation

/// A prompt OMPChat sends on a schedule while it runs on the Mac (Codex
/// scheduled tasks, `inbox.mode.automations`).
///
/// The bookkeeping rules live here so they can be tested without a clock:
/// a due task runs once however many slots it missed, the next slot is the
/// first one after the run, and a slot is consumed by the run or skip that
/// takes it, so it can never run twice.
public struct ScheduledTask: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case active, paused, completed

        /// Codex `inbox.automations.status.*`.
        public var title: String {
            switch self {
            case .active: "已启用"
            case .paused: "已暂停"
            case .completed: "已完成"
            }
        }
    }

    /// Where each run's reply goes.
    public enum Target: Hashable, Sendable {
        /// Every run starts a conversation titled with the task and run time.
        case newThread
        /// Every run sends the prompt into this conversation (Codex heartbeat).
        case attached(UUID)
    }

    public var id: UUID
    public var title: String
    public var prompt: String
    public var schedule: TaskSchedule
    public var target: Target
    /// Folder the run's conversation works in; nil leaves it unbound (a new
    /// thread) or unchanged (an attached one).
    public var workingDirectory: String?
    /// Project a new thread is filed under; attached runs ignore it.
    public var projectID: UUID?
    /// `PermissionMode` raw value; nil follows the conversation or the default.
    public var permissionMode: String?
    public var status: Status
    public var createdAt: Date
    public var lastRunAt: Date?
    /// The slot the scheduler waits for; nil when paused, completed or
    /// when the schedule has no slot left.
    public var nextRunAt: Date?
    public var runCount: Int
    public var lastRunConversationID: UUID?
    /// When the last slot was skipped instead of run, and why; cleared by
    /// the next run that goes through.
    public var lastSkippedAt: Date?
    public var lastSkipReason: String?

    /// Codex `inbox.automations.status.expiredResume`.
    public static let expiredResumeMessage = "这个任务的计划时间已过。先编辑它、选一个将来的时间，再继续。"

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        schedule: TaskSchedule,
        target: Target = .newThread,
        workingDirectory: String? = nil,
        projectID: UUID? = nil,
        permissionMode: String? = nil,
        status: Status = .active,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        runCount: Int = 0,
        lastRunConversationID: UUID? = nil,
        lastSkippedAt: Date? = nil,
        lastSkipReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.schedule = schedule
        self.target = target
        self.workingDirectory = workingDirectory
        self.projectID = projectID
        self.permissionMode = permissionMode
        self.status = status
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.runCount = runCount
        self.lastRunConversationID = lastRunConversationID
        self.lastSkippedAt = lastSkippedAt
        self.lastSkipReason = lastSkipReason
    }

    // MARK: Policy

    /// Whether the scheduler should run this task at `now`: it is active and
    /// its slot has arrived, however long ago.
    public func isDue(at now: Date) -> Bool {
        guard status == .active, let nextRunAt else { return false }
        return nextRunAt <= now
    }

    /// A new task: active with its first slot after `now`.
    public mutating func activate(now: Date, calendar: Calendar) {
        status = .active
        nextRunAt = schedule.nextRun(after: now, calendar: calendar)
    }

    /// Books a run that started at `now` in `conversationID`. A run at a due
    /// slot consumes it, and every slot missed while the app was closed or
    /// the Mac slept goes with it: the next slot is the first after `now`. A
    /// one-time task is then completed. A manual run before the slot leaves
    /// the schedule alone.
    public mutating func recordRun(at now: Date, conversationID: UUID, calendar: Calendar) {
        let consumesSlot = isDue(at: now)
        lastRunAt = now
        runCount += 1
        lastRunConversationID = conversationID
        lastSkippedAt = nil
        lastSkipReason = nil
        if consumesSlot { advance(after: now, calendar: calendar) }
    }

    /// Books a due slot that could not run. The slot is consumed like a run
    /// so it is not retried in a loop. A one-time task has no other slot, so
    /// it is paused rather than called completed though it never ran.
    public mutating func recordSkip(at now: Date, reason: String, calendar: Calendar) {
        guard isDue(at: now) else { return }
        lastSkippedAt = now
        lastSkipReason = reason
        if case .once = schedule {
            status = .paused
            nextRunAt = nil
        } else {
            nextRunAt = schedule.nextRun(after: now, calendar: calendar)
        }
    }

    public mutating func pause() {
        guard status == .active else { return }
        status = .paused
        nextRunAt = nil
    }

    /// Resumes a paused (or completed) task from its next slot after `now`.
    /// Returns why it cannot: a one-time task whose time has passed needs a
    /// new time first (Codex `expiredResume`).
    public mutating func resume(now: Date, calendar: Calendar) -> String? {
        guard status != .active else { return nil }
        guard let next = schedule.nextRun(after: now, calendar: calendar) else {
            if case .once = schedule { return Self.expiredResumeMessage }
            return schedule.validationError(now: now) ?? "这个计划没有下一次运行时间"
        }
        status = .active
        nextRunAt = next
        return nil
    }

    /// Applies the editor's fields to this task, keeping its run history. A
    /// changed schedule gets a fresh slot after `now`; an unchanged one keeps
    /// its slot, so saving a title edit never drops a due catch-up run. A
    /// completed task given a new schedule becomes active again; a paused one
    /// stays paused until resumed.
    public mutating func applyEdit(_ edited: ScheduledTask, now: Date, calendar: Calendar) {
        let scheduleChanged = edited.schedule != schedule
        title = edited.title
        prompt = edited.prompt
        target = edited.target
        workingDirectory = edited.workingDirectory
        projectID = edited.projectID
        permissionMode = edited.permissionMode
        schedule = edited.schedule
        guard scheduleChanged else { return }
        switch status {
        case .active:
            nextRunAt = schedule.nextRun(after: now, calendar: calendar)
        case .completed:
            if let next = schedule.nextRun(after: now, calendar: calendar) {
                status = .active
                nextRunAt = next
            }
        case .paused:
            nextRunAt = nil
        }
    }

    /// Field-by-field reasons the editor cannot save `self`. `previous` is
    /// the stored task when editing: a one-time schedule left unchanged on a
    /// task that is no longer active may keep its past date, so a finished
    /// task can still be renamed.
    public func validationErrors(now: Date, previous: ScheduledTask? = nil) -> [Field: String] {
        var errors: [Field: String] = [:]
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[.title] = "请填写标题" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[.prompt] = "请填写提示词" }
        let keepsPastOnce = previous.map { $0.schedule == schedule && $0.status != .active } ?? false
        if !keepsPastOnce, let message = schedule.validationError(now: now) { errors[.schedule] = message }
        if let directory = workingDirectory, directory.trimmingCharacters(in: .whitespaces).isEmpty {
            errors[.workingDirectory] = "工作目录为空"
        }
        return errors
    }

    public enum Field: Hashable, Sendable {
        case title, prompt, schedule, workingDirectory
    }

    /// Where the next run goes. An attached task whose conversation no longer
    /// exists falls back to a new thread instead of failing every slot.
    public func resolvedTarget(conversationExists: (UUID) -> Bool) -> Target {
        if case .attached(let id) = target, !conversationExists(id) { return .newThread }
        return target
    }

    /// Title of a new thread a run at `date` starts: 「日报 · 10月28日 09:00」.
    public func runTitle(at date: Date, calendar: Calendar) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "定时任务" : name) + " · " + TaskSchedule.dateLabel(date, now: date, calendar: calendar)
    }

    /// After a time-zone change, a wall-clock slot still ahead is found again
    /// in `calendar`'s (new) zone. A due slot stays due, and one-time moments
    /// and intervals are absolute, so they keep theirs.
    public mutating func followTimeZoneChange(now: Date, calendar: Calendar) {
        guard status == .active, let next = nextRunAt, next > now else { return }
        switch schedule {
        case .once, .everyHours, .everyMinutes:
            return
        case .daily, .weekdays, .weekends, .weekly:
            nextRunAt = schedule.nextRun(after: now, calendar: calendar)
        }
    }

    private mutating func advance(after now: Date, calendar: Calendar) {
        if case .once = schedule {
            status = .completed
            nextRunAt = nil
        } else {
            nextRunAt = schedule.nextRun(after: now, calendar: calendar)
        }
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case id, title, prompt, schedule, target, workingDirectory, projectID, permissionMode, status
        case createdAt, lastRunAt, nextRunAt, runCount, lastRunConversationID, lastSkippedAt, lastSkipReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        schedule = try container.decode(TaskSchedule.self, forKey: .schedule)
        target = try container.decodeIfPresent(Target.self, forKey: .target) ?? .newThread
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .paused
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        nextRunAt = try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
        runCount = try container.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        lastRunConversationID = try container.decodeIfPresent(UUID.self, forKey: .lastRunConversationID)
        lastSkippedAt = try container.decodeIfPresent(Date.self, forKey: .lastSkippedAt)
        lastSkipReason = try container.decodeIfPresent(String.self, forKey: .lastSkipReason)
    }

    /// Decodes a document's task list one task at a time, dropping any that
    /// cannot be read so one damaged task never stops the workspace opening.
    public static func decodeList<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>, forKey key: Key
    ) throws -> [ScheduledTask] {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return [] }
        var list = try container.nestedUnkeyedContainer(forKey: key)
        var tasks: [ScheduledTask] = []
        while !list.isAtEnd {
            // `decodeNil` moves past a null; the other two past anything else.
            if try list.decodeNil() { continue }
            if let task = try? list.decode(ScheduledTask.self) {
                tasks.append(task)
            } else if (try? list.decode(Skipped.self)) == nil {
                // Neither decode moved past the element; stop rather than spin.
                break
            }
        }
        return tasks
    }

    /// Consumes one element of any shape.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension ScheduledTask.Target: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, conversationID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "attached":
            self = .attached(try container.decode(UUID.self, forKey: .conversationID))
        default:
            self = .newThread
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .newThread:
            try container.encode("newThread", forKey: .kind)
        case .attached(let id):
            try container.encode("attached", forKey: .kind)
            try container.encode(id, forKey: .conversationID)
        }
    }
}
