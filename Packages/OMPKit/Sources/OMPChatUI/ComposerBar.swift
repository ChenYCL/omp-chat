import SwiftUI
import UniformTypeIdentifiers
import OMPCore
import OMPDesign

public struct ComposerBar: View {
    @Environment(ChatAppModel.self) private var model
    @State private var importingFiles = false
    @State private var showImageSheet = false
    @State private var hoveringSend = false
    @FocusState private var focused: Bool

    public init() {}

    private static let templates: [(title: String, prompt: String)] = [
        ("翻译成英文", "把下面的内容翻译成地道的英文：\n"),
        ("总结要点", "用要点总结下面的内容：\n"),
        ("更简洁", "把下面的内容改写得更简洁：\n"),
        ("审查代码", "审查下面这段代码的风险与改进点：\n```\n\n```"),
    ]

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            if showTemplates {
                templateList
            }
            VStack(alignment: .leading, spacing: 8) {
                if let quoted = model.replyingTo {
                    replyPreview(quoted)
                }
                if !model.draftAttachments.isEmpty {
                    attachmentStrip
                }

                TextField("发消息…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .lineLimit(1...10)
                    .focused($focused)
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return, !press.modifiers.contains(.shift) else { return .ignored }
                        guard model.settings.sendOnReturn else { return .ignored }
                        model.send()
                        return .handled
                    }
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .upArrow, model.draft.isEmpty else { return .ignored }
                        if let last = model.selectedConversation?.messages.last(where: { $0.role == .user }) {
                            model.draft = last.concatenatedText
                            return .handled
                        }
                        return .ignored
                    }

                HStack(spacing: 6) {
                    circleButton("paperclip", help: "添加图片或文件") {
                        importingFiles = true
                    }

                    modelPill

                    if !model.imageModels.isEmpty {
                        circleButton("photo.badge.plus", help: "生成图片") {
                            showImageSheet = true
                        }
                    }

                    Spacer(minLength: 0)

                    if model.isStreaming {
                        Button {
                            model.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.red, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("停止生成 (Esc)")
                        .keyboardShortcut(.cancelAction)
                    } else {
                        Button {
                            model.send()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(canSend ? Color.white : Color.ompTextTertiary)
                                .frame(width: 30, height: 30)
                                .background(canSend ? Color.accentColor : Color.ompFill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("发送 (Return)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.ompCard, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                    .strokeBorder(
                        focused ? Color.accentColor.opacity(0.45) : Color.ompBorder,
                        lineWidth: 1
                    )
            )
            .shadow(color: Theme.Shadow.composerColor, radius: Theme.Shadow.composerRadius, y: Theme.Shadow.composerY)
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
        .sheet(isPresented: $showImageSheet) {
            ImageGenerationSheet()
                .environment(model)
        }
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

    private var filteredTemplates: [(title: String, prompt: String)] {
        let query = String(model.draft.dropFirst())
        guard !query.isEmpty else { return Self.templates }
        return Self.templates.filter { $0.title.contains(query) }
    }

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredTemplates, id: \.title) { item in
                Button {
                    model.draft = item.prompt
                } label: {
                    HStack(spacing: 8) {
                        Text("/\(item.title)")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Text(item.prompt.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: Theme.Layout.transcriptMax)
        .ompSurface(radius: Theme.Radius.m)
        .padding(.horizontal, Theme.Layout.transcriptPadding)
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ompTextSecondary)
                .frame(width: 28, height: 28)
                .background(Color.ompFill, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var modelPill: some View {
        Menu {
            if model.availableModels.isEmpty {
                Text("先在设置中同步模型")
            } else {
                ForEach(model.availableModels) { descriptor in
                    Button {
                        model.setModel(descriptor)
                    } label: {
                        if descriptor.id == model.activeModel?.id {
                            Label(descriptor.displayName, systemImage: "checkmark")
                        } else {
                            Text(descriptor.displayName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 9.5))
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
