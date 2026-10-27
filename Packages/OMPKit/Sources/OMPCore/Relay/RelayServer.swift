import Foundation
import Network

/// Commands the host app consumes from a paired remote controller.
///
/// The set is deliberately the *action* surface rather than a data-sync API:
/// a phone must be able to drive the Mac session end to end (select, send,
/// stop, regenerate, branch, delete, rename, feedback, model, flags) without
/// ever holding authoritative state of its own.
public enum RelayCommand: Sendable, Equatable {
    /// Remote text submission; `nil` conversationID means "create a new
    /// conversation on the host, then send".
    case input(conversationID: String?, text: String)
    /// Ask the host to stop generating in the given conversation.
    case stop(conversationID: String)
    /// Switch the host's selected conversation.
    case select(conversationID: String)
    /// Create a fresh conversation on the host and select it.
    case newConversation
    /// Rename a conversation.
    case rename(conversationID: String, title: String)
    /// Delete a conversation.
    case delete(conversationID: String)
    /// Regenerate the last assistant reply.
    case regenerate(conversationID: String)
    /// Delete one message from a conversation.
    case deleteMessage(conversationID: String, messageID: String)
    /// Edit a user message and resend it (keeps the previous version).
    case editAndResend(conversationID: String, messageID: String, text: String)
    /// Branch a new conversation from a message.
    case branch(conversationID: String, messageID: String)
    /// Set feedback on an assistant message: 1 like, -1 dislike, 0 clear.
    case feedback(conversationID: String, messageID: String, value: Int)
    /// Switch the model used by a conversation.
    case setModel(conversationID: String, modelID: String)
    /// Toggle pin / archive / lock / unread on a conversation.
    case togglePin(conversationID: String)
    case toggleArchive(conversationID: String)
    case toggleLock(conversationID: String)
    case setUnread(conversationID: String, unread: Bool)
    /// Answer one approval card the host shows. Only the host decides whether
    /// it applies; a refusal is echoed under `requestID` in
    /// `RelaySnapshot.commandFailures`.
    case approve(approvalID: String, decision: RelayApprovalDecision, requestID: String?)
    /// 立即发送 on a follow-up queued in the conversation: interrupts the
    /// running reply there and sends it now.
    case sendQueuedNow(conversationID: String, queuedID: String)
    /// 删除 / 编辑 on a queued follow-up: drops it from the host's queue (the
    /// phone keeps the text in its own composer for 编辑).
    case removeQueued(conversationID: String, queuedID: String)
}

/// Errors thrown by [`RelayServer.start(port:token:)`].
public enum RelayServerError: Error, Sendable {
    /// The requested port could not be bound.
    case cannotBind
}

/// The side panel's tabs, shared by `SidePanel.Tab`, the model's panel state
/// and the `/debug/action` wire format. Raw values are the wire names; the
/// UI strings stay in the view layer.
public enum SidePanelTab: String, Codable, Sendable, CaseIterable {
    case terminal
    case files
    case changes
    /// 旁聊: questions about the thread, kept out of it.
    case sideChat
    case browser
}

/// Inline and block styles the composer's B/I/U pills, Aa menu and 格式 menu
/// apply. Raw values are the `/debug/action` wire names.
public enum DebugFormatStyle: String, Sendable, CaseIterable {
    case bold, italic, underline
    case heading1, heading2, heading3
    case paragraph, bulletedList, numberedList, link
}

/// What 继续于 does to a thread's working directory.
public enum DebugContinueTarget: Sendable, Equatable {
    /// Unbind (本地).
    case local
    /// Bind to an existing folder (选择文件夹…).
    case folder(String)
    /// Create a `git worktree` and bind to it (新建 Worktree).
    case worktree
}

/// One write in the side panel's 改动 tab. Paths are relative to the
/// repository root, as `GitWorkingTree.status` reports them.
public enum DebugGitOperation: Sendable, Equatable {
    case stage([String])
    case unstage([String])
    case stageAll
    case unstageAll
    case discard(String)
    case commit(String)
    case push
}

/// What a queued follow-up chip's buttons do.
public enum DebugQueuedOperation: String, Sendable, Equatable {
    case sendNow, edit, delete
}

/// 定时任务 writes, as the sidebar section and its editor offer them.
public enum DebugScheduledTaskOperation: Sendable, Equatable {
    /// The editor's 保存 for a new task; refused with the editor's own
    /// validation text when a field is invalid.
    case add(title: String, prompt: String, schedule: TaskSchedule, target: ScheduledTask.Target,
             workingDirectory: String?, permissionMode: String?)
    case pause(taskID: String)
    case resume(taskID: String)
    case delete(taskID: String)
    case runNow(taskID: String)
}

/// One sidebar write: what a conversation row's menu and the project /
/// section menus offer. Conversation ids default to the selected one.
public enum DebugSidebarOperation: Sendable, Equatable {
    case toggleArchive(conversationID: String?)
    case togglePin(conversationID: String?)
    case rename(conversationID: String?, title: String)
    /// Into a project or custom section; nil moves it out of any group.
    case move(conversationID: String?, groupID: String?)
    case createSection(name: String)
    /// A project or a custom section.
    case renameGroup(groupID: String, name: String)
    case deleteGroup(groupID: String)
    /// 全部归档 of a custom section.
    case archiveSection(groupID: String)
}

/// 本地环境: 设置 → 环境 writes and the header's action buttons.
public enum DebugLocalEnvironmentOperation: Sendable, Equatable {
    /// Writes `<project>/.codex/environments/<fileName>` from TOML in the
    /// official layout; refused with the editor's own validation text.
    case save(project: String, fileName: String, toml: String)
    /// nil clears the choice (the only file is then used); `"none"` is an
    /// explicit 不使用环境.
    case select(project: String, path: String?)
    case delete(path: String)
    /// Header action button `index` (from 0) of the thread's environment.
    case runAction(conversationID: String?, index: Int)
}

/// Worktree mode, the 设置 → Worktree list, and 交接.
public enum DebugWorktreeOperation: Sendable, Equatable {
    /// The composer's 本地 / Worktree switch and base-branch picker.
    case setMode(conversationID: String?, on: Bool, baseBranch: String?)
    case handoff(conversationID: String?, destination: HandoffDestination)
    /// Snapshot, cleanup script, then remove.
    case delete(worktreeID: String)
    /// The header's 恢复 for a chat whose worktree was deleted.
    case restore(conversationID: String?)
    /// Runs the auto-cleanup policy now.
    case cleanup
    /// 在此 worktree 新建对话.
    case newChat(worktreeID: String)
}

/// 从其他 AI 应用导入.
public enum DebugImportOperation: Sendable, Equatable {
    /// `detail` carries the scan as JSON.
    case scan
    /// Imports the entries with these ids from the last scan of `home`.
    case run(entryIDs: [String])
}

/// One automation action for the token-gated `POST /debug/action` route. This
/// is the black-box test channel: the integrator drives the app without
/// bringing it to the front, exactly the actions the UI's own menus offer.
///
/// The request body is decoded as `{"action": "<name>", ...}` where the
/// remaining keys are the case payload fields, so a new case only needs a
/// decoding branch in [`DebugAction.decode(from:)`] and, on the host, a
/// handler. Optional `conversationID` fields mean "the selected conversation".
public enum DebugAction: Sendable, Equatable {
    /// Select a conversation by UUID string.
    case select(conversationID: String)
    /// Create and select a fresh conversation.
    case newChat
    /// Show/hide the side panel and optionally switch its tab.
    case sidePanel(open: Bool, tab: SidePanelTab?)
    /// Open the app's Settings scene, optionally on one section (the settings
    /// sidebar's raw names: general, usage, dataControls, git…).
    case openSettings(section: String?)
    /// Close the Settings scene.
    case closeSettings
    /// Replace the composer draft.
    case setDraft(text: String)
    /// Apply one composer formatting style to the draft.
    case format(DebugFormatStyle)
    /// Set a thread goal; an empty string clears it.
    case setGoal(conversationID: String?, goal: String)
    /// 整理侧栏: grouping and/or filter; at least one is present.
    case sidebar(grouping: SidebarGrouping?, filter: SidebarFilter?)
    /// 待处理 → 全部标为已读.
    case markAllRead
    /// Row menu 标为未读 / 标为已读.
    case setUnread(conversationID: String, unread: Bool)
    /// Header 继续于.
    case continueIn(conversationID: String?, target: DebugContinueTarget)
    /// Header 分叉对话.
    case fork(conversationID: String?, mode: ForkMode)
    /// Open an `ompchat://` link as if the system had delivered it.
    case openLink(url: String)
    /// Delete a conversation (scenario cleanup).
    case delete(conversationID: String)
    /// Close the error banner (its × button).
    case dismissError
    /// Ask the side chat a question about a thread.
    case sideChat(conversationID: String?, text: String)
    /// Forget a thread's side chat.
    case clearSideChat(conversationID: String?)
    /// Stop the side chat's reply.
    case stopSideChat
    /// Side panel browser: open a tab (home page when `url` is nil), right of
    /// `rightOf` or at the end.
    case browserOpenTab(url: String?, rightOf: String?)
    case browserCloseTab(tabID: String)
    case browserDuplicateTab(tabID: String)
    /// A blank title clears the custom name.
    case browserRenameTab(tabID: String, title: String)
    case browserSelectTab(tabID: String)
    /// `url` must be complete; the address bar's search/https rules are UI-side.
    case browserNavigate(tabID: String, url: String)
    /// 改动 tab write, in the thread's working directory.
    case git(conversationID: String?, operation: DebugGitOperation)
    /// Archive, pin, rename, move, and project / section edits.
    case sidebarOp(DebugSidebarOperation)
    /// Send the given text as a user message, as typed: mention tokens in it
    /// are resolved, readable `@名称` text is not (see `sendDraft`).
    case send(conversationID: String?, text: String)
    /// The composer's send button on the current draft: readable mentions go
    /// out as tokens and are resolved, the draft is cleared.
    case sendDraft(conversationID: String?)
    /// Stop the reply, the running tool and every pending approval (⌘.).
    case stop
    /// Answer one approval card.
    case approve(approvalID: String, decision: ToolApprovalDecision)
    /// Permission mode for a thread; nil follows the settings default.
    case setPermissionMode(conversationID: String?, mode: PermissionMode?)
    /// Tools on/off for a thread; nil follows its working directory.
    case setToolsEnabled(conversationID: String?, enabled: Bool?)
    /// The composer's 「工具与权限」 pick, both fields in one write.
    case setAccess(conversationID: String?, access: AgentAccess)
    case scheduledTask(DebugScheduledTaskOperation)
    /// A file reference's 打开文件: the side panel's 文件 tab at `line`.
    case openFile(path: String, line: Int?)
    /// 用 Codex 审查: a read-only review thread for the working directory.
    case codeReview(conversationID: String?)
    /// A queued follow-up chip: 立即发送 / 编辑 / 删除.
    case queued(conversationID: String?, queuedID: String, op: DebugQueuedOperation)
    /// 压缩上下文 (the + menu and `/compact`).
    case compact(conversationID: String?)
    /// The composer's `@` / `$` list for a query: `detail` carries the
    /// candidates as JSON (token, kind, title, detail, badge).
    case mentionSearch(conversationID: String?, query: String, trigger: Character)
    /// Picking a row of that list: replaces the `@…` / `$…` being typed in
    /// the draft with the candidate's token.
    case pickMention(conversationID: String?, token: String)
    /// Transcribes an audio file into the draft with the same on-device
    /// recognizer as the composer's dictation (no microphone involved).
    case transcribeFile(conversationID: String?, path: String, locale: String?)
    /// 设置 → MCP 服务器 → 目录 → 安装: the entry's answers by input id.
    case mcpInstall(entryID: String, values: [String: [String]])
    /// Remove a server from settings (and its vault secrets).
    case mcpRemove(serverID: String)
    /// The composer's 联网 pill.
    case setWebSearch(enabled: Bool)
    /// Adds a computer-use server from `ComputerUseCatalog`, enabled, without
    /// the confirmation sheet 设置 → 电脑控制 shows. For black-box runs only
    /// (the route is token-gated); it makes no tool call and grants nothing.
    case computerUseAdd(serverID: String?)
    /// 设置 → 远程控制 → 允许手机访问文件与终端. Loopback-only like every
    /// debug action, so a phone cannot use it to grant itself access.
    case setPhoneAccess(enabled: Bool)
    /// The toast's 撤销: undoes the newest undoable sidebar action.
    case undo
    /// Hides the undo toast; the history is kept.
    case dismissUndo
    /// ⌘B: shows or hides the sidebar (macOS).
    case toggleSidebar
    case localEnvironment(DebugLocalEnvironmentOperation)
    case worktree(DebugWorktreeOperation)
    /// Import against `home`, an absolute folder standing in for `~`, so an
    /// automated run never reads or writes the user's real Claude / Cursor
    /// setups. Imported chats, MCP servers and instructions still land in
    /// this app's workspace.
    case externalImport(home: String, op: DebugImportOperation)
    /// 设置 → 浏览器 → 链接打开位置: `"app"` or `"system"`.
    case setLinkDestination(String)
    /// Hides the first-launch import prompt for this session only; unlike
    /// 暂不 it is not remembered.
    case hideImportPrompt
    /// Clicking a web link in a message; it goes where 链接打开位置 says, so a
    /// script should set `"app"` first or the user's browser opens.
    case clickLink(url: String)

    /// The wire name of the action.
    public var name: String {
        switch self {
        case .select: "select"
        case .newChat: "newChat"
        case .sidePanel: "sidePanel"
        case .openSettings: "openSettings"
        case .closeSettings: "closeSettings"
        case .setDraft: "setDraft"
        case .format: "format"
        case .setGoal: "setGoal"
        case .sidebar: "sidebar"
        case .markAllRead: "markAllRead"
        case .setUnread: "setUnread"
        case .continueIn: "continueIn"
        case .fork: "fork"
        case .openLink: "openLink"
        case .delete: "delete"
        case .dismissError: "dismissError"
        case .sideChat: "sideChat"
        case .clearSideChat: "clearSideChat"
        case .stopSideChat: "stopSideChat"
        case .browserOpenTab: "browserOpenTab"
        case .browserCloseTab: "browserCloseTab"
        case .browserDuplicateTab: "browserDuplicateTab"
        case .browserRenameTab: "browserRenameTab"
        case .browserSelectTab: "browserSelectTab"
        case .browserNavigate: "browserNavigate"
        case .git: "git"
        case .sidebarOp: "sidebarOp"
        case .send: "send"
        case .sendDraft: "sendDraft"
        case .stop: "stop"
        case .approve: "approve"
        case .setPermissionMode: "setPermissionMode"
        case .setToolsEnabled: "setToolsEnabled"
        case .setAccess: "setAccess"
        case .scheduledTask: "scheduledTask"
        case .openFile: "openFile"
        case .codeReview: "codeReview"
        case .queued: "queued"
        case .compact: "compact"
        case .mentionSearch: "mentionSearch"
        case .pickMention: "pickMention"
        case .transcribeFile: "transcribeFile"
        case .mcpInstall: "mcpInstall"
        case .mcpRemove: "mcpRemove"
        case .setWebSearch: "setWebSearch"
        case .computerUseAdd: "computerUseAdd"
        case .setPhoneAccess: "setPhoneAccess"
        case .undo: "undo"
        case .dismissUndo: "dismissUndo"
        case .toggleSidebar: "toggleSidebar"
        case .localEnvironment: "localEnvironment"
        case .worktree: "worktree"
        case .externalImport: "externalImport"
        case .setLinkDestination: "setLinkDestination"
        case .hideImportPrompt: "hideImportPrompt"
        case .clickLink: "clickLink"
        }
    }

    /// Decodes `{"action": ..., ...payload}`; any shape the parser does not
    /// fully understand — unknown action name, missing or mistyped fields,
    /// unknown enum values, wrong JSON type at the top level — returns `nil`,
    /// which the route answers with `400`.
    public static func decode(from data: Data) -> DebugAction? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let name = fields["action"] as? String else { return nil }

        /// Absent → `.some(nil)`; present but not a string → `nil` (reject).
        func optionalString(_ key: String) -> String?? {
            guard let raw = fields[key] else { return .some(nil) }
            guard let string = raw as? String else { return nil }
            return .some(string)
        }

        /// A JSON `true` / `false`. `as? Bool` also bridges the numbers 1 and 0,
        /// so a typo like `"enabled": 1` would flip a switch instead of 400.
        func boolean(_ raw: Any?) -> Bool? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }

        switch name {
        case "select":
            guard let id = fields["conversationID"] as? String else { return nil }
            return .select(conversationID: id)
        case "newChat":
            return .newChat
        case "sidePanel":
            guard let open = boolean(fields["open"]) else { return nil }
            if let rawTab = fields["tab"] {
                // A misspelled tab is a caller error, not a default: reject
                // instead of silently landing on 终端.
                guard let rawTab = rawTab as? String, let tab = SidePanelTab(rawValue: rawTab) else {
                    return nil
                }
                return .sidePanel(open: open, tab: tab)
            }
            return .sidePanel(open: open, tab: nil)
        case "openSettings":
            guard let section = optionalString("section") else { return nil }
            return .openSettings(section: section)
        case "closeSettings":
            return .closeSettings
        case "setDraft":
            guard let text = fields["text"] as? String else { return nil }
            return .setDraft(text: text)
        case "format":
            guard let raw = fields["style"] as? String, let style = DebugFormatStyle(rawValue: raw) else {
                return nil
            }
            return .format(style)
        case "setGoal":
            guard let id = optionalString("conversationID"), let goal = fields["goal"] as? String else {
                return nil
            }
            return .setGoal(conversationID: id, goal: goal)
        case "sidebar":
            guard let rawGrouping = optionalString("grouping"), let rawFilter = optionalString("filter") else {
                return nil
            }
            let grouping = rawGrouping.flatMap(SidebarGrouping.init(rawValue:))
            let filter = rawFilter.flatMap(SidebarFilter.init(rawValue:))
            // An unknown value must not be dropped silently, and an action
            // that changes nothing is a caller error.
            guard (rawGrouping == nil) == (grouping == nil),
                  (rawFilter == nil) == (filter == nil),
                  grouping != nil || filter != nil else { return nil }
            return .sidebar(grouping: grouping, filter: filter)
        case "markAllRead":
            return .markAllRead
        case "setUnread":
            guard let id = fields["conversationID"] as? String, let unread = boolean(fields["unread"]) else {
                return nil
            }
            return .setUnread(conversationID: id, unread: unread)
        case "continueIn":
            guard let id = optionalString("conversationID"), let mode = fields["mode"] as? String else {
                return nil
            }
            switch mode {
            case "local":
                return .continueIn(conversationID: id, target: .local)
            case "worktree":
                return .continueIn(conversationID: id, target: .worktree)
            case "folder":
                guard let path = fields["path"] as? String,
                      !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return .continueIn(conversationID: id, target: .folder(path))
            default:
                return nil
            }
        case "fork":
            guard let id = optionalString("conversationID"),
                  let raw = fields["mode"] as? String, let mode = ForkMode(rawValue: raw) else { return nil }
            return .fork(conversationID: id, mode: mode)
        case "openLink":
            guard let url = fields["url"] as? String else { return nil }
            return .openLink(url: url)
        case "delete":
            guard let id = fields["conversationID"] as? String else { return nil }
            return .delete(conversationID: id)
        case "dismissError":
            return .dismissError
        case "sideChat":
            guard let id = optionalString("conversationID"), let text = fields["text"] as? String else { return nil }
            return .sideChat(conversationID: id, text: text)
        case "clearSideChat":
            guard let id = optionalString("conversationID") else { return nil }
            return .clearSideChat(conversationID: id)
        case "stopSideChat":
            return .stopSideChat
        case "browserOpenTab":
            guard let url = optionalString("url"), let rightOf = optionalString("rightOf") else { return nil }
            return .browserOpenTab(url: url, rightOf: rightOf)
        case "browserCloseTab":
            guard let id = fields["tabID"] as? String else { return nil }
            return .browserCloseTab(tabID: id)
        case "browserDuplicateTab":
            guard let id = fields["tabID"] as? String else { return nil }
            return .browserDuplicateTab(tabID: id)
        case "browserRenameTab":
            guard let id = fields["tabID"] as? String, let title = fields["title"] as? String else { return nil }
            return .browserRenameTab(tabID: id, title: title)
        case "browserSelectTab":
            guard let id = fields["tabID"] as? String else { return nil }
            return .browserSelectTab(tabID: id)
        case "browserNavigate":
            guard let id = fields["tabID"] as? String, let url = fields["url"] as? String,
                  URL(string: url)?.scheme != nil else { return nil }
            return .browserNavigate(tabID: id, url: url)
        case "git":
            guard let id = optionalString("conversationID"), let op = fields["op"] as? String else { return nil }
            /// A non-empty list of strings, or nil.
            func paths() -> [String]? {
                guard let list = fields["paths"] as? [Any], !list.isEmpty else { return nil }
                let strings = list.compactMap { $0 as? String }
                return strings.count == list.count ? strings : nil
            }
            let operation: DebugGitOperation
            switch op {
            case "stage":
                guard let paths = paths() else { return nil }
                operation = .stage(paths)
            case "unstage":
                guard let paths = paths() else { return nil }
                operation = .unstage(paths)
            case "stageAll": operation = .stageAll
            case "unstageAll": operation = .unstageAll
            case "discard":
                guard let path = fields["path"] as? String, !path.isEmpty else { return nil }
                operation = .discard(path)
            case "commit":
                // A blank message is the host's refusal to report, not a
                // malformed request.
                guard let message = fields["message"] as? String else { return nil }
                operation = .commit(message)
            case "push": operation = .push
            default: return nil
            }
            return .git(conversationID: id, operation: operation)
        case "sidebarOp":
            guard let op = fields["op"] as? String, let id = optionalString("conversationID") else { return nil }
            func text(_ key: String) -> String? { fields[key] as? String }
            switch op {
            case "toggleArchive": return .sidebarOp(.toggleArchive(conversationID: id))
            case "togglePin": return .sidebarOp(.togglePin(conversationID: id))
            case "rename":
                guard let title = text("title") else { return nil }
                return .sidebarOp(.rename(conversationID: id, title: title))
            case "move":
                // Absent or null moves out of the group; anything but a
                // string is a caller error, not "out of the group".
                switch fields["groupID"] {
                case nil, is NSNull: return .sidebarOp(.move(conversationID: id, groupID: nil))
                case let group as String: return .sidebarOp(.move(conversationID: id, groupID: group))
                default: return nil
                }
            case "createSection":
                guard let name = text("name") else { return nil }
                return .sidebarOp(.createSection(name: name))
            case "renameGroup":
                guard let group = text("groupID"), let name = text("name") else { return nil }
                return .sidebarOp(.renameGroup(groupID: group, name: name))
            case "deleteGroup":
                guard let group = text("groupID") else { return nil }
                return .sidebarOp(.deleteGroup(groupID: group))
            case "archiveSection":
                guard let group = text("groupID") else { return nil }
                return .sidebarOp(.archiveSection(groupID: group))
            default:
                return nil
            }
        case "send":
            guard let id = optionalString("conversationID"), let text = fields["text"] as? String else { return nil }
            return .send(conversationID: id, text: text)
        case "sendDraft":
            guard let id = optionalString("conversationID") else { return nil }
            return .sendDraft(conversationID: id)
        case "stop":
            return .stop
        case "approve":
            guard let id = fields["approvalID"] as? String,
                  let raw = fields["decision"] as? String,
                  let decision = ToolApprovalDecision(rawValue: raw) else { return nil }
            return .approve(approvalID: id, decision: decision)
        case "setPermissionMode":
            guard let id = optionalString("conversationID") else { return nil }
            // Absent or null follows the default; an unknown mode is an error,
            // not a silent fallback.
            switch fields["mode"] {
            case nil, is NSNull:
                return .setPermissionMode(conversationID: id, mode: nil)
            case let raw as String:
                guard let mode = PermissionMode(rawValue: raw) else { return nil }
                return .setPermissionMode(conversationID: id, mode: mode)
            default:
                return nil
            }
        case "setToolsEnabled":
            guard let id = optionalString("conversationID") else { return nil }
            switch fields["enabled"] {
            case nil, is NSNull:
                return .setToolsEnabled(conversationID: id, enabled: nil)
            case let raw? where boolean(raw) != nil:
                return .setToolsEnabled(conversationID: id, enabled: boolean(raw))
            default:
                return nil
            }
        case "setAccess":
            guard let id = optionalString("conversationID"),
                  let raw = fields["access"] as? String,
                  let access = AgentAccess(wireValue: raw) else { return nil }
            return .setAccess(conversationID: id, access: access)
        case "scheduledTask":
            guard let op = fields["op"] as? String else { return nil }
            if op == "add" {
                // Schedule and target use the workspace file's own JSON
                // shapes, ISO-8601 dates included.
                func decoded<T: Decodable>(_ key: String, as type: T.Type) -> T? {
                    guard let object = fields[key], JSONSerialization.isValidJSONObject(object),
                          let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    return try? decoder.decode(type, from: data)
                }
                guard let title = fields["title"] as? String, let prompt = fields["prompt"] as? String,
                      let schedule = decoded("schedule", as: TaskSchedule.self),
                      let directory = optionalString("workingDirectory"),
                      let mode = optionalString("permissionMode") else { return nil }
                var target = ScheduledTask.Target.newThread
                if fields["target"] != nil {
                    guard let explicit = decoded("target", as: ScheduledTask.Target.self) else { return nil }
                    target = explicit
                }
                return .scheduledTask(.add(title: title, prompt: prompt, schedule: schedule, target: target,
                                           workingDirectory: directory, permissionMode: mode))
            }
            guard let id = fields["taskID"] as? String else { return nil }
            switch op {
            case "pause": return .scheduledTask(.pause(taskID: id))
            case "resume": return .scheduledTask(.resume(taskID: id))
            case "delete": return .scheduledTask(.delete(taskID: id))
            case "runNow": return .scheduledTask(.runNow(taskID: id))
            default: return nil
            }
        case "openFile":
            guard let path = fields["path"] as? String, !path.isEmpty else { return nil }
            switch fields["line"] {
            case nil, is NSNull:
                return .openFile(path: path, line: nil)
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID() && number.intValue >= 1
                && Double(number.intValue) == number.doubleValue:
                return .openFile(path: path, line: number.intValue)
            default:
                return nil
            }
        case "codeReview":
            guard let id = optionalString("conversationID") else { return nil }
            return .codeReview(conversationID: id)
        case "queued":
            guard let id = optionalString("conversationID"),
                  let queuedID = fields["queuedID"] as? String,
                  let raw = fields["op"] as? String,
                  let op = DebugQueuedOperation(rawValue: raw) else { return nil }
            return .queued(conversationID: id, queuedID: queuedID, op: op)
        case "compact":
            guard let id = optionalString("conversationID") else { return nil }
            return .compact(conversationID: id)
        case "mentionSearch":
            guard let id = optionalString("conversationID"),
                  let query = fields["query"] as? String,
                  let raw = fields["trigger"] as? String, raw == "@" || raw == "$" else { return nil }
            return .mentionSearch(conversationID: id, query: query, trigger: Character(raw))
        case "pickMention":
            guard let id = optionalString("conversationID"), let token = fields["token"] as? String else { return nil }
            return .pickMention(conversationID: id, token: token)
        case "transcribeFile":
            guard let id = optionalString("conversationID"), let locale = optionalString("locale"),
                  let path = fields["path"] as? String, path.hasPrefix("/") else { return nil }
            return .transcribeFile(conversationID: id, path: path, locale: locale)
        case "mcpInstall":
            guard let entry = fields["entryID"] as? String else { return nil }
            var values: [String: [String]] = [:]
            if let raw = fields["values"] {
                // Every answer is a list of strings; anything else is a
                // caller error rather than an empty answer.
                guard let table = raw as? [String: Any] else { return nil }
                for (key, value) in table {
                    guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else { return nil }
                    values[key] = list.compactMap { $0 as? String }
                }
            }
            return .mcpInstall(entryID: entry, values: values)
        case "mcpRemove":
            guard let id = fields["serverID"] as? String else { return nil }
            return .mcpRemove(serverID: id)
        case "setWebSearch":
            guard let enabled = boolean(fields["enabled"]) else { return nil }
            return .setWebSearch(enabled: enabled)
        case "computerUseAdd":
            // Absent means the primary pick; present must be a string.
            guard let id = optionalString("serverID") else { return nil }
            return .computerUseAdd(serverID: id)
        case "setPhoneAccess":
            guard let enabled = boolean(fields["enabled"]) else { return nil }
            return .setPhoneAccess(enabled: enabled)
        case "undo":
            return .undo
        case "dismissUndo":
            return .dismissUndo
        case "toggleSidebar":
            return .toggleSidebar
        case "localEnvironment":
            guard let op = fields["op"] as? String else { return nil }
            switch op {
            case "save":
                guard let project = fields["project"] as? String, project.hasPrefix("/"),
                      let file = fields["fileName"] as? String, !file.isEmpty,
                      let toml = fields["toml"] as? String else { return nil }
                return .localEnvironment(.save(project: project, fileName: file, toml: toml))
            case "select":
                guard let project = fields["project"] as? String, project.hasPrefix("/"),
                      let path = optionalString("path") else { return nil }
                if let path, path != "none", !path.hasPrefix("/") { return nil }
                return .localEnvironment(.select(project: project, path: path))
            case "delete":
                guard let path = fields["path"] as? String, path.hasPrefix("/") else { return nil }
                return .localEnvironment(.delete(path: path))
            case "runAction":
                guard let id = optionalString("conversationID"),
                      let number = fields["index"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.intValue >= 0, Double(number.intValue) == number.doubleValue else { return nil }
                return .localEnvironment(.runAction(conversationID: id, index: number.intValue))
            default:
                return nil
            }
        case "worktree":
            guard let op = fields["op"] as? String else { return nil }
            switch op {
            case "setMode":
                guard let id = optionalString("conversationID"), let on = boolean(fields["on"]),
                      let branch = optionalString("baseBranch") else { return nil }
                return .worktree(.setMode(conversationID: id, on: on, baseBranch: branch))
            case "handoff":
                guard let id = optionalString("conversationID"),
                      let raw = fields["destination"] as? String,
                      let destination = HandoffDestination(rawValue: raw) else { return nil }
                return .worktree(.handoff(conversationID: id, destination: destination))
            case "delete":
                guard let id = fields["worktreeID"] as? String else { return nil }
                return .worktree(.delete(worktreeID: id))
            case "restore":
                guard let id = optionalString("conversationID") else { return nil }
                return .worktree(.restore(conversationID: id))
            case "cleanup":
                return .worktree(.cleanup)
            case "newChat":
                guard let id = fields["worktreeID"] as? String else { return nil }
                return .worktree(.newChat(worktreeID: id))
            default:
                return nil
            }
        case "externalImport":
            guard let home = fields["home"] as? String, home.hasPrefix("/"),
                  let op = fields["op"] as? String else { return nil }
            switch op {
            case "scan":
                return .externalImport(home: home, op: .scan)
            case "run":
                guard let ids = fields["entryIDs"] as? [String] else { return nil }
                return .externalImport(home: home, op: .run(entryIDs: ids))
            default:
                return nil
            }
        case "setLinkDestination":
            guard let value = fields["value"] as? String, value == "app" || value == "system" else { return nil }
            return .setLinkDestination(value)
        case "hideImportPrompt":
            return .hideImportPrompt
        case "clickLink":
            guard let raw = fields["url"] as? String, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return .clickLink(url: raw)
        default:
            return nil
        }
    }
}

/// Result of one executed debug action, serialized as the route's reply.
public struct DebugActionOutcome: Codable, Sendable, Equatable {
    public var ok: Bool
    /// Present only when `ok` is false.
    public var error: String?
    /// What a query-like action found, as JSON text (e.g. `mentionSearch`).
    /// Left out of the reply when nil.
    public var detail: String?

    public init(ok: Bool, error: String?, detail: String? = nil) {
        self.ok = ok
        self.error = error
        self.detail = detail
    }

    public static let success = DebugActionOutcome(ok: true, error: nil)
    public static func failure(_ message: String) -> DebugActionOutcome {
        DebugActionOutcome(ok: false, error: message)
    }
}

/// Errors thrown by [`RelayServer.start(port:token:)`].

/// Minimal LAN HTTP server mirroring structured chat state to a remote
/// controller. Hand-rolled HTTP/1.1 (request line + headers +
/// `Content-Length` body) on top of `NWListener` — no third-party code.
///
/// Routes (all require `X-OMP-Token`, else `401`):
///
/// - `GET /pair` → `200 {"ok":true,"host":...,"rev":N}`
/// - `GET /snapshot` → `200` JSON [`RelaySnapshot`]
/// - `GET /state` → `text/event-stream`; sends `event: hello` on connect,
///   `event: rev` on every [`update(_:)`], and a `: ping` comment when the
///   state has been idle for 15 seconds.
/// - `POST /command` → flat [`RelayCommandWire`] body; the full action
///   surface (select/new/rename/delete/regenerate/edit/branch/feedback/
///   setModel/pin/archive/lock/unread/approve/sendQueuedNow/removeQueued)
///   goes through this one route.
///   A body whose `command` does not parse (unknown kind, an `approve` without
///   `approvalID` or with a decision other than `allowOnce`/`deny`) is `400`.
/// - `POST /rpc` → [`HostRPCRequest`] JSON; answered with [`HostRPCResponse`]
///   JSON at `200` even when `ok` is false. Unset `onRPC` answers
///   `ok: false, error: "unsupported"`.
/// - `GET /debug/events?since=<seq>` → JSON events with `seq` greater than
///   `since` (token gated, same as every other route).
/// - `GET /debug/report` → runs the host's diagnostics and returns the JSON
///   report. Answers `503` until the host installs `onDebugReport`.
/// - `GET /debug/windows` → JSON `{"windows":[…]}` describing the host app's
///   own windows. Answers `503` until the host installs `onDebugWindows`.
/// - `GET /debug/snapshot?window=<number>` → `image/png` of one of the host
///   app's own windows, rendered in process: it works while the app is behind
///   other windows and never contains another app. Without `window` the host
///   picks its main window. `400` for a non-numeric `window`, `404` when that
///   window does not exist, `503` until the host installs `onDebugSnapshot`.
/// - `POST /debug/action` → JSON `{"action": ..., ...}`; the host hook
///   [`onDebugAction`] runs it and the route answers
///   `200 {"ok":true,"error":null}` on success or
///   `200 {"ok":false,"error":"…"}` when the host could not do it. `400` for
///   a body that does not decode, `503` until the host installs the hook.
/// - `GET /debug/state` → JSON `{"selectedID":…,"sidePanelOpen":…,
///   "sidePanelTab":…,"windowTitles":[…]}` read from the host hook
///   [`onDebugState`]. Answers `503` until that hook is installed.
///
/// The windows, snapshot, action and state hooks run on the main actor. If it
/// cannot start one within `mainActorStartTimeout`, the route answers
/// `503 {"ok":false,"error":"main_thread_busy"}` and the hook is abandoned:
/// it will not run later (see `MainActorStart`).
public final class RelayServer: @unchecked Sendable {
    /// Host app hook. Commands are delivered one at a time, in arrival order;
    /// the next command waits for the previous handler to return.
    public var onInput: (@Sendable (RelayCommand) async -> Void)?
    /// Host-RPC hook. Unlike `onInput` this is request/response: the HTTP
    /// handler awaits the closure and writes its [`HostRPCResponse`] back.
    /// `nil` answers every `POST /rpc` with `error: "unsupported"`.
    public var onRPC: (@Sendable (HostRPCRequest) async -> HostRPCResponse)?
    /// Host hook for `GET /debug/report`. Returns the report JSON.
    public var onDebugReport: (@Sendable () async -> Data)?
    /// Host hook for `POST /debug/action`. Runs one [`DebugAction`] and
    /// reports success or a short error string; `nil` answers `503`.
    public var onDebugAction: (@MainActor @Sendable (DebugAction) async -> DebugActionOutcome)?
    /// Host hook for `GET /debug/state`. Returns the app-state JSON.
    public var onDebugState: (@MainActor @Sendable () -> Data)?
    /// Host hook for `GET /debug/windows`. Returns the window-list JSON.
    public var onDebugWindows: (@MainActor @Sendable () -> Data)?
    /// Host hook for `GET /debug/snapshot`. A `nil` argument means the main
    /// window; returning `nil` answers `404`.
    public var onDebugSnapshot: (@MainActor @Sendable (Int?) -> Data?)?
    /// How long a main-actor hook may wait to start before its route gives
    /// up with `main_thread_busy`.
    public var mainActorStartTimeout: Double = 10


    /// Internal: the bound listener, exposed so `RelayAdvertiser` can attach
    /// the Bonjour service to it (macOS refuses a second listener on the
    /// same port). Returns `nil` while the server is not running.
    func bonjourListener() -> NWListener? {
        queue.sync { listener }
    }
    /// All server state and connection I/O is confined to this serial queue.
    private let queue = DispatchQueue(label: "com.ompchat.relay.server")
    private var listener: NWListener?
    private var token = ""
    private var snapshot = RelaySnapshot(rev: 0, host: "", selectedID: nil, conversations: [])
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var pingTimer: DispatchSourceTimer?
    private var lastBroadcastAt = Date.distantPast
    private var boundPort: UInt16 = 0
    /// Tail of the serialized command chain; each command awaits its value.
    private var lastCommandTask: Task<Void, Never>?

    private struct Connection {
        let connection: NWConnection
        var isSSE: Bool
        var buffer: Data
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        let query: String
    }

    public init() {}

    /// The port the server listens on; when started with `0` this is the port
    /// the OS picked. Valid after `start(port:token:)` returns.
    public var port: UInt16 { queue.sync { boundPort } }

    /// Starts listening. Throws when the port cannot be bound; call `stop()`
    /// to release the listener and every open connection.
    public func start(port requested: UInt16, token: String) throws {
        let ready = DispatchSemaphore(value: 0)
        let box = FailureBox()
        queue.sync {
            stopLocked()
            self.token = token
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let endpointPort = NWEndpoint.Port(rawValue: requested) else {
                box.failure = URLError(.badURL)
                ready.signal()
                return
            }
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters, on: endpointPort)
            } catch {
                box.failure = error
                ready.signal()
                return
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                // The first ready / failed answers `start`. Later changes used
                // to be dropped: the listener could go away (a scenario saw
                // connections refused with no stop logged) and nothing said so.
                switch state {
                case .ready:
                    if box.settled {
                        DiagnosticsCenter.shared.record("relay", .info, "listener ready again", fields: ["port": String(requested)])
                    } else {
                        box.failure = nil
                        box.settled = true
                        ready.signal()
                    }
                case .failed(let error):
                    if box.settled {
                        DiagnosticsCenter.shared.record("relay", .error, "listener failed",
                            fields: ["port": String(requested), "error": String(describing: error)])
                    } else {
                        box.failure = error
                        box.settled = true
                        ready.signal()
                    }
                case .waiting(let error):
                    DiagnosticsCenter.shared.record("relay", .warn, "listener waiting",
                        fields: ["port": String(requested), "error": String(describing: error)])
                case .cancelled:
                    break
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
        ready.wait()
        if let failure = box.failure {
            queue.sync {
                listener?.stateUpdateHandler = nil
                listener?.newConnectionHandler = nil
                listener?.cancel()
                listener = nil
            }
            throw failure
        }
        queue.sync {
            boundPort = listener?.port?.rawValue ?? requested
            lastBroadcastAt = Date()
            startPingTimerLocked()
        }
    }

    /// Stops the listener, closes every connection, and cancels the ping
    /// timer. Safe to call twice; `start` may be called again afterwards.
    public func stop() {
        queue.sync { stopLocked() }
    }

    /// Installs `snapshot` as the new state with `rev` incremented by one and
    /// broadcasts a `rev` event to every connected SSE client.
    public func update(_ snapshot: RelaySnapshot) {
        queue.async {
            var snapshot = snapshot
            snapshot.rev = self.snapshot.rev + 1
            self.snapshot = snapshot
            self.broadcast("event: rev\ndata: {\"rev\":\(snapshot.rev)}\n\n")
        }
    }

    // MARK: - Listener

    private func stopLocked() {
        pingTimer?.cancel()
        pingTimer = nil
        for (_, connection) in connections {
            connection.connection.stateUpdateHandler = nil
            connection.connection.cancel()
        }
        connections.removeAll()
        lastCommandTask = nil
        boundPort = 0
        guard let listener else {
            self.listener = nil
            return
        }
        self.listener = nil
        // Wait for the port to actually be released so an immediate
        // `start` rebind succeeds (the `.cancelled` state fires before the
        // kernel releases the socket on some paths).
        let released = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { released.signal() }
        }
        listener.newConnectionHandler = nil
        listener.cancel()
        _ = released.wait(timeout: .now() + 2)
        listener.stateUpdateHandler = nil
    }

    private func startPingTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = Date().timeIntervalSince(self.lastBroadcastAt)
            if idle >= Self.pingInterval {
                self.broadcast(": ping\n\n")
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private static let pingInterval: TimeInterval = 15

    // MARK: - Connection lifecycle

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        queue.async {
            self.connections[id] = Connection(connection: connection, isSSE: false, buffer: Data())
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLoop(id: id, connection: connection)
            case .failed, .waiting:
                self.drop(id)
            case .cancelled:
                self.drop(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(id: ObjectIdentifier, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.connections[id] != nil else { return }
                if let data, !data.isEmpty {
                    self.ingest(data, id: id)
                }
                if isComplete || error != nil {
                    self.drop(id)
                    return
                }
                guard self.connections[id] != nil else { return }
                self.receiveLoop(id: id, connection: connection)
            }
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.connection.stateUpdateHandler = nil
        connection.connection.cancel()
    }

    // MARK: - HTTP parsing

    private func ingest(_ data: Data, id: ObjectIdentifier) {
        guard connections[id] != nil else { return }
        connections[id]?.buffer.append(data)
        if connections[id]!.buffer.count > Self.maxRequestBytes {
            drop(id)
            return
        }
        if let request = parseRequest(&connections[id]!.buffer) {
            handle(request, id: id)
        }
    }

    private static let maxRequestBytes = 1 << 20

    /// Removes one complete request from `buffer` and returns it, or `nil`
    /// while the request is still incomplete.
    private func parseRequest(_ buffer: inout Data) -> Request? {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let query = rawPath.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines {
            let keyAndValue = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyAndValue.count == 2 else { continue }
            let key = keyAndValue[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = keyAndValue[1].trimmingCharacters(in: .whitespaces)
            headers[key] = value
            if key == "content-length", let length = Int(value) {
                contentLength = max(0, length)
            }
        }
        guard contentLength <= Self.maxRequestBytes else { return nil }
        let bodyStart = headerEnd.upperBound
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength, limitedBy: buffer.endIndex) ?? nil
        guard let bodyEnd, buffer.distance(from: bodyStart, to: bodyEnd) == contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return Request(method: method, path: path, headers: headers, body: body, query: query)
    }

    // MARK: - Routing

    private func handle(_ request: Request, id: ObjectIdentifier) {
        guard let connection = connections[id] else { return }
        guard request.headers["x-omp-token"] == token, !token.isEmpty else {
            send(httpResponse(status: "401 Unauthorized", contentType: "application/json",
                              body: Data("{\"error\":\"unauthorized\"}".utf8)),
                 id: id)
            return
        }
        // Automation routes act on the Mac as its owner would, so they are
        // for local tools only; see `RelayPeer`.
        if request.path.hasPrefix("/debug/"), !RelayPeer.isLoopback(connection.connection.endpoint) {
            send(httpResponse(status: "403 Forbidden", contentType: "application/json",
                              body: Data("{\"error\":\"loopback_only\"}".utf8)),
                 id: id)
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/pair"):
            let payload = PairBody(ok: true, host: snapshot.host, rev: snapshot.rev)
            send(json(payload, status: "200 OK"), id: id)
        case ("GET", "/snapshot"):
            send(json(snapshot, status: "200 OK"), id: id)
        case ("GET", "/state"):
            connections[id]?.isSSE = true
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            lastBroadcastAt = Date()
            send(Data(head.utf8), id: id)
            send(Data("event: hello\ndata: {\"rev\":\(snapshot.rev)}\n\n".utf8), id: id)
        case ("POST", "/rpc"):
            guard let rpcRequest = decode(HostRPCRequest.self, from: request.body) else {
                send(json(HostRPCResponse(id: "", ok: false, error: "bad_request"), status: "200 OK"), id: id)
                return
            }
            let handler = onRPC
            if let handler {
                Task {
                    let rpcResponse = await handler(rpcRequest)
                    self.queue.async {
                        self.send(self.json(rpcResponse, status: "200 OK"), id: id)
                    }
                }
            } else {
                send(json(HostRPCResponse(id: rpcRequest.id, ok: false, error: "unsupported"), status: "200 OK"), id: id)
            }
        case ("POST", "/command"):
            guard let wire = decode(RelayCommandWire.self, from: request.body),
                  let command = wire.command else {
                send(json(ErrorBody(ok: false), status: "400 Bad Request"), id: id)
                return
            }
            dispatch(command)
            send(json(ErrorBody(ok: true), status: "200 OK"), id: id)
        case ("POST", "/input"):
            guard let body = decode(InputBody.self, from: request.body),
                  !body.text.isEmpty else {
                send(json(ErrorBody(ok: false), status: "400 Bad Request"), id: id)
                return
            }
            dispatch(.input(conversationID: body.conversationID, text: body.text))
            send(json(InputAck(ok: true, conversationID: body.conversationID), status: "200 OK"), id: id)
        case ("POST", "/stop"):
            guard let body = decode(StopBody.self, from: request.body) else {
                send(json(ErrorBody(ok: false), status: "400 Bad Request"), id: id)
                return
            }
            dispatch(.stop(conversationID: body.conversationID))
            send(json(ErrorBody(ok: true), status: "200 OK"), id: id)
        case ("GET", "/debug/events"):
            let since = UInt64(Self.queryValue("since", in: request.query) ?? "") ?? 0
            let events = DiagnosticsCenter.shared.events(since: since)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = (try? encoder.encode(EventsBody(events: events))) ?? Data("{}".utf8)
            send(httpResponse(status: "200 OK", contentType: "application/json", body: body), id: id)
        case ("GET", "/debug/report"):
            guard let handler = onDebugReport else {
                send(json(ErrorBody(ok: false), status: "503 Service Unavailable"), id: id)
                return
            }
            Task {
                let body = await handler()
                self.queue.async {
                    self.send(self.httpResponse(status: "200 OK", contentType: "application/json", body: body), id: id)
                }
            }
        case ("GET", "/debug/windows"):
            guard let handler = onDebugWindows else {
                send(json(ErrorBody(ok: false), status: "503 Service Unavailable"), id: id)
                return
            }
            let timeout = mainActorStartTimeout
            Task {
                let outcome = await MainActorStart.run(startWithin: timeout) { handler() }
                self.queue.async {
                    guard case .done(let body) = outcome else { return self.sendMainThreadBusy(id: id) }
                    self.send(self.httpResponse(status: "200 OK", contentType: "application/json", body: body), id: id)
                }
            }
        case ("GET", "/debug/snapshot"):
            guard let handler = onDebugSnapshot else {
                send(json(ErrorBody(ok: false), status: "503 Service Unavailable"), id: id)
                return
            }
            let raw = Self.queryValue("window", in: request.query)
            let window = raw.flatMap { Int($0) }
            if raw != nil, window == nil {
                send(json(ErrorBody(ok: false), status: "400 Bad Request"), id: id)
                return
            }
            let timeout = mainActorStartTimeout
            Task {
                let outcome = await MainActorStart.run(startWithin: timeout) { handler(window) }
                self.queue.async {
                    guard case .done(let png) = outcome else { return self.sendMainThreadBusy(id: id) }
                    if let png {
                        self.send(self.httpResponse(status: "200 OK", contentType: "image/png", body: png), id: id)
                    } else {
                        self.send(self.json(ErrorBody(ok: false), status: "404 Not Found"), id: id)
                    }
                }
            }
        case ("POST", "/debug/action"):
            guard let action = DebugAction.decode(from: request.body) else {
                send(json(DebugActionOutcome(ok: false, error: "bad_action"), status: "400 Bad Request"), id: id)
                return
            }
            guard let handler = onDebugAction else {
                send(json(DebugActionOutcome(ok: false, error: "unsupported"), status: "503 Service Unavailable"), id: id)
                return
            }
            let timeout = mainActorStartTimeout
            Task {
                let outcome = await MainActorStart.run(startWithin: timeout) { await handler(action) }
                self.queue.async {
                    guard case .done(let result) = outcome else { return self.sendMainThreadBusy(id: id) }
                    self.send(self.json(result, status: "200 OK"), id: id)
                }
            }
        case ("GET", "/debug/state"):
            guard let handler = onDebugState else {
                send(json(ErrorBody(ok: false), status: "503 Service Unavailable"), id: id)
                return
            }
            let timeout = mainActorStartTimeout
            Task {
                let outcome = await MainActorStart.run(startWithin: timeout) { handler() }
                self.queue.async {
                    guard case .done(let body) = outcome else { return self.sendMainThreadBusy(id: id) }
                    self.send(self.httpResponse(status: "200 OK", contentType: "application/json", body: body), id: id)
                }
            }
        default:
            send(json(ErrorBody(ok: false), status: "404 Not Found"), id: id)
        }
    }

    /// A main-actor hook could not start in time; the hook was abandoned.
    private func sendMainThreadBusy(id: ObjectIdentifier) {
        send(json(DebugActionOutcome(ok: false, error: "main_thread_busy"), status: "503 Service Unavailable"), id: id)
    }

    // MARK: - Command dispatch

    /// Enqueues a command onto the serial command chain; each command awaits
    /// the previous handler before running.
    private func dispatch(_ command: RelayCommand) {
        let handler = onInput
        queue.async {
            let previous = self.lastCommandTask
            let task = Task.detached(priority: .userInitiated) {
                _ = await previous?.value
                await handler?(command)
            }
            self.lastCommandTask = task
        }
    }

    // MARK: - Writing

    private func broadcast(_ text: String) {
        lastBroadcastAt = Date()
        let payload = Data(text.utf8)
        for (id, connection) in connections where connection.isSSE {
            send(payload, id: id)
        }
    }

    private func send(_ data: Data, id: ObjectIdentifier) {
        guard let connection = connections[id] else { return }
        connection.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.queue.async { self.drop(id) }
            }
        })
    }

    // MARK: - Encoding helpers

    private struct PairBody: Encodable {
        let ok: Bool
        let host: String
        let rev: Int
    }

    private struct InputBody: Decodable {
        let conversationID: String?
        let text: String
    }

    private struct StopBody: Decodable {
        let conversationID: String
    }

    private struct InputAck: Encodable {
        let ok: Bool
        let conversationID: String?
    }

    private struct ErrorBody: Encodable {
        let ok: Bool
    }
    private struct EventsBody: Encodable {
        let events: [DiagnosticsEvent]
    }

    private static func queryValue(_ name: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.first.map(String.init) == name else { continue }
            return parts.count == 2 ? String(parts[1]) : ""
        }
        return nil
    }


    private func json<T: Encodable>(_ value: T, status: String) -> Data {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return httpResponse(status: status, contentType: "application/json", body: body)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    private func httpResponse(status: String, contentType: String, body: Data) -> Data {
        var response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        return data
    }
}

/// Thread-safe box for the listener startup failure, signalled through a
/// semaphore whose waiter runs on a different thread than the listener queue.
private final class FailureBox: @unchecked Sendable {
    var failure: Error?
    /// Set once `start` has been answered; later states are only logged.
    var settled = false
}
