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
                .frame(minWidth: 900, minHeight: 600)
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

                Divider()

                Button("在对话中查找") {
                    NotificationCenter.default.post(name: .ompFindInChat, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("快速切换") {
                    NotificationCenter.default.post(name: .ompQuickSwitch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("切换侧栏") {
                    NotificationCenter.default.post(name: .ompToggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
            }
        }

        Settings {
            ProviderSettingsView()
                .environment(model)
        }
    }
}
