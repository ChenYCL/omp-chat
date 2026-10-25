import SwiftUI
import UniformTypeIdentifiers
import OMPCore
import OMPDesign

public struct ComposerBar: View {
    @Environment(ChatAppModel.self) private var model
    @State private var importingFiles = false
    @State private var showImageSheet = false
    @State private var showOptionsSheet = false
    @State private var showMCPSheet = false
    @State private var showVoiceSheet = false
    @State private var showModelPicker = false
    @State private var webSearchEnabled = false
    @State private var promptHistoryIndex = 0
    @State private var originalDraft = ""
    @FocusState private var focused: Bool
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
            if let token = mentionToken {
                mentionList(token)
            }
            composerCard
        }
        .padding(.horizontal, Theme.Layout.transcriptPadding)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: Theme.Layout.transcriptMax + Theme.Layout.transcriptPadding * 2)
        .frame(maxWidth: .infinity)
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .ompVoiceMode)) { _ in
            showVoiceSheet = true
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
        .sheet(isPresented: $showVoiceSheet) {
            VoiceModeSheet()
                .environment(model)
        }
    }

    // MARK: Official ComposerLayoutRoot

    /// Outer card: ompCard fill, 10pt radius, 1pt ompBorder hairline.
    /// Codex composer = flat bordered card, no shadow, no top menu panel.
    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            composerBody
            composerFooter
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
            .lineSpacing(8) // official --leading-normal 1.5 → 16 × 0.5 = 8
            .lineLimit(1...10)
            .focused($focused)
            .focusEffectDisabled()
            .padding(.top, 2)
            .onKeyPress(phases: .down) { press in
                guard press.key == .return, !press.modifiers.contains(.shift) else { return .ignored }
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
                        Label("MCP 工具", systemImage: "powerplug")
                    }
                }
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
            modelPill

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
                .keyboardShortcut(.cancelAction)
                .help("停止生成（Esc）")
                .accessibilityLabel("停止生成")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
    }

    /// 🌐 联网 toggle pill (real `webSearchEnabled` state).
    private var webSearchPill: some View {
        Button {
            webSearchEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                Text("联网")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(webSearchEnabled ? Color.ompInverseText : Color.ompTextSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(webSearchEnabled ? Color.ompPrimarySolid : Color.ompFill, in: Capsule())
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
                Text(projectName)
                    .font(.system(size: 11))
            }
            HStack(spacing: 4) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 10))
                Text("本地")
                    .font(.system(size: 11))
            }
            if let branch = currentBranch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .font(.system(size: 10.5, design: .monospaced))
                }
            }
            Spacer()
        }
        .foregroundStyle(Color.ompTextTertiary)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    /// Active @-mention query: the token after the last `@` when it contains no
    /// whitespace (ChatGPT `composer.atMentionList`).
    private var mentionToken: String? {
        guard let at = model.draft.lastIndex(of: "@") else { return nil }
        let tail = model.draft[model.draft.index(after: at)...]
        guard !tail.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(tail)
    }

    private struct MentionCandidate: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private func mentionCandidates(_ token: String) -> [MentionCandidate] {
        let q = token.lowercased()
        var items: [MentionCandidate] = []
        for conversation in model.sortedConversations.prefix(50) where q.isEmpty || conversation.title.lowercased().contains(q) {
            items.append(MentionCandidate(icon: "bubble.left", title: conversation.title, detail: "会话"))
        }
        for project in model.orderedProjects where q.isEmpty || project.name.lowercased().contains(q) {
            items.append(MentionCandidate(icon: "folder", title: project.name, detail: "项目"))
        }
        for custom in model.orderedCustomSections where q.isEmpty || custom.name.lowercased().contains(q) {
            items.append(MentionCandidate(icon: "rectangle.3.group", title: custom.name, detail: "分区"))
        }
        return Array(items.prefix(8))
    }

    private func mentionList(_ token: String) -> some View {
        let items = mentionCandidates(token)
        return VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("没有匹配的提及")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(10)
            } else {
                ForEach(items) { item in
                    Button {
                        insertMention(item.title)
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
                            Spacer()
                            Text(item.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.ompTextTertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
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
    }

    private func insertMention(_ title: String) {
        guard let at = model.draft.lastIndex(of: "@") else { return }
        model.draft = String(model.draft[..<at]) + "@" + title + " "
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
        if let id = model.selectedConversation?.projectID,
           let project = model.projects.first(where: { $0.id == id }) {
            return project.name
        }
        return "默认工作区"
    }

    private var currentBranch: String? {
        GitInfo.branch(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    private func handleHistoryKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .upArrow && (model.draft.isEmpty || promptHistoryIndex > 0) {
            if let prompts = model.selectedConversation?.messages.filter({ $0.role == .user }).map(\.concatenatedText), !prompts.isEmpty {
                if promptHistoryIndex == 0 { originalDraft = model.draft }
                if promptHistoryIndex < prompts.count {
                    promptHistoryIndex += 1
                    model.draft = prompts[prompts.count - promptHistoryIndex]
                    return .handled
                }
            }
        } else if press.key == .downArrow && promptHistoryIndex > 0 {
            if let prompts = model.selectedConversation?.messages.filter({ $0.role == .user }).map(\.concatenatedText), !prompts.isEmpty {
                promptHistoryIndex -= 1
                model.draft = promptHistoryIndex == 0 ? originalDraft : prompts[prompts.count - promptHistoryIndex]
                return .handled
            }
        }
        return .ignored
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
                Text(quoted.concatenatedText)
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
