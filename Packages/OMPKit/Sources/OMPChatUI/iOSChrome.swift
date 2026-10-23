import SwiftUI
import OMPCore
import OMPDesign

#if os(iOS)
/// Complete iOS experience matching PaseoPro / Moshi (from real device reference):
/// 1. Slide-out drawer with PaseoPro navigation (项目, 会话历史, 计划任务, 用量, 主机会话列表)
/// 2. Top bar with `[ 聊天 | 主机 ]` segmented pill + device selector / compose
/// 3. Chat screen with floating status chips (`∠ +932 -288`, `Ω 子代理 · 25`),
///    time elapsed dividers (`用时 45分钟34秒 >`), floating scroll-to-bottom chevron,
///    and pill composer (`+`, `发送消息`, mic, stop/send)
/// 4. Host screen with Files pane (bookmark pills, path header, folder rows),
///    Terminal pane (white terminal canvas, git prompt, keyboard accessory row),
///    and floating bottom accessory bar `[ 文件 | 终端 | 配置 ]`.
public struct iOSRootView: View {
    @Environment(ChatAppModel.self) private var model
    @State private var tab: Tab = .chat
    @State private var hostPane: HostPane = .files
    @State private var drawerOpen = false
    @State private var selectedHost = "Mac mini"

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
        ZStack(alignment: .leading) {
            // Main content
            VStack(spacing: 0) {
                topBar
                switch tab {
                case .chat:
                    PaseoChatScreen(onOpenDrawer: { withAnimation(Theme.Motion.quick) { drawerOpen = true } })
                case .host:
                    PaseoHostScreen(pane: $hostPane, selectedHost: $selectedHost)
                }
            }
            .background(Color.ompCanvas)
            .offset(x: drawerOpen ? 290 : 0)
            .disabled(drawerOpen)

            // Dimming overlay
            if drawerOpen {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .offset(x: 290)
                    .onTapGesture {
                        withAnimation(Theme.Motion.quick) { drawerOpen = false }
                    }
            }

            // Slide-out Drawer (Frame 1s)
            if drawerOpen {
                PaseoDrawer(isOpen: $drawerOpen, onSelectConversation: { id in
                    model.selectedConversationID = id
                    tab = .chat
                    withAnimation(Theme.Motion.quick) { drawerOpen = false }
                })
                .frame(width: 290)
                .transition(.move(edge: .leading))
            }
        }
        .sheet(isPresented: Binding(get: { model.showSettings }, set: { model.showSettings = $0 })) {
            ProviderSettingsView()
                .environment(model)
        }
        .task { await model.bootstrap() }
    }

    // MARK: Top Bar (Frame 15s / 60s)

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Theme.Motion.quick) { drawerOpen.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 36, height: 36)
                    .background(Color.ompFill, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            pillTabs

            Spacer()

            if tab == .chat {
                HStack(spacing: 6) {
                    Button {
                        model.newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.ompText)
                            .frame(width: 36, height: 36)
                            .background(Color.ompFill, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button {
                            _ = model.newTemporaryConversation()
                        } label: {
                            Label("临时对话", systemImage: "eye.slash")
                        }
                        Button {
                            model.showSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.ompText)
                            .frame(width: 36, height: 36)
                            .background(Color.ompFill, in: Circle())
                    }
                }
            } else {
                Menu {
                    Button("Mac mini") { selectedHost = "Mac mini" }
                    Button("MacBook") { selectedHost = "MacBook" }
                    Button("win11") { selectedHost = "win11" }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedHost)
                            .font(.system(size: 12.5, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.ompText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.ompFill, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
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
                        .shadow(color: tab == item ? Color.black.opacity(0.06) : .clear, radius: 4, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.ompFill))
    }
}

// MARK: - Slide-out Drawer (Frame 1s)

struct PaseoDrawer: View {
    @Environment(ChatAppModel.self) private var model
    @Binding var isOpen: Bool
    let onSelectConversation: (UUID) -> Void

    @State private var hostExpanded = true
    @State private var search = ""
    @State private var activeSheet: ActiveSheet?

    enum ActiveSheet: Identifiable {
        case projects, history, schedules, usage
        var id: Self { self }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: PaseoPro + Search
            HStack {
                Text("PaseoPro")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ompText)
                Spacer()
                Button {
                    // search action
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.ompText)
                        .frame(width: 32, height: 32)
                        .background(Color.ompFill, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 54)
            .padding(.bottom, 14)

            // Top 4 Menu Items
            VStack(spacing: 2) {
                Button { activeSheet = .projects } label: {
                    drawerItem(icon: "folder", title: "项目", badge: "\(model.projects.count)")
                }.buttonStyle(.plain)

                Button { activeSheet = .history } label: {
                    drawerItem(icon: "clock", title: "会话历史", badge: "\(model.sortedConversations.count)")
                }.buttonStyle(.plain)

                Button { activeSheet = .schedules } label: {
                    drawerItem(icon: "calendar", title: "计划任务")
                }.buttonStyle(.plain)

                Button { activeSheet = .usage } label: {
                    drawerItem(icon: "chart.bar", title: "用量")
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10)

            Divider()
                .padding(.vertical, 12)

            // Section: 全部主机 ⌵
            HStack {
                Text("全部主机")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ompTextTertiary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.ompTextTertiary)
                Spacer()
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Host Folder: 📁 ai-command-center 45 ⌵
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    Button {
                        withAnimation(Theme.Motion.quick) { hostExpanded.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.ompTextSecondary)
                            Text("ai-command-center")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.ompText)
                            Spacer()
                            Text("\(model.sortedConversations.count)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Color.ompTextTertiary)
                            Image(systemName: hostExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.ompTextTertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Session Thread Rows
                    if hostExpanded {
                        ForEach(model.sortedConversations) { conv in
                            Button {
                                onSelectConversation(conv.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(conv.title)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Color.ompText)
                                        .lineLimit(1)
                                    Spacer()
                                    if conv.id == model.selectedConversationID {
                                        Circle()
                                            .fill(Color.ompText)
                                            .frame(width: 5, height: 5)
                                    } else if conv.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    conv.id == model.selectedConversationID
                                        ? Color.ompFill
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }

            Spacer()

            // Bottom Bar in Drawer: [ 📝 聊天 ] + ⚙️
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .semibold))
                    Text("聊天")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Color.black, in: Capsule())

                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.ompText)
                        .frame(width: 36, height: 36)
                        .background(Color.ompFill, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ompCard)
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 8, y: 0)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .projects:
                PaseoProjectsSheet().environment(model)
            case .history:
                PaseoSessionHistorySheet(onSelectConversation: { id in
                    onSelectConversation(id)
                }).environment(model)
            case .schedules:
                PaseoScheduledTasksSheet()
            case .usage:
                PaseoUsageSheet().environment(model)
            }
        }
    }

    private func drawerItem(icon: String, title: String, badge: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompText)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.ompText)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Chat Screen (Frame 15s)

public struct PaseoChatScreen: View {
    @Environment(ChatAppModel.self) private var model
    let onOpenDrawer: () -> Void

    public init(onOpenDrawer: @escaping () -> Void = {}) {
        self.onOpenDrawer = onOpenDrawer
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Main transcript
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    ErrorBanner(message: message) { model.dismissError() }
                }
                ChatTranscriptView()
                // Spacer for composer
                Color.clear.frame(height: 100)
            }

            // Floating status chips + Scroll Chevron + Composer
            VStack(spacing: 8) {
                // Scroll to bottom floating chevron
                Button {
                    // scroll action
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.ompCard, in: Circle())
                        .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
                }
                .buttonStyle(.plain)

                // Status Chips Row (Frame 15s): ∠ +932 -288 | Ω 子代理 · 25
                HStack(spacing: 8) {
                    if let diff = totalDiff {
                        HStack(spacing: 5) {
                            Image(systemName: "angle")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.ompTextTertiary)
                            if diff.added > 0 {
                                Text("+\(diff.added)")
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.green)
                            }
                            if diff.removed > 0 {
                                Text("-\(diff.removed)")
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.ompCard, in: Capsule())
                        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 1)
                    } else if let usage = model.selectedConversation?.messages.compactMap(\.usage).last {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                            Text(TokenFormat.compact(usage.inputTokens))
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            Image(systemName: "arrow.down")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.accentColor)
                            Text(TokenFormat.compact(usage.outputTokens))
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.ompCard, in: Capsule())
                        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 1)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.ompTextTertiary)
                        Text(toolCount > 0 ? "操作 · \(toolCount)" : "子代理 · \(model.sortedConversations.count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.ompTextSecondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.ompCard, in: Capsule())
                    .shadow(color: Color.black.opacity(0.05), radius: 4, y: 1)

                    Spacer()
                }
                .padding(.horizontal, 20)

                // Composer Bar (Frame 15s)
                PaseoComposerBar()
            }
            .padding(.bottom, 8)
        }
    }

    private var totalDiff: (added: Int, removed: Int)? {
        guard let conversation = model.selectedConversation else { return nil }
        var added = 0
        var removed = 0
        for msg in conversation.messages {
            for part in msg.parts {
                if case .toolResult(let result) = part {
                    for line in result.outputText.split(separator: "\n", omittingEmptySubsequences: false) {
                        if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
                        else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
                    }
                }
            }
        }
        return (added == 0 && removed == 0) ? nil : (added, removed)
    }

    private var toolCount: Int {
        guard let conversation = model.selectedConversation else { return 0 }
        return conversation.messages.reduce(0) { count, msg in
            count + msg.parts.filter {
                if case .toolCall = $0 { return true }
                return false
            }.count
        }
    }

}

/// PaseoPro Pill Composer (Frame 15s)
struct PaseoComposerBar: View {
    @Environment(ChatAppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            // Left + button
            Button {
                // attach action
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            // Text input
            TextField("发送消息", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5))
                .lineLimit(1...5)

            // Yellow status ring
            Circle()
                .strokeBorder(Color.yellow.opacity(0.8), lineWidth: 2)
                .frame(width: 14, height: 14)

            // Mic button
            Button {
                // voice input action
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ompText)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            // Stop (running) / Send button
            if model.isStreaming {
                Button {
                    model.stop()
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    model.send()
                } label: {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.draftAttachments.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.ompCard, in: Capsule())
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
        .padding(.horizontal, 16)
    }
}

// MARK: - Host Screen (Frame 60s / 75s)

public struct PaseoHostScreen: View {
    @Environment(ChatAppModel.self) private var model
    @Binding var pane: iOSRootView.HostPane
    @Binding var selectedHost: String

    @State private var directory: URL = URL(fileURLWithPath: "/")

    public init(pane: Binding<iOSRootView.HostPane>, selectedHost: Binding<String>) {
        _pane = pane
        _selectedHost = selectedHost
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                switch pane {
                case .files:
                    PaseoFilesPane(directory: $directory)
                case .terminal:
                    PaseoTerminalPane(directory: directory)
                case .config:
                    ProviderSettingsEmbedded()
                }
            }
            .frame(maxHeight: .infinity)

            // Floating bottom accessory bar (Frame 60s)
            HStack(spacing: 4) {
                ForEach(iOSRootView.HostPane.allCases, id: \.self) { item in
                    Button {
                        withAnimation(Theme.Motion.quick) { pane = item }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: icon(item))
                                .font(.system(size: 12, weight: .medium))
                            Text(item.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(pane == item ? Color.ompText : Color.ompTextSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            pane == item
                                ? Color.ompFill
                                : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color.ompCard, in: Capsule())
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
            .padding(.bottom, 12)
        }
    }

    private func icon(_ pane: iOSRootView.HostPane) -> String {
        switch pane {
        case .files: "folder"
        case .terminal: "terminal"
        case .config: "slider.horizontal.3"
        }
    }
}

// MARK: - Files Pane (Frame 60s)

struct PaseoFilesPane: View {
    @Binding var directory: URL

    private let bookmarks: [(icon: String, name: String, path: String)] = [
        ("folder", "根目录", "/"),
        ("house", "个人目录", NSHomeDirectory()),
        ("internaldrive", "根目录", "/System/Volumes/Data"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Bookmark pills row: [📁 根目录] [🏠 个人目录] [💽 根目录] [+]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(bookmarks, id: \.path) { bm in
                        Button {
                            directory = URL(fileURLWithPath: bm.path)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: bm.icon)
                                    .font(.system(size: 11))
                                Text(bm.name)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(directory.path == bm.path ? Color.ompText : Color.ompTextSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().strokeBorder(Color.ompBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        // add bookmark
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.ompText)
                            .frame(width: 28, height: 28)
                            .background(Circle().strokeBorder(Color.ompBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            // Path Header row: / on left, ≡: and Q on right
            HStack {
                Text(directory.path)
                    .font(.system(size: 12, weight: .medium).monospaced())
                    .foregroundStyle(Color.ompTextSecondary)
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompText)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            // File / Folder rows
            List {
                ForEach(entries, id: \.path) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.isDir ? "folder.fill" : "doc")
                            .font(.system(size: 13))
                            .foregroundStyle(entry.isDir ? Color.black : Color.ompTextTertiary)
                            .frame(width: 20)
                        Text(entry.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ompText)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.ompTextTertiary)
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
    }

    private var entries: [(name: String, path: String, isDir: Bool)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return items
            .filter { !$0.hasPrefix(".") || $0 == ".vol" }
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
}

// MARK: - Terminal Pane (Frame 75s)

struct PaseoTerminalPane: View {
    let directory: URL
    @State private var lines: [String] = [
        "> ls",
        "__pycache__          infra",
        "AGENTS.md            machines",
        "aicc.egg-info        memories",
        "archive              pyproject.toml",
        "CLAUDE.bak.md        README.md",
        "CLAUDE.md            requirements-heavy.txt",
        "conftest.py          requirements.txt",
        "data                 test_aac",
        "docs                 test_aac.cpp",
        "experiments          uv.lock",
        "harness",
    ]
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            // Top bookmark pills: [>_ ~/Documents/ai-command-center] + •••
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                    Text(GitInfo.tildified(directory.path))
                        .font(.system(size: 11.5, weight: .medium).monospaced())
                        .lineLimit(1)
                }
                .foregroundStyle(Color.ompText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.ompFill, in: Capsule())

                Spacer()

                Button {
                    // add session
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompText)
                }
                .buttonStyle(.plain)

                Button {
                    // options
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Terminal canvas: white background, green/black monospace text (Frame 75s)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(line.hasPrefix(">") ? Color.green : Color.black)
                            .textSelection(.enabled)
                    }

                    // Prompt row (Frame 75s): ~/Documents/c/ai-command-center main !19 ?25 > █
                    HStack(spacing: 6) {
                        Text("\(GitInfo.tildified(directory.path))  main  !19  ?25  >")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.blue.opacity(0.8))
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: 7, height: 13)
                    }
                    .padding(.top, 4)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)

            // Keyboard accessory row (Frame 75s)
            HStack(spacing: 4) {
                ForEach(["Esc", "Tab", "Ctrl", "Alt", "Shift", "↑", "↓", "←", "→", "⌨"], id: \.self) { key in
                    Button {
                        // key press action
                    } label: {
                        Text(key)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.ompText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(Color.ompCard)
            .padding(.bottom, 50)
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
