import Foundation
import Observation
import OMPCore

/// Drives every screen: owns the workspace, the streaming task and the
/// provider/model selection. Views never talk to networking or storage directly.
@MainActor
@Observable
public final class ChatAppModel {
    // MARK: Published state

    public private(set) var conversations: [Conversation] = []
    public private(set) var providers: [ProviderProfile] = []
    public private(set) var models: [ModelDescriptor] = []
    public private(set) var settings = AppSettings()
    /// In-memory log of the last remote file and shell operations.
    public let remoteOperationLog = RemoteOperationLog()
    private var hostExecutor: HostExecutor
    public private(set) var projects: [Project] = []
    public private(set) var isStreaming = false
    public private(set) var streamingConversationID: UUID?
    public private(set) var errorMessage: String?
    public private(set) var statusMessage: String?
    public private(set) var refreshingProviderIDs: Set<UUID> = []
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

    public var selectedConversationID: UUID? {
        willSet {
            if let oldID = selectedConversationID {
                draftsByConversation[oldID] = draft
                attachmentsByConversation[oldID] = draftAttachments
            }
        }
        didSet {
            if let id = selectedConversationID {
                draft = draftsByConversation[id] ?? ""
                draftAttachments = attachmentsByConversation[id] ?? []
                pastedTexts = []
                replyingTo = nil
                selectedMessageIDs = []
                if let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].hasUnread {
                    conversations[index].hasUnread = false
                    persist(conversations[index])
                }
            } else {
                draft = ""
                draftAttachments = []
                pastedTexts = []
            }
        }
    }
    public var draft = ""
    /// Applies bold / italic / underline to the draft. The composer is a
    /// SwiftUI TextField, which exposes no selection, so this covers the whole
    /// draft; `MarkdownFormatting` already takes a range for when it can.
    public func applyMarkdown(_ style: MarkdownFormatting.Style) {
        draft = MarkdownFormatting.toggle(style, in: draft, selection: nil).text
    }

    /// Applies a block style to the draft's last paragraph (the whole draft
    /// for a link). The composer exposes no caret, so there is no selection.
    public func applyBlockFormat(_ style: MarkdownFormatting.BlockStyle) {
        draft = MarkdownFormatting.applyBlock(style, to: draft)
    }


    /// The composer's 联网 pill. When on, the next request asks the gateway
    /// to search the web server-side (`tools: [{type: web_search}]`).
    public var webSearchEnabled = false
    public var draftAttachments: [MediaRef] = []
    /// Long pastes folded into chips (ChatGPT `composer.pastedTextAttachment`).
    public var pastedTexts: [PastedTextAttachment] = []

    /// Folds a long paste into a chip instead of dumping it into the field.
    public func addPastedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pastedTexts.append(PastedTextAttachment(text: trimmed))
    }

    public func removePastedText(_ id: UUID) {
        pastedTexts.removeAll { $0.id == id }
    }
    /// Message the next send will quote.
    public var replyingTo: ChatMessage?
    /// Messages checked for bulk actions; empty means selection mode is off.
    public var selectedMessageIDs: Set<UUID> = []
    public var showSettings = false

    // MARK: - Settings navigation

    /// A settings section to show next (`ProviderSettingsView.SettingsSection`
    /// raw value). The settings window consumes and clears it; nothing else
    /// reads it.
    public var requestedSettingsSection: String?

    // MARK: - Side panel

    /// The right-hand 终端/文件/改动/浏览器 panel. Lives here rather than in
    /// view state so the relay's debug actions (and the header button, ⌘J and
    /// the 对话 menu, which all write through the same property) drive one
    /// shared truth.
    public var sidePanelOpen = false
    /// Selected tab; meaningful only while `sidePanelOpen`.
    public var sidePanelTab: SidePanelTab = .terminal

    /// Toggles the panel, optionally landing on one tab. Opening straight to a
    /// tab switches to it; toggling closed ignores the tab.
    public func toggleSidePanel(open: Bool? = nil, tab: SidePanelTab? = nil) {
        if let open {
            sidePanelOpen = open
        } else {
            sidePanelOpen.toggle()
        }
        if let tab {
            sidePanelTab = tab
        }
    }

    // MARK: - Browser tabs

    /// Where a new browser tab starts — the page the 浏览器 tab always opened on.
    public static let browserHomeURL = "https://example.com"

    /// The side panel 浏览器's tabs. Session-only: not persisted, so a relaunch
    /// starts with one tab at `browserHomeURL`. The live web views belong to
    /// the pane; this is the list they mirror, kept here so debug actions and
    /// the strip drive one truth.
    public private(set) var browserTabs = BrowserTabList(homeURL: ChatAppModel.browserHomeURL)

    /// Opens a tab right of `id` (at the end when nil) and selects it; a nil
    /// `url` opens the home page. Returns the new tab's id.
    @discardableResult
    public func openBrowserTab(url: String? = nil, rightOf id: UUID? = nil) -> UUID {
        browserTabs.open(url: url, rightOf: id)
    }

    public func closeBrowserTab(_ id: UUID) {
        browserTabs.close(id)
    }

    /// Copies a tab right of itself and selects the copy; nil for an unknown tab.
    @discardableResult
    public func duplicateBrowserTab(_ id: UUID) -> UUID? {
        browserTabs.duplicate(id)
    }

    /// A blank name clears the custom title.
    public func renameBrowserTab(_ id: UUID, to title: String) {
        browserTabs.rename(id, to: title)
    }

    public func selectBrowserTab(_ id: UUID) {
        browserTabs.select(id)
    }

    /// Points a tab at an already-resolved address; the pane loads it.
    public func navigateBrowserTab(_ id: UUID, to url: String) {
        browserTabs.navigate(id, to: url)
    }

    /// What a tab's web view reports after a load or a title change. Unchanged
    /// reports are dropped so they do not redraw everything watching the list.
    public func updateBrowserPage(_ id: UUID, url: String, title: String) {
        guard let tab = browserTabs.tab(id), tab.url != url || tab.title != title else { return }
        browserTabs.updatePage(id, url: url, title: title)
    }

    // MARK: Dependencies

    @ObservationIgnored private let store: any ConversationStoring
    @ObservationIgnored private let secrets: any SecretStoring
    @ObservationIgnored public let mediaLibrary: MediaLibrary
    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var apiKeys: [UUID: String] = [:]
    @ObservationIgnored private var draftsByConversation: [UUID: String] = [:]
    @ObservationIgnored private var attachmentsByConversation: [UUID: [MediaRef]] = [:]
    public init(
        store: any ConversationStoring = FileConversationStore.defaultStore(),
        secrets: any SecretStoring = FallbackSecretStore(primary: KeychainSecretStore()),
        mediaLibrary: MediaLibrary = .default(),
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.store = store
        self.secrets = secrets
        self.mediaLibrary = mediaLibrary
        self.transport = transport
        self.hostExecutor = HostExecutor(shellAllowed: false, log: remoteOperationLog)
    }

    // MARK: Derived state

    public var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    public var sortedConversations: [Conversation] {
        conversations
            .filter { !$0.isLocked && !$0.isTemporary && !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                switch settings.conversationSort {
                case "created":
                    return lhs.createdAt > rhs.createdAt
                case "manual":
                    switch (lhs.sortIndex, rhs.sortIndex) {
                    case let (l?, r?) where l != r: return l < r
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return lhs.updatedAt > rhs.updatedAt
                    }
                default:
                    return lhs.updatedAt > rhs.updatedAt
                }
            }
    }

    /// Temporary chats: not saved, and dropped when the window closes. They are
    /// excluded from `sortedConversations` (so history and search stay clean) but
    /// have to be listed somewhere or a chat vanishes the moment you switch away
    /// from it, which is what used to happen.
    public var temporaryConversations: [Conversation] {
        conversations
            .filter(\.isTemporary)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public var archivedConversations: [Conversation] {
        conversations.filter(\.isArchived).sorted { $0.updatedAt > $1.updatedAt }
    }

    public var lockedConversations: [Conversation] {
        conversations.filter(\.isLocked).sorted { $0.updatedAt > $1.updatedAt }
    }

    public var activeProvider: ProviderProfile? {
        if let id = selectedConversation?.providerID, let match = providers.first(where: { $0.id == id }) {
            return match
        }
        if let id = settings.defaultProviderID, let match = providers.first(where: { $0.id == id }) {
            return match
        }
        return providers.first
    }

    public var availableModels: [ModelDescriptor] {
        guard let provider = activeProvider else { return [] }
        return models
            .filter { $0.providerID == provider.id && $0.capabilities.chat }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public var imageModels: [ModelDescriptor] {
        models
            .filter { $0.capabilities.imageGeneration }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public var activeModel: ModelDescriptor? {
        if let modelID = selectedConversation?.modelID,
           let match = models.first(where: { $0.id == modelID }) {
            return match
        }
        if let modelID = settings.defaultModelID,
           let match = models.first(where: { $0.id == modelID }) {
            return match
        }
        return availableModels.first
    }

    public var needsSetup: Bool { providers.isEmpty || providers.allSatisfy { key(for: $0.id).isEmpty } }

    public func key(for providerID: UUID) -> String { apiKeys[providerID] ?? "" }


    public var storageDirectoryURL: URL? {
        (store as? FileConversationStore)?.directoryURL
    }
    // MARK: Lifecycle

    public func bootstrap() async {
        if let running = bootstrapTask {
            _ = await running.value
            return
        }
        let task = Task { await bootstrapOnce() }
        bootstrapTask = task
        await task.value
    }

    private func bootstrapOnce() async {
        do {
            conversations = try await store.loadAll()
            providers = try await store.loadProviders()
            models = try await store.loadModelCatalog()
            settings = try await store.loadSettings()
            projects = try await store.loadProjects()
            let folded = settings.foldLegacyConnection()
            let vaulted = PairedDeviceVault.hydrate(settings.pairedDevices, secrets: secrets)
            settings.pairedDevices = vaulted.devices
            let host = HostCredentialVault.hydrate(settings, secrets: secrets)
            settings = host.settings
            if folded || vaulted.needsRewrite || host.needsRewrite { await saveSettings(settings) }
        } catch {
            conversations = []
            providers = []
            models = []
            settings = AppSettings()
            projects = []
            DiagnosticsCenter.shared.record("workspace", .error, "workspace load failed",
                fields: ["error": error.localizedDescription])
        }
        for provider in providers {
            apiKeys[provider.id] = (try? secrets.secret(for: provider.keychainAccount)) ?? ""
        }
        if conversations.isEmpty {
            let conversation = Conversation(providerID: settings.defaultProviderID, modelID: settings.defaultModelID)
            conversations = [conversation]
            try? await store.save(conversation)
        }
        if selectedConversationID == nil || conversations.first(where: { $0.id == selectedConversationID }) == nil {
            selectedConversationID = sortedConversations.first?.id
        }
        registerBuiltinTools()
        for provider in providers where !apiKeys[provider.id, default: ""].isEmpty {
            if models.contains(where: { $0.providerID == provider.id }) { continue }
            await refreshModels(for: provider.id, silent: true)
        }
    }

    // MARK: Conversation actions

    @discardableResult
    public func newConversation() -> Conversation {
        let conversation = Conversation(providerID: activeProvider?.id, modelID: activeModel?.id)
        conversations.append(conversation)
        selectedConversationID = conversation.id
        persist(conversation)
        return conversation
    }

    @discardableResult
    public func duplicateConversation(_ id: UUID) -> Conversation? {
        guard let original = conversation(id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.title = "\(original.title) (副本)"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.isPinned = false
        copy.hasUnread = false
        conversations.insert(copy, at: 0)
        selectedConversationID = copy.id
        persist(copy)
        return copy
    }

    /// Official Codex `forkActions`. `local` copies the chat unbound, `sameWorktree`
    /// keeps the directory, and `worktree` creates a real `git worktree` beside
    /// the repository and binds the copy to it.
    @discardableResult
    public func forkConversation(_ id: UUID, mode: ForkMode) async -> String? {
        guard let original = conversation(id) else { return "找不到这个对话" }
        guard let copy = duplicateConversation(id) else { return nil }
        switch mode {
        case .local:
            // A plain copy keeps nothing of the original's binding.
            updateWorkingDirectory(copy.id, nil)
            return nil
        case .sameWorktree:
            updateWorkingDirectory(copy.id, original.workingDirectory)
            return nil
        case .worktree:
            // `Process` does not exist on iOS, and a phone has no repository to
            // fork anyway: say so instead of pretending the fork happened.
            #if os(iOS)
            return "新建 Worktree 只能在 Mac 上做"
            #else
                let repository = original.workingDirectory ?? FileManager.default.currentDirectoryPath
                guard let git = GitBinary.resolve() else { return "这台 Mac 上没有可用的 git" }
                let plan = WorktreeFork.plan(
                    title: original.title,
                    id: copy.id,
                    repository: repository,
                    baseDirectory: settings.worktreeBaseDirectory,
                    branchPrefix: settings.worktreeBranchPrefix
                )
                let process = Process()
                process.executableURL = URL(fileURLWithPath: git)
                process.arguments = plan.arguments
                process.currentDirectoryURL = URL(fileURLWithPath: repository)
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = Pipe()
                do { try process.run() } catch { return error.localizedDescription }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    // The copy is already made; say why the checkout failed rather
                    // than leaving a fork that silently points nowhere.
                    return text.isEmpty ? "git worktree add 失败（退出码 \(process.terminationStatus)）" : text
                }
                updateWorkingDirectory(copy.id, plan.path)
                return nil
            #endif
        }
    }

    /// Surfaces a message in the app's error banner.
    public func showError(_ message: String) {
        errorMessage = message
    }

    /// Binds a thread to a directory, or unbinds it with nil.
    public func updateWorkingDirectory(_ id: UUID, _ directory: String?) {
        guard var conversation = conversation(id) else { return }
        conversation.workingDirectory = directory
        replace(conversation)
        persist(conversation)
    }

    public func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        Task { try? await store.delete(id: id) }
        draftsByConversation.removeValue(forKey: id)
        attachmentsByConversation.removeValue(forKey: id)
        clearSideChat(id)
        if selectedConversationID == id {
            selectedConversationID = sortedConversations.first?.id
        }
        if conversations.isEmpty { _ = newConversation() }
    }

    public func renameConversation(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var conversation = conversation(id) else { return }
        conversation.title = trimmed
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
    }

    // MARK: - Changes review

    /// Bumped after every git write made through `changeWorkingTree`, so the
    /// side panel's 改动 tab re-reads status even when the write came from a
    /// debug action rather than the tab itself.
    public private(set) var workingTreeRevision = 0

    /// Runs one `GitWorkingTree` write off the main actor, then has the 改动
    /// tab re-read status — after a failure too, since a failed commit may
    /// still have run hooks that touched files.
    public func changeWorkingTree<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        defer { workingTreeRevision += 1 }
        return try await Task.detached(priority: .userInitiated) { try operation() }.value
    }

    // MARK: - Thread goal

    /// Sets the thread's goal, or clears it when the text is blank. Trimmed
    /// and persisted, so every later request of this conversation carries it.
    public func setGoal(_ id: UUID, _ goal: String?) {
        guard var conversation = conversation(id) else { return }
        let trimmed = goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        conversation.goal = trimmed.isEmpty ? nil : trimmed
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
    }


    // MARK: Projects


    public func conversations(in projectID: UUID?) -> [Conversation] {
        sortedConversations.filter { $0.projectID == projectID }
    }

    @discardableResult
    public func createProject(name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(name: trimmed.isEmpty ? "新项目" : trimmed, order: projects.count)
        projects.append(project)
        persistProjects()
        return project
    }

    public func renameProject(_ id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = trimmed
        persistProjects()
    }

    public func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for index in conversations.indices where conversations[index].projectID == id {
            conversations[index].projectID = nil
            persist(conversations[index])
        }
        persistProjects()
    }

    // MARK: Custom sections (ChatGPT sidebarElectron.customSections)

    public var orderedCustomSections: [Project] {
        projects.filter(\.isCustomSection).sorted { $0.order < $1.order }
    }

    public var orderedProjects: [Project] {
        projects.filter { !$0.isCustomSection }.sorted { $0.order < $1.order }
    }

    @discardableResult
    public func createCustomSection(name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let section = Project(
            name: trimmed.isEmpty ? "新分区" : trimmed,
            order: projects.count,
            isCustomSection: true
        )
        projects.append(section)
        persistProjects()
        return section
    }

    /// Archives every conversation in a custom section (bulk `archiveAll`).
    public func archiveConversations(inCustomSection sectionID: UUID) {
        for index in conversations.indices
        where conversations[index].projectID == sectionID && !conversations[index].isArchived {
            conversations[index].isArchived = true
            conversations[index].isPinned = false
            persist(conversations[index])
        }
    }

    /// Clears unread state for every conversation in a custom section.
    public func markCustomSectionRead(_ sectionID: UUID) {
        for index in conversations.indices
        where conversations[index].projectID == sectionID && conversations[index].hasUnread {
            conversations[index].hasUnread = false
            persist(conversations[index])
        }
    }

    public func renameCustomSection(_ id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = trimmed
        persistProjects()
    }

    public func deleteCustomSection(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for index in conversations.indices where conversations[index].projectID == id {
            conversations[index].projectID = nil
            persist(conversations[index])
        }
        persistProjects()
    }

    public func conversations(inCustomSection sectionID: UUID) -> [Conversation] {
        sortedConversations.filter { $0.projectID == sectionID }
    }

    public func moveConversation(_ id: UUID, toCustomSection sectionID: UUID?) {
        moveConversation(id, to: sectionID)
    }

    /// Moves a conversation into a project, or out of one when `projectID` is nil.
    public func moveConversation(_ id: UUID, to projectID: UUID?) {
        guard var conversation = conversation(id) else { return }
        conversation.projectID = projectID
        replace(conversation)
        persist(conversation)
    }

    public func newConversation(in projectID: UUID?) -> Conversation {
        var conversation = newConversation()
        if projectID != nil {
            conversation.projectID = projectID
            replace(conversation)
            persist(conversation)
        }
        return conversation
    }

    private func persistProjects() {
        let store = self.store
        let snapshot = projects
        Task {
            do { try await store.saveProjects(snapshot) }
            catch {
                DiagnosticsCenter.shared.record("workspace", .error, "projects save failed",
                    fields: ["error": error.localizedDescription])
            }
        }
    }

    @discardableResult
    public func newTemporaryConversation() -> Conversation {
        var conversation = newConversation()
        conversation.isTemporary = true
        conversation.title = "临时对话"
        replace(conversation)
        return conversation
    }

    /// Drops every temporary conversation. Called when the window closes.
    public func discardTemporaryConversations() {
        let ids = conversations.filter(\.isTemporary).map(\.id)
        conversations.removeAll { $0.isTemporary }
        for id in ids {
            Task { try? await store.delete(id: id) }
        }
        if let selected = selectedConversationID, ids.contains(selected) {
            selectedConversationID = sortedConversations.first?.id
        }
    }

    public func toggleArchive(_ id: UUID) {
        guard var conversation = conversation(id) else { return }
        conversation.isArchived.toggle()
        if conversation.isArchived { conversation.isPinned = false }
        replace(conversation)
        persist(conversation)
        if conversation.isArchived, selectedConversationID == id {
            selectedConversationID = sortedConversations.first?.id
        }
    }

    public func toggleLock(_ id: UUID) {
        guard var conversation = conversation(id) else { return }
        conversation.isLocked.toggle()
        replace(conversation)
        persist(conversation)
        if conversation.isLocked, selectedConversationID == id {
            selectedConversationID = sortedConversations.first?.id
        }
    }

    public func reorderConversations(_ ordered: [Conversation]) {
        for (index, item) in ordered.enumerated() {
            guard var conversation = conversation(item.id) else { continue }
            conversation.sortIndex = index
            replace(conversation)
            persist(conversation)
        }
    }

    public func togglePin(_ id: UUID) {
        guard var conversation = conversation(id) else { return }
        conversation.isPinned.toggle()
        replace(conversation)
        persist(conversation)
    }

    public func setUnread(_ id: UUID, unread: Bool) {
        guard var conversation = conversation(id) else { return }
        conversation.hasUnread = unread
        replace(conversation)
        persist(conversation)
    }

    // MARK: - Sidebar organization

    /// Clears the unread flag on every conversation that is not archived.
    /// Archived chats are left exactly as they are, flag included.
    public func markAllRead() {
        for conversation in conversations where !conversation.isArchived && conversation.hasUnread {
            var cleared = conversation
            cleared.hasUnread = false
            replace(cleared)
            persist(cleared)
        }
    }


    public func setModel(_ model: ModelDescriptor) {
        guard var conversation = selectedConversation else { return }
        conversation.modelID = model.id
        conversation.providerID = model.providerID
        replace(conversation)
        persist(conversation)
    }

    // MARK: Sending

    public func send() {
        let text = draft
        let attachments = draftAttachments
        guard !isStreaming else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || !pastedTexts.isEmpty else { return }
        draft = ""
        draftAttachments = []
        let pastes = pastedTexts
        pastedTexts = []
        if let id = selectedConversationID {
            draftsByConversation.removeValue(forKey: id)
            attachmentsByConversation.removeValue(forKey: id)
        }
        Task { await sendNow(text: text, attachments: attachments, pastes: pastes) }
    }

    public func sendNow(text: String, attachments: [MediaRef], pastes: [PastedTextAttachment] = []) async {
        guard var conversation = selectedConversation else { return }
        guard resolveProvider(for: conversation) != nil else {
            errorMessage = "先在设置中添加供应商"
            showSettings = true
            return
        }

        var parts: [ContentPart] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(text)) }
        for paste in pastes {
            parts.append(.text("\n\n```\n\(paste.text)\n```"))
        }
        parts.append(contentsOf: attachments.map { .media($0) })

        conversation.messages.append(ChatMessage(role: .user, parts: parts, replyToID: replyingTo?.id))
        replyingTo = nil
        AudioFeedback.playSend(enabled: settings.soundEffects)
        if conversation.title == "新对话" {
            let seed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            conversation.title = seed.isEmpty ? "图片消息" : String(seed.prefix(28))
        }
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
        await startReply(conversationID: conversation.id)
    }

    /// Appends an assistant placeholder and streams the reply for the
    /// conversation's current tail of messages. With tools on offer the reply
    /// is an agent loop (`runReply`): the turn's tool calls run and the model
    /// is called again, until it answers or `AgentLoop.maxModelTurns`.
    private func startReply(conversationID: UUID) async {
        guard let conversation = conversation(conversationID) else { return }
        guard let provider = resolveProvider(for: conversation), resolveModel(for: conversation, provider: provider) != nil else {
            errorMessage = "先在设置中添加供应商并选择模型"
            return
        }
        let storedKey = (try? secrets.secret(for: provider.keychainAccount)) ?? nil
        guard let apiKey = storedKey, !apiKey.isEmpty else {
            errorMessage = "「\(provider.name)」缺少 API Key"
            showSettings = true
            return
        }

        // Claimed before the tool lookup awaits, so a second send cannot
        // start another reply in between.
        isStreaming = true
        streamingConversationID = conversationID
        errorMessage = nil
        streamTask?.cancel()
        let generation = stopGeneration
        let registry = await toolRegistry(for: conversationID)
        guard generation == stopGeneration, let first = prepareTurn(conversationID: conversationID, registry: registry) else {
            isStreaming = false
            streamingConversationID = nil
            return
        }
        streamTask = Task { [weak self] in
            await self?.runReply(conversationID: conversationID, first: first)
        }
    }

    /// One model turn ready to stream: the request, and the placeholder it fills.
    private struct PreparedTurn: Sendable {
        var adapter: any ChatProvider
        var request: GenerationRequest
        var assistantID: UUID
        /// The tools this turn offers; routes the calls it makes.
        var registry: AgentToolRegistry
    }

    /// Appends an assistant placeholder and builds the request for the
    /// conversation's messages so far, offering `registry`'s tools.
    private func prepareTurn(conversationID: UUID, registry: AgentToolRegistry) -> PreparedTurn? {
        guard var conversation = conversation(conversationID),
              let provider = resolveProvider(for: conversation),
              let model = resolveModel(for: conversation, provider: provider),
              let apiKey = (try? secrets.secret(for: provider.keychainAccount)) ?? nil, !apiKey.isEmpty else { return nil }

        conversation.providerID = provider.id
        conversation.modelID = model.id
        let assistant = ChatMessage(role: .assistant, parts: [], status: .streaming)
        conversation.messages.append(assistant)
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)

        let offered = registry.specs()
        offeredToolCounts[conversationID] = offered.count
        let history = conversation.messages.dropLast()
        var request = GenerationRequest(
            modelID: model.id,
            messages: Array(history),
            systemPrompt: systemPrompt(for: conversation),
            temperature: settings.temperature,
            maxOutputTokens: settings.maxOutputTokens ?? model.limits.maxOutputTokens
        )
        if webSearchEnabled {
            request.tools = [ToolSpec(name: "web_search", description: "", parametersJSON: "{}", type: "web_search")]
        }
        request.tools += offered.map(\.wireSpec)
        if model.capabilities.thinking, let budget = request.maxOutputTokens {
            let effort = conversation.reasoningEffort ?? "medium"
            let fraction: Int = effort == "high" ? 2 : (effort == "low" ? 8 : 4)
            request.thinkingBudgetTokens = min(4096, max(512, budget / fraction))
        }

        let adapter = ProviderFactory.makeProvider(
            profile: provider,
            apiKey: apiKey,
            transport: transport,
            mediaPayloads: { [mediaLibrary] ref in mediaLibrary.loadPayload(for: ref) }
        )
        DiagnosticsCenter.shared.record("stream", .info, "stream started",
            fields: ["host": provider.baseURL.host ?? "", "model": model.id])
        return PreparedTurn(adapter: adapter, request: request, assistantID: assistant.id, registry: registry)
    }

    /// Stops the reply: cancels the stream or the running tool (its whole
    /// process tree), and refuses every approval card still waiting.
    public func stop() {
        stopGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        for request in pendingApprovals {
            resolveApproval(request.id, .deny)
        }
    }

    public func regenerateLast() {
        guard !isStreaming, var conversation = selectedConversation else { return }
        if let last = conversation.messages.last, last.role == .assistant {
            conversation.alternativeReplies.append(last)
            if conversation.alternativeReplies.count > 5 {
                conversation.alternativeReplies.removeFirst(conversation.alternativeReplies.count - 5)
            }
            conversation.messages.removeLast()
        }
        guard conversation.messages.last?.role == .user else { return }
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
        Task { await startReply(conversationID: conversation.id) }
    }

    /// Swaps the current assistant reply with a previously regenerated one.
    public func cycleReply(forward: Bool) {
        guard var conversation = selectedConversation,
              !conversation.alternativeReplies.isEmpty,
              let current = conversation.messages.last, current.role == .assistant else { return }
        if forward {
            let next = conversation.alternativeReplies.removeFirst()
            conversation.alternativeReplies.append(current)
            conversation.messages[conversation.messages.count - 1] = next
        } else {
            let previous = conversation.alternativeReplies.removeLast()
            conversation.alternativeReplies.insert(current, at: 0)
            conversation.messages[conversation.messages.count - 1] = previous
        }
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
    }

    public func selectPreviousConversation() {
        let list = sortedConversations
        guard let current = selectedConversationID,
              let index = list.firstIndex(where: { $0.id == current }),
              index > 0 else { return }
        selectedConversationID = list[index - 1].id
    }

    public func selectNextConversation() {
        let list = sortedConversations
        guard let current = selectedConversationID,
              let index = list.firstIndex(where: { $0.id == current }),
              index < list.count - 1 else { return }
        selectedConversationID = list[index + 1].id
    }


    // MARK: - Message actions

    public func deleteMessage(_ messageID: UUID) {
        guard var conversation = selectedConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversation.messages.remove(at: index)
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
    }

    public func toggleMessageSelection(_ id: UUID) {
        if selectedMessageIDs.contains(id) {
            selectedMessageIDs.remove(id)
        } else {
            selectedMessageIDs.insert(id)
        }
    }

    public func deleteSelectedMessages() {
        guard var conversation = selectedConversation, !selectedMessageIDs.isEmpty else { return }
        conversation.messages.removeAll { selectedMessageIDs.contains($0.id) }
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
        selectedMessageIDs = []
    }


    /// Truncates the conversation at `messageID`, replaces it with the edited
    /// text (keeping its attachments) and re-runs the reply.
    public func editAndResend(_ messageID: UUID, newText: String) {
        guard var conversation = selectedConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].role == .user else { return }

        let oldMessage = conversation.messages[index]
        let attachments = oldMessage.parts.compactMap { part -> MediaRef? in
            if case .media(let ref) = part { ref } else { nil }
        }
        var parts: [ContentPart] = []
        if !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(newText)) }
        parts.append(contentsOf: attachments.map { .media($0) })

        var versions = oldMessage.alternativeVersions
        if !versions.contains(oldMessage.concatenatedText) {
            versions.append(oldMessage.concatenatedText)
        }
        let newMessage = ChatMessage(
            role: .user,
            parts: parts,
            alternativeVersions: versions,
            currentVersionIndex: versions.count
        )

        conversation.messages = Array(conversation.messages.prefix(index))
        conversation.messages.append(newMessage)
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
        Task { await startReply(conversationID: conversation.id) }
    }

    public func switchUserPromptVersion(_ messageID: UUID, delta: Int) {
        guard var conversation = selectedConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].role == .user else { return }

        var message = conversation.messages[index]
        let allVersions = message.alternativeVersions + [message.concatenatedText]
        let newIndex = message.currentVersionIndex + delta
        guard newIndex >= 0 && newIndex < allVersions.count else { return }

        let newText = allVersions[newIndex]
        let attachments = message.parts.compactMap { part -> MediaRef? in
            if case .media(let ref) = part { ref } else { nil }
        }
        var newParts: [ContentPart] = [.text(newText)]
        newParts.append(contentsOf: attachments.map { .media($0) })
        message.parts = newParts
        message.currentVersionIndex = newIndex

        conversation.messages[index] = message
        replace(conversation)
        persist(conversation)
    }

    /// Forks the conversation at `messageID` into a new chat.
    @discardableResult
    public func branch(from messageID: UUID) -> Conversation? {
        guard let source = selectedConversation,
              let index = source.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let branch = Conversation(
            title: source.title + " · 分支",
            providerID: source.providerID,
            modelID: source.modelID,
            systemPrompt: source.systemPrompt,
            messages: Array(source.messages.prefix(index + 1))
        )
        conversations.append(branch)
        selectedConversationID = branch.id
        persist(branch)
        return branch
    }

    public func exportMarkdown(_ conversation: Conversation) -> String {
        var lines: [String] = ["# \(conversation.title)", ""]
        if let modelID = conversation.modelID { lines.append("> 模型：`\(modelID)`") }
        lines.append("")
        for message in conversation.messages {
            let heading: String
            switch message.role {
            case .user: heading = "## 你"
            case .assistant: heading = "## 助手"
            case .system: heading = "## 系统"
            case .tool: heading = "## 工具"
            }
            lines.append(heading)
            lines.append("")
            for part in message.parts {
                switch part {
                case .text(let value):
                    lines.append(value)
                case .thinking(let value):
                    lines.append("<details><summary>思考过程</summary>")
                    lines.append("")
                    lines.append(value)
                    lines.append("</details>")
                case .media(let ref):
                    lines.append("![附件](media/\(ref.relativePath))")
                case .toolCall(let call):
                    lines.append("`\(call.name)(\(call.argumentsJSON))`")
                case .toolResult(let result):
                    lines.append("```\n\(result.outputText)\n```")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func exportJSON(_ conversation: Conversation) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(conversation),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public func exportHTML(_ conversation: Conversation) -> String {
        var body = ""
        for message in conversation.messages {
            let isUser = message.role == .user
            let roleName = isUser ? "你" : "助手"
            let text = message.concatenatedText
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")

            body += """
            <div class="message-row \(isUser ? "user" : "assistant")">
                <div class="sender">\(roleName)</div>
                <div class="bubble">\(text)</div>
            </div>
            """
        }

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(conversation.title)</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f9f9fb; color: #1a1a1a; margin: 0; padding: 40px 20px; }
                .container { max-width: 760px; margin: 0 auto; background: #ffffff; padding: 32px; border-radius: 16px; box-shadow: 0 4px 20px rgba(0,0,0,0.06); }
                h1 { font-size: 24px; margin-top: 0; border-bottom: 1px solid #eee; padding-bottom: 16px; }
                .meta { color: #888; font-size: 13px; margin-bottom: 24px; }
                .message-row { margin-bottom: 20px; display: flex; flex-direction: column; }
                .message-row.user { align-items: flex-end; }
                .message-row.assistant { align-items: flex-start; }
                .sender { font-size: 12px; color: #999; margin-bottom: 4px; }
                .bubble { padding: 12px 16px; border-radius: 14px; max-width: 80%; font-size: 14.5px; line-height: 1.6; }
                .user .bubble { background: #007aff; color: #ffffff; }
                .assistant .bubble { background: #f2f2f7; color: #1a1a1a; }
                @media print { body { padding: 0; background: #fff; } .container { box-shadow: none; padding: 0; } }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>\(conversation.title)</h1>
                <div class="meta">模型: \(conversation.modelID ?? "默认")</div>
                \(body)
            </div>
        </body>
        </html>
        """
    }

    @discardableResult
    public func importConversation(from jsonString: String) throws -> Conversation {
        let decoder = JSONDecoder()
        var conversation = try decoder.decode(Conversation.self, from: Data(jsonString.utf8))
        if conversations.contains(where: { $0.id == conversation.id }) {
            conversation.id = UUID()
            conversation.title += " (导入)"
        }
        conversations.append(conversation)
        selectedConversationID = conversation.id
        persist(conversation)
        return conversation
    }

    // MARK: - Context budget

    /// Rough token estimate (CJK ≈ 1 token/char, latin ≈ 1 token/4 chars).
    public func estimatedTokens(_ conversation: Conversation) -> Int {
        conversation.messages.reduce(0) { total, message in
            let text = message.concatenatedText
            let wide = text.unicodeScalars.filter { $0.value > 0x2E80 }.count
            let narrow = max(0, text.count - wide)
            return total + wide + narrow / 4
        }
    }

    public func contextUsage(_ conversation: Conversation) -> (used: Int, limit: Int)? {
        guard let limit = activeModel?.limits.contextWindow, limit > 0 else { return nil }
        return (estimatedTokens(conversation), limit)
    }

    /// How one streamed model turn ended.
    private struct TurnReport {
        var failure: Error?
        var cancelled: Bool
    }

    /// Streams one model turn into `assistantID` and settles that message.
    /// The reply as a whole ends in `finishReply`.
    private func runStream(
        adapter: any ChatProvider,
        request: GenerationRequest,
        conversationID: UUID,
        assistantID: UUID
    ) async -> TurnReport {
        var failure: Error?
        var finishReason: FinishReason = .stop
        var firstTokenMillis: Int?
        let started = Date()
        do {
            for try await event in adapter.stream(request) {
                if firstTokenMillis == nil, case .textDelta = event {
                    firstTokenMillis = Int(Date().timeIntervalSince(started) * 1000)
                }
                if Task.isCancelled { break }
                apply(event, conversationID: conversationID, assistantID: assistantID)
                if case .finished(let reason) = event { finishReason = reason }
            }
        } catch {
            failure = error
        }

        let cancelled = Task.isCancelled
        updateMessage(conversationID: conversationID, messageID: assistantID) { message in
            if cancelled, !message.concatenatedText.isEmpty {
                // Keep what was already streamed instead of discarding it.
                message.status = .complete
            } else if let failure {
                message.status = .failed
                message.errorText = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
            } else {
                message.status = .complete
                if message.parts.isEmpty && finishReason == .contentFilter {
                    message.errorText = "响应被内容过滤器拦截"
                }
            }
        }
        if let failure, !cancelled { errorMessage = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription }
        var fields = ["host": providerHost(conversationID), "model": request.modelID]
        if let firstTokenMillis { fields["firstTokenMs"] = String(firstTokenMillis) }
        if let http = (failure as? ProviderError).flatMap(Self.httpStatus) { fields["status"] = String(http) }
        if let failure, !cancelled {
            fields["error"] = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
            DiagnosticsCenter.shared.record("stream", .error, "stream failed", fields: fields)
        } else {
            DiagnosticsCenter.shared.record("stream", .info, cancelled ? "stream cancelled" : "stream finished", fields: fields)
        }
        if let conversation = conversation(conversationID) { persist(conversation) }
        return TurnReport(failure: failure, cancelled: cancelled)
    }

    /// Ends a reply after its last turn: the stop button goes away, the
    /// completion sound and notification play for an answer, and the title
    /// and unread state settle.
    private func finishReply(conversationID: UUID, answered: Bool) {
        if answered {
            AudioFeedback.playComplete(enabled: settings.soundEffects)
            if settings.completionNotifications, selectedConversationID != conversationID {
                let title = conversation(conversationID)?.title ?? "新回复"
                CompletionNotifier.notify(title: title)
            }
        }
        isStreaming = false
        streamingConversationID = nil
        streamTask = nil
        runningToolCallIDs = []
        if var conversation = conversation(conversationID) {
            if conversation.title == "新对话" || conversation.title == "图片消息" {
                if let first = conversation.messages.first(where: { $0.role == .user }) {
                    let seed = first.concatenatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !seed.isEmpty { conversation.title = String(seed.prefix(28)) }
                }
            }
            if selectedConversationID != conversationID {
                conversation.hasUnread = true
            }
            replace(conversation)
            persist(conversation)
        }
    }
    private func providerHost(_ conversationID: UUID) -> String {
        guard let conversation = conversation(conversationID),
              let providerID = conversation.providerID,
              let provider = providers.first(where: { $0.id == providerID }) else { return "" }
        return provider.baseURL.host ?? ""
    }

    private static func httpStatus(_ error: ProviderError) -> Int? {
        if case .http(let status, _) = error { return status }
        return nil
    }


    private func apply(_ event: StreamEvent, conversationID: UUID, assistantID: UUID) {
        updateMessage(conversationID: conversationID, messageID: assistantID) { message in
            message.apply(event)
        }
    }

    // MARK: Attachments

    public func attach(url: URL, removeSandboxScope: Bool = false) throws {
        let ref = try mediaLibrary.importFile(at: url)
        draftAttachments.append(ref)
        if removeSandboxScope { url.stopAccessingSecurityScopedResource() }
    }

    public func removeAttachment(_ id: UUID) {
        draftAttachments.removeAll { $0.id == id }
    }

    // MARK: Image generation

    public func generateImage(prompt: String, model: ModelDescriptor, size: String?) async {
        guard var conversation = selectedConversation else { return }
        guard let provider = providers.first(where: { $0.id == model.providerID }) else { return }
        let apiKey = (try? secrets.secret(for: provider.keychainAccount)) ?? nil
        let generator = OpenAICompatibleMediaGenerator(
            profile: provider,
            apiKey: apiKey ?? "",
            transport: transport,
            library: mediaLibrary
        )
        conversation.messages.append(ChatMessage(role: .user, parts: [.text(prompt)]))
        replace(conversation)
        persist(conversation)
        do {
            let ref = try await generator.generateImage(
                ImageGenerationRequest(modelID: model.id, prompt: prompt, size: size)
            )
            conversation = self.conversation(conversation.id) ?? conversation
            conversation.messages.append(ChatMessage(role: .assistant, parts: [.media(ref)]))
            conversation.updatedAt = Date()
            if conversation.title == "新对话" { conversation.title = String(prompt.prefix(28)) }
            replace(conversation)
            persist(conversation)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Providers

    public func addProvider(_ profile: ProviderProfile, apiKey: String?) async {
        var profile = profile
        if providers.isEmpty { profile.isDefault = true }
        providers.append(profile)
        if let apiKey, !apiKey.isEmpty {
            try? secrets.setSecret(apiKey, for: profile.keychainAccount)
            apiKeys[profile.id] = apiKey
        }
        try? await store.saveProviders(providers)
        if settings.defaultProviderID == nil {
            settings.defaultProviderID = profile.id
            try? await store.saveSettings(settings)
        }
        await refreshModels(for: profile.id, silent: true)
    }

    public func updateProvider(_ profile: ProviderProfile, apiKey: String?) async {
        guard let index = providers.firstIndex(where: { $0.id == profile.id }) else { return }
        providers[index] = profile
        if let apiKey {
            try? secrets.setSecret(apiKey.isEmpty ? nil : apiKey, for: profile.keychainAccount)
            apiKeys[profile.id] = apiKey
        }
        try? await store.saveProviders(providers)
        models.removeAll { $0.providerID == profile.id }
        try? await store.replaceModelCatalog(models)
    }

    public func deleteProvider(_ id: UUID) async {
        providers.removeAll { $0.id == id }
        models.removeAll { $0.providerID == id }
        try? secrets.setSecret(nil, for: "provider.\(id.uuidString)")
        apiKeys[id] = nil
        if settings.defaultProviderID == id { settings.defaultProviderID = providers.first?.id }
        for index in conversations.indices where conversations[index].providerID == id {
            conversations[index].providerID = providers.first?.id
            conversations[index].modelID = nil
        }
        try? await store.saveProviders(providers)
        try? await store.replaceModelCatalog(models)
        try? await store.saveSettings(settings)
        for conversation in conversations {
            try? await store.save(conversation)
        }
    }

    public func refreshModels(for providerID: UUID, silent: Bool = false) async {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        let key = (try? secrets.secret(for: provider.keychainAccount)) ?? nil
        guard let key, !key.isEmpty || provider.baseURL.host == "127.0.0.1" || provider.baseURL.host == "localhost" else {
            if !silent { errorMessage = "「\(provider.name)」缺少 API Key" }
            return
        }
        refreshingProviderIDs.insert(providerID)
        defer { refreshingProviderIDs.remove(providerID) }
        let adapter = ProviderFactory.makeProvider(profile: provider, apiKey: key, transport: transport)
        do {
            let fetched = try await adapter.fetchModels()
            models.removeAll { $0.providerID == providerID }
            models.append(contentsOf: fetched)
            models.sort { $0.id < $1.id }
            try? await store.replaceModelCatalog(models)
            if settings.defaultModelID == nil, let first = fetched.first(where: { $0.capabilities.chat }) {
                settings.defaultModelID = first.id
                try? await store.saveSettings(settings)
            }
            if !silent { statusMessage = "「\(provider.name)」同步到 \(fetched.count) 个模型" }
        } catch {
            if !silent {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    public func saveSettings(_ newValue: AppSettings) async {
        let previous = settings.pairedDevices
        settings = newValue
        // Credentials stay in memory and in the vault; the document gets blanks.
        var persisted = HostCredentialVault.persistable(newValue, secrets: secrets)
        persisted.pairedDevices = PairedDeviceVault.persistable(
            newValue.pairedDevices, previous: previous, secrets: secrets
        )
        do {
            try await store.saveSettings(persisted)
        } catch {
            DiagnosticsCenter.shared.record("workspace", .error, "settings save failed",
                fields: ["error": error.localizedDescription])
        }
    }

    // MARK: Helpers

    private func resolveProvider(for conversation: Conversation) -> ProviderProfile? {
        if let id = conversation.providerID, let match = providers.first(where: { $0.id == id }) { return match }
        if let id = settings.defaultProviderID, let match = providers.first(where: { $0.id == id }) { return match }
        return providers.first
    }

    private func resolveModel(for conversation: Conversation, provider: ProviderProfile) -> ModelDescriptor? {
        if let id = conversation.modelID, let match = models.first(where: { $0.id == id && $0.providerID == provider.id }) {
            return match
        }
        if let id = settings.defaultModelID, let match = models.first(where: { $0.id == id && $0.providerID == provider.id }) {
            return match
        }
        return models
            .filter { $0.providerID == provider.id && $0.capabilities.chat }
            .sorted { $0.displayName < $1.displayName }
            .first
    }

    /// The system prompt as it would be sent. Exposed so the memory wiring can
    /// be tested without a network round trip.
    public func debugSystemPrompt(for conversation: Conversation) -> String? {
        systemPrompt(for: conversation)
    }

    private func systemPrompt(for conversation: Conversation) -> String? {
        let base = (conversation.systemPrompt ?? "").isEmpty ? settings.systemPrompt : (conversation.systemPrompt ?? "")
        let custom = settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        // The omp-ui guide always rides last so the client can render native
        // interfaces; user/system instructions above it still take priority.
        let memories = memoryLines
        let combined = [
            base.trimmingCharacters(in: .whitespacesAndNewlines),
            custom,
            memories.isEmpty ? "" : "用户希望你在对话中记住：\n" + memories.joined(separator: "\n"),
            conversation.goal.map { "本对话的目标：\($0)" } ?? "",
            agentsDocPrompt(for: conversation.id)?.text ?? "",
            agentToolsPrompt(for: conversation),
            skillPromptSection(for: conversation.id) ?? "",
            GenUIGuide.systemPrompt,
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return combined
    }

    /// The memory lines to send, one per non-empty line, or none when the
    /// switch is off. Capped so a pasted log cannot flood every request.
    private var memoryLines: [String] {
        guard settings.enableMemories else { return [] }
        return settings.memories
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(50)
            .map { $0 }
    }

    private func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    private func replace(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            conversations.append(conversation)
            return
        }
        conversations[index] = conversation
    }

    public func setConversationPrompt(_ text: String) {
        guard var conversation = selectedConversation else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.systemPrompt = trimmed.isEmpty ? nil : trimmed
        replace(conversation)
        persist(conversation)
    }

    public func setReasoningEffort(_ effort: String?) {
        guard var conversation = selectedConversation else { return }
        conversation.reasoningEffort = effort
        replace(conversation)
        persist(conversation)
    }

    /// Toggles like (+1) / dislike (-1). Passing the current value clears it.
    public func setFeedback(_ messageID: UUID, value: Int) {
        guard var conversation = selectedConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversation.messages[index].feedback = conversation.messages[index].feedback == value ? nil : value
        replace(conversation)
        persist(conversation)
    }

    private func updateMessage(conversationID: UUID, messageID: UUID, _ body: (inout ChatMessage) -> Void) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
        body(&conversations[conversationIndex].messages[messageIndex])
        conversations[conversationIndex].updatedAt = Date()
    }

    private func persist(_ conversation: Conversation) {
        guard !conversation.isTemporary else { return }
        let store = self.store
        Task {
            do { try await store.save(conversation) }
            catch {
                DiagnosticsCenter.shared.record("workspace", .error, "conversation save failed",
                    fields: ["error": error.localizedDescription])
            }
        }
    }

    public func dismissError() { errorMessage = nil }
    public func dismissStatus() { statusMessage = nil }

    /// Workspace-wide counts for the data controls settings pane.
    public var workspaceStats: (conversations: Int, messages: Int, mediaFiles: Int, formattedSize: String) {
        let messageCount = conversations.reduce(0) { $0 + $1.messages.count }
        let mediaCount = conversations.reduce(0) { total, conversation in
            total + conversation.messages.reduce(0) { $0 + $1.parts.filter { if case .media = $0 { true } else { false } }.count }
        }
        let size = directorySize(mediaLibrary.rootURL.deletingLastPathComponent())
        return (conversations.count, messageCount, mediaCount, ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Full workspace dump for the "导出全部数据" action.
    public func exportWorkspaceJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        struct Dump: Codable { var conversations: [Conversation]; var projects: [Project] }
        let data = (try? encoder.encode(Dump(conversations: conversations, projects: projects))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
    /// Local machine name; AppKit is macOS-only so this falls back elsewhere.
    static var relayHostName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        "Mac"
        #endif
    }

    // MARK: LAN relay

    /// Host-side relay controller (macOS). Created lazily on first enable.
    @ObservationIgnored public private(set) var relayController: RelayHostController?

    public func syncRelayController() {
        guard settings.relayEnabled else {
            relayController?.stop()
            relayController = nil
            return
        }
        let token = settings.relayToken.isEmpty ? UUID().uuidString : settings.relayToken
        if token != settings.relayToken {
            settings.relayToken = token
            Task { await saveSettings(settings) }
        }
        // Hub mode needs a stable room code so the phone can remember it.
        if !settings.relayHubURL.isEmpty, settings.relayRoomCode.isEmpty {
            settings.relayRoomCode = RelayHubClient.newRoomCode()
            Task { await saveSettings(settings) }
        }

        let controller: RelayHostController
        if let existing = relayController {
            existing.updateToken(token)
            existing.start(port: settings.relayPort)
            controller = existing
        } else {
            controller = RelayHostController(model: self, token: token)
            relayController = controller
            controller.start(port: settings.relayPort)
        }

        // Cross-network reachability runs alongside the LAN listener, so the
        // phone works both on the same Wi-Fi and from cellular.
        if !settings.relayHubURL.isEmpty,
           let hubURL = URL(string: settings.relayHubURL),
           RelayHubClient.isValidRoomCode(settings.relayRoomCode) {
            controller.startHub(roomCode: settings.relayRoomCode, hubURL: hubURL)
        } else {
            controller.stopHub()
        }
    }

    /// Regenerates the pairing room code (host side).
    public func regenerateRelayRoomCode() {
        settings.relayRoomCode = RelayHubClient.newRoomCode()
        Task { await saveSettings(settings) }
        syncRelayController()
    }


    /// Chats the sidebar's 待处理 group shows: unread, still generating, or
    /// waiting on a reply. Every other section hides these, so a chat never
    /// appears twice (the phone drawer uses the same set).
    public func priorityConversationIDs() -> Set<UUID> {
        ConversationPriority.ids(in: sortedConversations, streamingID: streamingConversationID)
    }

    /// Structured mirror of the workspace for the LAN relay server.
    ///
    /// Assistant messages carry their thinking transcript and tool activity so
    /// the phone can render moshi-style operation cards. Snapshot size matters
    /// because the hub re-sends the whole document on every rev: full detail
    /// (arguments + output) only rides on the last 5 assistant messages; every
    /// other message keeps summary rows only.
    public func relaySnapshot() -> RelaySnapshot {
        func relayActivity(
            for message: ChatMessage, includeDetail: Bool
        ) -> (thinking: String?, activity: [RelayActivity]?) {
            var thinking = message.thinkingText
            var activities: [RelayActivity] = []
            var pending: [String: ToolCall] = [:]
            for part in message.parts {
                switch part {
                case .toolCall(let call):
                    pending[call.id] = call
                    activities.append(
                        RelayActivity(
                            id: call.id,
                            name: call.name,
                            summary: ActivityLog.summary(for: call, result: nil),
                            status: "running"
                        )
                    )
                case .toolResult(let result):
                    let diff = ActivityLog.toolDiff(result)
                    let call = pending.removeValue(forKey: result.callID) ?? ToolCall(
                        id: result.callID, name: result.name, argumentsJSON: ""
                    )
                    let summary = ActivityLog.summary(for: call, result: result)
                    let detail = includeDetail
                        ? [call.argumentsJSON, result.outputText]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        : nil
                    if let index = activities.lastIndex(where: { $0.id == result.callID }) {
                        activities[index].status = result.isError ? "error" : "ok"
                        activities[index].summary = summary
                        activities[index].added = diff?.added
                        activities[index].removed = diff?.removed
                        activities[index].detail = detail
                    } else {
                        activities.append(
                            RelayActivity(
                                id: result.callID, name: result.name, summary: summary,
                                status: result.isError ? "error" : "ok",
                                added: diff?.added, removed: diff?.removed, detail: detail
                            )
                        )
                    }
                default:
                    break
                }
            }
            return RelayMessage.normalized(thinking: thinking, activity: activities)
        }

        let projectNameByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        let conversations = sortedConversations.map { conversation in
            // Last five assistant messages carry expandable detail; older ones
            // ship summaries only to keep the wire payload bounded.
            let visible = conversation.messages.suffix(100)
            let assistantIndexes = visible.enumerated().compactMap { index, message in
                message.role == .assistant && !message.parts.isEmpty ? index : nil
            }
            let detailIndexes = Set(assistantIndexes.suffix(5))
            let messages = visible.enumerated().map { index, message -> RelayMessage in
                let isAssistant = message.role != .user
                let (thinking, activity) = isAssistant
                    ? relayActivity(for: message, includeDetail: detailIndexes.contains(index))
                    : (nil, nil)
                return RelayMessage(
                    id: message.id.uuidString,
                    role: message.role == .user ? "user" : "assistant",
                    text: message.concatenatedText,
                    ts: message.createdAt,
                    streaming: conversation.id == streamingConversationID && message.status == .streaming,
                    thinking: thinking,
                    activity: activity
                )
            }
            return RelayConversation(
                id: conversation.id.uuidString,
                title: conversation.title,
                updatedAt: conversation.updatedAt,
                project: conversation.projectID.flatMap { projectNameByID[$0] },
                isStreaming: conversation.id == streamingConversationID,
                messages: messages
            )
        }
        return RelaySnapshot(
            rev: 0,
            host: Self.relayHostName,
            selectedID: selectedConversationID?.uuidString,
            conversations: conversations
        )
    }

    /// Executes one command coming from a paired remote controller.
    ///
    /// Every branch reuses the same model methods the desktop UI calls, so a
    /// phone-driven action is indistinguishable from a local one and always
    /// persists through the normal save path.
    public func handleRelayCommand(_ command: RelayCommand) async {
        func uuid(_ raw: String) -> UUID? { UUID(uuidString: raw) }

        switch command {
        case .input(let conversationID, let text):
            if let rawID = conversationID, let id = uuid(rawID),
               conversations.contains(where: { $0.id == id }) {
                selectedConversationID = id
            } else {
                _ = newConversation()
            }
            await sendNow(text: text, attachments: [])

        case .stop(let conversationID):
            if let id = uuid(conversationID), id == streamingConversationID {
                stop()
            }

        case .select(let conversationID):
            guard let id = uuid(conversationID),
                  conversations.contains(where: { $0.id == id }) else { return }
            selectedConversationID = id

        case .newConversation:
            _ = newConversation()

        case .rename(let conversationID, let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let id = uuid(conversationID) else { return }
            renameConversation(id, title: trimmed)

        case .delete(let conversationID):
            guard let id = uuid(conversationID) else { return }
            deleteConversation(id)

        case .regenerate(let conversationID):
            guard let id = uuid(conversationID) else { return }
            selectedConversationID = id
            regenerateLast()

        case .deleteMessage(let conversationID, let messageID):
            guard let conversation = uuid(conversationID),
                  conversations.contains(where: { $0.id == conversation }),
                  let message = uuid(messageID) else { return }
            selectedConversationID = conversation
            deleteMessage(message)

        case .editAndResend(let conversationID, let messageID, let text):
            guard let conversation = uuid(conversationID),
                  conversations.contains(where: { $0.id == conversation }),
                  let message = uuid(messageID) else { return }
            selectedConversationID = conversation
            editAndResend(message, newText: text)

        case .branch(let conversationID, let messageID):
            guard let conversation = uuid(conversationID),
                  conversations.contains(where: { $0.id == conversation }),
                  let message = uuid(messageID) else { return }
            selectedConversationID = conversation
            if let branched = branch(from: message) {
                selectedConversationID = branched.id
            }

        case .feedback(let conversationID, let messageID, let value):
            guard let conversation = uuid(conversationID),
                  conversations.contains(where: { $0.id == conversation }),
                  let message = uuid(messageID) else { return }
            selectedConversationID = conversation
            setFeedback(message, value: value)

        case .setModel(let conversationID, let modelID):
            guard let conversation = uuid(conversationID),
                  let id = UUID(uuidString: conversationID),
                  conversations.contains(where: { $0.id == id }) else { return }
            if let descriptor = availableModels.first(where: { $0.id == modelID })
                ?? models.first(where: { $0.id == modelID }) {
                selectedConversationID = conversation
                setModel(descriptor)
            }

        case .togglePin(let conversationID):
            guard let id = uuid(conversationID) else { return }
            togglePin(id)

        case .toggleArchive(let conversationID):
            guard let id = uuid(conversationID) else { return }
            toggleArchive(id)

        case .toggleLock(let conversationID):
            guard let id = uuid(conversationID) else { return }
            toggleLock(id)

        case .setUnread(let conversationID, let unread):
            guard let id = uuid(conversationID) else { return }
            setUnread(id, unread: unread)
        }
    }

    /// Answers an RPC for the desktop's own windows. Same executor as the phone
    /// path, but not gated on the phone-access switch: local use never leaves
    /// this Mac.
    public func handleHostRPCForThisMac(_ request: HostRPCRequest) async -> HostRPCResponse {
        await hostExecutor.handle(request, allowingShell: true)
    }

    /// `cli.sessions` for the desktop's own window. Local use does not depend
    /// on the phone-access switch; nothing leaves this Mac.
    public func localCLISessions() async -> HostRPCResponse {
        await hostExecutor.handle(
            HostRPCRequest(id: "local-cli-sessions", op: "cli.sessions"),
            allowingShell: true
        )
    }

    /// `cli.control` for the desktop's own window.
    public func localCLIControl(_ action: CLISessionAction, id: String?, prompt: String? = nil, agent: String = "claude") async -> HostRPCResponse {
        await hostExecutor.handle(
            HostRPCRequest(id: "local-cli-control", op: "cli.control", path: action.rawValue,
                           command: agent, requestID: id, prompt: prompt),
            allowingShell: true
        )
    }

    /// Answers one host RPC from a paired phone. `info` always runs; file and
    /// shell operations require `settings.relayAllowShell`.
    public func handleHostRPC(_ request: HostRPCRequest) async -> HostRPCResponse {
        hostExecutor.shellAllowed = settings.relayAllowShell
        let started = Date()
        let response = await hostExecutor.handle(request)
        let millis = Int(Date().timeIntervalSince(started) * 1000)
        var fields = ["op": request.op, "ms": String(millis), "ok": response.ok ? "true" : "false"]
        if let command = request.command {
            fields["command"] = String(command.prefix(80))
        }
        if let error = response.error { fields["error"] = error }
        DiagnosticsCenter.shared.record("rpc", response.ok ? .info : .warn, "host rpc \(request.op)", fields: fields)
        return response
    }
    /// Runs every health check and returns a report carrying the last 50
    /// events. Also what `GET /debug/report` serves.
    public func runDiagnostics(
        pairedHostProbe: (@Sendable () async -> Bool)? = nil,
        lastSnapshotAt: Date? = nil
    ) async -> DiagnosticsReport {
        let age = lastSnapshotAt.map { Date().timeIntervalSince($0) }

        var context = DiagnosticsContext(
            providers: providers,
            apiKeys: apiKeys,
            storeDirectory: storageDirectoryURL,
            relayEnabled: settings.relayEnabled,
            relayPort: settings.relayPort,
            relayListening: relayController?.isRunning ?? false,
            relayToken: settings.relayToken,
            relayRoomCode: settings.relayRoomCode,
            relayHubURL: settings.relayHubURL,
            relayAllowShell: settings.relayAllowShell,
            pairedHostReachable: nil,
            lastSnapshotAge: age,
            transport: transport
        )
        context.pairedHostProbe = pairedHostProbe

        let checks = await DiagnosticsChecks.runAll(context)
        return DiagnosticsReport(
            appVersion: DiagnosticsReport.appVersion(),
            platform: DiagnosticsReport.currentPlatform,
            osVersion: DiagnosticsReport.currentOSVersion,
            checks: checks,
            events: DiagnosticsCenter.shared.recent(50)
        )
    }

    // MARK: - Thread links

    /// Opens `ompchat://thread/<uuid>`: selects the conversation when it
    /// exists, otherwise says it cannot be found.
    public func openThreadLink(_ url: URL) {
        guard let id = ThreadLink.threadID(in: url) else { return }
        if conversations.contains(where: { $0.id == id }) {
            selectedConversationID = id
        } else {
            showError("找不到这个对话")
        }
    }

    /// Official Codex `threadHeader.continueActions`: rebinds THIS thread
    /// instead of copying it. `directory` nil unbinds it. Returns a failure
    /// message, nil on success.
    @discardableResult
    public func continueConversation(_ id: UUID, directory: String?) -> String? {
        guard conversation(id) != nil else { return "找不到这个对话" }
        updateWorkingDirectory(id, directory)
        return nil
    }

    /// 继续于 新建 Worktree: the same `git worktree add` fork uses, but the
    /// checkout is bound back onto this conversation rather than a copy.
    @discardableResult
    public func continueInNewWorktree(_ id: UUID) async -> String? {
        guard let original = conversation(id) else { return "找不到这个对话" }
        #if os(iOS)
        return "新建 Worktree 只能在 Mac 上做"
        #else
        let repository = original.workingDirectory ?? FileManager.default.currentDirectoryPath
        guard let git = GitBinary.resolve() else { return "这台 Mac 上没有可用的 git" }
        let plan = WorktreeFork.plan(
            title: original.title,
            id: original.id,
            repository: repository,
            baseDirectory: settings.worktreeBaseDirectory,
            branchPrefix: settings.worktreeBranchPrefix
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repository)
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        do { try process.run() } catch { return error.localizedDescription }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "git worktree add 失败（退出码 \(process.terminationStatus)）" : text
        }
        updateWorkingDirectory(original.id, plan.path)
        return nil
        #endif
    }

    // MARK: - Agent runtime

    /// Everything the model may call, by provider id: "builtin", "mcp", "skills".
    /// Providers come and go (an MCP server connecting or dropping), so the
    /// registry is mutable and `toolProvidersRevision` lets views and the loop
    /// notice.
    @ObservationIgnored public private(set) var toolProviders: [String: any AgentToolProvider] = [:]
    public private(set) var toolProvidersRevision = 0

    /// Registers (or with nil removes) a provider under `id`.
    public func setToolProvider(id: String, _ provider: (any AgentToolProvider)?) {
        if let provider {
            toolProviders[id] = provider
        } else {
            toolProviders.removeValue(forKey: id)
        }
        toolProvidersRevision += 1
    }

    /// Plugin hooks around every tool call (Codex PreToolUse /
    /// PermissionRequest / PostToolUse); nil runs none.
    @ObservationIgnored public private(set) var toolHooks: AgentToolHooks?

    public func setToolHooks(_ hooks: AgentToolHooks?) {
        toolHooks = hooks
    }

    /// Approval cards waiting for the user, oldest first. The loop is
    /// suspended until each is resolved; Stop refuses them all.
    public private(set) var pendingApprovals: [ToolApprovalRequest] = []
    /// Tools the user allowed with 始终允许. Session-only: a relaunch asks again.
    public private(set) var alwaysAllowedTools: Set<String> = []
    /// Call ids whose tool is running right now (approved, no result yet).
    public private(set) var runningToolCallIDs: Set<String> = []
    @ObservationIgnored private var approvalWaiters: [UUID: CheckedContinuation<ToolApprovalDecision, Never>] = [:]
    /// Tools offered by each conversation's latest turn; drives the system
    /// prompt's tool section so it only speaks of tools that were sent.
    @ObservationIgnored private var offeredToolCounts: [UUID: Int] = [:]
    /// Bumped by `stop()`, so a reply still looking up its tools knows not to start.
    @ObservationIgnored private var stopGeneration = 0
    @ObservationIgnored private var readableRootsByOwner: [String: [String]] = [:]
    @ObservationIgnored private var reportedToolProblems: Set<String> = []

    /// The conversation's mode, else the settings default, else 每次询问.
    public func permissionMode(for id: UUID) -> PermissionMode {
        if let raw = conversation(id)?.permissionMode, let mode = PermissionMode(rawValue: raw) { return mode }
        return PermissionMode(rawValue: settings.defaultPermissionMode) ?? .ask
    }

    /// Sets the conversation's mode; nil follows the settings default again.
    public func setPermissionMode(_ mode: PermissionMode?, for id: UUID) {
        guard var conversation = conversation(id) else { return }
        conversation.permissionMode = mode?.rawValue
        replace(conversation)
        persist(conversation)
    }

    /// Whether this conversation's requests offer tools. Automatic (nil)
    /// offers them when the thread has a working directory.
    public func toolsEnabled(for id: UUID) -> Bool {
        guard let conversation = conversation(id) else { return false }
        if let explicit = conversation.toolsEnabled { return explicit }
        return !(conversation.workingDirectory ?? "").isEmpty
    }

    /// Turns tools on or off for the conversation; nil goes back to automatic.
    public func setToolsEnabled(_ enabled: Bool?, for id: UUID) {
        guard var conversation = conversation(id) else { return }
        conversation.toolsEnabled = enabled
        replace(conversation)
        persist(conversation)
    }

    /// Answers an approval card. 始终允许 also allows the tool for the rest of
    /// the session — except a desktop-control card, which counts as 允许一次:
    /// control asks every time. Unknown ids (already answered) are ignored.
    public func resolveApproval(_ id: UUID, _ decision: ToolApprovalDecision) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let request = pendingApprovals.remove(at: index)
        if decision == .allowAlways, request.risk != .control { alwaysAllowedTools.insert(request.toolName) }
        approvalWaiters.removeValue(forKey: id)?.resume(returning: decision)
    }

    /// The tools the next request of this conversation would offer.
    public func offeredToolSpecs(for id: UUID) async -> [AgentToolSpec] {
        await toolRegistry(for: id).specs()
    }

    /// Replaces the folders `owner` (e.g. "plugins") lets tools read without
    /// asking, such as installed plugin and skill directories.
    public func setToolReadableRoots(_ roots: [String], owner: String) {
        readableRootsByOwner[owner] = roots.isEmpty ? nil : roots
    }

    /// Where a tool call of this conversation runs.
    public func toolContext(for id: UUID) -> AgentToolContext {
        var roots = readableRootsByOwner.keys.sorted().flatMap { readableRootsByOwner[$0] ?? [] }
        // Repo and user skill folders depend on the thread's directory, so
        // they are not in the owner table.
        for root in readableRoots(for: id) where !roots.contains(root) {
            roots.append(root)
        }
        return AgentToolContext(
            conversationID: id,
            workingDirectory: conversation(id)?.workingDirectory.flatMap { $0.isEmpty ? nil : $0 },
            readableRoots: roots
        )
    }

    private func registerBuiltinTools() {
        #if os(macOS)
        if toolProviders[BuiltinToolProvider.providerID] == nil {
            setToolProvider(id: BuiltinToolProvider.providerID, BuiltinToolProvider())
        }
        #endif
    }

    private func toolRegistry(for id: UUID) async -> AgentToolRegistry {
        guard toolsEnabled(for: id), !toolProviders.isEmpty else { return .empty }
        let registry = await AgentToolRegistry.build(toolProviders)
        var problems: Set<String> = []
        for clash in registry.clashes {
            problems.insert("同名工具 \(clash.name)：保留 \(clash.keptProviderID)，忽略 \(clash.droppedProviderID)")
        }
        for invalid in registry.invalidNames {
            problems.insert("工具名不合法，已忽略：\(invalid.providerID) · \(invalid.name)")
        }
        for problem in problems.subtracting(reportedToolProblems).sorted() {
            DiagnosticsCenter.shared.record("agent", .warn, problem)
        }
        reportedToolProblems.formUnion(problems)
        return registry
    }

    /// The system prompt's tool section; empty unless this turn offers tools.
    private func agentToolsPrompt(for conversation: Conversation) -> String {
        guard (offeredToolCounts[conversation.id] ?? 0) > 0 else { return "" }
        let place = conversation.workingDirectory.flatMap { $0.isEmpty ? nil : "工作目录：\($0)，相对路径以它为准。" }
            ?? "本对话没有工作目录，文件路径请用绝对路径。"
        let rule: String
        switch permissionMode(for: conversation.id) {
        case .readOnly: rule = "当前是只读模式：只能读取，写文件和运行命令会被拒绝。"
        case .ask: rule = "读取会直接执行；写文件、运行命令、访问工作目录以外的位置要先经用户批准。"
        case .auto: rule = "读写工作目录里的文件会直接执行；运行命令、访问工作目录以外的位置要先经用户批准。"
        case .full: rule = "文件和命令会直接执行；控制桌面要先经用户批准。"
        }
        return "【工具】你可以调用工具完成任务。\(place)\(rule)调用被拒绝时换个做法或询问用户，不要重复同一个调用。优先小步、可撤销的操作：先读后改，改动范围尽量小，不做用户没要求的破坏性操作。"
    }

    /// Mutable state of one running reply, shared with the loop's callbacks.
    @MainActor
    private final class ReplyProgress {
        var first: PreparedTurn?
        var lastAssistantID: UUID?

        init(first: PreparedTurn) {
            self.first = first
        }
    }

    /// The whole reply: model turns and their tool calls, through `AgentLoop`.
    /// `isStreaming` stays true throughout, so the stop button shows.
    private func runReply(conversationID: UUID, first: PreparedTurn) async {
        let progress = ReplyProgress(first: first)
        let fallback = AgentLoop.Environment(mode: .readOnly, context: AgentToolContext(conversationID: conversationID, workingDirectory: nil))
        let host = AgentLoop.Host(
            modelTurn: { [weak self] turn in
                await self?.agentModelTurn(turn, conversationID: conversationID, progress: progress) ?? .stopped
            },
            environment: { [weak self] in
                await self?.agentEnvironment(conversationID) ?? fallback
            },
            isAlwaysAllowed: { [weak self] name in
                await self?.alwaysAllowedTools.contains(name) ?? false
            },
            requestApproval: { [weak self] request in
                await self?.awaitApproval(request) ?? .deny
            },
            willRun: { [weak self] call in
                await self?.markToolRunning(call.id)
            },
            didRun: { [weak self] call, execution in
                await self?.recordToolResult(call, execution, conversationID: conversationID)
            },
            hooks: toolHooks
        )
        let ending = await AgentLoop().run(host)
        if ending == .turnLimit, let id = progress.lastAssistantID {
            updateMessage(conversationID: conversationID, messageID: id) { message in
                message.errorText = "已达到每条消息 \(AgentLoop.maxModelTurns) 轮模型调用的上限，已停止。发送新消息可以让它继续。"
            }
        }
        finishReply(conversationID: conversationID, answered: ending == .answered)
    }

    private func agentModelTurn(_ turn: Int, conversationID: UUID, progress: ReplyProgress) async -> AgentLoop.TurnOutcome {
        let prepared: PreparedTurn
        if let first = progress.first {
            prepared = first
            progress.first = nil
        } else {
            guard !Task.isCancelled else { return .stopped }
            let registry = await toolRegistry(for: conversationID)
            guard !Task.isCancelled, let next = prepareTurn(conversationID: conversationID, registry: registry) else { return .stopped }
            prepared = next
        }
        progress.lastAssistantID = prepared.assistantID
        let report = await runStream(
            adapter: prepared.adapter, request: prepared.request,
            conversationID: conversationID, assistantID: prepared.assistantID
        )
        let calls = conversation(conversationID)?.messages.first { $0.id == prepared.assistantID }?.parts.compactMap { part -> ToolCall? in
            if case .toolCall(let call) = part { call } else { nil }
        } ?? []
        // Calls that will never run still get a result, so no row spins forever.
        let unrun: String?
        if report.cancelled {
            unrun = AgentLoop.stoppedText
        } else if report.failure != nil {
            unrun = "回复中断，这次调用没有执行"
        } else if prepared.registry.isEmpty {
            unrun = "本对话没有提供工具，这次调用没有执行"
        } else {
            unrun = nil
        }
        if let unrun {
            for call in calls { recordToolResult(call, AgentLoop.failure(call, unrun), conversationID: conversationID) }
        }
        guard report.failure == nil, !report.cancelled else { return .stopped }
        return .finished(calls: calls, registry: prepared.registry)
    }

    private func agentEnvironment(_ conversationID: UUID) -> AgentLoop.Environment {
        AgentLoop.Environment(mode: permissionMode(for: conversationID), context: toolContext(for: conversationID))
    }

    /// Shows the card and waits for `resolveApproval`. Cancelling the reply
    /// answers it as a refusal.
    private func awaitApproval(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ToolApprovalDecision, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .deny)
                    return
                }
                approvalWaiters[request.id] = continuation
                pendingApprovals.append(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveApproval(request.id, .deny) }
        }
    }

    private func markToolRunning(_ callID: String) {
        runningToolCallIDs.insert(callID)
    }

    /// Puts a call's result beside the call, in the assistant message that
    /// made it: `MessageRow`'s activity rows, file-change cards and the relay
    /// snapshot pair calls with results inside one message, and the wire
    /// encoders turn the pair into `tool_calls` + `tool` messages. Returned
    /// images are stored in the media library and ride in `result.media`.
    private func recordToolResult(_ call: ToolCall, _ execution: AgentLoop.Execution, conversationID: UUID) {
        runningToolCallIDs.remove(call.id)
        var result = execution.result
        for image in execution.images {
            let subtype = image.mimeType.split(separator: "/").last.map(String.init) ?? "png"
            do {
                result.media.append(try mediaLibrary.write(
                    data: image.data, fileExtension: subtype == "jpeg" ? "jpg" : subtype,
                    kind: .image, mimeType: image.mimeType
                ))
            } catch {
                DiagnosticsCenter.shared.record("agent", .error, "tool image save failed",
                    fields: ["tool": call.name, "error": error.localizedDescription])
            }
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: { message in
                  message.role == .assistant && message.parts.contains { part in
                      if case .toolCall(let candidate) = part { candidate.id == call.id } else { false }
                  }
              }) else { return }
        conversations[conversationIndex].messages[messageIndex].parts.append(.toolResult(result))
        conversations[conversationIndex].updatedAt = Date()
        persist(conversations[conversationIndex])
    }

    // MARK: - Side chat

    /// Side-chat messages per thread (Codex `thread.sidePanel` Side chat).
    /// Session-only on purpose: a side question is scratch work, and keeping it
    /// out of `workspace.json` keeps it out of the thread, exports, search and
    /// the relay snapshot.
    public private(set) var sideChats: [UUID: [ChatMessage]] = [:]
    /// The thread whose side chat is streaming, if any. Independent of the
    /// thread's own stream, so a side question can be asked while it replies.
    public private(set) var sideChatStreamingID: UUID?
    @ObservationIgnored private var sideChatTask: Task<Void, Never>?

    public func sideChat(for id: UUID) -> [ChatMessage] {
        sideChats[id] ?? []
    }

    /// Asks `text` about a thread (the selected one by default). The thread's
    /// transcript goes in the system prompt; nothing is added to the thread.
    /// Returns why it could not be sent, or nil once the reply is streaming.
    @discardableResult
    public func sendSideChat(_ text: String, about id: UUID? = nil) -> String? {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return "问题是空的" }
        guard sideChatStreamingID == nil else { return "旁聊还在回复" }
        guard let threadID = id ?? selectedConversationID, let thread = conversation(threadID) else {
            return "找不到这个对话"
        }
        guard let provider = resolveProvider(for: thread),
              let model = resolveModel(for: thread, provider: provider) else {
            return "先在设置中添加供应商并选择模型"
        }
        let storedKey = (try? secrets.secret(for: provider.keychainAccount)) ?? nil
        guard let apiKey = storedKey, !apiKey.isEmpty else { return "「\(provider.name)」缺少 API Key" }

        var messages = sideChats[threadID] ?? []
        messages.append(ChatMessage(role: .user, parts: [.text(question)]))
        let history = messages
        let assistant = ChatMessage(role: .assistant, parts: [], status: .streaming)
        messages.append(assistant)
        sideChats[threadID] = messages

        let request = GenerationRequest(
            modelID: model.id,
            messages: history,
            systemPrompt: SideChatContext.systemPrompt(title: thread.title, goal: thread.goal, transcript: thread.messages),
            temperature: settings.temperature,
            maxOutputTokens: settings.maxOutputTokens ?? model.limits.maxOutputTokens
        )
        let adapter = ProviderFactory.makeProvider(
            profile: provider,
            apiKey: apiKey,
            transport: transport,
            mediaPayloads: { [mediaLibrary] ref in mediaLibrary.loadPayload(for: ref) }
        )
        sideChatStreamingID = threadID
        sideChatTask = Task { [weak self] in
            await self?.runSideChat(adapter: adapter, request: request, threadID: threadID, assistantID: assistant.id)
        }
        return nil
    }

    public func stopSideChat() {
        sideChatTask?.cancel()
    }

    /// Forgets a thread's side chat, stopping its reply first.
    public func clearSideChat(_ id: UUID) {
        if sideChatStreamingID == id { sideChatTask?.cancel() }
        sideChats[id] = nil
    }

    /// Puts a side-chat answer into the composer so it can be sent to the
    /// thread on purpose — the only way side-chat text reaches the thread.
    public func insertSideChatAnswer(_ messageID: UUID, from id: UUID) {
        guard let text = sideChats[id]?.first(where: { $0.id == messageID })?.concatenatedText,
              !text.isEmpty else { return }
        draft = draft.isEmpty ? text : draft + "\n\n" + text
    }

    private func runSideChat(adapter: any ChatProvider, request: GenerationRequest, threadID: UUID, assistantID: UUID) async {
        var failure: Error?
        do {
            for try await event in adapter.stream(request) {
                if Task.isCancelled { break }
                updateSideChatMessage(threadID, assistantID) { $0.apply(event) }
            }
        } catch {
            failure = error
        }
        let cancelled = Task.isCancelled
        if cancelled, sideChats[threadID]?.first(where: { $0.id == assistantID })?.concatenatedText.isEmpty ?? true {
            // Stopped before a word arrived: drop the empty placeholder.
            sideChats[threadID]?.removeAll { $0.id == assistantID }
        } else {
            updateSideChatMessage(threadID, assistantID) { message in
                if let failure, !cancelled {
                    message.status = .failed
                    message.errorText = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
                } else {
                    message.status = .complete
                }
            }
        }
        sideChatStreamingID = nil
        sideChatTask = nil
    }

    private func updateSideChatMessage(_ threadID: UUID, _ messageID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = sideChats[threadID]?.firstIndex(where: { $0.id == messageID }) else { return }
        change(&sideChats[threadID]![index])
    }

    // MARK: - Plugins

    /// Installed Codex plugins. Tests replace it with a store over a
    /// temporary folder, then call `reloadPlugins()`.
    @ObservationIgnored public var pluginStore = PluginStore(root: PluginStore.defaultRoot())
    /// Home whose `.agents/skills` holds the user's skills (Codex USER
    /// scope). Tests point it at a temporary folder; nil reads none.
    @ObservationIgnored public var skillsHome: String? = HostExecutor.realHomeDirectory()
    /// Installed plugins as of the last `reloadPlugins()`.
    public private(set) var installedPlugins: [InstalledPlugin] = []
    /// Bundled servers of enabled plugins (ids `<plugin>-<server>`, origin
    /// `plugin:<id>`), for the MCP manager to merge with its own.
    public private(set) var pluginMCPServers: [MCPServerConfig] = []
    /// Folders `read_file` may read without asking: enabled plugins and the
    /// user's skill folders. Also registered as the "plugins" readable roots.
    public private(set) var pluginReadableRoots: [String] = []
    /// Bumped by every `reloadPlugins()`.
    public private(set) var pluginsRevision = 0
    /// The most recent hook runs, oldest first.
    public private(set) var hookRunLog: [HookRunRecord] = []
    public static let hookRunLogCapacity = 50
    @ObservationIgnored private var activePluginHooks: [PluginHook] = []
    /// PreToolUse `additionalContext` waiting for its call's result.
    @ObservationIgnored private var pendingHookContext: [String: String] = [:]

    /// Re-reads installed plugins and the user's skills, and passes what they
    /// contribute on: MCP servers, readable folders and tool hooks.
    public func reloadPlugins() {
        let plugins = pluginStore.installed()
        installedPlugins = plugins
        pluginMCPServers = plugins.flatMap(\.activeMCPServers)
        activePluginHooks = plugins.flatMap(\.activeHooks)
        var roots = plugins.flatMap(\.activeReadableRoots)
        for root in SkillCatalog.load(roots: baseSkillRoots(plugins)).readableRoots where !roots.contains(root) {
            roots.append(root)
        }
        pluginReadableRoots = roots
        setToolReadableRoots(roots, owner: "plugins")
        installPluginToolHooks()
        pluginsRevision += 1
    }

    /// User skills, then enabled plugins' skills: every thread sees these.
    private func baseSkillRoots(_ plugins: [InstalledPlugin]) -> [SkillRoot] {
        var roots: [SkillRoot] = []
        if let home = skillsHome, let user = SkillCatalog.userRoot(home: home) { roots.append(user) }
        return roots + plugins.flatMap(\.activeSkillRoots)
    }

    /// Skills available to a thread: its repository's `.agents/skills`
    /// (nearest the working directory first), the user's, then plugins'.
    /// Read from disk on each call, so edited skills show up at once.
    public func skillCatalog(for conversationID: UUID?) -> SkillCatalog {
        var roots: [SkillRoot] = []
        if let id = conversationID, let directory = conversation(id)?.workingDirectory, !directory.isEmpty {
            roots += SkillCatalog.repositoryRoots(workingDirectory: directory)
        }
        return SkillCatalog.load(roots: roots + baseSkillRoots(installedPlugins))
    }

    /// The system prompt's skills list, within 2% of the model's context
    /// window (8,000 characters when unknown). Nil when the thread is not
    /// offered the built-in tools, since the model reads a skill with
    /// `read_file`.
    public func skillPromptSection(for conversationID: UUID) -> String? {
        guard let conversation = conversation(conversationID), toolsEnabled(for: conversationID),
              toolProviders[BuiltinToolProvider.providerID] != nil else { return nil }
        let modelID = conversation.modelID ?? settings.defaultModelID
        let window = models.first { $0.id == modelID }?.limits.contextWindow
        return skillCatalog(for: conversationID).promptSection(budget: .forContextWindow(window))
    }

    /// Folders `read_file` may read for this thread: `pluginReadableRoots`
    /// plus its repository skill folders, which can sit above the working
    /// directory.
    public func readableRoots(for conversationID: UUID) -> [String] {
        var roots = pluginReadableRoots
        for root in skillCatalog(for: conversationID).readableRoots where !roots.contains(root) {
            roots.append(root)
        }
        return roots
    }

    /// The thread's AGENTS.md instructions and the files they came from,
    /// root → leaf. Nil without a working directory or any non-empty file.
    public func agentsDocPrompt(for conversationID: UUID) -> (text: String, files: [String])? {
        guard let directory = conversation(conversationID)?.workingDirectory, !directory.isEmpty,
              let doc = AgentsMDLoader.load(workingDirectory: directory) else { return nil }
        let text = """
        ## 项目说明（AGENTS.md）
        以下内容来自从仓库根目录到工作目录的 AGENTS.md 文件，按这个顺序排列：越靠后的离工作目录越近，冲突时以靠后的为准。

        \(doc.text)
        """
        return (text, doc.files)
    }

    // Install, switches and uninstall. Each reloads on success.

    public func preparePluginInstall(folder: String) throws -> PluginInstallPlan {
        try pluginStore.prepareInstall(folder: folder)
    }

    public func preparePluginInstall(gitURL: String, ref: String?, subdirectory: String?) async throws -> PluginInstallPlan {
        let store = pluginStore
        return try await store.prepareInstall(gitURL: gitURL, ref: ref, subdirectory: subdirectory, runner: Self.pluginCommandRunner)
    }

    /// Installs a plan the user confirmed. Its hooks stay off until trusted.
    public func confirmPluginInstall(_ plan: PluginInstallPlan) throws {
        try pluginStore.commitInstall(plan)
        reloadPlugins()
    }

    public func cancelPluginInstall(_ plan: PluginInstallPlan) {
        pluginStore.discardInstall(plan)
    }

    public func uninstallPlugin(_ id: String) throws {
        try pluginStore.uninstall(id: id)
        reloadPlugins()
    }

    public func setPluginEnabled(_ enabled: Bool, id: String) throws {
        try pluginStore.setEnabled(enabled, id: id)
        reloadPlugins()
    }

    /// 「信任此插件的钩子」: trusts the plugin's current hook definitions.
    public func setPluginHooksTrusted(_ trusted: Bool, id: String) throws {
        try pluginStore.setHooksTrusted(trusted, id: id)
        reloadPlugins()
    }

    public func setPluginMCPServerEnabled(_ enabled: Bool, server: String, pluginID: String) throws {
        try pluginStore.setMCPServerEnabled(enabled, server: server, pluginID: pluginID)
        reloadPlugins()
    }

    /// Runs the trusted hooks of enabled plugins for one tool call, with
    /// Codex's names: `shell` is `Bash`, `write_file` / `edit_file` are
    /// `apply_patch` (matchers `Edit` and `Write` too), MCP tools are
    /// `mcp__<server>__<tool>`. Other tools have no hooks, as in Codex.
    public func runToolHooks(
        event: HookEvent, toolName: String, argumentsJSON: String, conversationID: UUID,
        callID: String = "", toolResponse: String? = nil
    ) async -> HookOutcome {
        let proceed = HookOutcome.allow(context: nil, updatedArgumentsJSON: nil)
        guard event.isTriggered, !activePluginHooks.isEmpty,
              let call = hookToolCall(name: toolName, argumentsJSON: argumentsJSON, callID: callID, toolResponse: toolResponse) else { return proceed }
        let selected = HookRunner.matching(activePluginHooks, event: event, call: call)
        guard !selected.isEmpty else { return proceed }
        for folder in Set(selected.map(\.pluginData)) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let report = await HookRunner(runner: Self.pluginCommandRunner)
            .run(event, call: call, session: hookSession(conversationID: conversationID, callID: callID), hooks: selected)
        hookRunLog.append(contentsOf: report.records)
        if hookRunLog.count > Self.hookRunLogCapacity { hookRunLog.removeFirst(hookRunLog.count - Self.hookRunLogCapacity) }
        for message in report.systemMessages {
            DiagnosticsCenter.shared.record("plugins", .warn, message, fields: ["tool": call.toolName, "event": event.rawValue])
        }
        // Codex reports a failed hook and carries on; so does this.
        for record in report.records where record.status == .failed {
            DiagnosticsCenter.shared.record("plugins", .warn, "hook failed",
                fields: ["plugin": record.pluginID, "event": event.rawValue, "tool": call.toolName, "error": record.message ?? ""])
        }
        let context = report.additionalContext.isEmpty ? nil : report.additionalContext.joined(separator: "\n\n")
        switch event {
        case .preToolUse:
            if let reason = report.blockReason { return .block(reason) }
            guard let updated = report.updatedInputJSON else { return .allow(context: context, updatedArgumentsJSON: nil) }
            switch call.kind {
            case .applyPatch:
                return .block("插件钩子要求改写这次文件修改（apply_patch 的 updatedInput）；本应用不能按补丁改写文件修改，所以没有执行。")
            case .bash:
                return .allow(context: context, updatedArgumentsJSON: Self.merging(updated, over: argumentsJSON))
            case .mcp:
                return .allow(context: context, updatedArgumentsJSON: updated)
            }
        case .permissionRequest:
            switch report.permission {
            case .deny(let message)?: return .block(message)
            case .allow?: return .approve
            case nil: return proceed
            }
        default:
            if let feedback = report.feedback { return .block(feedback) }
            return .allow(context: context, updatedArgumentsJSON: nil)
        }
    }

    /// Wires `runToolHooks` into the agent loop; no hooks, no wiring.
    private func installPluginToolHooks() {
        guard !activePluginHooks.isEmpty else {
            setToolHooks(nil)
            return
        }
        setToolHooks(AgentToolHooks(
            preToolUse: { [weak self] call, _, context in
                guard let self else { return .proceed }
                switch await self.runToolHooks(event: .preToolUse, toolName: call.name, argumentsJSON: call.argumentsJSON, conversationID: context.conversationID, callID: call.id) {
                case .block(let reason):
                    return .block(reason)
                case .allow(let note, let updated):
                    if let note { await self.stashHookContext(note, for: call.id) }
                    return updated.map { .rewrite(argumentsJSON: $0) } ?? .proceed
                case .approve:
                    return .proceed
                }
            },
            permissionRequest: { [weak self] call, _, context in
                guard let self else { return .undecided }
                switch await self.runToolHooks(event: .permissionRequest, toolName: call.name, argumentsJSON: call.argumentsJSON, conversationID: context.conversationID, callID: call.id) {
                case .approve: return .allow
                case .block(let message): return .deny(message)
                case .allow: return .undecided
                }
            },
            postToolUse: { [weak self] call, _, result, context in
                guard let self else { return .keep }
                let earlier = await self.takeHookContext(for: call.id)
                switch await self.runToolHooks(
                    event: .postToolUse, toolName: call.name, argumentsJSON: call.argumentsJSON,
                    conversationID: context.conversationID, callID: call.id, toolResponse: result.outputText
                ) {
                case .block(let feedback):
                    return .replace(feedback)
                case .allow(let note, _):
                    let notes = [earlier, note].compactMap { $0 }
                    return notes.isEmpty ? .keep : .append(notes.joined(separator: "\n\n"))
                case .approve:
                    return .keep
                }
            }
        ))
    }

    private func stashHookContext(_ note: String, for callID: String) {
        // Entries of calls the policy refused are never taken; keep it small.
        if pendingHookContext.count > 100 { pendingHookContext.removeAll() }
        pendingHookContext[callID] = note
    }

    private func takeHookContext(for callID: String) -> String? {
        pendingHookContext.removeValue(forKey: callID)
    }

    /// The call as Codex hooks name it, or nil for a tool Codex does not hook.
    private func hookToolCall(name: String, argumentsJSON: String, callID: String, toolResponse: String?) -> HookToolCall? {
        let response = toolResponse.map(Self.jsonString)
        if let mcp = toolProviders["mcp"] as? MCPToolProvider, let target = mcp.target(forWireName: name) {
            // A plugin's server keeps the name from its own config, so the
            // plugin's matchers (`mcp__docs__.*`) still match.
            let server = pluginMCPServers.first { $0.id == target.serverID }?.name ?? target.serverID
            return HookToolCall(kind: .mcp, toolName: "mcp__\(server)__\(target.tool)", toolInputJSON: argumentsJSON, toolUseID: callID, toolResponseJSON: response)
        }
        switch name {
        case "shell":
            return HookToolCall(kind: .bash, toolName: "Bash", toolInputJSON: argumentsJSON, toolUseID: callID, toolResponseJSON: response)
        case "write_file", "edit_file":
            return HookToolCall(kind: .applyPatch, toolName: "apply_patch", toolInputJSON: Self.applyPatchInput(tool: name, argumentsJSON: argumentsJSON), toolUseID: callID, toolResponseJSON: response)
        default:
            return nil
        }
    }

    private func hookSession(conversationID: UUID, callID: String) -> HookSession {
        let conversation = conversation(conversationID)
        // The turn is the assistant message that made the call.
        let turn = conversation?.messages.last { message in
            message.role == .assistant && message.parts.contains { part in
                if case .toolCall(let candidate) = part { candidate.id == callID } else { false }
            }
        }?.id ?? conversation?.messages.last { $0.role == .assistant }?.id
        let directory = conversation?.workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? HostExecutor.realHomeDirectory()
        return HookSession(
            sessionID: conversationID.uuidString,
            turnID: turn?.uuidString ?? "",
            cwd: directory,
            model: conversation?.modelID ?? settings.defaultModelID ?? "",
            permissionMode: HookSession.codexPermissionMode(permissionMode(for: conversationID))
        )
    }

    /// Codex's `apply_patch` input: the edit as a patch in `command`, with
    /// the built-in tool's own arguments alongside.
    nonisolated static func applyPatchInput(tool: String, argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              var arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = arguments["path"] as? String else { return argumentsJSON }
        func lines(_ text: String, _ prefix: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
        }
        var patch = "*** Begin Patch\n"
        if tool == "write_file" {
            patch += "*** Add File: \(path)\n" + lines(arguments["content"] as? String ?? "", "+") + "\n"
        } else {
            patch += "*** Update File: \(path)\n@@\n"
                + lines(arguments["old_string"] as? String ?? "", "-") + "\n"
                + lines(arguments["new_string"] as? String ?? "", "+") + "\n"
        }
        patch += "*** End Patch"
        arguments["command"] = patch
        guard let encoded = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else { return argumentsJSON }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// `replacement`'s keys over `original`'s: a Bash `updatedInput` sets
    /// `command` and keeps the call's other arguments, such as its timeout.
    nonisolated static func merging(_ replacement: String, over original: String) -> String {
        guard let new = replacement.data(using: .utf8).flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }) else { return replacement }
        var merged = original.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        merged.merge(new) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) else { return replacement }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs plugin commands (hooks, `git clone`) through `HostExecutor`.
    nonisolated static let pluginCommandRunner: PluginCommandRunner = { command in
        #if os(macOS)
        let run = await HostExecutor.runCommand(
            command.command, cwd: command.cwd, stdin: command.stdin, timeout: command.timeout,
            loginShell: command.loginShell, extraEnvironment: command.environment
        )
        return PluginCommandResult(
            exitCode: run.exitCode, stdout: run.stdout, stderr: run.stderr, timedOut: run.timedOut,
            launchError: run.launchError ?? (run.cancelled ? "已取消" : nil)
        )
        #else
        return PluginCommandResult(exitCode: -1, launchError: "iPhone 上不能运行插件命令")
        #endif
    }

    // MARK: - MCP

    #if os(macOS)
    @ObservationIgnored private var mcpManagerStorage: MCPManager?

    /// The MCP servers of 设置 → MCP 服务器, connected and offered to the agent
    /// as the "mcp" tool provider. Created on first use; `startMCP()` connects.
    public var mcp: MCPManager {
        if let existing = mcpManagerStorage { return existing }
        let manager = MCPManager(model: self)
        mcpManagerStorage = manager
        return manager
    }

    /// Connects the enabled MCP servers and keeps them in step with settings.
    /// Call once after `bootstrap()`; later calls do nothing.
    public func startMCP() {
        mcp.start()
    }
    #endif

    /// A secret environment value of an MCP server, from the vault.
    func mcpSecret(serverID: String, variable: String) -> String? {
        let account = MCPServerConfig.vaultAccount(serverID: serverID, variable: variable)
        guard let value = (try? secrets.secret(for: account)) ?? nil, !value.isEmpty else { return nil }
        return value
    }

    /// Stores (nil or blank: removes) a secret environment value of an MCP
    /// server. False when the vault refused the write.
    @discardableResult
    func setMCPSecret(_ value: String?, serverID: String, variable: String) -> Bool {
        let account = MCPServerConfig.vaultAccount(serverID: serverID, variable: variable)
        let stored = value.flatMap { $0.isEmpty ? nil : $0 }
        do {
            try secrets.setSecret(stored, for: account)
            return true
        } catch {
            DiagnosticsCenter.shared.record("mcp", .error, "secret write failed",
                fields: ["server": serverID, "error": error.localizedDescription])
            return false
        }
    }
}

/// A long clipboard paste kept as a chip instead of inline draft text.
public struct PastedTextAttachment: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var text: String
    public var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }
}

import UserNotifications

/// Posts a local notification when a reply finishes while the user is in
/// another conversation or the app is backgrounded.
enum CompletionNotifier {
    static func notify(title: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "回复已完成"
            content.body = title
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
