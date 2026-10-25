import SwiftUI
import OMPCore
import OMPDesign

/// ChatGPT / Moshi style Voice Mode with animated pulsing voice orb,
/// sound wave rings, live speech timer, and dictation transfer to composer.
public struct VoiceModeSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var isListening = true
    @State private var orbScale: CGFloat = 1.0
    @State private var ringScale: CGFloat = 1.0
    @State private var ringOpacity: Double = 0.6
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    @State private var recognizedText = "通过语音与大模型自然交互。你可以直接口述需求、提问或审查代码..."

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.ompTextTertiary)
                Text("语音输入还没接上")
                    .font(.system(size: 16, weight: .semibold))
                Text("这里之前只有一个动画，点发送会把一句固定的占位文字塞进输入框，并没有识别你说的话。消息的朗读是可用的：在消息上点朗读按钮即可。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("语音模式")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }

}
