import SwiftUI
import OMPChatUI
import OMPDesign

@main
struct OMPChatiOSApp: App {
    @State private var model = ChatAppModel()
    @State private var showRemote = false

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottomTrailing) {
                ChatRootView()
                    .environment(model)
                    .tint(customAccent)

                Button {
                    showRemote = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.ompText)
                        .frame(width: 44, height: 44)
                        .background(Color.ompCard, in: Circle())
                        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.bottom, 108)
            }
            .sheet(isPresented: $showRemote) {
                RemotePairSheet()
                    .environment(model)
            }
        }
    }

    private var customAccent: Color? {
        let hex = model.settings.accentColorHex
        guard hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color.ompFlat(rgb: value)
    }
}
