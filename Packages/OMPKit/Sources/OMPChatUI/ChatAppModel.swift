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
    public private(set) var projects: [Project] = []
    public private(set) var isStreaming = false
    public private(set) var streamingConversationID: UUID?
    public private(set) var errorMessage: String?
    public private(set) var statusMessage: String?
    public private(set) var refreshingProviderIDs: Set<UUID> = []
    public private(set) var bootstrapped = false

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
        guard !bootstrapped else { return }
        bootstrapped = true
        conversations = (try? await store.loadAll()) ?? []
        providers = (try? await store.loadProviders()) ?? []
        models = (try? await store.loadModelCatalog()) ?? []
        settings = (try? await store.loadSettings()) ?? AppSettings()
        projects = (try? await store.loadProjects()) ?? []
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

    public func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        Task { try? await store.delete(id: id) }
        draftsByConversation.removeValue(forKey: id)
        attachmentsByConversation.removeValue(forKey: id)
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
        Task { try? await store.saveProjects(snapshot) }
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
    /// conversation's current tail of messages.
    private func startReply(conversationID: UUID) async {
        guard var conversation = conversation(conversationID) else { return }
        guard let provider = resolveProvider(for: conversation), let model = resolveModel(for: conversation, provider: provider) else {
            errorMessage = "先在设置中添加供应商并选择模型"
            return
        }
        let storedKey = (try? secrets.secret(for: provider.keychainAccount)) ?? nil
        guard let apiKey = storedKey, !apiKey.isEmpty else {
            errorMessage = "「\(provider.name)」缺少 API Key"
            showSettings = true
            return
        }

        conversation.providerID = provider.id
        conversation.modelID = model.id
        let assistant = ChatMessage(role: .assistant, parts: [], status: .streaming)
        conversation.messages.append(assistant)
        conversation.updatedAt = Date()
        replace(conversation)
        persist(conversation)

        let history = conversation.messages.dropLast()
        var request = GenerationRequest(
            modelID: model.id,
            messages: Array(history),
            systemPrompt: systemPrompt(for: conversation),
            temperature: settings.temperature,
            maxOutputTokens: settings.maxOutputTokens ?? model.limits.maxOutputTokens
        )
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

        isStreaming = true
        streamingConversationID = conversation.id
        errorMessage = nil
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.runStream(adapter: adapter, request: request, conversationID: conversation.id, assistantID: assistant.id)
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
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

    private func runStream(
        adapter: any ChatProvider,
        request: GenerationRequest,
        conversationID: UUID,
        assistantID: UUID
    ) async {
        var failure: Error?
        var finishReason: FinishReason = .stop
        do {
            for try await event in adapter.stream(request) {
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
        if failure == nil && !cancelled {
            AudioFeedback.playComplete(enabled: settings.soundEffects)
        }
        isStreaming = false
        streamingConversationID = nil
        streamTask = nil
        if let failure, !cancelled { errorMessage = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription }
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
        settings = newValue
        try? await store.saveSettings(newValue)
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

    private func systemPrompt(for conversation: Conversation) -> String? {
        let prompt = (conversation.systemPrompt ?? "").isEmpty ? settings.systemPrompt : (conversation.systemPrompt ?? "")
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        Task { try? await store.save(conversation) }
    }

    public func dismissError() { errorMessage = nil }
    public func dismissStatus() { statusMessage = nil }
}

/// A long clipboard paste kept as a chip instead of inline draft text.
public struct PastedTextAttachment: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var text: String
    public var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }
}
