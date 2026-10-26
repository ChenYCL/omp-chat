import SwiftUI
import OMPChatUI
import OMPDesign

@main
struct OMPChatApp: App {
    @State private var model = ChatAppModel()

    var body: some Scene {
        WindowGroup {
            ChatRootView()
                .environment(model)
                .tint(customAccent)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    await model.bootstrap()
                    model.syncRelayController()
                    // Plugins first: their bundled MCP servers join the list
                    // MCP starts from. Without startMCP, servers would only
                    // start when the MCP pane is first opened.
                    model.reloadPlugins()
                    model.startMCP()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建对话") {
                    model.newConversation()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("新建临时对话") {
                    _ = model.newTemporaryConversation()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("格式") {
                // Menu commands, not onKeyPress: SwiftUI's TextField does not
                // deliver command-modified keys to onKeyPress, so the same
                // shortcuts had to live on menu items to fire at all.
                Button("加粗") { model.applyMarkdown(.bold) }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("斜体") { model.applyMarkdown(.italic) }
                .keyboardShortcut("i", modifiers: .command)

                Button("下划线") { model.applyMarkdown(.underline) }
                .keyboardShortcut("u", modifiers: .command)

                Divider()

                // Block styles have no shortcuts: every plain letter is already
                // taken by the 对话 menu (⌘F/⌘K/⌘J/⌘B) or by 加粗/斜体/下划线.
                Button("标题 1") { model.applyBlockFormat(.heading(1)) }
                Button("标题 2") { model.applyBlockFormat(.heading(2)) }
                Button("标题 3") { model.applyBlockFormat(.heading(3)) }
                Button("段落") { model.applyBlockFormat(.paragraph) }
                Button("无序列表") { model.applyBlockFormat(.bulletedList) }
                Button("有序列表") { model.applyBlockFormat(.numberedList) }
                Button("链接") { model.applyBlockFormat(.link) }
            }
            CommandMenu("对话") {
                Button("重新生成") {
                    model.regenerateLast()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isStreaming)

                Button("停止生成") {
                    model.stop()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isStreaming)

                Button("语音模式") {
                    NotificationCenter.default.post(name: .ompVoiceMode, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Button("在对话中查找") {
                    NotificationCenter.default.post(name: .ompFindInChat, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("快速切换") {
                    NotificationCenter.default.post(name: .ompQuickSwitch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("侧面板") {
                    NotificationCenter.default.post(name: .ompToggleTerminal, object: nil)
                }
                .keyboardShortcut("j", modifiers: .command)

                Button("切换侧栏") {
                    NotificationCenter.default.post(name: .ompToggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Divider()

                Button("上一个对话") {
                    model.selectPreviousConversation()
                }
                .keyboardShortcut(.upArrow, modifiers: .option)

                Button("下一个对话") {
                    model.selectNextConversation()
                }
                .keyboardShortcut(.downArrow, modifiers: .option)
            }
        }

        Settings {
            // Same theme and accent as the main window; without these the
            // Settings window followed the system and stayed light in 深色.
            ProviderSettingsView()
                .environment(model)
                .tint(customAccent)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
    }

    private var customAccent: Color? {
        let hex = model.settings.accentColorHex
        guard hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color.ompFlat(rgb: value)
    }
}
