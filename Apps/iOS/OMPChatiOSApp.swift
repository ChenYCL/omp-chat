import SwiftUI
import OMPChatUI
import OMPDesign

@main
struct OMPChatiOSApp: App {
    @State private var model = ChatAppModel()

    var body: some Scene {
        WindowGroup {
            ChatRootView()
                .environment(model)
        }
    }
}
