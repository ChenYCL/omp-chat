import Foundation
import Observation
import OMPCore
#if os(macOS)
import AppKit
#endif

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
                pickedMentionsByConversation[oldID] = pickedMentions
            }
        }
        didSet {
            dictationFollowSelection()
            if let id = selectedConversationID {
                pickedMentions = pickedMentionsByConversation[id] ?? []
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
                pickedMentions = []
                draft = ""
                draftAttachments = []
                pastedTexts = []
            }
        }
    }
    public var draft = "" {
        didSet { prunePickedMentions() }
    }
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
    /// Conversations whose current reply a paired phone started; see
    /// `effectivePermissionMode(for:)`.
    @ObservationIgnored private var remoteDrivenConversations: Set<UUID> = []
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

    // MARK: - Local environments (slice: LocalEnvironments)

    /// Codex local environments (`.codex/environments/*.toml`). Discovery is
    /// cached briefly so header rendering and the settings pane never hit the
    /// disk on every render; writes drop the cache for their project. The key
    /// is the standardized project root, matching
    /// `AppSettings.localEnvironmentSelections`.
    @ObservationIgnored private var localEnvironmentCache: [String: (files: [LocalEnvironmentFile], at: Date)] = [:]
    /// Revision (size + hash) seen when a file was last listed, so a save can
    /// refuse to clobber a file that changed on disk since.
    @ObservationIgnored private var localEnvironmentRevisions: [String: String] = [:]
    /// The terminal's next command; the panel clears it once taken.
    public private(set) var sidePanelTerminalRequest: SidePanelTerminalRequest?
    /// How long a discovery result is reused before the disk is asked again.
    @ObservationIgnored private static let localEnvironmentCacheLifetime: TimeInterval = 2

    // MARK: - Settings navigation

    /// A settings section to show next (`ProviderSettingsView.SettingsSection`
    /// raw value). The settings window consumes and clears it; nothing else
    /// reads it.
    public var requestedSettingsSection: String?

    // MARK: - ExternalImport prompt

    /// Non-nil while the first-launch import prompt should be on screen.
    /// macOS only; set once after bootstrap when something importable exists
    /// and the user has not dismissed it.
    public var externalImportPrompt: ExternalImportScan?

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
            scheduledTasks = try await store.loadScheduledTasks()
            managedWorktrees = try await store.loadManagedWorktrees()
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
            scheduledTasks = []
            managedWorktrees = []
            DiagnosticsCenter.shared.record("workspace", .error, "workspace load failed",
                fields: ["error": error.localizedDescription])
        }
        for provider in providers {
            apiKeys[provider.id] = (try? secrets.secret(for: provider.keychainAccount)) ?? ""
        }
        // A reply cannot be running yet; one saved mid-stream was cut off.
        for index in conversations.indices where conversations[index].closeInterruptedReplies() {
            try? await store.save(conversations[index])
        }
        // Rows written before deleting a chat unlinked it (or by a deletion
        // that wrote back a stale copy) still name chats that are gone.
        let existing = Set(conversations.map(\.id))
        for record in managedWorktrees {
            for missing in record.conversationIDs where !existing.contains(missing) {
                unlinkDeletedConversationFromWorktrees(missing)
            }
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
        await presentExternalImportPromptIfNeeded()
        // Worktree housekeeping runs off the main actor inside; a deleted
        // worktree's chat shows its 恢复 pill whenever it is opened later.
        _ = await runWorktreeCleanup()
        await refreshWorktreeDetails()
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
                // Codex-managed worktree: detached under the managed root,
                // registered, `.worktreeinclude` copied, setup script run.
                if case .failure(let failure) = await createManagedWorktreeRecord(
                    for: copy.id,
                    baseBranch: nil,
                    carryUncommittedChanges: true,
                    bindConversation: true,
                    sourceDirectory: original.workingDirectory
                ) {
                    // The copy already exists; say why its checkout failed
                    // rather than leaving a fork that silently points nowhere.
                    return failure.message
                }
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
        // A reply (or an approval card) of a deleted chat would otherwise run
        // on with nothing to show it, keeping the stop button and the cards
        // alive for a conversation that no longer exists.
        if streamingConversationID == id { stop() }
        conversations.removeAll { $0.id == id }
        Task { try? await store.delete(id: id) }
        draftsByConversation.removeValue(forKey: id)
        attachmentsByConversation.removeValue(forKey: id)
        pickedMentionsByConversation.removeValue(forKey: id)
        clearSideChat(id)
        unlinkDeletedConversationFromWorktrees(id)
        if selectedConversationID == id {
            selectedConversationID = sortedConversations.first?.id
        }
        if conversations.isEmpty { _ = newConversation() }
    }

    public func renameConversation(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var conversation = conversation(id) else { return }
        let entry = AppUndoEntry.renamed(conversation, to: trimmed)
        conversation.title = trimmed
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
        registerUndo(entry)
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

    // MARK: - Open in

    /// Which paths assistant messages mention exist, checked once per
    /// (working directory, path) so re-rendering a message stays off the disk.
    @ObservationIgnored public let fileReferences = FileReferenceResolver(home: HostExecutor.realHomeDirectory())

    /// A file the side panel's 文件 tab is asked to show. `id` makes asking
    /// for the same file again count as a new request.
    public struct SidePanelFileRequest: Equatable, Sendable {
        public let id: UUID
        public let path: String
        /// 1-based line to scroll to and select.
        public let line: Int?
    }

    /// The file the 文件 tab shows next; the panel clears it once shown.
    public private(set) var sidePanelFileRequest: SidePanelFileRequest?

    /// A mentioned file's 打开文件: shows `path` in the side panel's 文件 tab,
    /// scrolled to `line`. A directory is listed instead.
    public func openFileInSidePanel(_ path: String, line: Int? = nil) {
        sidePanelFileRequest = SidePanelFileRequest(id: UUID(), path: path, line: line)
        toggleSidePanel(open: true, tab: .files)
    }

    /// The panel took request `id`; a later request is left in place.
    public func finishSidePanelFileRequest(_ id: UUID) {
        if sidePanelFileRequest?.id == id { sidePanelFileRequest = nil }
    }

    /// The most 拷贝文件内容 copies.
    public static let fileCopyLimit = 1024 * 1024

    /// 拷贝文件内容: the file's text on the pasteboard. A file over 1 MB, a
    /// binary file or a folder is refused; the reason is returned and shown.
    @discardableResult
    public func copyFileContents(_ path: String) -> String? {
        do {
            copyToPasteboard(try FileReference.readText(at: path, limit: Self.fileCopyLimit))
            return nil
        } catch {
            showError(error.localizedDescription)
            return error.localizedDescription
        }
    }

    /// 拷贝路径.
    public func copyFilePath(_ path: String) {
        copyToPasteboard(path)
    }

    #if os(macOS)
    /// Installed apps of `OpenInTarget.catalog`, looked up once per launch.
    @ObservationIgnored private var installedOpenInApps: [OpenInApps.Installed]?

    /// With icons, for the menus.
    var openInApps: [OpenInApps.Installed] {
        if let installedOpenInApps { return installedOpenInApps }
        let found = OpenInApps.installed()
        installedOpenInApps = found
        return found
    }

    /// The catalog's apps installed on this Mac, in menu order.
    public var openInTargets: [OpenInTarget] { openInApps.map(\.target) }

    /// The header's primary Open-in app: the last one used while it is still
    /// installed, otherwise the first installed.
    public var preferredOpenInTarget: OpenInTarget? {
        OpenInTarget.preferred(lastUsedID: settings.openInTargetID, installed: openInTargets)
    }

    /// Opens `path` — the thread's folder or a mentioned file — in the app
    /// `targetID` names, the preferred one when nil, and remembers that app
    /// for the header's primary button. Returns why it failed, which also
    /// shows in the error banner.
    @discardableResult
    public func open(_ path: String, in targetID: String? = nil) async -> String? {
        let failure = await openFailure(path, in: targetID ?? preferredOpenInTarget?.id)
        if let failure { showError(failure) }
        return failure
    }

    private func openFailure(_ path: String, in targetID: String?) async -> String? {
        guard let app = openInApps.first(where: { $0.target.id == targetID }) else {
            let name = OpenInTarget.catalog.first { $0.id == targetID }?.name ?? targetID ?? "应用"
            return "这台 Mac 上没有安装\(name)"
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "“\(path)”不存在"
        }
        do {
            try await OpenInApps.perform(app.target.action(for: path, isDirectory: isDirectory.boolValue), with: app.url)
        } catch {
            return "无法在\(app.target.name)中打开：\(error.localizedDescription)"
        }
        if settings.openInTargetID != app.target.id {
            var updated = settings
            updated.openInTargetID = app.target.id
            await saveSettings(updated)
        }
        return nil
    }

    /// 在访达中显示: selects `path` in its Finder folder.
    @discardableResult
    public func revealInFinder(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            showError("“\(path)”不存在")
            return "“\(path)”不存在"
        }
        OpenInApps.reveal(path)
        return nil
    }
    #endif

    // MARK: - Code review

    /// 「用 Codex 审查」: reviews the uncommitted changes of the thread's
    /// working directory — or `directory`, the 改动 tab's checkout — in a new
    /// thread 「审查：<分支>」 bound to that directory, 只读 with tools on, so
    /// the reviewer can read files for context but change nothing. Selects
    /// it and sends the request. Returns why no review started.
    @discardableResult
    public func startCodeReview(for conversationID: UUID, directory: String? = nil) async -> String? {
        guard let source = conversation(conversationID) else { return "找不到这个对话" }
        guard let directory = directory ?? source.workingDirectory, !directory.isEmpty else {
            return "这个对话没有绑定工作目录"
        }
        guard !isStreaming else { return "当前回复结束后再开始审查" }
        guard resolveProvider(for: source) != nil else { return "先在设置中添加供应商" }
        let material: CodeReviewPrompt.Material
        do {
            material = try await Task.detached(priority: .userInitiated) {
                try CodeReviewPrompt.collect(in: directory)
            }.value
        } catch {
            return error.localizedDescription
        }
        guard let request = CodeReviewPrompt.build(material) else { return "没有可审查的改动" }
        // A reply may have started while git ran.
        guard !isStreaming else { return "当前回复结束后再开始审查" }
        var review = Conversation(
            title: CodeReviewPrompt.title(for: material),
            providerID: source.providerID,
            modelID: source.modelID,
            projectID: source.projectID,
            workingDirectory: directory
        )
        review.permissionMode = PermissionMode.readOnly.rawValue
        review.toolsEnabled = true
        review.isCodeReview = true
        conversations.append(review)
        selectedConversationID = review.id
        persist(review)
        await sendNow(text: request, attachments: [])
        return nil
    }

    /// How the review thread's request ended, for the note above it; nil
    /// for any other thread.
    public func codeReviewOutcome(_ conversationID: UUID) -> CodeReviewPrompt.Outcome? {
        guard let conversation = conversation(conversationID) else { return nil }
        return CodeReviewPrompt.outcome(
            of: conversation,
            isStreaming: isStreaming && streamingConversationID == conversationID
        )
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
        let entry = AppUndoEntry.renamedGroup(projects[index], to: trimmed)
        projects[index].name = trimmed
        persistProjects()
        registerUndo(entry)
    }

    public func deleteProject(_ id: UUID) {
        let position = projects.firstIndex(where: { $0.id == id })
        let group = position.map { projects[$0] }
        let members = conversations.filter { $0.projectID == id }.map(\.id)
        projects.removeAll { $0.id == id }
        for index in conversations.indices where conversations[index].projectID == id {
            conversations[index].projectID = nil
            persist(conversations[index])
        }
        persistProjects()
        if let group, let position {
            registerUndo(.deletedGroup(group, position: position, memberIDs: members))
        }
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
        registerUndo(.createdGroup(section))
        return section
    }

    /// Archives every conversation in a custom section (bulk `archiveAll`).
    public func archiveConversations(inCustomSection sectionID: UUID) {
        let archived = conversations.filter { $0.projectID == sectionID && !$0.isArchived }
        for index in conversations.indices
        where conversations[index].projectID == sectionID && !conversations[index].isArchived {
            conversations[index].isArchived = true
            conversations[index].isPinned = false
            persist(conversations[index])
        }
        registerUndo(.archived(archived))
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
        let entry = AppUndoEntry.renamedGroup(projects[index], to: trimmed)
        projects[index].name = trimmed
        persistProjects()
        registerUndo(entry)
    }

    public func deleteCustomSection(_ id: UUID) {
        let position = projects.firstIndex(where: { $0.id == id })
        let group = position.map { projects[$0] }
        let members = conversations.filter { $0.projectID == id }.map(\.id)
        projects.removeAll { $0.id == id }
        for index in conversations.indices where conversations[index].projectID == id {
            conversations[index].projectID = nil
            persist(conversations[index])
        }
        persistProjects()
        if let group, let position {
            registerUndo(.deletedGroup(group, position: position, memberIDs: members))
        }
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
        let destination = projectID.flatMap { target in projects.first { $0.id == target } }
        // A move into a group that does not exist has no honest message.
        let entry = projectID == nil || destination != nil ? AppUndoEntry.moved(conversation, to: destination) : nil
        conversation.projectID = projectID
        replace(conversation)
        persist(conversation)
        registerUndo(entry)
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
        let before = conversation
        conversation.isArchived.toggle()
        replace(conversation)
        persist(conversation)
        registerUndo(.toggledArchive(before))
        if conversation.isArchived, selectedConversationID == id {
            selectedConversationID = sortedConversations.first?.id
        }
        // Official: a managed worktree goes with its chat's archive (snapshot
        // first), unless the switch is off or another chat still uses it.
        // The policy refuses pinned or streaming chats on its own, so an
        // archived-but-pinned chat keeps its worktree — exactly the official
        // "won't be deleted automatically if a pinned chat is tied to it".
        if conversation.isArchived {
            Task { _ = await runWorktreeCleanup() }
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
        let before = ordered.compactMap { conversation($0.id) }
        let newIndexes = Dictionary(
            ordered.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let entry = AppUndoEntry.reordered(before, newIndexes: newIndexes)
        for (index, item) in ordered.enumerated() {
            guard var conversation = conversation(item.id) else { continue }
            conversation.sortIndex = index
            replace(conversation)
            persist(conversation)
        }
        registerUndo(entry)
    }

    public func togglePin(_ id: UUID) {
        guard var conversation = conversation(id) else { return }
        let before = conversation
        conversation.isPinned.toggle()
        replace(conversation)
        persist(conversation)
        registerUndo(.toggledPin(before))
    }

    public func setUnread(_ id: UUID, unread: Bool) {
        guard var conversation = conversation(id) else { return }
        conversation.hasUnread = unread
        replace(conversation)
        persist(conversation)
    }

    // MARK: - Undo

    /// Sidebar actions 撤销 / ⌘Z can take back, newest last (Codex `appUndo.*`).
    /// The actions register themselves, so the desktop sidebar, the phone
    /// drawer, the sheets and debug actions all record them alike.
    public private(set) var undoStack = AppUndoStack()
    /// The bottom toast: the newest action with 撤销, or an undo's result.
    /// Dismissing it keeps the history, so the Edit menu can still undo.
    public private(set) var undoToast: AppUndoToast?
    /// Off while a paired phone's command runs. The phone shows no toast and
    /// has no undo of its own; recording its actions here would announce on
    /// the Mac something its user did not do, and let a ⌘Z at the Mac
    /// silently revert what was done on the phone.
    @ObservationIgnored private var recordsUndo = true

    private func registerUndo(_ entry: AppUndoEntry?) {
        guard recordsUndo, let entry else { return }
        undoStack.push(entry)
        undoToast = AppUndoToast(message: entry.message, offersUndo: true)
    }

    /// Takes the newest action back and returns what the toast then shows:
    /// the confirmation, or why it could not be undone (the entry is dropped
    /// either way). Nil when there is nothing to undo.
    @discardableResult
    public func undoLast() -> String? {
        guard let entry = undoStack.pop() else { return nil }
        var workspace = AppUndoWorkspace(
            conversations: conversations,
            projects: projects,
            composerConversationID: selectedConversationID,
            composerAttachments: draftAttachments,
            parkedAttachments: attachmentsByConversation
        )
        let text: String
        switch entry.inverse.apply(to: &workspace) {
        case .failed(let reason):
            text = reason
        case .restored(let changes):
            if !changes.conversationIDs.isEmpty {
                conversations = workspace.conversations
                let changed = Set(changes.conversationIDs)
                for conversation in conversations where changed.contains(conversation.id) {
                    persist(conversation)
                }
            }
            if changes.projects {
                projects = workspace.projects
                persistProjects()
            }
            if changes.attachments {
                draftAttachments = workspace.composerAttachments
                attachmentsByConversation = workspace.parkedAttachments
            }
            text = entry.confirmation
        }
        undoToast = AppUndoToast(message: text, offersUndo: false)
        return text
    }

    public func dismissUndoToast() {
        undoToast = nil
    }

    private func withoutUndo(_ body: () -> Void) {
        let previous = recordsUndo
        recordsUndo = false
        defer { recordsUndo = previous }
        body()
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
        // The field shows mentions readably; the send path reads tokens.
        let text = draftForSending
        let attachments = draftAttachments
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == Self.compactCommand, attachments.isEmpty, pastedTexts.isEmpty,
           let id = selectedConversationID {
            draft = ""
            Task { _ = await compactConversation(id) }
            return
        }
        // A reply running in this conversation takes the message as a
        // follow-up; one running elsewhere still blocks the composer.
        guard !isStreaming || streamingConversationID == selectedConversationID else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || !pastedTexts.isEmpty else { return }
        let pastes = pastedTexts
        // Worktree mode: the first message of an empty, directory-bound chat
        // creates the managed worktree first (progress card shows the phases).
        // The draft only clears once the checkout exists, so a failure leaves
        // the message in place to retry.
        if let id = selectedConversationID, needsWorktreeFirstSend(id) {
            let conversationID = id
            let baseBranch = worktreeBaseBranch(for: conversationID)
            Task {
                if let failure = await createManagedWorktree(for: conversationID, baseBranch: baseBranch) {
                    errorMessage = failure
                    return
                }
                draft = ""
                draftAttachments = []
                pastedTexts = []
                draftsByConversation.removeValue(forKey: conversationID)
                attachmentsByConversation.removeValue(forKey: conversationID)
                pickedMentionsByConversation.removeValue(forKey: conversationID)
                await sendNow(text: text, attachments: attachments, pastes: pastes)
            }
            return
        }
        draft = ""
        draftAttachments = []
        pastedTexts = []
        if let id = selectedConversationID {
            draftsByConversation.removeValue(forKey: id)
            attachmentsByConversation.removeValue(forKey: id)
            pickedMentionsByConversation.removeValue(forKey: id)
        }
        Task { await sendNow(text: text, attachments: attachments, pastes: pastes) }
    }

    public func sendNow(text: String, attachments: [MediaRef], pastes: [PastedTextAttachment] = [], remote: Bool = false) async {
        guard var conversation = selectedConversation else { return }
        guard resolveProvider(for: conversation) != nil else {
            errorMessage = "先在设置中添加供应商"
            showSettings = true
            return
        }

        // Mentions are read now, at send time; a phone's text goes as typed.
        let replyToID = replyingTo?.id
        let mentions = remote ? [] : await resolveMentions(in: text, for: conversation.id).attachments
        if !mentions.isEmpty {
            // Reading files or a page awaited: go on with the thread as it is
            // now, wherever the selection went meanwhile.
            guard let current = self.conversation(conversation.id) else { return }
            conversation = current
        }
        let queued = QueuedMessage(
            text: text, attachments: attachments, pastes: pastes.map(\.text), mentions: mentions,
            replyToID: replyToID, remote: remote
        )
        if replyingTo?.id == replyToID { replyingTo = nil }
        AudioFeedback.playSend(enabled: settings.soundEffects)
        // A reply (or a compaction) is running here: the message waits for
        // the next point the model can read it instead of cancelling it.
        if streamingConversationID == conversation.id {
            enqueue(queued, in: conversation.id)
            return
        }
        conversation.messages.append(queued.message)
        if conversation.title == "新对话" {
            let seed = queued.shownText.trimmingCharacters(in: .whitespacesAndNewlines)
            conversation.title = seed.isEmpty ? "图片消息" : String(seed.prefix(28))
        }
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
        await startReply(conversationID: conversation.id, remote: remote)
    }

    /// Appends an assistant placeholder and streams the reply for the
    /// conversation's current tail of messages. With tools on offer the reply
    /// is an agent loop (`runReply`): the turn's tool calls run and the model
    /// is called again, until it answers or `AgentLoop.maxModelTurns`.
    private func startReply(conversationID: UUID, remote: Bool = false) async {
        // Remembered for the whole loop: effectivePermissionMode reads it on
        // every tool call.
        if remote {
            remoteDrivenConversations.insert(conversationID)
        } else {
            remoteDrivenConversations.remove(conversationID)
        }
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
        let replyID = UUID()
        currentReplyID = replyID
        let generation = stopGeneration
        let registry = await toolRegistry(for: conversationID)
        // Another send claimed the reply while the tools were looked up and
        // owns the state now; appending a placeholder here would leave one
        // spinning forever.
        guard currentReplyID == replyID else { return }
        // Near the window: summarise the older turns first, inside the
        // reply's task so 停止 reaches it and follow-ups queue meanwhile.
        if generation == stopGeneration, needsAutoCompaction(conversationID) {
            streamTask = Task { [weak self] in
                await self?.compactThenReply(conversationID: conversationID, registry: registry, replyID: replyID, generation: generation)
            }
            return
        }
        guard generation == stopGeneration, let first = prepareTurn(conversationID: conversationID, registry: registry) else {
            currentReplyID = nil
            isStreaming = false
            streamingConversationID = nil
            return
        }
        streamTask = Task { [weak self] in
            await self?.runReply(conversationID: conversationID, first: first, replyID: replyID)
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
        // A compacted thread sends its summary in place of the older turns.
        let history = ContextCompaction.requestMessages(Array(conversation.messages.dropLast()), compaction: conversation.compaction)
        var request = GenerationRequest(
            modelID: model.id,
            messages: history,
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
    /// Follow-ups queued for it stay queued, held: the user decides.
    public func stop() {
        stopGeneration += 1
        if let id = streamingConversationID { holdQueue(in: id) }
        streamTask?.cancel()
        streamTask = nil
        for request in pendingApprovals {
            resolveApproval(request.id, .deny)
        }
    }

    public func regenerateLast(remote: Bool = false) {
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
        Task { await startReply(conversationID: conversation.id, remote: remote) }
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
    /// text (keeping its attachments, and the attached mentions the text
    /// still names) and re-runs the reply.
    public func editAndResend(_ messageID: UUID, newText: String, remote: Bool = false) {
        guard var conversation = selectedConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].role == .user else { return }

        let oldMessage = conversation.messages[index]
        let attachments = oldMessage.parts.compactMap { part -> MediaRef? in
            if case .media(let ref) = part { ref } else { nil }
        }
        var parts: [ContentPart] = []
        if !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(newText)) }
        // The editor shows the readable `@说明.md`; a mention edited out
        // drops its content. The note described the old text, so it goes.
        let attached = oldMessage.mentionAttachments
        let named = MentionDraft(text: newText, picked: attached.compactMap(\.mention)).mentions
        var marks: [MessageMention] = []
        for attachment in attached where attachment.mention.map(named.contains) == true {
            marks.append(MessageMention(part: parts.count, attachment: attachment))
            parts.append(.text(attachment.text))
        }
        parts.append(contentsOf: attachments.map { .media($0) })

        var versions = oldMessage.alternativeVersions
        if !versions.contains(oldMessage.concatenatedText) {
            versions.append(oldMessage.concatenatedText)
        }
        let newMessage = ChatMessage(
            role: .user,
            parts: parts,
            alternativeVersions: versions,
            currentVersionIndex: versions.count,
            mentions: marks
        )

        conversation.messages = Array(conversation.messages.prefix(index))
        conversation.messages.append(newMessage)
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
        Task { await startReply(conversationID: conversation.id, remote: remote) }
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
        // A version is one text part; the marks described the parts it replaced.
        message.mentions = []
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
            // Attached mentions fold away under their name, the way thinking
            // does; the note on the ones left out stays as written.
            let marked = message.mentionParts
            for (index, part) in message.parts.enumerated() {
                switch part {
                case .text(let value):
                    if let mention = marked[index]?.mention {
                        lines.append("<details><summary>\(mention.readable)</summary>")
                        lines.append("")
                        lines.append(value.trimmingCharacters(in: .newlines))
                        lines.append("")
                        lines.append("</details>")
                    } else {
                        lines.append(marked[index] == nil ? value : value.trimmingCharacters(in: .newlines))
                    }
                case .thinking(let value):
                    lines.append("<details><summary>思考过程</summary>")
                    lines.append("")
                    lines.append(value)
                    lines.append("</details>")
                case .thinkingSeal:
                    continue
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
        // Queued follow-ups were never sent; the compaction summary stays, so
        // an imported copy (message ids kept) still sends it.
        var exported = conversation.withoutThinkingSeals
        exported.queuedMessages = []
        guard let data = try? encoder.encode(exported),
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
            func escaped(_ value: String) -> String {
                value
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            var text = escaped(message.writtenText).replacingOccurrences(of: "\n", with: "<br>")
            for attachment in message.mentionAttachments {
                let name = escaped(attachment.mention?.readable ?? "")
                text += "<details class=\"mention\"><summary>\(name)</summary><pre>\(escaped(attachment.text.trimmingCharacters(in: .newlines)))</pre></details>"
            }
            let notes = message.mentionNotes
            if !notes.isEmpty {
                text += "<div class=\"mention-notes\">" + notes.map(escaped).joined(separator: "<br>") + "</div>"
            }

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
                .mention { margin-top: 8px; font-size: 13px; }
                .mention summary { cursor: pointer; opacity: 0.85; }
                .mention pre { white-space: pre-wrap; background: rgba(0,0,0,0.12); padding: 8px; border-radius: 8px; max-height: 320px; overflow: auto; }
                .mention-notes { margin-top: 8px; font-size: 12px; opacity: 0.75; }
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

    /// Rough token estimate (CJK ≈ 1 token/char, latin ≈ 1 token/4 chars) of
    /// what the next request sends: text and tool traffic, with a compacted
    /// thread's summary in place of the turns it covers.
    public func estimatedTokens(_ conversation: Conversation) -> Int {
        ContextCompaction.estimatedTokens(of: conversation)
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
    private func finishReply(conversationID: UUID, answered: Bool, replyID: UUID) {
        if answered {
            AudioFeedback.playComplete(enabled: settings.soundEffects)
            if settings.completionNotifications, selectedConversationID != conversationID {
                let title = conversation(conversationID)?.title ?? "新回复"
                CompletionNotifier.notify(title: title)
            }
        }
        // A superseded reply only settles its own conversation below.
        if currentReplyID == replyID {
            currentReplyID = nil
            isStreaming = false
            streamingConversationID = nil
            streamTask = nil
            runningToolCallIDs = []
        }
        if var conversation = conversation(conversationID) {
            if conversation.title == "新对话" || conversation.title == "图片消息" {
                if let first = conversation.messages.first(where: { $0.role == .user }) {
                    let seed = first.writtenText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let position = draftAttachments.firstIndex(where: { $0.id == id }) else { return }
        let ref = draftAttachments.remove(at: position)
        registerUndo(.removedAttachment(ref, position: position, conversationID: selectedConversationID))
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


    /// Chats the sidebar's 待处理 group shows: unread, still generating,
    /// waiting on a reply, an approval card or the user's input. Every other
    /// section hides these, so a chat never appears twice (the phone drawer
    /// uses the same set).
    public func priorityConversationIDs() -> Set<UUID> {
        ConversationPriority.ids(in: sortedConversations, streamingID: streamingConversationID,
                                 awaitingApprovalIDs: Set(pendingApprovals.map(\.conversationID)))
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
                    // What the user wrote: attached mentions stay on the Mac
                    // like attachments, and the phone's 编辑 starts from this.
                    text: message.writtenText,
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
                messages: messages,
                // Text only: attachments stay on the Mac, and the compaction
                // summary only shapes what the Mac sends to the model.
                queued: conversation.queuedMessages.map { queued in
                    RelayQueuedMessage(
                        id: queued.id.uuidString,
                        text: queued.shownText,
                        hasAttachments: !queued.attachments.isEmpty || !queued.pastes.isEmpty || !queued.mentions.isEmpty,
                        held: queued.isHeld
                    )
                },
                isCompacting: compactingConversationIDs.contains(conversation.id),
                status: rowStatus(for: conversation).primary?.rawValue
            )
        }
        return RelaySnapshot(
            rev: 0,
            host: Self.relayHostName,
            selectedID: selectedConversationID?.uuidString,
            conversations: conversations,
            approvals: relayApprovals(),
            commandFailures: relayCommandFailures
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
            await sendNow(text: text, attachments: [], remote: true)

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
            // Phone-originated: no undo entry on the Mac (see `recordsUndo`).
            withoutUndo { renameConversation(id, title: trimmed) }

        case .delete(let conversationID):
            guard let id = uuid(conversationID) else { return }
            deleteConversation(id)

        case .regenerate(let conversationID):
            guard let id = uuid(conversationID) else { return }
            selectedConversationID = id
            regenerateLast(remote: true)

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
            editAndResend(message, newText: text, remote: true)

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
            withoutUndo { togglePin(id) }

        case .toggleArchive(let conversationID):
            guard let id = uuid(conversationID) else { return }
            withoutUndo { toggleArchive(id) }

        case .toggleLock(let conversationID):
            guard let id = uuid(conversationID) else { return }
            toggleLock(id)

        case .setUnread(let conversationID, let unread):
            guard let id = uuid(conversationID) else { return }
            setUnread(id, unread: unread)

        case .approve(let approvalID, let decision, let requestID):
            answerRemoteApproval(approvalID, decision, requestID: requestID)

        case .sendQueuedNow(let conversationID, let queuedID):
            guard let id = uuid(conversationID), let queued = uuid(queuedID) else { return }
            await sendQueuedNow(queued, in: id, remote: true)

        case .removeQueued(let conversationID, let queuedID):
            guard let id = uuid(conversationID), let queued = uuid(queuedID) else { return }
            removeQueued(queued, in: id)
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

    /// 继续于 新建 Worktree: the same managed worktree a fork gets, but the
    /// checkout is bound back onto this conversation rather than a copy.
    @discardableResult
    public func continueInNewWorktree(_ id: UUID) async -> String? {
        guard conversation(id) != nil else { return "找不到这个对话" }
        if case .failure(let failure) = await createManagedWorktreeRecord(for: id, baseBranch: nil) {
            return failure.message
        }
        return nil
    }

    // MARK: - Worktree mode

    /// Codex-managed worktrees this app created, persisted in the workspace
    /// document (`managedWorktrees`). Cleanup, snapshots and handoff build on
    /// this registry.
    public private(set) var managedWorktrees: [ManagedWorktree] = []
    /// Progress of the newest managed worktree creation, shown over the
    /// transcript (official `worktreeInitV2.progress.*`).
    public private(set) var worktreeProgress: ManagedWorktreeProgress?
    /// The composer's 本地/Worktree switch per conversation; a first send on an
    /// empty conversation with this on creates the worktree before replying.
    @ObservationIgnored private var worktreeModeByConversation: [UUID: Bool] = [:]
    /// The base branch the composer picked, per conversation.
    @ObservationIgnored private var worktreeBaseBranchByConversation: [UUID: String] = [:]
    /// The running `git fetch` of a creation, so 「跳过更新」 can stop it.
    @ObservationIgnored private var worktreeFetchHandles: [UUID: ManagedWorktreeFetchHandle] = [:]

    /// The conversation's worktree: the live entry when one exists, a deleted
    /// one only otherwise.
    public func managedWorktree(for conversationID: UUID) -> ManagedWorktree? {
        if let live = managedWorktrees.first(where: { $0.deletedAt == nil && $0.conversationIDs.contains(conversationID) }) {
            return live
        }
        return managedWorktrees.first(where: { $0.conversationIDs.contains(conversationID) })
    }

    /// Insert-or-replace; used by creation here and by cleanup, snapshots and
    /// handoff.
    func updateManagedWorktree(_ record: ManagedWorktree) {
        if let index = managedWorktrees.firstIndex(where: { $0.id == record.id }) {
            managedWorktrees[index] = record
        } else {
            managedWorktrees.append(record)
        }
        persistManagedWorktrees()
    }

    /// Removes a just-created worktree completely — git's entry, the
    /// directory, the registry row. No snapshot: this is the pure rollback
    /// path for a worktree with nothing to keep.
    @discardableResult
    public func discardManagedWorktree(id: UUID) async -> String? {
        #if os(iOS)
        _ = id
        return "新建 Worktree 只能在 Mac 上做"
        #else
        guard let record = managedWorktrees.first(where: { $0.id == id }) else { return "没有这个 Worktree" }
        let remove = await ManagedWorktreeGit.run(["worktree", "remove", "--force", record.path], in: record.sourceRoot, timeout: 60)
        _ = await ManagedWorktreeGit.run(["worktree", "prune"], in: record.sourceRoot, timeout: 30)
        try? FileManager.default.removeItem(atPath: record.path)
        guard remove.ok || !FileManager.default.fileExists(atPath: record.path) else {
            return remove.failureText
        }
        managedWorktrees.removeAll { $0.id == id }
        persistManagedWorktrees()
        return nil
        #endif
    }

    private func persistManagedWorktrees() {
        let store = self.store
        let snapshot = managedWorktrees
        Task {
            do { try await store.saveManagedWorktrees(snapshot) }
            catch {
                DiagnosticsCenter.shared.record("workspace", .error, "managed worktrees save failed",
                    fields: ["error": error.localizedDescription])
            }
        }
    }

    /// Where new managed worktrees go: the configured root, else the app's
    /// Application Support `OMPChat/worktrees`.
    public func resolvedWorktreeRoot() -> String {
        let configured = settings.worktreeBaseDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? ManagedWorktreeLayout.defaultRoot().path : configured
    }

    // MARK: 本地 / Worktree switch (official composer.toggleWorktreeMode)

    public func setWorktreeMode(_ on: Bool, for conversationID: UUID) {
        worktreeModeByConversation[conversationID] = on
        if !on { worktreeBaseBranchByConversation[conversationID] = nil }
    }

    /// ⌘⇧W: flips the switch of the selected conversation, when it can show one.
    public func toggleWorktreeModeForSelected() {
        guard let conversation = selectedConversation,
              conversation.messages.isEmpty,
              conversation.workingDirectory != nil,
              managedWorktree(for: conversation.id) == nil else { return }
        setWorktreeMode(!worktreeMode(for: conversation.id), for: conversation.id)
    }

    public func worktreeMode(for conversationID: UUID) -> Bool {
        worktreeModeByConversation[conversationID] ?? false
    }

    /// The base branch the composer picked; nil = the source's current branch.
    public func setWorktreeBaseBranch(_ branch: String?, for conversationID: UUID) {
        worktreeBaseBranchByConversation[conversationID] = branch
    }

    public func worktreeBaseBranch(for conversationID: UUID) -> String? {
        worktreeBaseBranchByConversation[conversationID]
    }

    /// Branches of the conversation's repository, for the base-branch picker.
    public func worktreeBaseBranchChoices(for conversationID: UUID) async -> [String] {
        #if os(macOS)
        guard let directory = conversation(conversationID)?.workingDirectory else { return [] }
        guard let root = try? GitWorkingTree.repositoryRoot(of: directory) else { return [] }
        return await ManagedWorktreeGit.branches(in: root)
        #else
        return []
        #endif
    }

    /// 「跳过更新」: stop the running fetch and create from the local refs.
    public func skipWorktreeFetch(for conversationID: UUID) {
        worktreeFetchHandles[conversationID]?.skip()
    }

    /// Worktree mode is a promise for the FIRST send: an empty conversation
    /// with a directory bound. Later sends just run in the (now bound)
    /// worktree.
    private func needsWorktreeFirstSend(_ conversationID: UUID) -> Bool {
        guard worktreeMode(for: conversationID), let conversation = conversation(conversationID) else { return false }
        return conversation.messages.isEmpty && conversation.workingDirectory != nil
    }

    /// Creates a managed worktree for the conversation and returns nil on
    /// success, the failure message otherwise.
    @discardableResult
    public func createManagedWorktree(for conversationID: UUID, baseBranch: String?) async -> String? {
        if case .failure(let failure) = await createManagedWorktreeRecord(
            for: conversationID,
            baseBranch: baseBranch,
            carryUncommittedChanges: true,
            bindConversation: true,
            sourceDirectory: nil
        ) {
            return failure.message
        }
        return nil
    }

    /// The full creation: detached `git worktree add` at the branch's HEAD,
    /// the source's uncommitted work carried when the branch is the source's
    /// current branch, `.worktreeinclude` files copied, the selected local
    /// environment's setup script run, registry row written, conversation
    /// bound. `sourceDirectory` nil uses the conversation's own binding.
    public func createManagedWorktreeRecord(
        for conversationID: UUID,
        baseBranch: String?,
        carryUncommittedChanges: Bool = true,
        bindConversation: Bool = true,
        sourceDirectory: String? = nil
    ) async -> Result<ManagedWorktree, ManagedWorktreeCreationFailure> {
        guard let conversation = conversation(conversationID) else { return .failure(ManagedWorktreeCreationFailure("找不到这个对话")) }
        #if os(iOS)
        return .failure(ManagedWorktreeCreationFailure("新建 Worktree 只能在 Mac 上做"))
        #else
        guard GitBinary.resolve() != nil else { return .failure(ManagedWorktreeCreationFailure("这台 Mac 上没有可用的 git")) }
        let directory = sourceDirectory ?? conversation.workingDirectory
        guard let directory, FileManager.default.fileExists(atPath: directory) else {
            return .failure(ManagedWorktreeCreationFailure("这个对话还没有绑定本地文件夹"))
        }
        guard let root = try? GitWorkingTree.repositoryRoot(of: directory) else {
            return .failure(ManagedWorktreeCreationFailure("当前目录不在 git 仓库里"))
        }

        // Carry the source's uncommitted work only when the chosen branch is
        // where the source currently sits (Codex carries a branch's unstaged
        // changes; another branch's HEAD has none of this checkout's edits).
        let headRef = await ManagedWorktreeGit.run(["symbolic-ref", "--short", "-q", "HEAD"], in: root)
        let currentBranch = headRef.ok
            ? headRef.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let chosen = baseBranch ?? currentBranch
        let carry = carryUncommittedChanges && chosen != nil && chosen == currentBranch

        // A unique managed path: <root>/<repo-name>/<slug>.
        let slug = WorktreeFork.slug(title: conversation.title, id: conversationID)
        let rootDirectory = resolvedWorktreeRoot()
        try? FileManager.default.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
        var worktreePath = ManagedWorktreeLayout.managedPath(root: rootDirectory, sourceRoot: root, slug: slug)
        var suffix = 2
        while FileManager.default.fileExists(atPath: worktreePath) {
            worktreePath = ManagedWorktreeLayout.managedPath(root: rootDirectory, sourceRoot: root, slug: "\(slug)-\(suffix)")
            suffix += 1
        }

        let handle = ManagedWorktreeFetchHandle()
        if settings.worktreeFetchUpstream { worktreeFetchHandles[conversationID] = handle }
        defer { worktreeFetchHandles[conversationID] = nil }

        let creation = ManagedWorktreeCreation(
            sourceRoot: root,
            worktreePath: worktreePath,
            baseBranch: chosen,
            carryUncommittedChanges: carry,
            fetchUpstream: settings.worktreeFetchUpstream,
            fetchHandle: handle
        )
        let outcome: ManagedWorktreeCreation.Outcome
        switch await creation.perform(onProgress: { [weak self] phase, detail, canSkip in
            await self?.applyWorktreePhase(phase, detail: detail, canSkipFetch: canSkip, conversationID: conversationID)
        }) {
        case .success(let value):
            outcome = value
        case .failure(let failure):
            worktreeProgress = ManagedWorktreeProgress(
                conversationID: conversationID, phase: .failed,
                detail: [failure.message, failure.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            )
            return .failure(ManagedWorktreeCreationFailure(failure.message))
        }

        let environmentPath = selectedLocalEnvironmentPath(forProject: root)
        let record = ManagedWorktree(
            path: outcome.worktreePath,
            sourceRoot: root,
            baseCommit: outcome.baseCommit,
            baseBranch: chosen,
            environmentPath: environmentPath,
            conversationIDs: [conversationID]
        )
        updateManagedWorktree(record)
        if bindConversation { updateWorkingDirectory(conversationID, outcome.worktreePath) }
        // The chat now lives in the worktree; the switch served its purpose.
        setWorktreeMode(false, for: conversationID)

        // Setup runs once the checkout is registered and bound, so a slow
        // script never leaves the app without a usable directory.
        if let environmentPath {
            worktreeProgress = ManagedWorktreeProgress(conversationID: conversationID, phase: .settingUp)
            let result = await LocalEnvironmentDiscovery.runLocalEnvironmentScript(
                .setup, configPath: environmentPath, sourceRoot: root, worktreeRoot: outcome.worktreePath
            )
            if !result.skipped, result.exitCode != 0 {
                // Official worktreeSetupFailed: the chat still starts, the
                // worktree stays usable, the output shows.
                worktreeProgress = ManagedWorktreeProgress(
                    conversationID: conversationID, phase: .failed,
                    detail: "初始化脚本失败（退出码 \(result.exitCode)），Worktree 可以继续使用。脚本可在 .codex/environments 中调整。\n"
                        + worktreeOutputTail(result.output)
                )
                Task { _ = await runWorktreeCleanup() }
                return .success(record)
            }
        }
        worktreeProgress = nil
        // Created one, so maybe the keep limit is over now.
        Task { _ = await runWorktreeCleanup() }
        return .success(record)
        #endif
    }

    private func applyWorktreePhase(_ phase: ManagedWorktreePhase, detail: String?, canSkipFetch: Bool, conversationID: UUID) {
        worktreeProgress = ManagedWorktreeProgress(
            conversationID: conversationID, phase: phase, detail: detail, canSkipFetch: canSkipFetch
        )
    }

    /// Keeps script or git output on the failure card readable.
    private func worktreeOutputTail(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2000 else { return trimmed }
        return "…\n" + trimmed.suffix(2000)
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
    /// The reply that owns `isStreaming`, `streamingConversationID`,
    /// `streamTask` and `runningToolCallIDs`. A message sent while a reply
    /// runs here waits in the queue, but 立即发送 (and a phone send to another
    /// conversation) cancels the old reply, and the old loop must not clear
    /// the new reply's state when it winds down: it used to, which left the
    /// new reply running with no stop button and its approval cards
    /// unreachable by 停止.
    @ObservationIgnored private var currentReplyID: UUID?
    @ObservationIgnored private var readableRootsByOwner: [String: [String]] = [:]
    @ObservationIgnored private var reportedToolProblems: Set<String> = []

    /// The conversation's mode, else the settings default, else 每次询问.
    public func permissionMode(for id: UUID) -> PermissionMode {
        if let raw = conversation(id)?.permissionMode, let mode = PermissionMode(rawValue: raw) { return mode }
        return PermissionMode(rawValue: settings.defaultPermissionMode) ?? .ask
    }

    /// The mode a reply actually runs under. A reply a paired phone started
    /// is held to 每次询问 unless 「允许手机访问文件与终端」 is on, so a phone
    /// cannot reach the Mac's files and shell by prompting a conversation whose
    /// mode is 自动 or 完全访问; the cards then wait on the Mac.
    func effectivePermissionMode(for id: UUID) -> PermissionMode {
        permissionMode(for: id).limited(
            remoteDriven: remoteDrivenConversations.contains(id),
            phoneMayTouchMac: settings.relayAllowShell
        )
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

    /// The composer's 「工具与权限」 choice for this conversation.
    public func agentAccess(for id: UUID) -> AgentAccess {
        guard let conversation = conversation(id) else { return .followDefault }
        return AgentAccess.current(
            toolsEnabled: conversation.toolsEnabled,
            permissionMode: conversation.permissionMode.flatMap(PermissionMode.init(rawValue:)),
            hasWorkingDirectory: !(conversation.workingDirectory ?? "").isEmpty,
            defaultMode: defaultPermissionMode
        )
    }

    /// What the thread gets now; the composer button shows this.
    public func effectiveAgentAccess(for id: UUID) -> AgentAccess {
        let access = agentAccess(for: id)
        return access == .followDefault ? defaultAgentAccess(for: id) : access
    }

    /// What 跟随默认 currently gives this conversation (never followDefault).
    public func defaultAgentAccess(for id: UUID) -> AgentAccess {
        AgentAccess.followDefault.resolved(
            hasWorkingDirectory: !(conversation(id)?.workingDirectory ?? "").isEmpty,
            defaultMode: defaultPermissionMode
        )
    }

    /// Stores both fields of the choice in one write.
    public func setAgentAccess(_ access: AgentAccess, for id: UUID) {
        guard var conversation = conversation(id) else { return }
        let stored = access.stored
        conversation.toolsEnabled = stored.toolsEnabled
        conversation.permissionMode = stored.permissionMode?.rawValue
        replace(conversation)
        persist(conversation)
    }

    private var defaultPermissionMode: PermissionMode {
        PermissionMode(rawValue: settings.defaultPermissionMode) ?? .ask
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
        switch effectivePermissionMode(for: conversation.id) {
        case .readOnly: rule = "当前是只读模式：只能读取，写文件和运行命令会被拒绝。"
        case .ask: rule = "读取会直接执行；写文件、运行命令、访问工作目录以外的位置要先经用户批准。"
        case .auto: rule = "读写工作目录里的文件会直接执行；运行命令、访问工作目录以外的位置要先经用户批准。"
        case .full: rule = "文件和命令会直接执行；控制桌面要先经用户批准。"
        }
        // Measured in the installed app: scripts created by the sandboxed app
        // or its commands cannot be exec'd, but an interpreter reads them.
        let sandbox = "命令运行在应用沙盒里：这里新建的脚本（包括 npm install 装出的 .bin 命令）不能直接执行，会报 Operation not permitted；用解释器去跑，例如 bash x.sh、node x.js、python3 x.py、node node_modules/.bin/xxx 指向的 js 文件。"
        return "【工具】你可以调用工具完成任务。\(place)\(rule)\(sandbox)调用被拒绝时换个做法或询问用户，不要重复同一个调用。优先小步、可撤销的操作：先读后改，改动范围尽量小，不做用户没要求的破坏性操作。"
    }

    /// Mutable state of one running reply, shared with the loop's callbacks.
    @MainActor
    private final class ReplyProgress {
        var first: PreparedTurn?
        var lastAssistantID: UUID?
        /// Follow-ups delivered into this reply that no model turn has
        /// answered yet.
        var unansweredFollowUps: [UUID]

        init(first: PreparedTurn, followUps: [UUID]) {
            self.first = first
            self.unansweredFollowUps = followUps
        }
    }

    /// The whole reply: model turns and their tool calls, through `AgentLoop`.
    /// `isStreaming` stays true throughout, so the stop button shows.
    /// `followUps` are queued messages delivered just before the first turn.
    private func runReply(conversationID: UUID, first: PreparedTurn, replyID: UUID, followUps: [UUID] = []) async {
        let progress = ReplyProgress(first: first, followUps: followUps)
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
            hooks: toolHooks,
            betweenTurns: { [weak self] in
                await self?.deliverFollowUps(conversationID: conversationID, replyID: replyID, progress: progress) ?? false
            }
        )
        let ending = await AgentLoop().run(host)
        if ending == .turnLimit, let id = progress.lastAssistantID {
            updateMessage(conversationID: conversationID, messageID: id) { message in
                message.errorText = "已达到每条消息 \(AgentLoop.maxModelTurns) 轮模型调用的上限，已停止。发送新消息可以让它继续。"
            }
        }
        // Follow-ups still waiting start the next reply, unless 停止 ended
        // this one or a newer reply took over (it carries them).
        let owner = currentReplyID == replyID
        let continues = owner && !Task.isCancelled && hasDeliverableQueue(conversationID)
        if owner, !continues { markUnanswered(progress.unansweredFollowUps, in: conversationID) }
        finishReply(conversationID: conversationID, answered: ending == .answered, replyID: replyID)
        if continues { await startQueuedReply(conversationID) }
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
        // A finished turn read every follow-up before it.
        settleFollowUps(progress, in: conversationID)
        return .finished(calls: calls, registry: prepared.registry)
    }

    private func agentEnvironment(_ conversationID: UUID) -> AgentLoop.Environment {
        AgentLoop.Environment(mode: effectivePermissionMode(for: conversationID), context: toolContext(for: conversationID))
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
        // The tool may have created a file a message already mentioned.
        fileReferences.forgetMissing()
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

    // MARK: - Mentions

    /// Files and skills the composer's `@` / `$` lists search, listed off
    /// the main actor and cached until a list opens again.
    @ObservationIgnored public let mentionIndex = MentionIndex()
    /// Absolute file targets picked from the `@` list this session. Only
    /// these may attach a file outside the thread's working directory.
    @ObservationIgnored private var pickedMentionTargets: Set<String> = []
    /// Readers of a tab's live page text, one per browser pane on screen.
    @ObservationIgnored private var browserPageReaders: [UUID: @MainActor (UUID) async -> String?] = [:]

    private static let mentionFileLimit = 8
    private static let mentionChatLimit = 5
    private static let mentionTabLimit = 5

    /// A browser pane installs its reader while it is on screen and removes
    /// it (nil) when it goes; the reader answers nil for a tab it has no
    /// page for.
    public func setBrowserPageReader(_ reader: (@MainActor (UUID) async -> String?)?, owner: UUID) {
        browserPageReaders[owner] = reader
    }

    /// Mentions picked into the draft, which shows them readably
    /// (`@说明.md`); `MentionDraft` says when one still counts. Kept per
    /// conversation beside the draft, and pruned as the draft is edited.
    public private(set) var pickedMentions: [ComposerMention] = []
    @ObservationIgnored private var pickedMentionsByConversation: [UUID: [ComposerMention]] = [:]

    private var composedDraft: MentionDraft {
        MentionDraft(text: draft, picked: pickedMentions)
    }

    /// The mentions the draft holds, for the chips above the field.
    public var draftMentions: [ComposerMention] {
        composedDraft.mentions
    }

    /// The `@…` / `$…` the composer's list searches for; nil right after a
    /// mention already in the draft.
    public var activeMentionQuery: ComposerMention.ActiveQuery? {
        composedDraft.activeQuery
    }

    /// The draft as sent: each readable mention swapped for its token.
    public var draftForSending: String {
        composedDraft.tokenized
    }

    /// Replaces the draft and the mentions picked into it (a prompt recalled
    /// from history); mentions not standing in `text` are dropped.
    public func setDraft(_ text: String, mentions: [ComposerMention] = []) {
        pickedMentions = MentionDraft(text: text, picked: mentions).pruned.picked
        draft = text
    }

    /// A picked mention edited out of the draft stops counting at once.
    private func prunePickedMentions() {
        guard !pickedMentions.isEmpty else { return }
        let live = composedDraft.pruned.picked
        if live.count != pickedMentions.count { pickedMentions = live }
    }

    /// Lists the thread's folder (`@`) and reloads its skills (`$`) afresh;
    /// nil does both. The composer calls it when a list opens.
    public func refreshMentionIndex(for conversationID: UUID, trigger: Character? = nil) async {
        if trigger != "$", let directory = mentionDirectory(conversationID) {
            _ = try? await mentionIndex.refresh(directory)
        }
        if trigger != "@" {
            await mentionIndex.loadSkills(for: conversationID, roots: skillRoots(for: conversationID))
        }
    }

    /// The rows the `@` (files, chats, tabs) or `$` (skills) list shows for
    /// `query` in conversation `conversationID`.
    public func mentionCandidates(query: String, trigger: Character, for conversationID: UUID) async -> [MentionCandidate] {
        await mentionSearch(query: query, trigger: trigger, for: conversationID).candidates
    }

    /// `mentionCandidates`, plus whether the file search failed.
    public func mentionSearch(query: String, trigger: Character, for conversationID: UUID) async -> MentionSearchResult {
        if trigger == "$" {
            return MentionSearchResult(candidates: await skillMentionCandidates(query, for: conversationID))
        }
        return await atMentionSearch(query, for: conversationID)
    }

    /// Puts `mention` in the draft, readably, in place of the `@…` / `$…`
    /// being typed or at the end. A file picked by its absolute path may
    /// then attach from outside the working directory.
    public func pickMention(_ mention: ComposerMention) {
        if mention.kind == .file, mention.target.hasPrefix("/") || mention.target.hasPrefix("~/") {
            pickedMentionTargets.insert(mention.target)
        }
        var composed = composedDraft
        composed.insert(mention)
        apply(composed)
    }

    /// A chip's ×: takes the mention out of the draft.
    public func removeMention(_ mention: ComposerMention) {
        var composed = composedDraft
        composed.remove(mention)
        apply(composed)
    }

    /// Table first, so pruning on the draft's change keeps what was picked.
    private func apply(_ composed: MentionDraft) {
        pickedMentions = composed.picked
        draft = composed.text
    }

    /// The context the mentions in `text` add to a message of conversation
    /// `conversationID`: files and skills read, chats quoted, a tab's page
    /// text taken from its live web view — now, at send time. Never fails;
    /// whatever cannot be attached becomes a note.
    public func resolveMentions(in text: String, for conversationID: UUID) async -> MentionResolution {
        let mentions = ComposerMention.mentions(in: text)
        guard !mentions.isEmpty else { return MentionResolution() }
        var chats: [UUID: MentionSources.Chat] = [:]
        var tabs: [UUID: MentionSources.Tab] = [:]
        for mention in mentions {
            guard let id = UUID(uuidString: mention.target) else { continue }
            if mention.kind == .chat, let chat = conversation(id) {
                chats[id] = MentionSources.Chat(title: chat.title, messages: chat.messages, isLocked: chat.isLocked)
            }
            #if os(macOS)
            if mention.kind == .tab, let tab = browserTabs.tab(id) {
                tabs[id] = MentionSources.Tab(title: tab.displayTitle, url: tab.url, pageText: await browserPageText(id))
            }
            #endif
        }
        var skills: [Skill] = []
        if mentions.contains(where: { $0.kind == .skill }) {
            skills = await mentionIndex.loadSkills(for: conversationID, roots: skillRoots(for: conversationID))
        }
        let sources = MentionSources(
            workingDirectory: mentionDirectory(conversationID), home: HostExecutor.realHomeDirectory(),
            pickedTargets: pickedMentionTargets, chats: chats, tabs: tabs, skills: skills
        )
        return await Task.detached(priority: .userInitiated) {
            MentionResolver.resolve(mentions, sources: sources)
        }.value
    }

    private func mentionDirectory(_ conversationID: UUID) -> String? {
        conversation(conversationID)?.workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func browserPageText(_ tabID: UUID) async -> String? {
        for reader in browserPageReaders.values {
            if let text = await reader(tabID) { return text }
        }
        return nil
    }

    /// Files (an absolute path typed out, then the working directory's best
    /// matches), other chats, then open tabs. An empty query lists no files.
    private func atMentionSearch(_ query: String, for conversationID: UUID) async -> MentionSearchResult {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = MentionSearchResult()
        if !needle.isEmpty {
            if let path = await mentionIndex.existingFile(needle, home: HostExecutor.realHomeDirectory()),
               let mention = ComposerMention(kind: .file, label: (path as NSString).lastPathComponent, target: path) {
                result.candidates.append(Self.fileCandidate(mention, shownPath: GitInfo.tildified(path)))
            }
            if let directory = mentionDirectory(conversationID) {
                do {
                    for path in try await mentionIndex.search(directory, query: needle, limit: Self.mentionFileLimit) {
                        guard let mention = ComposerMention(kind: .file, label: (path as NSString).lastPathComponent, target: path) else { continue }
                        result.candidates.append(Self.fileCandidate(mention, shownPath: path))
                    }
                } catch {
                    result.fileSearchFailed = true
                }
            }
        }
        let others = sortedConversations.filter { $0.id != conversationID }
        for chat in (needle.isEmpty ? others : ConversationSearch.filter(others, query: needle)).prefix(Self.mentionChatLimit) {
            guard let mention = ComposerMention(kind: .chat, label: chat.title, target: chat.id.uuidString) else { continue }
            let preview = chat.lastMessagePreview.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            result.candidates.append(MentionCandidate(
                mention: mention, section: .chats, title: mention.label, detail: preview, badge: "对话", icon: "bubble.left"
            ))
        }
        #if os(macOS)
        let tabs = browserTabs.tabs.filter {
            needle.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(needle) || $0.url.localizedCaseInsensitiveContains(needle)
        }
        for tab in tabs.prefix(Self.mentionTabLimit) {
            guard let mention = ComposerMention(kind: .tab, label: tab.displayTitle, target: tab.id.uuidString) else { continue }
            result.candidates.append(MentionCandidate(
                mention: mention, section: .tabs, title: mention.label, detail: tab.url, badge: "标签页", icon: "globe"
            ))
        }
        #endif
        return result
    }

    private static func fileCandidate(_ mention: ComposerMention, shownPath: String) -> MentionCandidate {
        let folder = (shownPath as NSString).deletingLastPathComponent
        return MentionCandidate(
            mention: mention, section: .files, title: mention.label, detail: folder, badge: "文件", icon: "doc.text"
        )
    }

    /// Every skill of the thread, explicit-only ones included, matching
    /// `query`; loaded once per list opening.
    private func skillMentionCandidates(_ query: String, for conversationID: UUID) async -> [MentionCandidate] {
        let skills: [Skill]
        if let cached = await mentionIndex.cachedSkills(for: conversationID) {
            skills = cached
        } else {
            skills = await mentionIndex.loadSkills(for: conversationID, roots: skillRoots(for: conversationID))
        }
        return MentionIndex.rankSkills(skills, query: query).compactMap { skill in
            guard let mention = ComposerMention(kind: .skill, label: skill.name, target: skill.path) else { return nil }
            return MentionCandidate(
                mention: mention, section: .skills, title: skill.name,
                detail: skill.shortDescription ?? skill.description, badge: skill.mentionSourceLabel, icon: "sparkles"
            )
        }
    }

    // MARK: - Steering

    /// Typed into the composer, runs compaction instead of sending.
    public static let compactCommand = "/compact"
    /// Under a follow-up the running reply took in and then ended without
    /// answering (Codex `responseError.unansweredSteering`). Defined in
    /// OMPCore so row status recognises the note.
    public static let unansweredFollowUpText = ConversationRowStatus.unansweredFollowUpNote
    /// Codex `composer.queuedSteerDuringCompaction`.
    public static let queuedDuringCompactionText = "压缩时不能插话，消息会在压缩完成后发送"

    /// Follow-ups waiting in this conversation, oldest first.
    public func queuedMessages(for id: UUID) -> [QueuedMessage] {
        conversation(id)?.queuedMessages ?? []
    }

    /// 立即发送: sends the queued message now, the way sending used to work
    /// while a reply ran: the running reply (or compaction) here is cancelled
    /// and a new one starts with this message. The rest of the queue keeps
    /// waiting for the new reply. Refused while another conversation replies.
    public func sendQueuedNow(_ queuedID: UUID, in id: UUID, remote: Bool = false) async {
        guard var conversation = conversation(id),
              let index = conversation.queuedMessages.firstIndex(where: { $0.id == queuedID }) else { return }
        if isStreaming, streamingConversationID != id {
            errorMessage = "另一个对话正在回复，结束后再发送"
            return
        }
        guard resolveProvider(for: conversation) != nil else {
            errorMessage = "先在设置中添加供应商"
            showSettings = true
            return
        }
        let queued = conversation.queuedMessages.remove(at: index)
        conversation.messages.append(queued.message)
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
        // startReply cancels the running task and claims the reply before
        // awaiting, so the old loop's wind-down leaves the new state alone.
        await startReply(conversationID: id, remote: remote || queued.remote)
    }

    /// 删除: drops a queued message unsent.
    public func removeQueued(_ queuedID: UUID, in id: UUID) {
        guard var conversation = conversation(id),
              let index = conversation.queuedMessages.firstIndex(where: { $0.id == queuedID }) else { return }
        conversation.queuedMessages.remove(at: index)
        replace(conversation)
        persist(conversation)
    }

    /// 编辑: takes a queued message out of the queue and back into the
    /// conversation's draft, after whatever the draft already holds.
    public func editQueued(_ queuedID: UUID, in id: UUID) {
        guard let queued = queuedMessages(for: id).first(where: { $0.id == queuedID }) else { return }
        removeQueued(queuedID, in: id)
        if selectedConversationID != id { selectedConversationID = id }
        // Tokens come back as readable mentions, picked again.
        var composed = composedDraft
        composed.appendTokenized(queued.text, separator: "\n")
        apply(composed)
        draftAttachments += queued.attachments
        pastedTexts += queued.pastes.map { PastedTextAttachment(text: $0) }
    }

    private func enqueue(_ message: QueuedMessage, in id: UUID) {
        guard var conversation = conversation(id) else { return }
        conversation.queuedMessages.append(message)
        replace(conversation)
        persist(conversation)
        if compactingConversationIDs.contains(id) { statusMessage = Self.queuedDuringCompactionText }
    }

    /// After 停止 the queue stays, but nothing in it goes out on its own.
    private func holdQueue(in id: UUID) {
        guard var conversation = conversation(id),
              conversation.queuedMessages.contains(where: { !$0.isHeld }) else { return }
        for index in conversation.queuedMessages.indices { conversation.queuedMessages[index].isHeld = true }
        replace(conversation)
        persist(conversation)
    }

    private func hasDeliverableQueue(_ id: UUID) -> Bool {
        queuedMessages(for: id).contains { !$0.isHeld }
    }

    /// Appends every queued message that is not held as a user message, in
    /// order, and returns their message ids. A phone's follow-up holds the
    /// rest of the reply to the phone's permission limit.
    private func deliverQueue(in id: UUID) -> (messageIDs: [UUID], remote: Bool) {
        guard var conversation = conversation(id) else { return ([], false) }
        let ready = conversation.queuedMessages.filter { !$0.isHeld }
        guard !ready.isEmpty else { return ([], false) }
        conversation.queuedMessages.removeAll { !$0.isHeld }
        let messages = ready.map(\.message)
        conversation.messages += messages
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)
        let remote = ready.contains(where: \.remote)
        if remote { remoteDrivenConversations.insert(id) }
        return (messages.map(\.id), remote)
    }

    /// The loop's safe point: the turn's tool results are in, the next
    /// request is not built yet.
    private func deliverFollowUps(conversationID: UUID, replyID: UUID, progress: ReplyProgress) -> Bool {
        guard currentReplyID == replyID, !Task.isCancelled else { return false }
        let delivered = deliverQueue(in: conversationID).messageIDs
        progress.unansweredFollowUps += delivered
        return !delivered.isEmpty
    }

    /// A reply ended with follow-ups still waiting: they start the next one.
    private func startQueuedReply(_ id: UUID) async {
        let delivered = deliverQueue(in: id)
        guard !delivered.messageIDs.isEmpty else { return }
        await startReply(conversationID: id, remote: delivered.remote)
    }

    /// A model turn finished: the follow-ups before it were read, and a
    /// note left by an earlier reply no longer applies.
    private func settleFollowUps(_ progress: ReplyProgress, in id: UUID) {
        progress.unansweredFollowUps = []
        guard var conversation = conversation(id) else { return }
        var changed = false
        for index in conversation.messages.indices
        where conversation.messages[index].role == .user && conversation.messages[index].errorText == Self.unansweredFollowUpText {
            conversation.messages[index].errorText = nil
            changed = true
        }
        guard changed else { return }
        replace(conversation)
        persist(conversation)
    }

    /// The reply ended (failed, stopped or cut off) before any turn read
    /// these follow-ups, and nothing after it will.
    private func markUnanswered(_ messageIDs: [UUID], in id: UUID) {
        guard !messageIDs.isEmpty, var conversation = conversation(id) else { return }
        for index in conversation.messages.indices where messageIDs.contains(conversation.messages[index].id) {
            conversation.messages[index].errorText = Self.unansweredFollowUpText
        }
        replace(conversation)
        persist(conversation)
    }

    /// Clears the reply state if `replyID` still owns it.
    private func releaseReply(_ replyID: UUID) {
        guard currentReplyID == replyID else { return }
        currentReplyID = nil
        isStreaming = false
        streamingConversationID = nil
        streamTask = nil
        runningToolCallIDs = []
    }

    // MARK: - Compaction

    /// Conversations whose earlier turns are being summarised right now;
    /// the transcript shows 正在压缩上下文… for them.
    public private(set) var compactingConversationIDs: Set<UUID> = []

    public func isCompacting(_ id: UUID) -> Bool {
        compactingConversationIDs.contains(id)
    }

    /// The compaction this conversation's requests use, if any still applies.
    public func compaction(for id: UUID) -> ConversationCompaction? {
        guard let conversation = conversation(id),
              ContextCompaction.coveredIndex(of: conversation.compaction, in: conversation.messages) != nil else { return nil }
        return conversation.compaction
    }

    /// 压缩上下文 / `/compact`: summarises the earlier turns in one model
    /// request (no tools) with the conversation's own provider and model,
    /// keeping the newest `ContextCompaction.keptTurns` verbatim. Returns
    /// nil on success, else the reason, also shown to the user. Follow-ups
    /// sent meanwhile are queued and go out afterwards, success or not;
    /// 停止 cancels it and holds them.
    public func compactConversation(_ id: UUID) async -> String? {
        guard let conversation = conversation(id) else { return "找不到这个对话" }
        if isStreaming {
            let text = streamingConversationID == id ? "回复进行中，结束后再压缩" : "另一个对话正在回复，结束后再压缩"
            errorMessage = text
            return text
        }
        guard ContextCompaction.boundary(in: conversation.messages, after: conversation.compaction) != nil else {
            let text = "还没有足够早的内容可以压缩"
            statusMessage = text
            return text
        }
        guard let provider = resolveProvider(for: conversation), resolveModel(for: conversation, provider: provider) != nil else {
            let text = "先在设置中添加供应商并选择模型"
            errorMessage = text
            return text
        }
        isStreaming = true
        streamingConversationID = id
        errorMessage = nil
        let replyID = UUID()
        currentReplyID = replyID
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            streamTask = Task { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let error = await self.runCompaction(id)
                continuation.resume(returning: error)
                let owner = self.currentReplyID == replyID
                self.releaseReply(replyID)
                guard owner, !Task.isCancelled else { return }
                // Starting the reply clears the banner; a failed compaction's
                // error must stay in sight while the queued messages go out.
                let shown = self.errorMessage
                await self.startQueuedReply(id)
                if self.errorMessage == nil { self.errorMessage = shown }
            }
        }
    }

    /// Whether the next request of this conversation would reach
    /// `ContextCompaction.autoThreshold` of its model's window.
    private func needsAutoCompaction(_ id: UUID) -> Bool {
        guard let conversation = conversation(id),
              let provider = resolveProvider(for: conversation),
              let model = resolveModel(for: conversation, provider: provider) else { return false }
        return ContextCompaction.shouldAutoCompact(
            conversation.messages, compaction: conversation.compaction, contextWindow: model.limits.contextWindow
        )
    }

    /// Automatic compaction ahead of a reply that already owns the reply
    /// state. A failure leaves the thread as it was; the reply goes on
    /// either way, with the follow-ups queued meanwhile, unless 停止.
    private func compactThenReply(conversationID: UUID, registry: AgentToolRegistry, replyID: UUID, generation: Int) async {
        _ = await runCompaction(conversationID)
        guard !Task.isCancelled, currentReplyID == replyID, generation == stopGeneration else {
            releaseReply(replyID)
            return
        }
        let followUps = deliverQueue(in: conversationID).messageIDs
        guard let first = prepareTurn(conversationID: conversationID, registry: registry) else {
            releaseReply(replyID)
            return
        }
        await runReply(conversationID: conversationID, first: first, replyID: replyID, followUps: followUps)
    }

    static let compactionNotSmallerText = "较早的内容还很少，摘要不比原文短，已保留原文"

    /// Streams the summary and stores the compaction. Returns nil on
    /// success, else the reason; a failure is also shown as an error, a
    /// summary that would not shrink anything only as a status line.
    private func runCompaction(_ id: UUID) async -> String? {
        compactingConversationIDs.insert(id)
        defer {
            compactingConversationIDs.remove(id)
            // 「压缩时不能插话…」 describes the compaction, not the message;
            // it stayed on screen after the compaction had finished.
            if compactingConversationIDs.isEmpty, statusMessage == Self.queuedDuringCompactionText {
                statusMessage = nil
            }
        }
        guard let conversation = conversation(id),
              let boundary = ContextCompaction.boundary(in: conversation.messages, after: conversation.compaction) else {
            return "还没有足够早的内容可以压缩"
        }
        guard let provider = resolveProvider(for: conversation),
              let model = resolveModel(for: conversation, provider: provider),
              let apiKey = (try? secrets.secret(for: provider.keychainAccount)) ?? nil, !apiKey.isEmpty else {
            return compactionFailed("没有可用的供应商、模型或 API Key")
        }
        let request = ContextCompaction.summaryRequest(
            modelID: model.id,
            messages: conversation.messages,
            boundary: boundary,
            previous: conversation.compaction,
            contextWindow: model.limits.contextWindow,
            maxOutputTokens: model.limits.maxOutputTokens
        )
        let adapter = ProviderFactory.makeProvider(
            profile: provider,
            apiKey: apiKey,
            transport: transport,
            mediaPayloads: { [mediaLibrary] ref in mediaLibrary.loadPayload(for: ref) }
        )
        var summary = ""
        var failure: Error?
        do {
            for try await event in adapter.stream(request) {
                if Task.isCancelled { break }
                if case .textDelta(let delta) = event { summary += delta }
            }
        } catch {
            failure = error
        }
        if Task.isCancelled { return "已停止压缩" }
        if let failure {
            return compactionFailed((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return compactionFailed("模型没有返回摘要")
        }
        // Messages can be deleted while the summary streams; the cut follows
        // the covered message, and is dropped if that message is gone.
        let coveredID = conversation.messages[boundary - 1].id
        guard var latest = self.conversation(id),
              let covered = latest.messages.firstIndex(where: { $0.id == coveredID }) else {
            return compactionFailed("压缩期间对话被改动了")
        }
        let made = ContextCompaction.compaction(
            summary: summary, messages: latest.messages, boundary: covered + 1, previous: latest.compaction
        )
        // A summary no shorter than the turns it replaces would make every
        // later request bigger (a short thread: 167 → 325 tokens was seen).
        guard made.shrinksRequest else {
            statusMessage = Self.compactionNotSmallerText
            return Self.compactionNotSmallerText
        }
        latest.compaction = made
        replace(latest)
        persist(latest)
        DiagnosticsCenter.shared.record("compaction", .info, "context compacted", fields: [
            "model": model.id, "before": String(made.tokensBefore), "after": String(made.tokensAfter),
        ])
        return nil
    }

    private func compactionFailed(_ reason: String) -> String {
        let text = "压缩上下文失败：\(reason)"
        errorMessage = text
        DiagnosticsCenter.shared.record("compaction", .error, "compaction failed", fields: ["error": reason])
        return text
    }

    // MARK: - Scheduled tasks

    /// Codex scheduled tasks (`inbox.mode.automations`). Saved in the
    /// workspace document; `scheduledTaskScheduler` runs them while the app
    /// runs on the Mac. Every change goes through `scheduledTasksChanged()`.
    public private(set) var scheduledTasks: [ScheduledTask] = []
    /// The calendar schedules are read in: the system's, following time-zone
    /// changes. Tests pin a zone.
    @ObservationIgnored var scheduleCalendar: Calendar = .autoupdatingCurrent
    @ObservationIgnored private var schedulerStorage: ScheduledTaskScheduler?
    /// The reply each task's latest run started, so its row can say
    /// 正在运行… only while that reply (not a later one) streams.
    @ObservationIgnored private var scheduledRunReplyIDs: [UUID: UUID] = [:]

    public var scheduledTaskScheduler: ScheduledTaskScheduler {
        if let schedulerStorage { return schedulerStorage }
        let scheduler = ScheduledTaskScheduler(model: self)
        schedulerStorage = scheduler
        return scheduler
    }

    /// Starts firing due tasks; on iOS this does nothing, tasks run on the
    /// Mac. Call once after `bootstrap()`; later calls do nothing.
    public func startScheduledTasks() {
        scheduledTaskScheduler.start()
    }

    /// Adds `task` as an active task with its first slot after `now`.
    @discardableResult
    public func addScheduledTask(_ task: ScheduledTask, now: Date = Date()) -> ScheduledTask {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.activate(now: now, calendar: scheduleCalendar)
        scheduledTasks.append(task)
        scheduledTasksChanged()
        return task
    }

    /// Applies an edited copy of a stored task; see `ScheduledTask.applyEdit`.
    public func updateScheduledTask(_ task: ScheduledTask, now: Date = Date()) {
        guard let index = scheduledTasks.firstIndex(where: { $0.id == task.id }) else { return }
        var edited = task
        edited.title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        scheduledTasks[index].applyEdit(edited, now: now, calendar: scheduleCalendar)
        scheduledTasksChanged()
    }

    /// Deletes the task. Conversations its runs created stay.
    public func deleteScheduledTask(_ id: UUID) {
        scheduledTasks.removeAll { $0.id == id }
        scheduledRunReplyIDs.removeValue(forKey: id)
        scheduledTasksChanged()
    }

    public func pauseScheduledTask(_ id: UUID) {
        guard let index = scheduledTasks.firstIndex(where: { $0.id == id }) else { return }
        scheduledTasks[index].pause()
        scheduledTasksChanged()
    }

    /// Resumes a paused task from its next slot. Returns why it cannot, e.g.
    /// a one-time task whose time has passed.
    @discardableResult
    public func resumeScheduledTask(_ id: UUID, now: Date = Date()) -> String? {
        guard let index = scheduledTasks.firstIndex(where: { $0.id == id }) else { return "找不到这个定时任务" }
        if let failure = scheduledTasks[index].resume(now: now, calendar: scheduleCalendar) { return failure }
        scheduledTasksChanged()
        return nil
    }

    /// 立即运行: sends the prompt now, whatever the schedule says, without
    /// moving a slot that is not due yet. Returns why it could not start.
    @discardableResult
    public func runScheduledTaskNow(_ id: UUID, now: Date = Date()) async -> String? {
        switch await startScheduledRun(id, now: now, manual: true) {
        case .started, .notDue:
            return nil
        case .skipped(let reason), .failed(let reason):
            return "无法启动定时任务：\(reason)"
        case .waiting:
            return "无法启动定时任务：另一个对话正在回复，等它结束再运行"
        }
    }

    /// Whether the reply the task's latest run started is still streaming.
    public func isScheduledTaskRunning(_ id: UUID) -> Bool {
        guard isStreaming, let replyID = scheduledRunReplyIDs[id] else { return false }
        return replyID == currentReplyID
    }

    /// True when an attached task's conversation is gone, so its runs go to
    /// new conversations instead.
    public func scheduledTaskTargetMissing(_ task: ScheduledTask) -> Bool {
        if case .attached(let id) = task.target { return conversation(id) == nil }
        return false
    }

    /// Opens the conversation of the task's latest run. False when there is
    /// none, it was deleted, or it is locked (opening it here would bypass
    /// the lock).
    @discardableResult
    public func openScheduledTaskRun(_ id: UUID) -> Bool {
        guard let conversationID = scheduledTasks.first(where: { $0.id == id })?.lastRunConversationID,
              let run = conversation(conversationID), !run.isLocked else { return false }
        selectedConversationID = conversationID
        return true
    }

    /// Clears the unread flag of every task's latest run (Codex
    /// `sidebarElectron.automationsMarkAllRead`).
    public func markScheduledTaskRunsRead() {
        for id in Set(scheduledTasks.compactMap(\.lastRunConversationID)) where conversation(id)?.hasUnread == true {
            setUnread(id, unread: false)
        }
    }

    /// One attempt to run task `id` at `now`. The scheduler's path runs only
    /// a due task and books a slot it cannot run as skipped; 立即运行
    /// (`manual`) runs regardless and books nothing it could not start.
    func startScheduledRun(_ id: UUID, now: Date, manual: Bool = false) async -> ScheduledRunOutcome {
        guard let task = scheduledTasks.first(where: { $0.id == id }) else { return .failed("找不到这个定时任务") }
        guard manual || task.isDue(at: now) else { return .notDue }
        func refuse(_ reason: String) -> ScheduledRunOutcome {
            guard !manual else { return .failed(reason) }
            if let index = scheduledTasks.firstIndex(where: { $0.id == id }) {
                scheduledTasks[index].recordSkip(at: now, reason: reason, calendar: scheduleCalendar)
                scheduledTasksChanged()
            }
            return .skipped(reason)
        }
        let target = task.resolvedTarget { conversation($0) != nil }
        if case .attached(let conversationID) = target, isStreaming, streamingConversationID == conversationID {
            // Never queue a prompt into a reply that is still working.
            return refuse("对话仍在回复")
        }
        // One reply streams at a time and starting another cancels it.
        if isStreaming { return manual ? .failed("另一个对话正在回复，等它结束再运行") : .waiting }

        var run: Conversation
        if case .attached(let conversationID) = target, let existing = conversation(conversationID) {
            run = existing
        } else {
            run = Conversation(title: task.runTitle(at: now, calendar: scheduleCalendar))
            run.scheduledTaskID = task.id
            if let projectID = task.projectID, projects.contains(where: { $0.id == projectID }) {
                run.projectID = projectID
            }
        }
        guard let provider = resolveProvider(for: run), resolveModel(for: run, provider: provider) != nil else {
            return refuse("先在设置中添加供应商并选择模型")
        }
        guard let key = (try? secrets.secret(for: provider.keychainAccount)) ?? nil, !key.isEmpty else {
            return refuse("「\(provider.name)」缺少 API Key")
        }
        if let directory = task.workingDirectory, !directory.isEmpty { run.workingDirectory = directory }
        if let mode = task.permissionMode, PermissionMode(rawValue: mode) != nil { run.permissionMode = mode }
        run.messages.append(ChatMessage(role: .user, parts: [.text(task.prompt)]))
        run.updatedAt = Date()
        replace(run)
        persist(run)
        // Booked before the reply starts: the slot is spent even if the app
        // quits mid-reply, so it can never run twice.
        if let index = scheduledTasks.firstIndex(where: { $0.id == id }) {
            scheduledTasks[index].recordRun(at: now, conversationID: run.id, calendar: scheduleCalendar)
        }
        scheduledTasksChanged()
        await startReply(conversationID: run.id, remote: false)
        if isStreaming, streamingConversationID == run.id, let replyID = currentReplyID {
            scheduledRunReplyIDs[id] = replyID
        }
        return .started(conversationID: run.id)
    }

    /// After a time-zone change, wall-clock slots still ahead are read again
    /// in the new zone, so 「每天 09:00」 means 09:00 where the Mac now is.
    /// Due slots are left for the scheduler to run.
    func rescheduleScheduledTasksForTimeZoneChange(now: Date = Date()) {
        for index in scheduledTasks.indices {
            scheduledTasks[index].followTimeZoneChange(now: now, calendar: scheduleCalendar)
        }
        scheduledTasksChanged()
    }

    /// Saves the tasks and re-arms the scheduler for the new earliest slot.
    private func scheduledTasksChanged() {
        let store = self.store
        let snapshot = scheduledTasks
        Task {
            do { try await store.saveScheduledTasks(snapshot) }
            catch {
                DiagnosticsCenter.shared.record("workspace", .error, "scheduled tasks save failed",
                    fields: ["error": error.localizedDescription])
            }
        }
        schedulerStorage?.rearm()
    }

    // MARK: - Worktree management (Codex worktree cleanup, snapshot/restore,
    // handoff)

    /// Settings-driven deletion decision state, kept together so the policy
    /// reads one consistent snapshot (official `settings.worktrees.*`).
    private var cleanupSettings: (auto: Bool, keep: Int) {
        (settings.worktreeAutoCleanup, settings.worktreeKeepCount)
    }

    /// The detail rows the Worktree settings pane lists, refreshed off the
    /// main actor. `nil` until the first `refreshWorktreeDetails()` ran.
    public private(set) var worktreeDetails: [ManagedWorktreeDetail] = []
    /// One git operation per worktree at a time: deletion, restore and the
    /// handoff moves all take this lock so a double click cannot race git.
    @ObservationIgnored private var busyWorktreeIDs: Set<UUID> = []
    @ObservationIgnored private var worktreeCleanupRunning = false
    /// The handoff's step text per conversation, shown under the header.
    public private(set) var handoffProgress: [UUID: String] = [:]

    func isWorktreeBusy(_ id: UUID) -> Bool { busyWorktreeIDs.contains(id) }

    /// A deleted chat is unlinked from the registry. A live worktree stays:
    /// deleting a chat is not deleting its checkout, which may hold work the
    /// user still wants. 设置 → Worktree lists it without a chat and the
    /// keep-count cleanup counts it. A row that was already deleted has no chat
    /// left to restore it into, so it goes; its snapshot ref stays in the
    /// repository, so the work is still reachable with git.
    func unlinkDeletedConversationFromWorktrees(_ id: UUID) {
        guard managedWorktrees.contains(where: { $0.conversationIDs.contains(id) }) else { return }
        managedWorktrees = managedWorktrees.compactMap { record in
            guard record.conversationIDs.contains(id) else { return record }
            var next = record
            next.conversationIDs.removeAll { $0 == id }
            return next.deletedAt != nil && next.conversationIDs.isEmpty ? nil : next
        }
        persistManagedWorktrees()
    }

    /// Changes the registry row as it is now. Async paths (delete, restore,
    /// handoff) must not write back a copy taken before their git work: a chat
    /// deleted meanwhile would be linked again. False when the row is gone.
    @discardableResult
    func modifyManagedWorktree(_ id: UUID, _ change: (inout ManagedWorktree) -> Void) -> Bool {
        guard let index = managedWorktrees.firstIndex(where: { $0.id == id }) else { return false }
        change(&managedWorktrees[index])
        persistManagedWorktrees()
        return true
    }

    /// Pins `streamingConversationID` for tests, so a chat can count as
    /// 「正在运行」 without a network round trip. Nil clears it.
    func markStreamingForTest(_ id: UUID?) {
        streamingConversationID = id
        isStreaming = id != nil
    }

    /// Why the pane's 删除 button cannot proceed, or nil when it may. Shown
    /// verbatim before the confirmation dialog ever opens.
    public func worktreeDeletionRefusal(for id: UUID) -> String? {
        guard let record = managedWorktrees.first(where: { $0.id == id }) else {
            return "没有这个 Worktree"
        }
        guard record.deletedAt == nil else { return "这个 Worktree 已经删除" }
        let linked = conversations.filter { record.conversationIDs.contains($0.id) }
        if linked.contains(where: \.isPinned) {
            return "有置顶的对话在使用这个 Worktree。先取消置顶，或手动删除。"
        }
        if linked.contains(where: { $0.id == streamingConversationID }) {
            return "这个 Worktree 的对话还在运行，等回复结束后再删。"
        }
        return nil
    }

    private func setWorktreeBusy(_ id: UUID, _ busy: Bool) {
        if busy { busyWorktreeIDs.insert(id) } else { busyWorktreeIDs.remove(id) }
    }

    func setHandoffProgress(_ id: UUID, _ step: String?) {
        if let step { handoffProgress[id] = step } else { handoffProgress[id] = nil }
    }

    /// Recomputes path / branch / size for every registry row (and collects
    /// linked conversation titles). Called by the pane's refresh and after a
    /// deletion or restore; the disk walk runs detached.
    public func refreshWorktreeDetails() async {
        let registry = managedWorktrees
        let titles = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.title) })
        let rows: [ManagedWorktreeDetail] = await Task.detached(priority: .utility) {
            registry.map { record in
                var size: Int64?
                var exists = false
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    exists = true
                    if record.deletedAt == nil {
                        // An enumerator walk, ignoring symlinked files.
                        if let enumerator = FileManager.default.enumerator(
                            at: URL(fileURLWithPath: record.path),
                            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
                        ) {
                            var total: Int64 = 0
                            for case let file as URL in enumerator {
                                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
                            }
                            size = total
                        }
                    }
                }
                var label: String
                if record.deletedAt != nil {
                    label = "已删除"
                } else if let branch = record.branch {
                    label = branch
                } else if exists, let live = try? GitInfo.branch(at: URL(fileURLWithPath: record.path)) {
                    label = "已分离 · \(live)"
                } else {
                    label = "已分离"
                }
                return ManagedWorktreeDetail(
                    id: record.id,
                    path: record.path,
                    sourceRoot: record.sourceRoot,
                    branchLabel: label,
                    createdAt: record.createdAt,
                    environmentPath: record.environmentPath,
                    conversationTitles: record.conversationIDs,
                    linkedConversationTitles: record.conversationIDs.compactMap { titles[$0] },
                    sizeOnDisk: size,
                    existsOnDisk: exists,
                    deleted: record.deletedAt != nil
                )
            }
        }.value
        worktreeDetails = rows
    }

    /// The worktree whose deleted snapshot the chat offers to restore, or nil.
    /// Bound to the current workingDirectory, not the chat id alone: after a
    /// handoff to Local the worktree keeps serving nothing.
    public func deletedWorktree(forConversation id: UUID) -> ManagedWorktree? {
        guard let conversation = conversation(id), let directory = conversation.workingDirectory else { return nil }
        guard let record = managedWorktrees.first(where: {
            $0.conversationIDs.contains(id) && $0.deletedAt != nil
        }), directory == record.path else { return nil }
        return record
    }

    /// The deletion decision (pure policy), applied. Returns the ids actually
    /// deleted, oldest-first; called after a worktree creation (by
    /// WorktreeMode) and once at launch.
    @discardableResult
    public func runWorktreeCleanup() async -> [UUID] {
        #if os(iOS)
        return []
        #else
        guard !worktreeCleanupRunning else { return [] }
        worktreeCleanupRunning = true
        defer { worktreeCleanupRunning = false }
        let (auto, keep) = cleanupSettings
        let chats = conversations.map {
            WorktreeCleanup.Chat(id: $0.id, isPinned: $0.isPinned, isArchived: $0.isArchived)
        }
        let items = managedWorktrees
            .filter { $0.deletedAt == nil }
            .map { WorktreeCleanup.Item(id: $0.id, createdAt: $0.createdAt, conversationIDs: Set($0.conversationIDs)) }
        let plan = WorktreeCleanup.orderedDeletions(
            items: items,
            conversations: chats,
            streamingConversationID: streamingConversationID,
            autoCleanup: auto,
            keepCount: keep
        )
        var deleted: [UUID] = []
        for id in plan {
            if let failure = await deleteManagedWorktree(id) {
                // One worktree refusing to go does not stop the rest; the
                // reason is surfaced where the user can see it.
                showError(failure)
                continue
            }
            deleted.append(id)
        }
        if !deleted.isEmpty { await refreshWorktreeDetails() }
        return deleted
        #endif
    }

    /// Snapshot → environment cleanup script → `git worktree remove --force`
    /// → prune → mark the registry row deleted with the snapshot. Refusals:
    /// a pinned chat linked to it, or a chat whose reply is running (official
    /// texts; the settings pane shows them verbatim).
    @discardableResult
    public func deleteManagedWorktree(_ id: UUID) async -> String? {
        #if os(iOS)
        return "删除 Worktree 只能在 Mac 上做"
        #else
        guard let record = managedWorktrees.first(where: { $0.id == id }) else {
            return "没有这个 Worktree"
        }
        guard record.deletedAt == nil else { return "这个 Worktree 已经删除" }
        let linked = conversations.filter { record.conversationIDs.contains($0.id) }
        if linked.contains(where: \.isPinned) {
            return "有置顶的对话在使用这个 Worktree。先取消置顶，或手动删除。"
        }
        if linked.contains(where: { $0.id == streamingConversationID }) {
            return "这个 Worktree 的对话还在运行，等回复结束后再删。"
        }
        guard !busyWorktreeIDs.contains(id) else { return "这个 Worktree 正忙，请稍后再试。" }
        setWorktreeBusy(id, true)
        defer { setWorktreeBusy(id, false) }

        let sourceRoot = record.sourceRoot
        let path = record.path
        let worktreeID = record.id
        let environmentPath = record.environmentPath
        var snapshot: ManagedWorktreeSnapshot?
        var cleanupNote: String?
        do {
            let gathered = try await Task.detached(priority: .userInitiated) { () -> WorktreeGit.Snapshot? in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return try WorktreeGit.snapshot(worktreeRoot: path, id: worktreeID)
            }.value
            if let gathered {
                snapshot = ManagedWorktreeSnapshot(
                    ref: "refs/omp/snapshots/\(worktreeID.uuidString)",
                    commit: gathered.commit,
                    head: gathered.head,
                    createdAt: Date()
                )
            }
        } catch {
            // No snapshot, no deletion: the work may not be committed anywhere.
            return "快照失败，未删除：\(error.localizedDescription)"
        }
        if let environmentPath {
            let result = await LocalEnvironmentDiscovery.runLocalEnvironmentScript(
                .cleanup, configPath: environmentPath, sourceRoot: sourceRoot, worktreeRoot: path
            )
            if !result.skipped, result.exitCode != 0 {
                cleanupNote = "清理脚本失败（退出码 \(result.exitCode)）：\n" + worktreeOutputTail(result.output)
            }
        }
        let removed = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try WorktreeGit.remove(worktreePath: path, repositoryRoot: sourceRoot)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let removed { return "删除 Worktree 失败：\(removed)" }

        // Re-read the row: a chat may have been deleted (and unlinked) while
        // git ran, and the copy from the start would bring it back. A row
        // left without chats has nothing to restore it into; the snapshot
        // ref keeps the work in the repository.
        modifyManagedWorktree(worktreeID) { current in
            current.snapshot = snapshot
            current.deletedAt = Date()
        }
        if managedWorktrees.first(where: { $0.id == worktreeID })?.conversationIDs.isEmpty == true {
            managedWorktrees.removeAll { $0.id == worktreeID }
            persistManagedWorktrees()
        }
        await refreshWorktreeDetails()
        if let cleanupNote { showError(cleanupNote) }
        return nil
        #endif
    }

    /// Re-creates a deleted worktree from its snapshot at the registered path
    /// (or the nearest free suffixed path) and rebinds every linked chat.
    /// The snapshot's uncommitted work comes back uncommitted, staged files
    /// staged. Unarchiving never auto-restores; only this does.
    @discardableResult
    public func restoreManagedWorktree(for conversationID: UUID) async -> String? {
        #if os(iOS)
        return "恢复 Worktree 只能在 Mac 上做"
        #else
        guard let record = managedWorktrees.first(where: {
            $0.id == deletedWorktree(forConversation: conversationID)?.id
        }) else {
            return "这个对话的 Worktree 没有可恢复的快照"
        }
        guard let snapshot = record.snapshot else {
            return "删除前没有留下快照，无法恢复"
        }
        let id = record.id
        guard !busyWorktreeIDs.contains(id) else { return "这个 Worktree 正忙，请稍后再试。" }
        setWorktreeBusy(id, true)
        defer { setWorktreeBusy(id, false) }
        do {
            // The index tree rides as the snapshot commit's second parent.
            let parents = await ManagedWorktreeGit.run(
                ["rev-list", "--parents", "-n", "1", snapshot.commit], in: record.sourceRoot
            )
            var indexCommit: String?
            if parents.ok {
                let parts = parents.stdoutText.split(whereSeparator: \.isWhitespace).map(String.init)
                if parts.count >= 3 { indexCommit = parts[2] }
            }
            let used = try await Task.detached(priority: .userInitiated) { () throws -> String in
                try WorktreeGit.restore(
                    repositoryRoot: record.sourceRoot,
                    head: snapshot.head,
                    commit: snapshot.commit,
                    indexCommit: indexCommit,
                    to: record.path
                )
            }.value
            // The current row, not the copy from before the restore ran.
            let linkedNow = managedWorktrees.first(where: { $0.id == record.id })?.conversationIDs ?? []
            modifyManagedWorktree(record.id) { current in
                current.path = used
                current.deletedAt = nil
            }
            for linked in linkedNow {
                guard let conversation = conversation(linked) else { continue }
                updateWorkingDirectory(linked, subdirectorySuffix(conversation.workingDirectory, from: record.path, to: used) ?? used)
            }
            await refreshWorktreeDetails()
            return nil
        } catch {
            return "恢复失败：\(error.localizedDescription)"
        }
        #endif
    }

    /// A chat bound to `<worktree>/<sub>` keeps its sub-path when the
    /// worktree returns at a suffixed path. Both roots are standardized:
    /// `repositoryRoot` resolves `/var` → `/private/var` while conversations
    /// may carry the short form, which would break the prefix match.
    private func subdirectorySuffix(_ original: String?, from oldRoot: String, to newRoot: String) -> String? {
        guard let original else { return newRoot }
        let originalStandard = (original as NSString).standardizingPath
        let oldStandard = (oldRoot as NSString).standardizingPath
        let newStandard = (newRoot as NSString).standardizingPath
        if originalStandard == oldStandard { return newStandard }
        guard originalStandard.hasPrefix(oldStandard + "/") else { return original }
        return newStandard + String(originalStandard.dropFirst(oldStandard.count))
    }

    /// Moves a chat and its code between its local checkout and its
    /// associated worktree (official `localConversation.moveTo*`). Returns
    /// nil on success, the failure message otherwise; every step reports
    /// progress through `handoffProgress` and nothing is lost on a failure.
    @discardableResult
    public func handoff(_ conversationID: UUID, to destination: HandoffDestination) async -> String? {
        guard let conversation = conversation(conversationID) else { return "找不到这个对话" }
        #if os(iOS)
        return "交接只能在 Mac 上做"
        #else
        guard conversationID != streamingConversationID else {
            return "当前回复结束后再交接"
        }
        switch destination {
        case .local: return await handoffToLocal(conversationID, conversation)
        case .worktree: return await handoffToWorktree(conversationID, conversation)
        }
        #endif
    }

    private func handoffToLocal(_ conversationID: UUID, _ conversation: Conversation) async -> String? {
        #if os(iOS)
        return "交接只能在 Mac 上做"
        #else
        guard let record = managedWorktrees.first(where: {
            $0.deletedAt == nil && $0.conversationIDs.contains(conversationID)
        }), let worktreeDirectory = conversation.workingDirectory,
           FileManager.default.fileExists(atPath: worktreeDirectory),
           (worktreeDirectory + "/").hasPrefix(record.path + "/")
        else {
            return "这个对话不在它的 Worktree 里"
        }
        let localRoot = record.sourceRoot
        guard FileManager.default.fileExists(atPath: localRoot) else {
            return "本地仓库不见了：\(GitInfo.tildified(localRoot))"
        }
        guard WorktreeHandoff.sameRepository(worktreeDirectory, localRoot) else {
            return "Worktree 和本地目录不再是同一个仓库"
        }
        setHandoffProgress(conversationID, "正在检查两边状态…")
        defer { setHandoffProgress(conversationID, nil) }
        do {
            let move: WorktreeHandoff.Move = try await Task.detached(priority: .userInitiated) { () throws in
                let base = try WorktreeHandoff.mergeBase(worktreeRoot: worktreeDirectory, localRoot: localRoot)
                return try WorktreeHandoff.buildMove(root: worktreeDirectory, base: base, id: record.id)
            }.value
            let conflicts = try await Task.detached(priority: .userInitiated) {
                try WorktreeHandoff.conflictingPaths(move, destination: localRoot)
            }.value
            if !conflicts.isEmpty {
                let names = conflicts.prefix(5).joined(separator: "、")
                return "先把本地的这些改动暂存或提交：\(names)"
            }
            setHandoffProgress(conversationID, "正在把改动搬回本地…")
            try await Task.detached(priority: .userInitiated) {
                if move.patch.isEmpty {
                    // Nothing to carry; the chat just returns to Local.
                    return
                }
                try WorktreeHandoff.apply(move, to: localRoot)
            }.value
            setHandoffProgress(conversationID, "正在清理 Worktree…")
            let cleanFailure: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try WorktreeHandoff.cleanSource(root: worktreeDirectory, paths: move.paths)
                    return nil
                } catch {
                    // The work is safe in Local; the worktree side just could
                    // not be folded back. Say so instead of failing the move.
                    return error.localizedDescription
                }
            }.value
            updateWorkingDirectory(conversationID, localRoot)
            await refreshWorktreeDetails()
            statusMessage = "已把对话移到本地工作区"
            if let cleanFailure {
                showError("改动已到本地，但 Worktree 没能清干净：\(cleanFailure)")
            }
            return nil
        } catch let error as WorktreeHandoff.GitError {
            return error.message
        } catch {
            return "交接失败：\(error.localizedDescription)"
        }
        #endif
    }

    private func handoffToWorktree(_ conversationID: UUID, _ conversation: Conversation) async -> String? {
        #if os(iOS)
        return "交接只能在 Mac 上做"
        #else
        guard let localDirectory = conversation.workingDirectory,
              FileManager.default.fileExists(atPath: localDirectory)
        else {
            return "这个对话还没有绑定本地文件夹"
        }
        guard let localRoot = try? GitWorkingTree.repositoryRoot(of: localDirectory) else {
            return "当前目录不在 git 仓库里"
        }
        setHandoffProgress(conversationID, "正在检查本地改动…")
        defer { setHandoffProgress(conversationID, nil) }

        // Reuse the chat's own worktree when it lives in the same repository;
        // otherwise create one (detached, no carried changes — the handoff
        // itself moves the local work over).
        var record = managedWorktrees.first(where: {
            $0.deletedAt == nil && $0.conversationIDs.contains(conversationID)
        })
        if let existing = record,
           !WorktreeHandoff.sameRepository(existing.sourceRoot, localRoot) {
            return "这个对话的 Worktree 属于另一个仓库"
        }
        if record == nil {
            setHandoffProgress(conversationID, "正在创建 Worktree…")
            let created = await createManagedWorktreeRecord(
                for: conversationID,
                baseBranch: nil,
                carryUncommittedChanges: false,
                bindConversation: false,
                sourceDirectory: localDirectory
            )
            switch created {
            case .success(let fresh):
                record = fresh
            case .failure(let failure):
                return failure.message
            }
        }
        guard let worktree = record else { return "没能找到或创建 Worktree" }
        let worktreeID = worktree.id
        guard !busyWorktreeIDs.contains(worktreeID) else { return "这个 Worktree 正忙，请稍后再试。" }
        setWorktreeBusy(worktreeID, true)
        defer { setWorktreeBusy(worktreeID, false) }

        do {
            let move: WorktreeHandoff.Move = try await Task.detached(priority: .userInitiated) {
                try WorktreeHandoff.buildMove(root: localRoot, base: "HEAD", id: UUID())
            }.value
            let worktreePath = worktree.path
            guard FileManager.default.fileExists(atPath: worktreePath) else {
                return "这个 Worktree 已经不在磁盘上，先删除记录再新建。"
            }
            let busy = try await Task.detached(priority: .userInitiated) {
                try WorktreeHandoff.conflictingPaths(move, destination: worktreePath)
            }.value
            if !busy.isEmpty {
                let names = busy.prefix(5).joined(separator: "、")
                return "Worktree 里还有没处理的改动，先处理这些文件：\(names)"
            }
            // Land the worktree on the local HEAD when it can fast-forward,
            // so the patch applies to files the worktree actually has.
            setHandoffProgress(conversationID, "正在对齐 Worktree…")
            let moved = try await Task.detached(priority: .userInitiated) { () throws -> Bool in
                try WorktreeHandoff.fastForwardWorktree(root: worktreePath, to: move.baseHead)
            }.value
            guard moved else {
                return "Worktree 里有没提交的改动，交接取消。"
            }
            setHandoffProgress(conversationID, "正在把本地改动搬进 Worktree…")
            try await Task.detached(priority: .userInitiated) {
                if !move.patch.isEmpty {
                    try WorktreeHandoff.apply(move, to: worktreePath)
                }
            }.value
            setHandoffProgress(conversationID, "正在恢复本地目录…")
            let cleanFailure: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    if !move.patch.isEmpty {
                        try WorktreeHandoff.cleanSource(root: localRoot, paths: move.paths)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard cleanFailure == nil else {
                // Local never got cleaned; undo the worktree side so neither
                // side is half-moved.
                let undone: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                    do {
                        if !move.patch.isEmpty { try WorktreeHandoff.revert(move, on: worktreePath) }
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                let rollback = undone ?? "Worktree 已还原"
                return "本地目录没能恢复干净，交接已回滚（\(rollback)）"
            }
            let rebased = subdirectorySuffix(localDirectory, from: localRoot, to: worktreePath) ?? worktreePath
            updateWorkingDirectory(conversationID, rebased)
            // Freshen the registry row: the worktree now starts at Local's HEAD.
            modifyManagedWorktree(worktree.id) { $0.baseCommit = move.baseHead }
            await refreshWorktreeDetails()
            statusMessage = "已把对话移到 Worktree"
            return nil
        } catch let error as WorktreeHandoff.GitError {
            return error.message
        } catch {
            return "交接失败：\(error.localizedDescription)"
        }
        #endif
    }

    /// A chat bound to this worktree (worktree ⋯ menu, settings row).
    @discardableResult
    public func newChat(inManagedWorktree id: UUID) -> UUID? {
        guard let record = managedWorktrees.first(where: { $0.id == id }), record.deletedAt == nil,
              FileManager.default.fileExists(atPath: record.path) else { return nil }
        let conversation = newConversation(in: nil)
        updateWorkingDirectory(conversation.id, record.path)
        var updated = record
        if !updated.conversationIDs.contains(conversation.id) {
            updated.conversationIDs.append(conversation.id)
            updateManagedWorktree(updated)
        }
        return conversation.id
    }

    /// Truncates script output for cards and banners: head and tail.
    nonisolated func worktreeOutputTail(_ output: String, cap: Int = 1500) -> String {
        guard output.count > cap else { return output }
        let head = String(output.prefix(cap / 2))
        let tail = String(output.suffix(cap / 2))
        return head + "\n…（中间省略）…\n" + tail
    }

    // MARK: - Row status

    /// The tags conversation `id`'s sidebar row shows (Codex
    /// `localTaskRow`). In-memory facts only; `.none` when it is gone.
    public func rowStatus(for id: UUID) -> ConversationRowStatus {
        guard let conversation = conversation(id) else { return .none }
        return rowStatus(for: conversation)
    }

    /// Same, for a conversation the caller already holds, so a row needs
    /// no lookup: a scan of the waiting cards and the tasks, both short.
    public func rowStatus(for conversation: Conversation) -> ConversationRowStatus {
        let id = conversation.id
        var originLive = false
        var attachedTaskID: UUID?
        for task in scheduledTasks {
            if task.id == conversation.scheduledTaskID { originLive = true }
            if attachedTaskID == nil, case .attached(id) = task.target { attachedTaskID = task.id }
        }
        return ConversationRowStatus(conversation, facts: .init(
            hasPendingApproval: pendingApprovals.contains { $0.conversationID == id },
            isBusy: streamingConversationID == id || compactingConversationIDs.contains(id),
            originTaskIsLive: originLive,
            attachedTaskID: attachedTaskID
        ))
    }

    #if os(macOS)
    /// 「打开定时任务」: opens the editor of the task linked to conversation
    /// `id` (the one that created it, else the one attached to it). False
    /// when no linked task exists any more.
    @discardableResult
    public func openLinkedScheduledTask(_ id: UUID) -> Bool {
        guard let taskID = rowStatus(for: id).taskID else { return false }
        NotificationCenter.default.post(name: .ompEditScheduledTask, object: taskID)
        return true
    }
    #endif

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
    /// Home scanned for other AI apps (`~/.claude`, `~/.cursor`, their
    /// `Library/Application Support`). Tests point it at a fixture folder so
    /// the user's real setups are never read; nil means `skillsHome`'s home.
    @ObservationIgnored public var externalImportHome: String?
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
        SkillCatalog.load(roots: skillRoots(for: conversationID))
    }

    /// The folders `skillCatalog(for:)` reads, so the `$` list can load them
    /// off the main actor.
    func skillRoots(for conversationID: UUID?) -> [SkillRoot] {
        var roots: [SkillRoot] = []
        if let id = conversationID, let directory = conversation(id)?.workingDirectory, !directory.isEmpty {
            roots += SkillCatalog.repositoryRoots(workingDirectory: directory)
        }
        return roots + baseSkillRoots(installedPlugins)
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

    // MARK: - Link destination

    /// 设置 → 浏览器 → 链接打开位置 (official linkDestinationPrompt).
    public func updateLinkDestination(_ value: String) {
        settings.linkDestination = value == "app" ? "app" : "system"
        Task { await saveSettings(settings) }
    }

    #if os(macOS)
    /// Where `openMessageLink` sent a link.
    public enum OpenedLink: Equatable, Sendable {
        case sidePanelTab(UUID)
        case systemBrowser
    }

    /// A web link clicked in a message: a new tab of the side-panel browser
    /// when 链接打开位置 is 应用内, else the default browser.
    @discardableResult
    public func openMessageLink(_ url: URL) -> OpenedLink {
        if settings.linkDestination == "app" {
            let tab = openBrowserTab(url: url.absoluteString)
            toggleSidePanel(open: true, tab: .browser)
            return .sidePanelTab(tab)
        }
        NSWorkspace.shared.open(url)
        return .systemBrowser
    }
    #endif

    // MARK: - Dictation

    /// Composer dictation, recognised on the device. Tests swap in a
    /// controller over a fake microphone and recognizer.
    @ObservationIgnored public internal(set) var dictation = DictationController()
    /// The conversation the dictation belongs to: its text lands in that
    /// conversation's draft even after switching away.
    public private(set) var dictationConversationID: UUID?
    @ObservationIgnored private var dictationSendsWhenDone = false

    /// Where dictation is (Codex `composer.dictation.*`).
    public var dictationState: DictationState { dictation.state }

    /// The selected conversation's composer shows the dictation bar: a
    /// session of this conversation is active or failed.
    public var showsDictationBar: Bool {
        dictation.isEngaged && dictationConversationID == selectedConversationID
    }

    /// 听写: listens into the selected conversation's draft. Read-aloud stops
    /// first so the microphone does not take it down.
    public func startDictation() {
        guard !dictation.state.isActive else { return }
        Speech.stop()
        dictationConversationID = selectedConversationID
        dictationSendsWhenDone = false
        dictation.onTranscript = { [weak self] text in self?.deliverDictation(text) }
        dictation.chosenLocale = settings.dictationLocale
        dictation.start()
    }

    /// 停止 puts the text in the draft; 转写并发送 (`send`) then sends it
    /// through the normal path.
    public func stopDictation(send: Bool) {
        guard dictation.state.isActive else { return }
        dictationSendsWhenDone = send
        dictation.stop()
    }

    /// 取消: drops what was heard.
    public func cancelDictation() {
        dictation.cancel()
    }

    /// 听写 ⌘⇧V: starts, stops into the draft, or cancels one still starting.
    public func toggleDictation() {
        switch dictation.state {
        case .starting: cancelDictation()
        case .listening: stopDictation(send: false)
        case .finishing, .transcribing: break
        default: startDictation()
        }
    }

    /// Transcribes a recording into the selected conversation's draft with
    /// the live recognizer and its error mapping, so dictation can be tested
    /// without a microphone. `localeIdentifier` overrides 听写语言 and the
    /// system's preferred languages. Returns the error text; nil when the
    /// text landed or the transcription was cancelled.
    public func transcribeIntoDraft(fileURL: URL, localeIdentifier: String? = nil) async -> String? {
        guard !dictation.state.isActive else { return DictationError.startFailed.message }
        dictationConversationID = selectedConversationID
        dictationSendsWhenDone = false
        dictation.onTranscript = { [weak self] text in self?.deliverDictation(text) }
        dictation.chosenLocale = settings.dictationLocale
        return await dictation.transcribe(fileURL: fileURL, localeIdentifier: localeIdentifier)?.message
    }

    /// Codex `dictation.recovery.*` on a failed dictation; actions the
    /// failure does not offer are ignored. 重试 transcribes the kept audio
    /// after a transcription failure, otherwise listens again.
    public func applyDictationRecovery(_ action: DictationRecoveryAction) {
        guard let recovery = dictation.state.recovery, recovery.actions.contains(action) else { return }
        switch action {
        case .copyText:
            if let text = recovery.text {
                copyToPasteboard(text)
                statusMessage = "已复制听写的文字"
            }
        case .addToMessage:
            if let text = recovery.text { mergeDictation(text) }
            dictation.dismiss()
        case .retry:
            if recovery.error == .transcriptionFailed, dictation.retranscribe() { return }
            startDictation()
        case .dismiss:
            dictation.dismiss()
        }
    }

    /// 打开麦克风设置 (Codex `microphonePermissionDeniedWithSettings`).
    public func openMicrophoneSettings() {
        DictationSystemSettings.open(.microphone)
    }

    /// 打开语音识别设置, for the macOS 15 / iOS 18 recognizer's permission.
    public func openSpeechRecognitionSettings() {
        DictationSystemSettings.open(.speechRecognition)
    }

    /// Switching conversations closes the microphone; what was said still
    /// lands in the draft of the conversation it was said in, unsent.
    private func dictationFollowSelection() {
        guard dictationConversationID != selectedConversationID else { return }
        switch dictation.state {
        case .starting:
            dictation.cancel()
        case .listening:
            dictationSendsWhenDone = false
            dictation.stop()
        case .finishing, .transcribing:
            dictationSendsWhenDone = false
        default:
            break
        }
    }

    private func deliverDictation(_ text: String) {
        mergeDictation(text)
        if dictation.reachedMaxDuration { statusMessage = "已达到最长录音时长" }
        let sends = dictationSendsWhenDone
        dictationSendsWhenDone = false
        if sends, dictationConversationID == selectedConversationID { send() }
    }

    /// Appends to the dictation conversation's draft: the live one when that
    /// conversation is on screen, else the one kept for it.
    private func mergeDictation(_ text: String) {
        if dictationConversationID == selectedConversationID {
            draft = DictationText.merge(text, into: draft)
        } else if let id = dictationConversationID {
            draftsByConversation[id] = DictationText.merge(text, into: draftsByConversation[id] ?? "")
        }
    }

    // MARK: - Remote approvals

    /// Phone commands this Mac refused, oldest first, capped at
    /// `RelayCommandFailure.maxKept`. Commands get no reply over the LAN route
    /// or the hub, so the snapshot echoes these and the phone matches them by
    /// `requestID`. Session-only.
    public private(set) var relayCommandFailures: [RelayCommandFailure] = []

    /// The approval cards a paired phone sees, oldest first. Only cards of
    /// conversations the snapshot mirrors: a locked, archived or temporary
    /// chat's tool call never leaves this Mac.
    public func relayApprovals() -> [RelayApproval] {
        let mirrored = Set(sortedConversations.map(\.id))
        return pendingApprovals.filter { mirrored.contains($0.conversationID) }.map { request in
            RelayApproval(
                id: request.id.uuidString,
                conversationID: request.conversationID.uuidString,
                callID: request.callID,
                toolName: request.toolName,
                source: request.source,
                risk: request.risk.rawValue,
                summary: request.summary,
                argumentsJSON: request.argumentsJSON,
                canApprove: RelayApproval.phoneMayAllow(request.risk, allowShell: settings.relayAllowShell)
            )
        }
    }

    /// Answers an approval card for a paired phone. The phone can only answer
    /// cards `relayApprovals()` mirrors; 拒绝 always applies, 允许一次 beyond a
    /// read needs 允许手机访问文件与终端. Returns nil when applied, else the
    /// refusal code — `not_found` (unknown or already answered) or
    /// `shell_disabled` — which is also kept in `relayCommandFailures` under
    /// `requestID` when the phone sent one.
    @discardableResult
    public func answerRemoteApproval(
        _ approvalID: String, _ decision: RelayApprovalDecision, requestID: String? = nil
    ) -> String? {
        let card = relayApprovals().first { $0.id.caseInsensitiveCompare(approvalID) == .orderedSame }
        let error: String?
        if let card, let id = UUID(uuidString: card.id) {
            if decision == .allowOnce, !card.canApprove {
                error = "shell_disabled"
            } else {
                resolveApproval(id, decision == .allowOnce ? .allowOnce : .deny)
                error = nil
            }
        } else {
            error = "not_found"
        }
        var fields = ["decision": decision.rawValue, "tool": card?.toolName ?? ""]
        if let error { fields["error"] = error }
        DiagnosticsCenter.shared.record("relay", error == nil ? .info : .warn, "remote approval", fields: fields)
        if let error, let requestID, !requestID.isEmpty {
            relayCommandFailures.append(RelayCommandFailure(requestID: requestID, error: error))
            relayCommandFailures.removeFirst(max(0, relayCommandFailures.count - RelayCommandFailure.maxKept))
        }
        return error
    }

    /// Raises `request` as an approval card and waits for its answer, the way
    /// the agent loop does. Internal: tests use it for cards the loop's policy
    /// never raises (a read) and without a model round trip.
    func presentApproval(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        await awaitApproval(request)
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

// MARK: - ExternalImport

extension ChatAppModel {
    /// Reads Claude Code and Cursor on disk (macOS) and reports what can be
    /// imported. iOS returns an empty scan: those files live on the Mac.
    public func scanExternalAgents() async -> ExternalImportScan {
        #if os(macOS)
        let environment = externalImportEnvironment()
        return await Task.detached(priority: .userInitiated) {
            ExternalImportScanner.scan(environment: environment)
        }.value
        #else
        return .empty
        #endif
    }

    /// Imports the selected entries. Re-scans first so the selection always
    /// applies to the current files, and a second run skips what the first
    /// already brought over.
    @discardableResult
    public func runExternalImport(_ selection: ExternalImportSelection) async -> ExternalImportReport {
        #if os(macOS)
        let environment = externalImportEnvironment()
        let (report, outcome) = await Task.detached(priority: .userInitiated) {
            let scan = ExternalImportScanner.scan(environment: environment)
            return ExternalImportExecutor.run(selection: selection, scan: scan, environment: environment)
        }.value
        return await applyExternalImport(outcome, base: report)
        #else
        return ExternalImportReport(lines: [])
        #endif
    }

    /// 暂不: remembers the choice so the first-launch prompt stays away.
    public func dismissExternalImportPrompt() {
        var next = settings
        next.externalImportPromptDismissed = true
        settings = next
        externalImportPrompt = nil
        Task { await saveSettings(next) }
    }

    /// Called once at the end of bootstrap: scans (off the main actor) and,
    /// when something importable exists and the user has not dismissed the
    /// prompt before, raises it.
    public func presentExternalImportPromptIfNeeded() async {
        guard settings.externalImportPromptDismissed == false else { return }
        let scan = await scanExternalAgents()
        externalImportPrompt = scan.isEmpty ? nil : scan
    }

    #if os(macOS)
    private func externalImportEnvironment() -> ExternalImportScanner.Environment {
        let home = externalImportHome ?? skillsHome ?? HostExecutor.realHomeDirectory()
        let skillsRoot = (home as NSString).appendingPathComponent(".agents/skills")
        var skillNames = Set<String>()
        if let names = try? FileManager.default.contentsOfDirectory(atPath: skillsRoot) {
            skillNames = Set(names.filter { !$0.hasPrefix(".") })
        }
        return ExternalImportScanner.Environment(
            home: home,
            skillsRoot: skillsRoot,
            existingSkillNames: skillNames,
            projectNames: Set(projects.map(\.name)),
            importedSessionKeys: Set(conversations.compactMap(\.importedFrom)),
            mcpServers: settings.mcpServers,
            customInstructions: settings.customInstructions,
            installedPluginNames: Set(pluginStore.installed().compactMap { $0.manifest?.name }),
            projectIDByName: Dictionary(projects.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private func applyExternalImport(_ outcome: ExternalImportExecutor.Outcome, base: ExternalImportReport) async -> ExternalImportReport {
        var lines = base.lines
        var next = settings
        for block in outcome.instructionsBlocks where !next.customInstructions.contains(block) {
            next.customInstructions = next.customInstructions.isEmpty
                ? block
                : next.customInstructions + "\n\n" + block
        }
        for server in outcome.mcpServers {
            var stored = server
            for (variable, value) in server.env where !value.isEmpty {
                guard setMCPSecret(value, serverID: server.id, variable: variable) else {
                    lines.append(ExternalImportReport.Line(
                        id: "mcp-secret-\(server.id)-\(variable)", provider: .claudeCode, kind: .mcpServers,
                        title: server.name, note: "无法把「\(variable)」写入钥匙串，该服务器没有导入", failed: true
                    ))
                    stored = MCPServerConfig(id: "", name: "")
                    break
                }
                stored.env[variable] = ""
            }
            guard !stored.id.isEmpty else { continue }
            next.mcpServers.append(stored)
        }
        if next != settings { await saveSettings(next) }

        for project in outcome.newProjects {
            projects.append(project)
        }
        if !outcome.newProjects.isEmpty { persistProjects() }
        for conversation in outcome.conversations {
            conversations.append(conversation)
            persist(conversation)
        }
        if selectedConversationID == nil { selectedConversationID = outcome.conversations.first?.id }

        for plugin in outcome.pluginFolders {
            do {
                let plan = try preparePluginInstall(folder: plugin.folder)
                try confirmPluginInstall(plan)
                lines.append(ExternalImportReport.Line(
                    id: plugin.id, provider: .claudeCode, kind: .plugins,
                    title: plugin.name, note: nil, failed: false
                ))
            } catch {
                lines.append(ExternalImportReport.Line(
                    id: plugin.id, provider: .claudeCode, kind: .plugins,
                    title: plugin.name, note: "安装插件失败：\(error.localizedDescription)", failed: true
                ))
            }
        }
        if !outcome.pluginFolders.isEmpty { reloadPlugins() }
        return ExternalImportReport(lines: lines)
    }
    #endif

    // MARK: - Local environments

    /// Every environment file for `root`'s repository: the working
    /// directory's own first, then inherited ones, each labelled.
    public func localEnvironments(forProject root: String) -> [LocalEnvironmentFile] {
        let key = LocalEnvironmentDiscovery.standardize(root)
        if let cached = localEnvironmentCache[key],
           Date().timeIntervalSince(cached.at) < Self.localEnvironmentCacheLifetime {
            return cached.files
        }
        let files = LocalEnvironmentDiscovery.files(inWorkingDirectory: root)
        for file in files {
            localEnvironmentRevisions[LocalEnvironmentDiscovery.standardize(file.path)] =
                LocalEnvironmentDiscovery.revision(ofFileAt: file.path)
        }
        localEnvironmentCache[key] = (files, Date())
        return files
    }

    /// Drops the discovery cache, for tests and after external changes.
    func invalidateLocalEnvironmentCache() {
        localEnvironmentCache.removeAll()
    }

    /// Which environment file is in force for `root`: the user's choice while
    /// it still exists, else the only discovered file, else nil.
    public func selectedLocalEnvironmentPath(forProject root: String) -> String? {
        LocalEnvironmentDiscovery.selectedPath(
            projectRoot: root,
            files: localEnvironments(forProject: root),
            selections: settings.localEnvironmentSelections
        )
    }

    /// Records the user's environment choice for `root`; nil clears it.
    public func selectLocalEnvironment(_ path: String?, forProject root: String) {
        let key = LocalEnvironmentDiscovery.standardize(root)
        var selections = settings.localEnvironmentSelections
        if let path {
            selections[key] = LocalEnvironmentDiscovery.standardize(path)
        } else {
            selections.removeValue(forKey: key)
        }
        // First in memory, so the next read sees the choice; then persisted.
        var updated = settings
        updated.localEnvironmentSelections = selections
        settings = updated
        Task { await saveSettings(updated) }
    }

    /// Validates and writes an environment file into
    /// `<root>/.codex/environments/<fileName>`, refusing when the file on
    /// disk changed since it was last listed. The saved file becomes the
    /// project's selection, as the official flow does. nil on success.
    @discardableResult
    public func saveLocalEnvironment(_ environment: LocalEnvironment, toProject root: String, fileName: String) -> String? {
        let problems = environment.validationErrors()
        guard problems.isEmpty else { return problems.joined(separator: "；") }
        let destination = LocalEnvironmentDiscovery.standardize(root)
            + "/.codex/environments/" + LocalEnvironmentDiscovery.sanitizedFileName(fileName)
        let expected = localEnvironmentRevisions[LocalEnvironmentDiscovery.standardize(destination)]
        let failure = LocalEnvironmentDiscovery.save(
            environment, toProject: root, fileName: fileName, expectedRevision: expected
        )
        guard failure == nil else { return failure }
        localEnvironmentRevisions[LocalEnvironmentDiscovery.standardize(destination)] =
            LocalEnvironmentDiscovery.revision(ofFileAt: destination)
        localEnvironmentCache.removeValue(forKey: LocalEnvironmentDiscovery.standardize(root))
        selectLocalEnvironment(destination, forProject: root)
        return nil
    }

    /// Deletes the environment file at `path`. Selections pointing at it fall
    /// back automatically. nil on success.
    @discardableResult
    public func deleteLocalEnvironment(at path: String) -> String? {
        let failure = LocalEnvironmentDiscovery.delete(at: path)
        guard failure == nil else { return failure }
        localEnvironmentRevisions.removeValue(forKey: LocalEnvironmentDiscovery.standardize(path))
        localEnvironmentCache.removeAll()
        return nil
    }

    /// The distinct repository roots the app knows: every conversation's
    /// working directory, resolved to its repository root.
    public func knownProjectRoots() -> [String] {
        var roots: [String] = []
        for conversation in conversations {
            guard let directory = conversation.workingDirectory,
                  let root = LocalEnvironmentDiscovery.repositoryRoot(containing: directory) else { continue }
            let standardized = LocalEnvironmentDiscovery.standardize(root)
            if !roots.contains(standardized) { roots.append(standardized) }
        }
        return roots
    }

    /// Runs an environment's setup or cleanup script at `worktreeRoot` and
    /// records one diagnostics event per run. See
    /// `LocalEnvironmentDiscovery.runLocalEnvironmentScript` for the rules.
    public func runLocalEnvironmentScript(
        _ phase: LocalEnvironmentPhase, configPath: String, sourceRoot: String, worktreeRoot: String
    ) async -> LocalEnvironmentRunResult {
        #if os(macOS)
        let result = await LocalEnvironmentDiscovery.runLocalEnvironmentScript(
            phase, configPath: configPath, sourceRoot: sourceRoot, worktreeRoot: worktreeRoot
        )
        DiagnosticsCenter.shared.record(
            "environment", result.exitCode == 0 ? .info : .warn,
            "\(phase == .setup ? "setup" : "cleanup") \(result.skipped ? "skipped" : "exit \(result.exitCode)")",
            fields: ["config": configPath, "worktree": worktreeRoot]
        )
        return result
        #else
        _ = phase; _ = configPath; _ = sourceRoot; _ = worktreeRoot
        return LocalEnvironmentRunResult(exitCode: 0, output: "本地环境只能在 Mac 上运行", skipped: true)
        #endif
    }

    #if os(macOS)
    /// Runs the header's environment action `index` for the thread: opens the
    /// side panel on the terminal and sends the command through the
    /// terminal's own run path. Returns the reason it could not, or nil.
    public func runEnvironmentAction(index: Int, in conversationID: UUID) -> String? {
        guard let conversation = conversation(conversationID) else { return "找不到这个对话" }
        guard let directory = conversation.workingDirectory else { return "这个对话没有绑定工作目录" }
        let files = localEnvironments(forProject: directory)
        guard let chosen = selectedLocalEnvironmentPath(forProject: directory),
              let file = files.first(where: {
                  LocalEnvironmentDiscovery.standardize($0.path) == LocalEnvironmentDiscovery.standardize(chosen)
              }),
              let environment = file.environment else {
            return "这个项目还没有选择环境"
        }
        let actions = environment.actions(for: .current)
        guard actions.indices.contains(index) else { return "没有这个环境动作" }
        let action = actions[index]
        DiagnosticsCenter.shared.record(
            "environment", .info, "action run",
            fields: ["name": action.name, "command": action.command, "directory": directory]
        )
        runCommandInSidePanel(action.command, directory: directory)
        return nil
    }
    #endif

    /// A command the side panel's terminal should run right now. `id` makes
    /// asking for the same command twice a new request.
    public struct SidePanelTerminalRequest: Equatable, Sendable {
        public let id: UUID
        public let command: String
        /// Where the command runs; the terminal keeps its own directory when
        /// nil.
        public let directory: String?

        public init(id: UUID, command: String, directory: String?) {
            self.id = id
            self.command = command
            self.directory = directory
        }
    }

    /// Opens the side panel on the terminal and runs `command` there.
    public func runCommandInSidePanel(_ command: String, directory: String?) {
        sidePanelTerminalRequest = SidePanelTerminalRequest(id: UUID(), command: command, directory: directory)
        toggleSidePanel(open: true, tab: .terminal)
    }

    /// The terminal took request `id`; a later request is left in place.
    public func finishSidePanelTerminalRequest(_ id: UUID) {
        if sidePanelTerminalRequest?.id == id { sidePanelTerminalRequest = nil }
    }
}
