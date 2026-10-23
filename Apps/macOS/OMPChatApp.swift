import SwiftUI
import OMPCore
import OMPDesign

@main
struct OMPChatApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct RootView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Text("对话").font(Theme.Typography.secondary)
                    .foregroundStyle(Color.ompSecondaryLabel)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            ContentUnavailableView(
                "OMP Chat",
                systemImage: "sparkles",
                description: Text("骨架已就绪，等待核心模块接入。")
            )
        }
    }
}
