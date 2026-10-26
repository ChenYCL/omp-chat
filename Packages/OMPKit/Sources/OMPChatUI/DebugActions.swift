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

        case .send(let raw, let text):
            guard let id = targetID(raw, in: model) else { return .failure("no such conversation") }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure("消息是空的") }
            guard !model.isStreaming else { return .failure("还在回复") }
            if model.selectedConversationID != id { model.selectedConversationID = id }
            let before = model.selectedConversation?.messages.count ?? 0
            // Not awaited: with tools on, the reply can stop at an approval
            // card that only a later `approve` action resolves.
            Task { await model.sendNow(text: text, attachments: []) }
            let sent = await waitUntil { (model.selectedConversation?.messages.count ?? 0) > before || model.errorMessage != nil }
            if sent, (model.selectedConversation?.messages.count ?? 0) > before { return .success }
            return .failure(model.errorMessage ?? "没有发出")

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
            /// The selected thread's side chat; never part of the thread.
            var sideChat: [SideChatLine]
            var permissionMode: String
            var toolsEnabled: Bool
            /// The reply to the last user message. An agent reply spans one
            /// assistant message per model turn, so this covers all of them:
            /// every tool call in order, and the last message's text.
            var lastReply: ReplyLine?
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
        struct State: Encodable {
            var selectedID: String?
            var selected: Selected?
            var draft: String
            var conversationCount: Int
            /// Non-archived chats with an unread reply, so a scenario that
            /// runs 全部标为已读 can put back exactly what was unread before.
            var unreadIDs: [String]
            /// What the 待处理 group lists.
            var priorityIDs: [String]
            var sidebarGrouping: String
            var sidebarFilter: String
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
                sideChat: model.sideChat(for: $0.id).map {
                    SideChatLine(role: $0.role.rawValue, text: $0.concatenatedText, status: $0.status.rawValue, error: $0.errorText)
                },
                permissionMode: model.permissionMode(for: $0.id).rawValue,
                toolsEnabled: model.toolsEnabled(for: $0.id),
                lastReply: replyLine($0.messages)
            )
        }
        let state = State(
            selectedID: model.selectedConversationID?.uuidString,
            selected: selected,
            draft: model.draft,
            conversationCount: model.conversations.count,
            unreadIDs: model.conversations.filter { $0.hasUnread && !$0.isArchived }.map(\.id.uuidString).sorted(),
            priorityIDs: model.priorityConversationIDs().map(\.uuidString).sorted(),
            sidebarGrouping: model.settings.sidebarGrouping,
            sidebarFilter: model.settings.sidebarFilter,
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

    /// The named conversation, or the selected one when no id was given.
    private static func targetID(_ raw: String?, in model: ChatAppModel) -> UUID? {
        guard let raw else { return model.selectedConversationID }
        return existingID(raw, in: model)
    }

    /// Model methods report failure as an optional message.
    private static func outcome(_ failure: String?) -> DebugActionOutcome {
        failure.map(DebugActionOutcome.failure) ?? .success
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
