import SwiftUI
import UniformTypeIdentifiers
import OMPCore
import OMPDesign

public struct ComposerBar: View {
    @Environment(ChatAppModel.self) private var model
    @State private var importingFiles = false
    @State private var showImageSheet = false
    @State private var showOptionsSheet = false
    @State private var showGoalPopover = false
    @State private var goalDraft = ""
    @State private var showMCPSheet = false
    @State private var showModelPicker = false
    @State private var promptHistoryIndex = 0
    @State private var originalDraft = ""
    @State private var originalMentions: [ComposerMention] = []
    @FocusState private var focused: Bool
    @State private var inputHeight: CGFloat = 22
    public init() {}

    private static let templates: [(title: String, alias: String, icon: String, prompt: String)] = [
        ("代码审查", "review", "sparkle.magnifyingglass", "请全面审查以下代码，指出潜在 bug、边界条件、性能瓶颈与六个月可维护性风险：\n\n```\n\n```"),
        ("错误修复", "fix", "wrench.and.screwdriver", "这段代码在运行时报错，请分析根本原因并给出最小改动的修复方案：\n\n```\n\n```"),
        ("单元测试", "test", "checklist", "请为以下模块编写严谨的单元测试，覆盖正常路径、边界值与错误分支：\n\n```\n\n```"),
        ("架构设计", "arch", "square.3.layers.3d", "我需要设计一个系统模块，请给出：1) 职责边界 2) 接口契约 3) 数据流 4) 关键风险与权衡。"),
        ("性能优化", "opt", "bolt.fill", "请分析以下代码的计算与内存热点，给出减少非必要分配和避免重复计算的优化建议：\n\n```\n\n```"),
        ("要点总结", "summary", "doc.plaintext", "用清晰条理的要点总结以下内容，突出核心结论与行动建议：\n\n"),
        ("翻译润色", "translate", "character.book.closed", "把下面的内容翻译或润色为地道专业的技术英文：\n\n"),
    ]

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if showTemplates {
                templateList
            }
            contextStrip
            if let query = visibleMentionQuery {
                mentionList(query)
            }
            QueuedMessagesStrip()
            composerCard
        }
        .padding(.horizontal, Theme.Layout.transcriptPadding)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: Theme.Layout.transcriptMax + Theme.Layout.transcriptPadding * 2)
        .frame(maxWidth: .infinity)
        .task(id: mentionSearchKey) { await runMentionSearch() }
        .fileImporter(
            isPresented: $importingFiles,
            allowedContentTypes: [.image, .movie, .audio, .pdf, .plainText, .data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    try model.attach(url: url, removeSandboxScope: scoped)
                } catch {
                    model.dismissError()
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { try? model.attach(url: url) }
            return !urls.isEmpty
        }
        .onReceive(NotificationCenter.default.publisher(for: .ompNewChat)) { _ in
            focused = true
        }
        .onChange(of: model.selectedConversationID) { _, _ in
            promptHistoryIndex = 0
            originalDraft = ""
            focused = true
        }
        .onAppear {
            focused = true
        }
        .onChange(of: model.draft) { _, newValue in
            foldLongPaste(newValue)
            if model.activeMentionQuery?.triggerOffset != dismissedMentionOffset {
                dismissedMentionOffset = nil
            }
        }
        .sheet(isPresented: $showImageSheet) {
            ImageGenerationSheet()
                .environment(model)
        }
        .sheet(isPresented: $showOptionsSheet) {
            ConversationOptionsSheet().environment(model)
        }
        .sheet(isPresented: $showMCPSheet) {
            MCPPluginsSheet()
        }
    }

    // MARK: Official ComposerLayoutRoot

    /// Outer card: ompCard fill, 10pt radius, 1pt ompBorder hairline.
    /// Codex composer = flat bordered card, no shadow, no top menu panel.
    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            composerBody
            if model.showsDictationBar {
                dictationBar
            } else {
                composerFooter
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.officialLG, style: .continuous)
                .fill(Color.ompCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.officialLG, style: .continuous)
                .strokeBorder(Color.ompBorder, lineWidth: 1)
        )
        .padding(.top, 4)
    }


    /// `ComposerLayoutBody`: RichTextInput + attachment chips.
    private var composerBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quoted = model.replyingTo {
                replyPreview(quoted)
            }
            if !model.draftAttachments.isEmpty {
                attachmentStrip
            }
            if !model.pastedTexts.isEmpty {
                pastedTextStrip
            }
            mentionChipStrip
            composerInput
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Image(systemName: "return")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompTextTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    /// RichTextInput: official 16pt with 1.5 leading.
    private var composerInput: some View {
        @Bindable var model = model
        return TextField("随心输入", text: $model.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .lineSpacing(8)
            .lineLimit(1...10)
            .focused($focused)
            .focusEffectDisabled()
            .padding(.top, 2)
            .onKeyPress(phases: .down) { press in
                handleMentionKey(press)
            }
            .onKeyPress(phases: .down) { press in
                guard press.key == .return, !press.modifiers.contains(.shift) else { return .ignored }
                guard !mentionListTakesKeys else { return .ignored }
                guard model.settings.sendOnReturn else { return .ignored }
                model.send()
                return .handled
            }
            .onKeyPress(phases: .down) { press in
                handleHistoryKey(press)
            }
    }

    /// `ComposerLayoutFooter`: + / 🌐 / model / ⚙ left, spinner while streaming.
    private var composerFooter: some View {
        HStack(spacing: 4) {
            Menu {
                Button { importingFiles = true } label: {
                    Label("添加图片或文件", systemImage: "paperclip")
                }
                if !model.imageModels.isEmpty {
                    Button { showImageSheet = true } label: {
                        Label("生成图片", systemImage: "photo.badge.plus")
                    }
                }
                Menu("提示词模板") {
                    ForEach(Self.templates, id: \.alias) { item in
                        Button(item.title) { model.draft = item.prompt }
                    }
                }
                Menu("自定义指令") {
                    Button { showOptionsSheet = true } label: {
                        Label("对话设置", systemImage: "slider.horizontal.3")
                    }
                    Button { showMCPSheet = true } label: {
                        Label("本对话的工具", systemImage: "hammer")
                    }
                }
                Button {
                    beginGoalEdit()
                } label: {
                    Label("设定目标", systemImage: "target")
                }
                .accessibilityIdentifier("composer.goal.set")
                Button {
                    compactSelected(clearingDraft: false)
                } label: {
                    Label("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(model.selectedConversationID == nil)
                .accessibilityIdentifier("composer.compact")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 28, height: 28)
                    .background(hoverPlus ? ompGhostHover : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .onHover { hoverPlus = $0 }
            .help("添加素材与工具")

            webSearchPill
            formatPills
            blockFormatMenu
            modelPill
            if let conversationID = model.selectedConversationID {
                AgentModeMenu(conversationID: conversationID)
            }

            Button {
                showOptionsSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 28, height: 28)
                    .background(hoverOptions ? ompGhostHover : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoverOptions = $0 }
            .help("自定义指令与推理强度")

            Spacer(minLength: 0)
            dictationButton

            if model.isStreaming {
                // Official stop control: the send slot turns into a solid
                // circle with a square, so "stop" is visible, not a spinner.
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.ompInverseText)
                        .frame(width: 28, height: 28)
                        .background(Color.ompPrimarySolid, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(visibleMentionQuery == nil ? .cancelAction : nil)
                .help("停止生成（Esc）")
                .accessibilityLabel("停止生成")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
    }

    /// Formats the current selection (or inserts empty markers at the caret).
    /// `style` is "b" / "i" / "u" so the menu and the pills share one path.
    /// `b` / `i` / `u`, shared by the pills and the 格式 menu.
    static func style(for key: String) -> MarkdownFormatting.Style? {
        switch key.lowercased() {
        case "b": return .bold
        case "i": return .italic
        case "u": return .underline
        default: return nil
        }
    }

    func applyFormat(_ key: String) {
        guard let style = Self.style(for: key) else { return }
        model.applyMarkdown(style)
    }

    /// Bold / italic / underline as source-markup buttons, the clickable form
    /// of ⌘B / ⌘I / ⌘U (official composer.formatToolbar).
    private var formatPills: some View {
        HStack(spacing: 2) {
            ForEach([("B", "b", "加粗 ⌘B"), ("I", "i", "斜体 ⌘I"), ("U", "u", "下划线 ⌘U")], id: \.1) { item in
                Button {
                    applyFormat(item.1)
                } label: {
                    Text(item.0)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.draft.isEmpty)
                .help(item.2)
            }
        }
    }

    /// Block styles for the draft's last paragraph (official
    /// composer.formatToolbar beyond B/I/U).
    private var blockFormatMenu: some View {
        Menu {
            Button("标题 1") { model.applyBlockFormat(.heading(1)) }
            Button("标题 2") { model.applyBlockFormat(.heading(2)) }
            Button("标题 3") { model.applyBlockFormat(.heading(3)) }
            Button("段落") { model.applyBlockFormat(.paragraph) }
            Divider()
            Button("无序列表") { model.applyBlockFormat(.bulletedList) }
            Button("有序列表") { model.applyBlockFormat(.numberedList) }
            Button("链接") { model.applyBlockFormat(.link) }
        } label: {
            Text("Aa")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ompTextSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("composer.format.blocks")
        .accessibilityLabel("段落格式")
        .help("段落格式")
    }

    /// Opens the goal editor seeded with the current goal.
    private func beginGoalEdit() {
        goalDraft = model.selectedConversation?.goal ?? ""
        showGoalPopover = true
    }

    /// 「目标：…」 chip, shown only while this thread has a goal.
    @ViewBuilder
    private var goalChip: some View {
        if let goal = model.selectedConversation?.goal, !goal.isEmpty {
            Button {
                beginGoalEdit()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "target")
                        .font(.system(size: 9))
                    Text("目标：\(goal)")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.goal.chip")
            .accessibilityLabel("目标：\(goal)")
            .help(goal)
        }
    }

    /// Edits or clears the thread goal.
    private var goalPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本对话的目标")
                .font(.system(size: 12, weight: .semibold))
            TextField("这个对话要达成什么", text: $goalDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("composer.goal.field")
            HStack {
                Button("清除") {
                    if let id = model.selectedConversationID { model.setGoal(id, nil) }
                    showGoalPopover = false
                }
                .accessibilityIdentifier("composer.goal.clear")
                Spacer()
                Button("完成") {
                    if let id = model.selectedConversationID { model.setGoal(id, goalDraft) }
                    showGoalPopover = false
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("composer.goal.save")
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    /// 🌐 联网 toggle pill (real `webSearchEnabled` state).
    private var webSearchPill: some View {
        Button {
            model.webSearchEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                Text("联网")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(model.webSearchEnabled ? Color.ompInverseText : Color.ompTextSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(model.webSearchEnabled ? Color.ompPrimarySolid : Color.ompFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("启用联网搜索参考")
    }

    @State private var hoverPlus = false
    @State private var hoverOptions = false

    /// Context line: 11pt tertiary bare text (no strip background).
    private var contextStrip: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                // One line, truncated: a worktree name such as 新对话-7857391d
                // wrapped onto two lines once a goal chip shared the row. No
                // layout priorities in this row — any one item given priority
                // squeezed the others down to a single character, so the
                // folder, branch and goal share the width and truncate evenly.
                Text(projectName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(model.selectedConversation?.workingDirectory.map(GitInfo.tildified) ?? projectName)
            .accessibilityIdentifier("composer.workspace")
            HStack(spacing: 4) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 10))
                Text("本地")
                    .font(.system(size: 11))
            }
            .fixedSize()
            if let branch = currentBranch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            goalChip
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.ompTextTertiary)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .popover(isPresented: $showGoalPopover, arrowEdge: .top) {
            goalPopover
        }
    }

    // MARK: - Mentions

    /// The list's last search: files, then chats, then tabs (skills for
    /// `$`); `mentionHighlight` indexes it.
    @State private var mentionResults: [MentionCandidate] = []
    @State private var mentionSearchFailed = false
    @State private var mentionSearching = false
    @State private var mentionHighlight = 0
    /// Thread and trigger of the list that is open; a new one refreshes the
    /// index.
    @State private var openedMention: String?
    /// The trigger whose list Escape closed; it stays closed while that
    /// query is typed on.
    @State private var dismissedMentionOffset: Int?

    private static let mentionRowHeight: CGFloat = 30
    private static let mentionHeaderHeight: CGFloat = 22
    private static let mentionListMaxHeight: CGFloat = 300

    /// The `@` / `$` query being typed (official `composer.atMentionList`,
    /// `composer.skillMentionList`), unless Escape closed its list.
    private var visibleMentionQuery: ComposerMention.ActiveQuery? {
        guard model.selectedConversationID != nil, let query = model.activeMentionQuery,
              query.triggerOffset != dismissedMentionOffset else { return nil }
        return query
    }

    private var mentionSearchKey: String {
        guard let query = visibleMentionQuery, let id = model.selectedConversationID else { return "" }
        return "\(id.uuidString)|\(query.trigger)|\(query.triggerOffset)|\(query.query)"
    }

    /// The list is open with rows to pick: ↑/↓/Return are its keys.
    private var mentionListTakesKeys: Bool {
        visibleMentionQuery != nil && !mentionResults.isEmpty
    }

    private func runMentionSearch() async {
        guard let query = visibleMentionQuery, let id = model.selectedConversationID else {
            openedMention = nil
            mentionResults = []
            mentionSearchFailed = false
            mentionSearching = false
            return
        }
        let opening = "\(id.uuidString)|\(query.trigger)|\(query.triggerOffset)"
        if openedMention != opening {
            // A list that just opened lists the folder (or the skills) afresh.
            openedMention = opening
            mentionHighlight = 0
            mentionResults = []
            mentionSearchFailed = false
            mentionSearching = true
            await model.refreshMentionIndex(for: id, trigger: query.trigger)
        } else {
            // Typing on: let the burst settle before searching.
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !Task.isCancelled else { return }
        mentionSearching = true
        let result = await model.mentionSearch(query: query.query, trigger: query.trigger, for: id)
        guard !Task.isCancelled else { return }
        mentionResults = result.candidates
        mentionSearchFailed = result.fileSearchFailed
        mentionSearching = false
        mentionHighlight = result.candidates.isEmpty ? 0 : min(mentionHighlight, result.candidates.count - 1)
    }

    /// ↑/↓ move, Return or Tab picks, Escape closes the list.
    private func handleMentionKey(_ press: KeyPress) -> KeyPress.Result {
        guard let query = visibleMentionQuery else { return .ignored }
        if press.key == .escape {
            dismissedMentionOffset = query.triggerOffset
            return .handled
        }
        guard !mentionResults.isEmpty else { return .ignored }
        switch press.key {
        case .downArrow:
            mentionHighlight = (mentionHighlight + 1) % mentionResults.count
        case .upArrow:
            mentionHighlight = (mentionHighlight + mentionResults.count - 1) % mentionResults.count
        case .return, .tab:
            guard !press.modifiers.contains(.shift) else { return .ignored }
            pickMention(mentionResults[min(mentionHighlight, mentionResults.count - 1)])
        default:
            return .ignored
        }
        return .handled
    }

    private func pickMention(_ candidate: MentionCandidate) {
        model.pickMention(candidate.mention)
        mentionHighlight = 0
        focused = true
    }

    private enum MentionListEntry: Hashable {
        case header(String)
        case status(String)
        case row(Int)
    }

    /// What the list shows, top to bottom, with the official headers:
    /// 文件和对话 / 文件 / 对话, 标签页; 技能 for `$`.
    private func mentionEntries(_ query: ComposerMention.ActiveQuery) -> [MentionListEntry] {
        let indices = Array(mentionResults.indices)
        if query.trigger == "$" {
            guard !indices.isEmpty else { return [.header("技能"), .status(mentionSearching ? "正在加载技能…" : "没有找到技能")] }
            return [.header("技能")] + indices.map(MentionListEntry.row)
        }
        var entries: [MentionListEntry] = []
        if query.query.trimmingCharacters(in: .whitespaces).isEmpty {
            entries.append(.status("输入以搜索文件或对话"))
        }
        let files = indices.filter { mentionResults[$0].section == .files }
        let chats = indices.filter { mentionResults[$0].section == .chats }
        let tabs = indices.filter { mentionResults[$0].section == .tabs }
        if mentionSearchFailed {
            entries += [.header("文件"), .status("无法搜索文件")]
            if !chats.isEmpty { entries.append(.header("对话")) }
            entries += chats.map(MentionListEntry.row)
        } else if !files.isEmpty || !chats.isEmpty {
            entries.append(.header(files.isEmpty ? "对话" : chats.isEmpty ? "文件" : "文件和对话"))
            entries += (files + chats).map(MentionListEntry.row)
        }
        if !tabs.isEmpty {
            entries.append(.header("标签页"))
            entries += tabs.map(MentionListEntry.row)
        }
        if entries.isEmpty {
            entries.append(.status(mentionSearching ? "正在搜索文件…" : "没有结果"))
        }
        return entries
    }

    private func mentionList(_ query: ComposerMention.ActiveQuery) -> some View {
        let entries = mentionEntries(query)
        let height = entries.reduce(CGFloat(8)) { total, entry in
            if case .header = entry { return total + Self.mentionHeaderHeight }
            return total + Self.mentionRowHeight
        }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries, id: \.self) { entry in
                        switch entry {
                        case .header(let title):
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.ompTextTertiary)
                                .padding(.horizontal, 10)
                                .frame(height: Self.mentionHeaderHeight, alignment: .bottomLeading)
                        case .status(let text):
                            Text(text)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ompTextTertiary)
                                .padding(.horizontal, 10)
                                .frame(height: Self.mentionRowHeight)
                                .accessibilityIdentifier("composer.mention.status")
                        case .row(let index):
                            mentionRow(mentionResults[index], index: index)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .frame(height: min(height, Self.mentionListMaxHeight))
            .onChange(of: mentionHighlight) { _, index in
                proxy.scrollTo(MentionListEntry.row(index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ompCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.ompBorder.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
        .padding(.horizontal, Theme.Layout.transcriptPadding)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.mention.list")
    }

    private func mentionRow(_ item: MentionCandidate, index: Int) -> some View {
        Button {
            pickMention(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 16)
                Text(item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if item.section == .skills {
                    Text(item.badge)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.ompTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.mentionRowHeight)
            .background(index == mentionHighlight ? Color.ompFill : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { mentionHighlight = index } }
        .accessibilityIdentifier("composer.mention.item.\(index)")
        .accessibilityLabel(item.section == .tabs ? "\(item.title) \(item.detail)" : item.title)
    }

    /// The draft's mentions as chips — the field itself holds the tokens —
    /// each with × to take it out of the draft.
    @ViewBuilder
    private var mentionChipStrip: some View {
        let mentions = model.draftMentions
        if !mentions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(mentions.enumerated()), id: \.element) { index, mention in
                        HStack(spacing: 5) {
                            Image(systemName: Self.mentionIcon(mention.kind))
                                .font(.system(size: 10))
                            Text(mention.readable)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Button {
                                model.removeMention(mention)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("composer.mention.chip.\(index).remove")
                            .accessibilityLabel("移除 \(mention.readable)")
                        }
                        .foregroundStyle(Color.ompTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.ompFill, in: Capsule())
                        .help(Self.mentionHelp(mention))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("composer.mention.chip.\(index)")
                    }
                }
            }
        }
    }

    private static func mentionIcon(_ kind: MentionKind) -> String {
        switch kind {
        case .file: "doc.text"
        case .chat: "bubble.left"
        case .tab: "globe"
        case .skill: "sparkles"
        }
    }

    private static func mentionHelp(_ mention: ComposerMention) -> String {
        switch mention.kind {
        case .file: "文件 \(mention.target)"
        case .chat: "对话「\(mention.label)」"
        case .tab: "标签页「\(mention.label)」"
        case .skill: "技能 \(mention.target)"
        }
    }

    private var pastedTextStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.pastedTexts) { paste in
                    HStack(spacing: 5) {
                        Image(systemName: "doc.plaintext")
                            .font(.system(size: 10))
                        Text("粘贴的文本 · \(paste.lineCount) 行")
                            .font(.system(size: 11, weight: .medium))
                        Button {
                            model.removePastedText(paste.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Color.ompTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.ompFill, in: Capsule())
                    .help(String(paste.text.prefix(200)))
                }
            }
        }
    }


    private var projectName: String {
        let conversation = model.selectedConversation
        let project = conversation?.projectID.flatMap { id in model.projects.first { $0.id == id }?.name }
        return ThreadWorkspace.name(workingDirectory: conversation?.workingDirectory, projectName: project)
    }

    /// The bound folder's branch; the app's own directory only for unbound
    /// threads.
    private var currentBranch: String? {
        let directory = model.selectedConversation?.workingDirectory ?? FileManager.default.currentDirectoryPath
        return GitInfo.branch(at: URL(fileURLWithPath: directory))
    }

    /// ↑/↓ walk the prompt history, newest first.
    private func handleHistoryKey(_ press: KeyPress) -> KeyPress.Result {
        guard !mentionListTakesKeys else { return .ignored }
        // What the user wrote, with its mentions picked again, so a recalled
        // prompt reads its files afresh when sent.
        let prompts = model.selectedConversation?.messages.filter { $0.role == .user } ?? []
        func recall(_ message: ChatMessage) {
            model.setDraft(message.writtenText, mentions: message.mentionAttachments.compactMap(\.mention))
        }
        switch press.key {
        case .upArrow where model.draft.isEmpty || promptHistoryIndex > 0:
            guard !prompts.isEmpty, promptHistoryIndex < prompts.count else { return .ignored }
            if promptHistoryIndex == 0 {
                originalDraft = model.draft
                originalMentions = model.pickedMentions
            }
            promptHistoryIndex += 1
            recall(prompts[prompts.count - promptHistoryIndex])
            return .handled
        case .downArrow where promptHistoryIndex > 0:
            promptHistoryIndex -= 1
            if promptHistoryIndex == 0 {
                model.setDraft(originalDraft, mentions: originalMentions)
            } else {
                recall(prompts[prompts.count - promptHistoryIndex])
            }
            return .handled
        default:
            return .ignored
        }
    }

    /// Folds a single oversized paste into a chip (ChatGPT pastedTextAttachment).
    private func foldLongPaste(_ value: String) {
        guard value.count > 1500, value.contains("\n") else { return }
        model.draft = ""
        model.addPastedText(value)
    }

    private var contextChips: some View {
        HStack(spacing: 6) {
            if let provider = model.activeProvider {
                chip("folder", provider.name)
            }
            if let modelID = model.activeModel?.id {
                chip("cpu", modelID)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: Theme.Layout.transcriptMax)
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color.ompTextSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.ompFill, in: Capsule())
    }

    private func replyPreview(_ quoted: ChatMessage) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(width: 2, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(quoted.role == .user ? "引用你的消息" : "引用助手")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(quoted.writtenText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.replyingTo = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftAttachments.isEmpty
    }

    private var showTemplates: Bool {
        model.draft.hasPrefix("/") && !model.draft.contains("\n")
    }

    private var filteredTemplates: [(title: String, alias: String, icon: String, prompt: String)] {
        let query = String(model.draft.dropFirst()).lowercased()
        guard !query.isEmpty else { return Self.templates }
        return Self.templates.filter {
            $0.title.lowercased().contains(query) || $0.alias.lowercased().contains(query)
        }
    }

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("快捷指令 (Slash Commands)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ompTextTertiary)
                Spacer()
                Text("ESC 关闭")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ompTextTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Divider().opacity(0.4)

            if showsCompactCommand {
                Button {
                    compactSelected(clearingDraft: true)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        Text(ChatAppModel.compactCommand)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.ompText)
                        Text("压缩上下文")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompTextSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.ompFill.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.slash.compact")
            }
            ForEach(filteredTemplates, id: \.alias) { item in
                Button {
                    model.draft = item.prompt
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        Text("/\(item.alias)")
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.ompText)
                        Text(item.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompTextSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.ompFill.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: Theme.Layout.transcriptMax)
        .ompSurface(radius: Theme.Radius.m)
        .padding(.horizontal, Theme.Layout.transcriptPadding)
    }

    // MARK: - Dictation

    /// 听写, beside the send slot.
    private var dictationButton: some View {
        DictationButton(size: 28, iconSize: 13)
    }

    /// While dictating, the footer row gives way to the dictation bar.
    private var dictationBar: some View {
        DictationBar(rowHeight: 32)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.bottom, 4)
    }

    // MARK: - Compaction

    /// The palette's `/compact` row matches its name or 压缩上下文.
    private var showsCompactCommand: Bool {
        let query = String(model.draft.dropFirst()).lowercased()
        return query.isEmpty || "compact".contains(query) || "压缩上下文".contains(query)
    }

    /// 压缩上下文 from the + menu or the slash palette (which also clears the
    /// typed `/…`). Failures show as the model's error banner.
    private func compactSelected(clearingDraft: Bool) {
        guard let id = model.selectedConversationID else { return }
        if clearingDraft { model.draft = "" }
        Task { _ = await model.compactConversation(id) }
    }

    private var modelPill: some View {
        Group {
            if model.availableModels.count > 12 {
                Button {
                    showModelPicker = true
                } label: {
                    modelPillLabel
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    if model.availableModels.isEmpty {
                        Text("先在设置中同步模型")
                    } else {
                        ForEach(model.availableModels) { descriptor in
                            Button {
                                model.setModel(descriptor)
                            } label: {
                                let tag = [
                                    descriptor.capabilities.thinking ? "🧠 思考" : nil,
                                    descriptor.capabilities.vision ? "👁 视觉" : nil,
                                    descriptor.limits.contextWindow.map { TokenFormat.compact($0) }
                                ].compactMap { $0 }.joined(separator: " · ")
                                let suffix = tag.isEmpty ? "" : " (\(tag))"
                                if descriptor.id == model.activeModel?.id {
                                    Label(descriptor.displayName + suffix, systemImage: "checkmark")
                                } else {
                                    Text(descriptor.displayName + suffix)
                                }
                            }
                        }
                    }
                } label: {
                    modelPillLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .fixedSize()
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet()
                .environment(model)
        }
    }

    private var modelPillLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: model.activeModel?.capabilities.thinking == true ? "sparkles" : "cpu")
                .font(.system(size: 9.5))
                .foregroundStyle(model.activeModel?.capabilities.thinking == true ? Color.purple : Color.ompTextSecondary)
            Text(model.activeModel?.displayName ?? "选择模型")
                .font(Theme.Typography.pill)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(Color.ompTextSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.ompFill, in: Capsule())
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.draftAttachments) { ref in
                    ZStack(alignment: .topTrailing) {
                        if ref.kind == .image, let image = PlatformImage.load(at: model.mediaLibrary.url(for: ref)) {
                            Image(platformImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            VStack(spacing: 2) {
                                Image(systemName: "doc")
                                Text(ref.originalName ?? "文件")
                                    .font(.system(size: 8))
                                    .lineLimit(1)
                            }
                            .frame(width: 54, height: 54)
                            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        Button {
                            model.removeAttachment(ref.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 15, height: 15)
                                .background(Color.black.opacity(0.6), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 2)
        }
    }
}
