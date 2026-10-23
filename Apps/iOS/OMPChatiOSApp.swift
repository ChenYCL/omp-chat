import SwiftUI
import OMPCore
import OMPDesign

@main
struct OMPChatiOSApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "OMP Chat",
                systemImage: "sparkles",
                description: Text("骨架已就绪，等待核心模块接入。")
            )
            .navigationTitle("OMP Chat")
        }
    }
}
