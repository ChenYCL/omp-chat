import SwiftUI
import UniformTypeIdentifiers
import OMPCore
import OMPDesign

public extension Notification.Name {
    /// Opens the scheduled-task editor for a new task (Codex `sidebarElectron.addAutomation`).
    static let ompAddScheduledTask = Notification.Name("omp.addScheduledTask")
    /// Opens the editor for the task whose `UUID` is the notification's object.
    static let ompEditScheduledTask = Notification.Name("omp.editScheduledTask")
}

// MARK: - Sidebar section

/// Sidebar 「定时任务」 (Codex `inbox.mode.automations`): one row per task with
/// its next run or status, a dot while its last run is unread, and the
/// task's actions. Hidden while there are no tasks; 更多 → 添加定时任务…
/// stays available. The editor itself is presented by
/// `scheduledTaskEditorHost()`, outside the lazily built list.
public struct ScheduledTasksSidebarSection: View {
    @Environment(ChatAppModel.self) private var model
    @State private var deleting: ScheduledTask?
    @State private var failure: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.scheduledTasks.isEmpty {
                header
                // Relative labels (今天 / 明天 / 周三) move with the clock.
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(model.scheduledTasks) { task in
                            ScheduledTaskRow(task: task, now: context.date, failure: $failure, deleting: $deleting)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "删除定时任务「\(deleting?.title ?? "")」？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let id = deleting?.id { model.deleteScheduledTask(id) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("任务运行出的对话会保留。")
        }
        .alert("定时任务", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("定时任务")
                .font(.system(size: 11.5, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(Color.ompTextTertiary)
            Spacer(minLength: 0)
            Menu {
                Button("全部标为已读") { model.markScheduledTaskRunsRead() }
                    .accessibilityIdentifier("sidebar.scheduledTasks.markAllRead")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("定时任务选项")
            .accessibilityIdentifier("sidebar.scheduledTasks.menu")
            Button {
                NotificationCenter.default.post(name: .ompAddScheduledTask, object: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ompTextTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("添加定时任务…")
            .accessibilityLabel("添加定时任务")
            .accessibilityIdentifier("sidebar.scheduledTasks.add")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityIdentifier("sidebar.scheduledTasks")
    }
}

/// One task: 32pt like a conversation row, clock icon, title, then the next
/// run (今天 09:00) or status (已暂停 / 已完成 / 正在运行…).
private struct ScheduledTaskRow: View {
    @Environment(ChatAppModel.self) private var model
    let task: ScheduledTask
    let now: Date
    @Binding var failure: String?
    @Binding var deleting: ScheduledTask?
    @State private var hovering = false

    var body: some View {
        let running = model.isScheduledTaskRunning(task.id)
        HStack(spacing: 6) {
            Image(systemName: task.status == .active ? "clock" : (task.status == .paused ? "pause.circle" : "checkmark.circle"))
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
                .frame(width: 14)
            Text(task.title)
                .font(.system(size: 13))
                .foregroundStyle(task.status == .active ? Color.ompText : Color.ompTextSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if task.lastSkipReason != nil {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            if hovering && !running {
                Menu {
                    ScheduledTaskMenu(task: task, failure: $failure, deleting: $deleting)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.ompFill, in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                if running {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(statusLabel(running: running))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
                    .lineLimit(1)
            }
            if lastRunUnread {
                Circle()
                    .fill(Color.ompText)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("有未读结果")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.officialSM, style: .continuous)
                .fill(hovering ? ompGhostHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
        .onTapGesture {
            // A task that has not run yet (or whose run is gone) opens its editor.
            if !model.openScheduledTaskRun(task.id) {
                NotificationCenter.default.post(name: .ompEditScheduledTask, object: task.id)
            }
        }
        .contextMenu { ScheduledTaskMenu(task: task, failure: $failure, deleting: $deleting) }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title)，\(statusLabel(running: running))")
        .accessibilityIdentifier("sidebar.scheduledTask.\(task.id.uuidString)")
    }

    private var lastRunUnread: Bool {
        guard let id = task.lastRunConversationID else { return false }
        return model.conversations.first { $0.id == id }?.hasUnread ?? false
    }

    private func statusLabel(running: Bool) -> String {
        if running { return "正在运行…" }
        switch task.status {
        case .active: return TaskSchedule.nextRunLabel(task.nextRunAt, now: now, calendar: model.scheduleCalendar)
        case .paused, .completed: return task.status.title
        }
    }

    /// Codex `sidebarTaskRow.heartbeatAutomation.nextRun` plus the schedule
    /// and the last skip, if any.
    private var helpText: String {
        let calendar = model.scheduleCalendar
        var lines = [task.schedule.summary(now: now, calendar: calendar)]
        if task.status == .active {
            lines.append("下次运行：" + TaskSchedule.nextRunLabel(task.nextRunAt, now: now, calendar: calendar))
        }
        if let last = task.lastRunAt {
            lines.append("上次运行：" + TaskSchedule.nextRunLabel(last, now: now, calendar: calendar))
        }
        if let reason = task.lastSkipReason {
            lines.append("上次跳过：\(reason)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 编辑… / 立即运行 / 暂停 / 继续 / 删除…, shared by the context menu and
/// the hover ⋯ menu.
private struct ScheduledTaskMenu: View {
    @Environment(ChatAppModel.self) private var model
    let task: ScheduledTask
    @Binding var failure: String?
    @Binding var deleting: ScheduledTask?

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .ompEditScheduledTask, object: task.id)
        } label: {
            Label("编辑…", systemImage: "pencil")
        }
        Button {
            Task {
                if let message = await model.runScheduledTaskNow(task.id) { failure = message }
            }
        } label: {
            Label("立即运行", systemImage: "play")
        }
        switch task.status {
        case .active:
            Button {
                model.pauseScheduledTask(task.id)
            } label: {
                Label("暂停", systemImage: "pause")
            }
        case .paused:
            Button {
                if let message = model.resumeScheduledTask(task.id) { failure = message }
            } label: {
                Label("继续", systemImage: "play.circle")
            }
        case .completed:
            EmptyView()
        }
        Divider()
        Button(role: .destructive) {
            deleting = task
        } label: {
            Label("删除…", systemImage: "trash")
        }
    }
}

// MARK: - Editor host

public extension View {
    /// Presents the scheduled-task editor when `.ompAddScheduledTask` or
    /// `.ompEditScheduledTask` is posted. Attach it outside lazy lists, so
    /// the request is heard wherever the sidebar is scrolled.
    func scheduledTaskEditorHost() -> some View {
        modifier(ScheduledTaskEditorHost())
    }
}

private struct ScheduledTaskEditorHost: ViewModifier {
    @Environment(ChatAppModel.self) private var model
    @State private var request: EditorRequest?

    struct EditorRequest: Identifiable {
        let id = UUID()
        var task: ScheduledTask?
        /// What 「发到当前对话」 means for a new task.
        var currentConversationID: UUID?
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ompAddScheduledTask)) { _ in
                request = EditorRequest(task: nil, currentConversationID: model.selectedConversationID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ompEditScheduledTask)) { note in
                guard let id = note.object as? UUID,
                      let task = model.scheduledTasks.first(where: { $0.id == id }) else { return }
                request = EditorRequest(task: task, currentConversationID: model.selectedConversationID)
            }
            .sheet(item: $request) { request in
                ScheduledTaskEditor(existing: request.task, currentConversationID: request.currentConversationID)
                    .environment(model)
            }
    }
}

// MARK: - Editor

/// Add / edit sheet (Codex `sidebarElectron.addAutomation` / `editAutomation`).
struct ScheduledTaskEditor: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let existing: ScheduledTask?
    let currentConversationID: UUID?

    @State private var title = ""
    @State private var prompt = ""
    @State private var kind: TaskSchedule.Kind = .daily
    @State private var onceDate = Date().addingTimeInterval(3600)
    @State private var time = Date()
    @State private var weekdays: Set<Weekday> = [.monday]
    @State private var hours = 3
    @State private var minutes = 30
    @State private var attach = false
    /// The conversation 「发到当前对话」 sends into.
    @State private var attachID: UUID?
    @State private var projectID: UUID?
    @State private var directory: String?
    /// `PermissionMode` raw value; empty follows the default.
    @State private var permission = ""
    @State private var showErrors = false
    @State private var choosingDirectory = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $title)
                        .accessibilityIdentifier("scheduledTask.editor.title")
                    issue(.title)
                    TextField("每次运行时发送的提示词", text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                        .accessibilityIdentifier("scheduledTask.editor.prompt")
                    issue(.prompt)
                } header: {
                    Text("任务")
                }

                Section {
                    Picker("计划", selection: $kind) {
                        ForEach(TaskSchedule.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("scheduledTask.editor.kind")
                    scheduleControls
                    VStack(alignment: .leading, spacing: 3) {
                        Text(schedule.summary(now: Date(), calendar: calendar))
                            .font(.system(size: 12.5, weight: .medium))
                            .accessibilityIdentifier("scheduledTask.editor.summary")
                        Text(nextRunPreview)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("scheduledTask.editor.nextRun")
                    }
                    if let message = scheduleIssue {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("计划")
                }

                Section {
                    Picker("结果", selection: $attach) {
                        Text("每次新建对话").tag(false)
                        Text(attachTitle).tag(true)
                    }
                    .disabled(attachID == nil)
                    .accessibilityIdentifier("scheduledTask.editor.target")
                    if targetMissing {
                        Text("原来的对话已删除，运行时会新建对话。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !attach, !model.orderedProjects.isEmpty {
                        Picker("项目", selection: $projectID) {
                            Text("无").tag(UUID?.none)
                            ForEach(model.orderedProjects) { project in
                                Text(project.name).tag(UUID?.some(project.id))
                            }
                        }
                        .accessibilityIdentifier("scheduledTask.editor.project")
                    }
                } header: {
                    Text("结果")
                }

                Section {
                    HStack {
                        Text(directory ?? (attach ? "沿用对话的目录" : "不绑定目录"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(directory == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if directory != nil {
                            Button("清除") { directory = nil }
                                .accessibilityIdentifier("scheduledTask.editor.directory.clear")
                        }
                        Button("选择…") { choosingDirectory = true }
                            .accessibilityIdentifier("scheduledTask.editor.directory.choose")
                    }
                    .accessibilityIdentifier("scheduledTask.editor.directory")
                    Picker("权限", selection: $permission) {
                        Text(attach ? "沿用对话的设置" : "跟随默认（\(defaultPermissionTitle)）").tag("")
                        ForEach(PermissionMode.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .accessibilityIdentifier("scheduledTask.editor.permission")
                } header: {
                    Text("工作目录与权限")
                } footer: {
                    Text(footerText)
                        .font(.caption2)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "添加定时任务" : "编辑定时任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("scheduledTask.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .accessibilityIdentifier("scheduledTask.editor.save")
                }
            }
            .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                directory = url.path
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    // MARK: Schedule

    private var calendar: Calendar { model.scheduleCalendar }

    @ViewBuilder
    private var scheduleControls: some View {
        switch kind {
        case .once:
            DatePicker("时间", selection: $onceDate, displayedComponents: [.date, .hourAndMinute])
                .accessibilityIdentifier("scheduledTask.editor.once")
        case .daily, .weekdays, .weekends:
            timePicker
        case .weekly:
            HStack(spacing: 6) {
                ForEach(Weekday.mondayFirst, id: \.self) { day in
                    let on = weekdays.contains(day)
                    Button {
                        if on { weekdays.remove(day) } else { weekdays.insert(day) }
                    } label: {
                        Text(String(day.shortTitle.dropFirst()))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(on ? Color.white : Color.ompText)
                            .frame(width: 28, height: 28)
                            .background(on ? Color.accentColor : Color.ompFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day.shortTitle)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("scheduledTask.editor.weekday.\(day.rawValue)")
                }
            }
            timePicker
        case .everyHours:
            Stepper("每 \(hours) 小时", value: $hours, in: 1...24)
                .accessibilityIdentifier("scheduledTask.editor.hours")
        case .everyMinutes:
            Stepper("每 \(minutes) 分钟", value: $minutes, in: TaskSchedule.minimumMinutes...720, step: 5)
                .accessibilityIdentifier("scheduledTask.editor.minutes")
        }
    }

    private var timePicker: some View {
        DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
            .accessibilityIdentifier("scheduledTask.editor.time")
    }

    private var schedule: TaskSchedule {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let timeOfDay = TimeOfDay(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        switch kind {
        case .once:
            // Whole minutes: the picker carries the seconds of the moment it opened.
            let whole = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: onceDate)
            return .once(calendar.date(from: whole) ?? onceDate)
        case .daily: return .daily(timeOfDay)
        case .weekdays: return .weekdays(timeOfDay)
        case .weekends: return .weekends(timeOfDay)
        case .weekly: return .weekly(weekdays, timeOfDay)
        case .everyHours: return .everyHours(hours)
        case .everyMinutes: return .everyMinutes(minutes)
        }
    }

    private var nextRunPreview: String {
        let next = schedule.nextRun(after: Date(), calendar: calendar)
        let label = "下次运行：" + TaskSchedule.nextRunLabel(next, now: Date(), calendar: calendar)
        if let existing, existing.status == .paused { return label + "（继续后生效）" }
        return label
    }

    /// Schedule problems show as soon as they exist; empty fields only
    /// after a save attempt.
    private var scheduleIssue: String? {
        draft.validationErrors(now: Date(), previous: existing)[.schedule]
    }

    @ViewBuilder
    private func issue(_ field: ScheduledTask.Field) -> some View {
        if showErrors, let message = draft.validationErrors(now: Date(), previous: existing)[field] {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: Target

    private var targetMissing: Bool {
        guard let existing else { return false }
        return model.scheduledTaskTargetMissing(existing)
    }

    private var attachTitle: String {
        guard let attachID, let conversation = model.conversations.first(where: { $0.id == attachID }) else {
            return "发到当前对话"
        }
        return "发到「\(conversation.title)」"
    }

    private var defaultPermissionTitle: String {
        (PermissionMode(rawValue: model.settings.defaultPermissionMode) ?? .ask).title
    }

    private var footerText: String {
        #if os(macOS)
        var text = "定时任务在这台 Mac 上运行 OMPChat 时执行；应用关闭或 Mac 睡眠期间错过的运行，会在下次启动或唤醒后补跑一次。"
        if attach { text += "发到当前对话时，选定的工作目录和权限会写到该对话上。" }
        return text
        #else
        return "定时任务只在 Mac 上运行：在 Mac 版 OMPChat 里添加和管理。"
        #endif
    }

    // MARK: Load & save

    private var draft: ScheduledTask {
        var task = existing ?? ScheduledTask(title: "", prompt: "", schedule: schedule)
        task.title = title
        task.prompt = prompt
        task.schedule = schedule
        task.target = attach ? attachID.map(ScheduledTask.Target.attached) ?? .newThread : .newThread
        task.workingDirectory = directory
        task.projectID = attach ? nil : projectID
        task.permissionMode = permission.isEmpty ? nil : permission
        return task
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        // Temporary chats vanish on quit, so a task cannot target one.
        let current = currentConversationID.flatMap { id in model.conversations.first { $0.id == id && !$0.isTemporary }?.id }
        guard let existing else {
            attachID = current
            var start = calendar.dateComponents([.year, .month, .day], from: Date())
            start.hour = 9
            time = calendar.date(from: start) ?? Date()
            return
        }
        title = existing.title
        prompt = existing.prompt
        kind = existing.schedule.kind
        switch existing.schedule {
        case .once(let date):
            onceDate = date
        case .daily(let at), .weekdays(let at), .weekends(let at):
            time = date(at)
        case .weekly(let days, let at):
            weekdays = days
            time = date(at)
        case .everyHours(let value):
            hours = value
        case .everyMinutes(let value):
            minutes = value
        }
        if case .attached(let id) = existing.target, !model.scheduledTaskTargetMissing(existing) {
            attach = true
            attachID = id
        } else {
            attachID = current
        }
        projectID = existing.projectID
        directory = existing.workingDirectory
        permission = existing.permissionMode ?? ""
    }

    private func date(_ time: TimeOfDay) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: Date())
        parts.hour = time.hour
        parts.minute = time.minute
        return calendar.date(from: parts) ?? Date()
    }

    private func save() {
        // Commit any IME composition first; SwiftUI copies it into the
        // bindings on a later run-loop turn, so read them only after that.
        GenUIButton.endTextEditing()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            let task = draft
            guard task.validationErrors(now: Date(), previous: existing).isEmpty else {
                showErrors = true
                return
            }
            if existing == nil {
                model.addScheduledTask(task)
            } else {
                model.updateScheduledTask(task)
            }
            dismiss()
        }
    }
}
