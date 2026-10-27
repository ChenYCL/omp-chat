#if os(macOS)
import AppKit
import OMPCore

/// Executes the token-gated `POST /debug/action` automation actions and
/// answers `GET /debug/state` for the macOS host.
///
/// Everything here must work while the app is in the background — that is the
/// whole point of the route: the integrator black-box tests the app without
/// bringing it to the front. Actions therefore go through the same model
/// methods the menus call, never through synthetic clicks on windows.
///
/// Settings: SwiftUI exposes the Settings scene only to the `openSettings`
/// environment action, which views can call but a model cannot, and
/// `NSApplication` itself does not answer `showSettingsWindow:` — so the
/// handler performs the app menu's own 设置… item (`⌘,`). SwiftUI keeps the
/// Settings window in `NSApp.windows` after it closes, so "open" means
/// *visible*, and both handlers wait for the window to actually change.
@MainActor
enum DebugActions {
    /// Runs one action and reports success or a short error.
    static func perform(_ action: DebugAction, model: ChatAppModel) async -> DebugActionOutcome {
        switch action {
        case .select(let raw):
            guard let id = existingID(raw, in: model) else { return .failure("no such conversation") }
            model.selectedConversationID = id
            return .success

        case .newChat:
            _ = model.newConversation()
            return .success

        case .sidePanel(let open, let tab):
            model.toggleSidePanel(open: open, tab: tab)
            return .success

        case .openSettings(let section):
            // Set before opening so a freshly created window picks it up too.
            if let section { model.requestedSettingsSection = section }
            return await openSettings()

        case .closeSettings:
            return await closeSettings()

        case .setDraft(let text):
            model.draft = text
            return .success

        case .format(let style):
            apply(style, model: model)
            return .success

        case .setGoal(let raw, let goal):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            model.setGoal(id, goal)
            return .success

        case .sidebar(let grouping, let filter):
            var settings = model.settings
            if let grouping { settings.sidebarGrouping = grouping.rawValue }
            if let filter { settings.sidebarFilter = filter.rawValue }
            await model.saveSettings(settings)
            return .success

        case .markAllRead:
            model.markAllRead()
            return .success

        case .setUnread(let raw, let unread):
            guard let id = existingID(raw, in: model) else { return .failure("no such conversation") }
            model.setUnread(id, unread: unread)
            return .success

        case .continueIn(let raw, let target):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            switch target {
            case .local:
                return outcome(model.continueConversation(id, directory: nil))
            case .folder(let path):
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return .failure("not a directory: \(path)") }
                return outcome(model.continueConversation(id, directory: path))
            case .worktree:
                return outcome(await model.continueInNewWorktree(id))
            }

        case .fork(let raw, let mode):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            return outcome(await model.forkConversation(id, mode: mode))

        case .openLink(let raw):
            guard let url = URL(string: raw), let id = ThreadLink.threadID(in: url) else {
                return .failure("not an ompchat thread link")
            }
            model.openThreadLink(url)
            return model.selectedConversationID == id ? .success : .failure("no such conversation")

        case .delete(let raw):
            guard let id = existingID(raw, in: model) else { return .failure("no such conversation") }
            model.deleteConversation(id)
            return .success

        case .dismissError:
            model.dismissError()
            return .success

        case .sideChat(let raw, let text):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            return outcome(model.sendSideChat(text, about: id))

        case .clearSideChat(let raw):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            model.clearSideChat(id)
            return .success

        case .stopSideChat:
            model.stopSideChat()
            return .success

        case .browserOpenTab(let url, let rightOf):
            var anchor: UUID?
            if let rightOf {
                guard let id = tabID(rightOf, in: model) else { return .failure("no such tab") }
                anchor = id
            }
            model.openBrowserTab(url: url, rightOf: anchor)
            return .success

        case .browserCloseTab(let raw):
            guard let id = tabID(raw, in: model) else { return .failure("no such tab") }
            model.closeBrowserTab(id)
            return .success

        case .browserDuplicateTab(let raw):
            guard let id = tabID(raw, in: model) else { return .failure("no such tab") }
            return model.duplicateBrowserTab(id) == nil ? .failure("duplicate failed") : .success

        case .browserRenameTab(let raw, let title):
            guard let id = tabID(raw, in: model) else { return .failure("no such tab") }
            model.renameBrowserTab(id, to: title)
            return .success

        case .browserSelectTab(let raw):
            guard let id = tabID(raw, in: model) else { return .failure("no such tab") }
            model.selectBrowserTab(id)
            return .success

        case .browserNavigate(let raw, let url):
            guard let id = tabID(raw, in: model) else { return .failure("no such tab") }
            model.navigateBrowserTab(id, to: url)
            return .success

        case .git(let raw, let operation):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            guard let directory = model.conversations.first(where: { $0.id == id })?.workingDirectory else {
                return .failure("这个对话没有绑定工作目录")
            }
            return await runGit(operation, in: directory, model: model)

        case .sidebarOp(let operation):
            return sidebar(operation, model: model)

        case .send(let raw, let text):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure("消息是空的") }
            return await deliver(to: id, model: model) {
                // Not awaited: with tools on, the reply can stop at an
                // approval card that only a later `approve` action resolves.
                Task { await model.sendNow(text: text, attachments: []) }
            }

        case .sendDraft(let raw):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            if model.selectedConversationID != id { model.selectedConversationID = id }
            // The send button's path: readable mentions become tokens, the
            // draft and its picks are cleared.
            guard !model.draftForSending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("草稿是空的")
            }
            // Worktree mode's first message creates the checkout and runs the
            // environment's setup script before it is sent.
            let createsWorktree = model.worktreeMode(for: id) && model.managedWorktree(for: id) == nil
            return await deliver(to: id, model: model, within: createsWorktree ? .seconds(600) : .seconds(2)) { model.send() }

        case .stop:
            model.stop()
            return .success

        case .approve(let raw, let decision):
            guard let id = UUID(uuidString: raw), model.pendingApprovals.contains(where: { $0.id == id }) else {
                return .failure("no such approval")
            }
            model.resolveApproval(id, decision)
            return .success

        case .setPermissionMode(let raw, let mode):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            model.setPermissionMode(mode, for: id)
            return .success

        case .setToolsEnabled(let raw, let enabled):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            model.setToolsEnabled(enabled, for: id)
            return .success

        case .setAccess(let raw, let access):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            model.setAgentAccess(access, for: id)
            return .success

        case .scheduledTask(let operation):
            return await scheduledTask(operation, model: model)

        case .openFile(let path, let line):
            model.openFileInSidePanel(path, line: line)
            return .success

        case .codeReview(let raw):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            return outcome(await model.startCodeReview(for: id))

        case .queued(let raw, let queuedRaw, let op):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            guard let queuedID = UUID(uuidString: queuedRaw),
                  model.queuedMessages(for: id).contains(where: { $0.id == queuedID }) else {
                return .failure("no such queued message")
            }
            switch op {
            case .sendNow:
                // Refused (and left queued) while another conversation replies.
                if model.isStreaming, model.streamingConversationID != id { return .failure("另一个对话正在回复") }
                Task { await model.sendQueuedNow(queuedID, in: id) }
                let gone = await waitUntil { !model.queuedMessages(for: id).contains { $0.id == queuedID } }
                return gone ? .success : .failure(model.errorMessage ?? "没有发出")
            case .edit:
                model.editQueued(queuedID, in: id)
            case .delete:
                model.removeQueued(queuedID, in: id)
            }
            return .success

        case .compact(let raw):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            return outcome(await model.compactConversation(id))

        case .mentionSearch(let raw, let query, let trigger):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            let result = await model.mentionSearch(query: query, trigger: trigger, for: id)
            struct Line: Encodable {
                var token: String
                var kind: String
                var section: String
                var title: String
                var detail: String
                var badge: String
            }
            struct Body: Encodable {
                var candidates: [Line]
                var fileSearchFailed: Bool
            }
            let body = Body(
                candidates: result.candidates.map {
                    Line(token: $0.mention.token, kind: $0.mention.kind.rawValue, section: $0.section.rawValue,
                         title: $0.title, detail: $0.detail, badge: $0.badge)
                },
                fileSearchFailed: result.fileSearchFailed
            )
            let data = (try? JSONEncoder().encode(body)) ?? Data("{}".utf8)
            return DebugActionOutcome(ok: true, error: nil, detail: String(decoding: data, as: UTF8.self))

        case .pickMention(let raw, let token):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            // Exactly one well-formed token, as the list hands out.
            let found = ComposerMention.mentions(in: token)
            guard found.count == 1, let mention = found.first, mention.token == token else {
                return .failure("not a mention token")
            }
            // The pick edits the draft on screen, which is the selected thread's.
            if model.selectedConversationID != id { model.selectedConversationID = id }
            model.pickMention(mention)
            return .success

        case .transcribeFile(let raw, let path, let locale):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            // The text lands in the draft on screen, which is the selected thread's.
            if model.selectedConversationID != id { model.selectedConversationID = id }
            return outcome(await model.transcribeIntoDraft(fileURL: URL(fileURLWithPath: path), localeIdentifier: locale))

        case .mcpInstall(let entryID, let values):
            guard let entry = MCPCatalog.entries.first(where: { $0.id == entryID }) else {
                return .failure("no such catalog entry")
            }
            var settings = model.settings
            let installation: MCPCatalogEntry.Installation
            do {
                installation = try entry.install(
                    values: values, existingIDs: Set(model.mcp.servers.map(\.id)),
                    home: HostExecutor.realHomeDirectory()
                )
            } catch {
                return .failure(error.localizedDescription)
            }
            // Same order as the pane: secrets into the vault first, so a
            // failed write never leaves a server without its key.
            for (variable, value) in installation.secrets
            where !model.setMCPSecret(value, serverID: installation.config.id, variable: variable) {
                return .failure("无法把「\(variable)」写入钥匙串")
            }
            settings.mcpServers.append(installation.config)
            await model.saveSettings(settings)
            return .success

        case .mcpRemove(let serverID):
            var settings = model.settings
            guard let config = settings.mcpServers.first(where: { $0.id == serverID }) else {
                return .failure("no such server")
            }
            for variable in config.env.keys {
                model.setMCPSecret(nil, serverID: serverID, variable: variable)
            }
            settings.mcpServers.removeAll { $0.id == serverID }
            await model.saveSettings(settings)
            return .success

        case .setWebSearch(let enabled):
            model.webSearchEnabled = enabled
            return .success

        case .setPhoneAccess(let enabled):
            var settings = model.settings
            settings.relayAllowShell = enabled
            await model.saveSettings(settings)
            return .success

        case .undo:
            // undoLast returns the entry's confirmation when it restored
            // something, and the reason otherwise (target since deleted).
            // The confirmation stays readable as `undoToast` in /debug/state.
            guard let confirmation = model.undoStack.top?.confirmation else { return .failure("nothing to undo") }
            let text = model.undoLast() ?? ""
            return text == confirmation ? .success : .failure(text)

        case .dismissUndo:
            model.dismissUndoToast()
            return .success

        case .toggleSidebar:
            // The sidebar's visibility is the root view's state; ⌘B reaches it
            // through this notification too.
            NotificationCenter.default.post(name: .ompToggleSidebar, object: nil)
            return .success

        case .localEnvironment(let operation):
            return localEnvironment(operation, model: model)

        case .worktree(let operation):
            return await worktree(operation, model: model)

        case .externalImport(let home, let operation):
            return await externalImport(home: home, operation, model: model)

        case .setLinkDestination(let value):
            model.updateLinkDestination(value)
            return .success

        case .hideImportPrompt:
            model.externalImportPrompt = nil
            return .success

        case .clickLink(let raw):
            guard let url = URL(string: raw) else { return .failure("bad url") }
            switch model.openMessageLink(url) {
            case .sidePanelTab(let tab): return DebugActionOutcome(ok: true, error: nil, detail: "tab:\(tab.uuidString)")
            case .systemBrowser: return DebugActionOutcome(ok: true, error: nil, detail: "system")
            }

        case .computerUseAdd(let raw):
            let server = raw.map { ComputerUseCatalog.server(id: $0) } ?? ComputerUseCatalog.servers.first
            guard let server else { return .failure("no such computer-use server") }
            var settings = model.settings
            guard !settings.mcpServers.contains(where: { $0.id == server.id }) else {
                return .failure("already added")
            }
            // Same config the pane's 添加 stores, enabled; the server still
            // has no macOS permission and nothing here calls one of its tools.
            var config = server.config
            config.enabled = true
            settings.mcpServers.append(config)
            await model.saveSettings(settings)
            return .success
        }
    }

    /// Runs one 改动-tab write through the model, so the tab re-reads status
    /// exactly as it does after a click.
    private static func runGit(_ operation: DebugGitOperation, in directory: String, model: ChatAppModel) async -> DebugActionOutcome {
        do {
            switch operation {
            case .stage(let paths):
                try await model.changeWorkingTree { try GitWorkingTree.stage(paths, in: directory) }
            case .unstage(let paths):
                try await model.changeWorkingTree { try GitWorkingTree.unstage(paths, in: directory) }
            case .stageAll:
                try await model.changeWorkingTree { try GitWorkingTree.stageAll(in: directory) }
            case .unstageAll:
                try await model.changeWorkingTree { try GitWorkingTree.unstageAll(in: directory) }
            case .discard(let path):
                try await model.changeWorkingTree { try GitWorkingTree.discard(path, in: directory) }
            case .commit(let message):
                _ = try await model.changeWorkingTree { try GitWorkingTree.commit(message: message, in: directory) }
            case .push:
                _ = try await model.changeWorkingTree { try GitWorkingTree.push(in: directory) }
            }
            return .success
        } catch let failure as GitWorkingTree.Failure {
            return .failure(failure.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Serialized app state for the integrator: what the model selected, the
    /// composer draft, sidebar organisation and which of the app's own windows
    /// are showing (titles only, no pixels).
    static func stateJSON(model: ChatAppModel) -> Data {
        struct Selected: Encodable {
            var id: String
            var title: String
            var goal: String?
            var workingDirectory: String?
            var messageCount: Int
            var hasUnread: Bool
            var isPinned: Bool
            var isArchived: Bool
            /// Project or custom section it is filed under.
            var groupID: String?
            /// The row's status tags (`ConversationRowTag` raw values), the
            /// primary one first, as the sidebar shows them.
            var rowTags: [String]
            /// The selected thread's side chat; never part of the thread.
            var sideChat: [SideChatLine]
            var permissionMode: String
            var toolsEnabled: Bool
            /// The entry the 「工具与权限」 menu checks (`AgentAccess.wireValue`).
            var access: String
            /// What the composer button reads, e.g. 仅聊天 or 完全访问.
            var accessLabel: String
            /// The reply to the last user message. An agent reply spans one
            /// assistant message per model turn, so this covers all of them:
            /// every tool call in order, and the last message's text.
            var lastReply: ReplyLine?
            /// A 用 Codex 审查 thread, and how its review ended.
            var isCodeReview: Bool
            /// running / reported / unreported; nil for other threads.
            var reviewOutcome: String?
            /// Follow-ups waiting for the running reply, oldest first.
            var queued: [QueuedLine]
            var isCompacting: Bool
            /// The summary that stands in for the earlier messages, if any.
            var compaction: CompactionLine?
            /// Every message in order, text trimmed; notes such as the
            /// unanswered-follow-up one are in `error`.
            var transcript: [MessageLine]
            /// The composer's 本地 / Worktree switch, and the managed worktree
            /// the chat runs in (or ran in, when `worktreeDeleted`).
            var worktreeMode: Bool
            var managedWorktreeID: String?
            var worktreeDeleted: Bool
            /// Environment files for the working directory (own, then
            /// inherited) and the one in force.
            var environments: [EnvironmentLine]
            var selectedEnvironment: String?
        }
        struct EnvironmentLine: Encodable {
            var path: String
            var name: String?
            var inherited: Bool
            var actions: [String]
            var parseError: String?
        }
        struct WorktreeLine: Encodable {
            var id: String
            var path: String
            var sourceRoot: String
            var baseCommit: String
            /// nil while detached, as managed worktrees start.
            var branch: String?
            var conversationIDs: [String]
            var environmentPath: String?
            var deleted: Bool
            var hasSnapshot: Bool
        }
        struct ImportedLine: Encodable {
            var id: String
            var title: String
            var importedFrom: String
            var workingDirectory: String?
        }
        struct WorktreeProgressLine: Encodable {
            var conversationID: String
            /// fetching / checkingOut / settingUp / failed
            var phase: String
            var detail: String?
        }
        struct QueuedLine: Encodable {
            var id: String
            var text: String
            var held: Bool
        }
        struct CompactionLine: Encodable {
            var summary: String
            var coveredThroughID: String
            var tokensBefore: Int
            var tokensAfter: Int
        }
        struct MessageLine: Encodable {
            var id: String
            var role: String
            /// What the bubble shows: the written text, without attached
            /// mention content (the model still reads all of it).
            var text: String
            var status: String
            var error: String?
            /// Mention chips under the bubble (`@notes.md`, `$review`).
            var attached: [String]
            /// The 提及说明 line under the bubble: mentions left out or cut.
            var mentionNotes: [String]
        }
        struct ReplyLine: Encodable {
            var text: String
            var status: String
            var error: String?
            var toolCalls: [ToolCallLine]
        }
        struct ToolCallLine: Encodable {
            var id: String
            var name: String
            var arguments: String
            /// Nil until the call has a result.
            var result: String?
            var isError: Bool
        }
        struct MCPServerLine: Encodable {
            var id: String
            var name: String
            var origin: String
            var enabled: Bool
            /// disabled / needsRuntime / connecting / ready / failed
            var status: String
            var toolCount: Int?
            /// The missing runtime, or the failure reason and stderr tail.
            var detail: String?
            var tools: [String]
        }
        struct ApprovalLine: Encodable {
            var id: String
            var conversationID: String
            var callID: String
            var toolName: String
            var source: String
            var risk: String
            var summary: String
        }
        struct SideChatLine: Encodable {
            var role: String
            var text: String
            var status: String
            var error: String?
        }
        struct BrowserTabLine: Encodable {
            var id: String
            var title: String
            var url: String
            var selected: Bool
        }
        struct UndoToastLine: Encodable {
            var message: String
            var offersUndo: Bool
        }
        struct ScheduledTaskLine: Encodable {
            var id: String
            var title: String
            /// active / paused / completed
            var status: String
            var summary: String
            /// 今天 09:00 / 明天 09:00 / 未安排 …
            var nextRunLabel: String
            var nextRunAt: Date?
            var runCount: Int
            var lastRunConversationID: String?
            var lastSkipReason: String?
            var running: Bool
        }
        struct GroupLine: Encodable {
            var id: String
            var name: String
            /// A custom section rather than a project.
            var isSection: Bool
            var conversationIDs: [String]
        }
        struct State: Encodable {
            var selectedID: String?
            var selected: Selected?
            var draft: String
            /// The mentions the draft holds, as the chips above the field
            /// show them (`@说明.md`, `$review`).
            var draftMentions: [String]
            /// idle / starting / listening / finishing / transcribing / done /
            /// failed / cancelled, and the error text when failed.
            var dictation: String
            var dictationError: String?
            var conversationCount: Int
            /// Chats brought over by 从其他 AI 应用导入 (`importedFrom` is
            /// `claude-code:<id>` / `cursor:<id>`), so a scenario can find and
            /// remove what it imported.
            var importedConversations: [ImportedLine]
            /// Non-archived chats with an unread reply, so a scenario that
            /// runs 全部标为已读 can put back exactly what was unread before.
            var unreadIDs: [String]
            /// What the 待处理 group lists.
            var priorityIDs: [String]
            var sidebarGrouping: String
            var sidebarFilter: String
            var webSearchEnabled: Bool
            /// 设置 → 远程控制 → 允许手机访问文件与终端.
            var phoneAccess: Bool
            /// The undo toast on screen: its text and whether it offers 撤销.
            var undoToast: UndoToastLine?
            /// Undoable actions left, newest first (their toast texts).
            var undoHistory: [String]
            /// Projects and custom sections in sidebar order, with members.
            var groups: [GroupLine]
            /// 定时任务, in sidebar order.
            var scheduledTasks: [ScheduledTaskLine]
            /// A file the 文件 tab was asked to show and has not picked up yet.
            var pendingFileRequest: String?
            /// A command the side-panel terminal was asked to run and has not
            /// picked up yet.
            var pendingTerminalCommand: String?
            /// 设置 → 浏览器 → 链接打开位置: app / system.
            var linkDestination: String
            /// Managed worktrees, deleted ones included (they keep a snapshot).
            var managedWorktrees: [WorktreeLine]
            var worktreeProgress: WorktreeProgressLine?
            /// Conversation id → the 交接 step running for it.
            var handoffProgress: [String: String]
            /// The first-launch 从其他 AI 应用导入 prompt is up.
            var importPromptShown: Bool
            var sidePanelOpen: Bool
            var sidePanelTab: String?
            var sideChatStreaming: Bool
            /// The banner above the thread, if one is showing.
            var errorMessage: String?
            var isStreaming: Bool
            /// Approval cards waiting, oldest first.
            var pendingApprovals: [ApprovalLine]
            /// Tool calls executing right now.
            var runningToolCallIDs: [String]
            /// 设置 → MCP 服务器, including plugin servers.
            var mcpServers: [MCPServerLine]
            var browserTabs: [BrowserTabLine]
            var settingsOpen: Bool
            var windowTitles: [String]
        }
        func replyLine(_ messages: [ChatMessage]) -> ReplyLine? {
            let turn = messages.reversed().prefix { $0.role != .user }.reversed().filter { $0.role == .assistant }
            guard let last = turn.last else { return nil }
            let parts = turn.flatMap(\.parts)
            let results = parts.compactMap { part -> ToolResult? in
                if case .toolResult(let result) = part { result } else { nil }
            }
            let calls = parts.compactMap { part -> ToolCallLine? in
                guard case .toolCall(let call) = part else { return nil }
                let result = results.first { $0.callID == call.id }
                return ToolCallLine(
                    id: call.id, name: call.name, arguments: call.argumentsJSON,
                    result: result.map { String($0.outputText.prefix(2000)) }, isError: result?.isError ?? false
                )
            }
            return ReplyLine(
                text: last.concatenatedText, status: last.status.rawValue,
                error: last.errorText, toolCalls: calls
            )
        }
        let selected = model.selectedConversation.map {
            Selected(
                id: $0.id.uuidString,
                title: $0.title,
                goal: $0.goal,
                workingDirectory: $0.workingDirectory,
                messageCount: $0.messages.count,
                hasUnread: $0.hasUnread,
                isPinned: $0.isPinned,
                isArchived: $0.isArchived,
                groupID: $0.projectID?.uuidString,
                rowTags: model.rowStatus(for: $0).tags.map(\.rawValue),
                sideChat: model.sideChat(for: $0.id).map {
                    SideChatLine(role: $0.role.rawValue, text: $0.concatenatedText, status: $0.status.rawValue, error: $0.errorText)
                },
                permissionMode: model.permissionMode(for: $0.id).rawValue,
                toolsEnabled: model.toolsEnabled(for: $0.id),
                access: model.agentAccess(for: $0.id).wireValue,
                accessLabel: model.effectiveAgentAccess(for: $0.id).title,
                lastReply: replyLine($0.messages),
                isCodeReview: $0.isCodeReview,
                reviewOutcome: model.codeReviewOutcome($0.id).map {
                    switch $0 {
                    case .running: "running"
                    case .reported: "reported"
                    case .unreported: "unreported"
                    }
                },
                queued: model.queuedMessages(for: $0.id).map {
                    QueuedLine(id: $0.id.uuidString, text: $0.text, held: $0.isHeld)
                },
                isCompacting: model.isCompacting($0.id),
                compaction: model.compaction(for: $0.id).map {
                    CompactionLine(
                        summary: $0.summary, coveredThroughID: $0.coveredThroughID.uuidString,
                        tokensBefore: $0.tokensBefore, tokensAfter: $0.tokensAfter
                    )
                },
                transcript: $0.messages.map {
                    MessageLine(
                        id: $0.id.uuidString, role: $0.role.rawValue, text: String($0.writtenText.prefix(400)),
                        status: $0.status.rawValue, error: $0.errorText,
                        attached: $0.mentionAttachments.compactMap { $0.mention?.readable },
                        mentionNotes: $0.mentionNotes
                    )
                },
                worktreeMode: model.worktreeMode(for: $0.id),
                managedWorktreeID: (model.managedWorktree(for: $0.id) ?? model.deletedWorktree(forConversation: $0.id))?.id.uuidString,
                worktreeDeleted: model.deletedWorktree(forConversation: $0.id) != nil,
                environments: $0.workingDirectory.map { directory in
                    model.localEnvironments(forProject: directory).map { file in
                        EnvironmentLine(
                            path: file.path, name: file.environment?.name, inherited: file.inherited,
                            actions: file.environment?.actions(for: .current).map(\.name) ?? [],
                            parseError: file.parseError.map { "第 \($0.line) 行：\($0.message)" }
                        )
                    }
                } ?? [],
                selectedEnvironment: $0.workingDirectory.flatMap { model.selectedLocalEnvironmentPath(forProject: $0) }
            )
        }
        let state = State(
            selectedID: model.selectedConversationID?.uuidString,
            selected: selected,
            draft: model.draft,
            draftMentions: model.draftMentions.map(\.readable),
            dictation: {
                switch model.dictationState {
                case .idle: "idle"
                case .starting: "starting"
                case .listening: "listening"
                case .finishing: "finishing"
                case .transcribing: "transcribing"
                case .done: "done"
                case .failed: "failed"
                case .cancelled: "cancelled"
                }
            }(),
            dictationError: {
                if case .failed(let error, _) = model.dictationState { return error.message }
                return nil
            }(),
            conversationCount: model.conversations.count,
            importedConversations: model.conversations.compactMap { conversation in
                conversation.importedFrom.map {
                    ImportedLine(id: conversation.id.uuidString, title: conversation.title, importedFrom: $0,
                                 workingDirectory: conversation.workingDirectory)
                }
            },
            unreadIDs: model.conversations.filter { $0.hasUnread && !$0.isArchived }.map(\.id.uuidString).sorted(),
            priorityIDs: model.priorityConversationIDs().map(\.uuidString).sorted(),
            sidebarGrouping: model.settings.sidebarGrouping,
            sidebarFilter: model.settings.sidebarFilter,
            webSearchEnabled: model.webSearchEnabled,
            phoneAccess: model.settings.relayAllowShell,
            undoToast: model.undoToast.map { UndoToastLine(message: $0.message, offersUndo: $0.offersUndo) },
            undoHistory: model.undoStack.entries.reversed().map(\.message),
            groups: model.projects.map { group in
                GroupLine(
                    id: group.id.uuidString, name: group.name, isSection: group.isCustomSection,
                    conversationIDs: model.conversations.filter { $0.projectID == group.id }.map(\.id.uuidString)
                )
            },
            scheduledTasks: model.scheduledTasks.map { task in
                ScheduledTaskLine(
                    id: task.id.uuidString, title: task.title, status: task.status.rawValue,
                    summary: task.schedule.summary(now: Date(), calendar: model.scheduleCalendar),
                    nextRunLabel: TaskSchedule.nextRunLabel(task.nextRunAt, now: Date(), calendar: model.scheduleCalendar),
                    nextRunAt: task.nextRunAt, runCount: task.runCount,
                    lastRunConversationID: task.lastRunConversationID?.uuidString,
                    lastSkipReason: task.lastSkipReason, running: model.isScheduledTaskRunning(task.id)
                )
            },
            pendingFileRequest: model.sidePanelFileRequest.map { request in
                request.line.map { "\(request.path):\($0)" } ?? request.path
            },
            pendingTerminalCommand: model.sidePanelTerminalRequest?.command,
            linkDestination: model.settings.linkDestination,
            managedWorktrees: model.managedWorktrees.map { tree in
                WorktreeLine(
                    id: tree.id.uuidString, path: tree.path, sourceRoot: tree.sourceRoot, baseCommit: tree.baseCommit,
                    branch: tree.branch, conversationIDs: tree.conversationIDs.map(\.uuidString),
                    environmentPath: tree.environmentPath, deleted: tree.deletedAt != nil, hasSnapshot: tree.snapshot != nil
                )
            },
            worktreeProgress: model.worktreeProgress.map { progress in
                let phase: String = switch progress.phase {
                case .fetching: "fetching"
                case .checkingOut: "checkingOut"
                case .settingUp: "settingUp"
                case .failed: "failed"
                }
                return WorktreeProgressLine(conversationID: progress.conversationID.uuidString, phase: phase, detail: progress.detail)
            },
            handoffProgress: Dictionary(uniqueKeysWithValues: model.handoffProgress.map { ($0.key.uuidString, $0.value) }),
            importPromptShown: model.externalImportPrompt != nil,
            sidePanelOpen: model.sidePanelOpen,
            sidePanelTab: model.sidePanelOpen ? model.sidePanelTab.rawValue : nil,
            sideChatStreaming: model.sideChatStreamingID != nil,
            errorMessage: model.errorMessage,
            isStreaming: model.isStreaming,
            pendingApprovals: model.pendingApprovals.map {
                ApprovalLine(
                    id: $0.id.uuidString, conversationID: $0.conversationID.uuidString, callID: $0.callID,
                    toolName: $0.toolName, source: $0.source, risk: $0.risk.rawValue, summary: $0.summary
                )
            },
            runningToolCallIDs: model.runningToolCallIDs.sorted(),
            mcpServers: model.mcp.servers.map { config in
                let line: (String, Int?, String?)
                switch model.mcp.status(of: config.id) {
                case .disabled: line = ("disabled", nil, nil)
                case .needsRuntime(let runtime): line = ("needsRuntime", nil, runtime.rawValue)
                case .connecting: line = ("connecting", nil, nil)
                case .ready(let count): line = ("ready", count, nil)
                case .failed(let reason, let log): line = ("failed", nil, ([reason] + log.suffix(5)).joined(separator: "\n"))
                }
                return MCPServerLine(
                    id: config.id, name: config.name, origin: config.origin, enabled: config.enabled,
                    status: line.0, toolCount: line.1, detail: line.2,
                    tools: (model.mcp.tools[config.id] ?? []).map(\.name)
                )
            },
            browserTabs: model.browserTabs.tabs.map {
                BrowserTabLine(
                    id: $0.id.uuidString, title: $0.displayTitle, url: $0.url,
                    selected: $0.id == model.browserTabs.selectedID
                )
            },
            settingsOpen: visibleSettingsWindow() != nil,
            windowTitles: AppSnapshot.windows().filter(\.visible).map(\.title).filter { !$0.isEmpty }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(state)) ?? Data("{}".utf8)
    }

    // MARK: - Helpers

    /// A UUID string that names a conversation in the model.
    private static func existingID(_ raw: String, in model: ChatAppModel) -> UUID? {
        guard let id = UUID(uuidString: raw), model.conversations.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    /// A UUID string that names an open browser tab.
    private static func tabID(_ raw: String, in model: ChatAppModel) -> UUID? {
        guard let id = UUID(uuidString: raw), model.browserTabs.tab(id) != nil else { return nil }
        return id
    }

    /// Runs `start` (which kicks off a send without awaiting it) for `id` and
    /// waits until the message is in the thread, or queued when the thread
    /// was busy. Same rule as the desktop composer: a reply in another
    /// conversation blocks; one in this conversation (or a compaction of it)
    /// takes the message as a queued follow-up.
    private static func deliver(
        to id: UUID, model: ChatAppModel, within timeout: Duration = .seconds(2), start: () -> Void
    ) async -> DebugActionOutcome {
        if model.isStreaming, model.streamingConversationID != id {
            return .failure("另一个对话正在回复")
        }
        if model.selectedConversationID != id { model.selectedConversationID = id }
        let busy = model.isStreaming || model.isCompacting(id)
        let before = model.selectedConversation?.messages.count ?? 0
        let queuedBefore = model.queuedMessages(for: id).count
        start()
        if busy {
            let queued = await waitUntil { model.queuedMessages(for: id).count > queuedBefore }
            return queued ? .success : .failure(model.errorMessage ?? "没有排进队列")
        }
        let sent = await waitUntil(timeout) { (model.selectedConversation?.messages.count ?? 0) > before || model.errorMessage != nil }
        if sent, (model.selectedConversation?.messages.count ?? 0) > before { return .success }
        return .failure(model.errorMessage ?? "没有发出")
    }

    /// The named conversation, or the selected one when no id was given.
    private static func targetID(_ raw: String?, in model: ChatAppModel) -> UUID? {
        guard let raw else { return model.selectedConversationID }
        return existingID(raw, in: model)
    }

    private static func scheduledTask(_ operation: DebugScheduledTaskOperation, model: ChatAppModel) async -> DebugActionOutcome {
        func task(_ raw: String) -> UUID? {
            UUID(uuidString: raw).flatMap { id in model.scheduledTasks.contains { $0.id == id } ? id : nil }
        }
        switch operation {
        case .add(let title, let prompt, let schedule, let target, let directory, let mode):
            if let mode, PermissionMode(rawValue: mode) == nil { return .failure("unknown permission mode") }
            let draft = ScheduledTask(
                title: title, prompt: prompt, schedule: schedule, target: target,
                workingDirectory: directory, permissionMode: mode
            )
            // The editor's own checks, in the order its fields appear.
            let errors = draft.validationErrors(now: Date())
            let order: [ScheduledTask.Field] = [.title, .prompt, .schedule, .workingDirectory]
            let messages = order.compactMap { errors[$0] }
            guard messages.isEmpty else { return .failure(messages.joined(separator: "；")) }
            model.addScheduledTask(draft)
            return .success
        case .pause(let raw):
            guard let id = task(raw) else { return .failure("no such scheduled task") }
            model.pauseScheduledTask(id)
            return .success
        case .resume(let raw):
            guard let id = task(raw) else { return .failure("no such scheduled task") }
            return outcome(model.resumeScheduledTask(id))
        case .delete(let raw):
            guard let id = task(raw) else { return .failure("no such scheduled task") }
            model.deleteScheduledTask(id)
            return .success
        case .runNow(let raw):
            guard let id = task(raw) else { return .failure("no such scheduled task") }
            return outcome(await model.runScheduledTaskNow(id))
        }
    }

    private static func sidebar(_ operation: DebugSidebarOperation, model: ChatAppModel) -> DebugActionOutcome {
        func group(_ raw: String) -> Project? {
            UUID(uuidString: raw).flatMap { id in model.projects.first { $0.id == id } }
        }
        switch operation {
        case .toggleArchive(let raw):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            model.toggleArchive(id)
        case .togglePin(let raw):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            model.togglePin(id)
        case .rename(let raw, let title):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure("名称是空的") }
            model.renameConversation(id, title: title)
        case .move(let raw, let groupID):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            var destination: UUID?
            if let groupID {
                guard let target = group(groupID) else { return .failure("no such project or section") }
                destination = target.id
            }
            model.moveConversation(id, to: destination)
        case .createSection(let name):
            model.createCustomSection(name: name)
        case .renameGroup(let raw, let name):
            guard let target = group(raw) else { return .failure("no such project or section") }
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure("名称是空的") }
            if target.isCustomSection {
                model.renameCustomSection(target.id, name: name)
            } else {
                model.renameProject(target.id, name: name)
            }
        case .deleteGroup(let raw):
            guard let target = group(raw) else { return .failure("no such project or section") }
            if target.isCustomSection {
                model.deleteCustomSection(target.id)
            } else {
                model.deleteProject(target.id)
            }
        case .archiveSection(let raw):
            guard let target = group(raw), target.isCustomSection else { return .failure("no such section") }
            model.archiveConversations(inCustomSection: target.id)
        }
        return .success
    }

    /// Model methods report failure as an optional message.
    private static func outcome(_ failure: String?) -> DebugActionOutcome {
        failure.map(DebugActionOutcome.failure) ?? .success
    }

    private static func localEnvironment(_ operation: DebugLocalEnvironmentOperation, model: ChatAppModel) -> DebugActionOutcome {
        switch operation {
        case .save(let project, let fileName, let toml):
            let environment: LocalEnvironment
            do {
                environment = try LocalEnvironmentTOML.parse(toml)
            } catch let error as LocalEnvironmentParseError {
                return .failure("第 \(error.line) 行：\(error.message)")
            } catch {
                return .failure(error.localizedDescription)
            }
            return outcome(model.saveLocalEnvironment(environment, toProject: project, fileName: fileName))
        case .select(let project, let path):
            model.selectLocalEnvironment(path == "none" ? LocalEnvironmentDiscovery.noneSelection : path, forProject: project)
            return .success
        case .delete(let path):
            return outcome(model.deleteLocalEnvironment(at: path))
        case .runAction(let raw, let index):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            return outcome(model.runEnvironmentAction(index: index, in: id))
        }
    }

    private static func worktree(_ operation: DebugWorktreeOperation, model: ChatAppModel) async -> DebugActionOutcome {
        func registered(_ raw: String) -> UUID? {
            UUID(uuidString: raw).flatMap { id in model.managedWorktrees.contains { $0.id == id } ? id : nil }
        }
        switch operation {
        case .setMode(let raw, let on, let branch):
            guard let id = targetID(raw, in: model), let conversation = model.conversations.first(where: { $0.id == id }) else {
                return .failure("no such conversation")
            }
            // The composer shows the switch only on an empty chat bound to a
            // folder that does not already run in a managed worktree.
            guard conversation.messages.isEmpty, conversation.workingDirectory != nil,
                  model.managedWorktree(for: id) == nil else {
                return .failure("只有绑定了工作目录、还没有消息的对话能切换本地 / Worktree")
            }
            model.setWorktreeMode(on, for: id)
            if on { model.setWorktreeBaseBranch(branch, for: id) }
            return .success
        case .handoff(let raw, let destination):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            return outcome(await model.handoff(id, to: destination))
        case .delete(let raw):
            guard let id = registered(raw) else { return .failure("no such worktree") }
            return outcome(await model.deleteManagedWorktree(id))
        case .restore(let raw):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            return outcome(await model.restoreManagedWorktree(for: id))
        case .cleanup:
            let deleted = await model.runWorktreeCleanup()
            return DebugActionOutcome(ok: true, error: nil, detail: deleted.map(\.uuidString).joined(separator: ","))
        case .newChat(let raw):
            guard let id = registered(raw) else { return .failure("no such worktree") }
            guard let created = model.newChat(inManagedWorktree: id) else { return .failure("无法在这个 worktree 新建对话") }
            return DebugActionOutcome(ok: true, error: nil, detail: created.uuidString)
        }
    }

    /// Points the import at `home` for this one call, so an automated run
    /// reads and writes only a fixture folder.
    private static func externalImport(home: String, _ operation: DebugImportOperation, model: ChatAppModel) async -> DebugActionOutcome {
        let previous = model.externalImportHome
        model.externalImportHome = home
        defer { model.externalImportHome = previous }
        struct EntryLine: Encodable {
            var id: String, provider: String, kind: String, title: String, detail: String, count: Int
            var skippedReason: String?
        }
        struct NotImportedLine: Encodable { var provider: String, kind: String, reason: String }
        struct ScanLine: Encodable { var providers: [String], entries: [EntryLine], notImported: [NotImportedLine] }
        struct ReportLine: Encodable { var id: String, kind: String, title: String, note: String?, failed: Bool }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch operation {
        case .scan:
            let scan = await model.scanExternalAgents()
            let line = ScanLine(
                providers: scan.providersFound.map(\.rawValue),
                entries: scan.entries.map {
                    EntryLine(id: $0.id, provider: $0.provider.rawValue, kind: $0.kind.rawValue, title: $0.title,
                              detail: $0.detail, count: $0.count, skippedReason: $0.skippedReason)
                },
                notImported: scan.notImported.map {
                    NotImportedLine(provider: $0.provider.rawValue, kind: $0.kind.rawValue, reason: $0.reason)
                }
            )
            let data = (try? encoder.encode(line)) ?? Data("{}".utf8)
            return DebugActionOutcome(ok: true, error: nil, detail: String(decoding: data, as: UTF8.self))
        case .run(let ids):
            let report = await model.runExternalImport(ExternalImportSelection(enabledEntryIDs: Set(ids)))
            let lines = report.lines.map {
                ReportLine(id: $0.id, kind: $0.kind.rawValue, title: $0.title, note: $0.note, failed: $0.failed)
            }
            let data = (try? encoder.encode(lines)) ?? Data("[]".utf8)
            return DebugActionOutcome(ok: report.failedCount == 0, error: report.errorSummary,
                                      detail: String(decoding: data, as: UTF8.self))
        }
    }

    private static func apply(_ style: DebugFormatStyle, model: ChatAppModel) {
        switch style {
        case .bold: model.applyMarkdown(.bold)
        case .italic: model.applyMarkdown(.italic)
        case .underline: model.applyMarkdown(.underline)
        case .heading1: model.applyBlockFormat(.heading(1))
        case .heading2: model.applyBlockFormat(.heading(2))
        case .heading3: model.applyBlockFormat(.heading(3))
        case .paragraph: model.applyBlockFormat(.paragraph)
        case .bulletedList: model.applyBlockFormat(.bulletedList)
        case .numberedList: model.applyBlockFormat(.numberedList)
        case .link: model.applyBlockFormat(.link)
        }
    }

    /// Polls `condition` on the main actor until it holds or time runs out.
    private static func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: - Settings scene

    private static func openSettings() async -> DebugActionOutcome {
        if visibleSettingsWindow() != nil { return .success }
        if let retained = settingsWindow() {
            // Closed before: SwiftUI kept it, so bring it back without the
            // menu (which would also activate the app).
            retained.orderFront(nil)
        } else if let item = settingsMenuItem(), let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
        } else {
            return .failure("no 设置… menu item")
        }
        return await waitUntil { visibleSettingsWindow() != nil }
            ? .success : .failure("settings window did not open")
    }

    private static func closeSettings() async -> DebugActionOutcome {
        guard let window = visibleSettingsWindow() else { return .success }
        window.performClose(nil)
        let closed = await waitUntil { visibleSettingsWindow() == nil }
        if closed { return .success }
        window.close()
        return await waitUntil { visibleSettingsWindow() == nil }
            ? .success : .failure("settings window refused to close")
    }

    /// The Settings scene's window, by the identifier SwiftUI assigns it,
    /// whether or not it is on screen.
    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
    }

    private static func visibleSettingsWindow() -> NSWindow? {
        settingsWindow().flatMap { $0.isVisible ? $0 : nil }
    }

    /// The app menu's 设置… item (⌘,).
    private static func settingsMenuItem() -> NSMenuItem? {
        NSApp.mainMenu?.items.first?.submenu?.items.first {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
        }
    }
}
#endif
