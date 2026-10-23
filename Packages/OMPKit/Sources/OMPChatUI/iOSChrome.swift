import SwiftUI
import OMPCore
import OMPDesign

#if os(iOS)
/// iOS chrome matching Moshi-style clients: pill tab bar (聊天/主机),
/// host workspace with 文件/终端/配置 accessory bar.
public struct iOSRootView: View {
    @Environment(ChatAppModel.self) private var model
    @State private var tab: Tab = .chat
    @State private var hostPane: HostPane = .files

    public init() {}

    public enum Tab: String, CaseIterable {
        case chat = "聊天"
        case host = "主机"
    }

    public enum HostPane: String, CaseIterable {
        case files = "文件"
        case terminal = "终端"
        case config = "配置"
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            switch tab {
            case .chat: ChatScreen()
            case .host: HostScreen(pane: $hostPane)
            }
        }
        .background(Color.ompCanvas)
        .sheet(isPresented: Binding(get: { model.showSettings }, set: { model.showSettings = $0 })) {
            ProviderSettingsView()
                .environment(model)
        }
        .task { await model.bootstrap() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.sortedConversations) { conversation in
                    Button {
                        model.selectedConversationID = conversation.id
                        tab = .chat
                    } label: {
                        if conversation.id == model.selectedConversationID {
                            Label(conversation.title, systemImage: "checkmark")
                        } else {
                            Text(conversation.title)
                        }
                    }
                }
                Divider()
                Button {
                    model.newConversation()
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                }
                Button {
                    model.showSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 34, height: 34)
                    .background(Color.ompFill, in: Circle())
            }

            Spacer()

            pillTabs

            Spacer()

            Button {
                model.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 34, height: 34)
                    .background(Color.ompFill, in: Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var pillTabs: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    withAnimation(Theme.Motion.quick) { tab = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 13, weight: tab == item ? .semibold : .medium))
                        .foregroundStyle(tab == item ? Color.ompText : Color.ompTextSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(tab == item ? Color.ompCard : Color.clear)
                        )
                        .shadow(color: tab == item ? Theme.Shadow.composerColor : .clear, radius: 6, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.ompFill))
    }
}

public struct ChatScreen: View {
    @Environment(ChatAppModel.self) private var model

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            modelLine
            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.dismissError() }
            }
            ChatTranscriptView()
            ComposerBar()
        }
    }

    private var modelLine: some View {
        HStack(spacing: 8) {
            if let descriptor = model.activeModel {
                Text(descriptor.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.ompTextSecondary)
                    .lineLimit(1)
                if descriptor.capabilities.thinking {
                    Text("thinking")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.ompTextTertiary)
                }
                if let conversation = model.selectedConversation,
                   let usage = model.contextUsage(conversation) {
                    ContextBadge(used: usage.used, limit: usage.limit)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

public struct HostScreen: View {
    @Environment(ChatAppModel.self) private var model
    @Binding var pane: iOSRootView.HostPane

    @State private var directory: URL = FileConversationStore.defaultDirectory()

    public init(pane: Binding<iOSRootView.HostPane>) {
        _pane = pane
    }

    public var body: some View {
        VStack(spacing: 0) {
            pathBar
            Group {
                switch pane {
                case .files: fileList
                case .terminal: TerminalView()
                case .config: ProviderSettingsEmbedded()
                }
            }
            .frame(maxHeight: .infinity)
            accessoryBar
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(Color.ompTextTertiary)
            Text(GitInfo.tildified(directory.path))
                .font(.system(size: 11.5, weight: .medium).monospaced())
                .foregroundStyle(Color.ompTextSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let branch = GitInfo.branch(at: directory) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8, weight: .semibold))
                    Text(branch)
                        .font(.system(size: 10, weight: .medium).monospaced())
                }
                .foregroundStyle(Color.ompTextSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.ompFill, in: Capsule())
            }
            Spacer()
            if directory.path != "/" {
                Button {
                    directory = directory.deletingLastPathComponent()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(width: 28, height: 28)
                        .background(Color.ompFill, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var fileList: some View {
        List {
            ForEach(entries, id: \.path) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isDir ? "folder.fill" : "doc")
                        .font(.system(size: 13))
                        .foregroundStyle(entry.isDir ? Color.accentColor : Color.ompTextTertiary)
                        .frame(width: 20)
                    Text(entry.name)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.ompText)
                        .lineLimit(1)
                    Spacer()
                    if entry.isDir {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if entry.isDir { directory = URL(fileURLWithPath: entry.path) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.ompCanvas)
    }

    private var entries: [(name: String, path: String, isDir: Bool)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return items
            .filter { !$0.hasPrefix(".") }
            .sorted { lhs, rhs in
                let lDir = isDir(lhs), rDir = isDir(rhs)
                if lDir != rDir { return lDir }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { (name: $0, path: directory.appendingPathComponent($0).path, isDir: isDir($0)) }
    }

    private func isDir(_ name: String) -> Bool {
        var flag: ObjCBool = false
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &flag)
        return flag.boolValue
    }

    private var accessoryBar: some View {
        HStack(spacing: 2) {
            ForEach(iOSRootView.HostPane.allCases, id: \.self) { item in
                Button {
                    withAnimation(Theme.Motion.quick) { pane = item }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon(item))
                            .font(.system(size: 13, weight: .medium))
                        Text(item.rawValue)
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(pane == item ? Color.accentColor : Color.ompTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(pane == item ? Color.ompFill : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func icon(_ pane: iOSRootView.HostPane) -> String {
        switch pane {
        case .files: "folder"
        case .terminal: "terminal"
        case .config: "slider.horizontal.3"
        }
    }
}

struct ProviderSettingsEmbedded: View {
    @Environment(ChatAppModel.self) private var model

    var body: some View {
        ScrollView {
            ProviderSettingsView()
                .environment(model)
        }
    }
}
#endif
