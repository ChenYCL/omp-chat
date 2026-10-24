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
                .tint(customAccent)
        }
    }

    private var customAccent: Color? {
        let hex = model.settings.accentColorHex
        guard hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color.ompFlat(rgb: value)
    }
}
