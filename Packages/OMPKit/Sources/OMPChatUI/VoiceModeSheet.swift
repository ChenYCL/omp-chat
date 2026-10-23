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
            VStack(spacing: 0) {
                Spacer()

                // Animated Pulsing Voice Orb (ChatGPT Voice Mode signature)
                ZStack {
                    // Outer expanding sound ring
                    Circle()
                        .stroke(Color.accentColor.opacity(ringOpacity), lineWidth: 2)
                        .frame(width: 180, height: 180)
                        .scaleEffect(ringScale)

                    // Secondary glow ring
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.accentColor.opacity(0.25), Color.clear],
                                center: .center,
                                startRadius: 40,
                                endRadius: 90
                            )
                        )
                        .frame(width: 170, height: 170)
                        .scaleEffect(orbScale * 1.08)

                    // Core gradient orb
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.purple, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)
                        .scaleEffect(orbScale)
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 24, y: 6)

                    // Center mic/soundwave icon
                    Image(systemName: isListening ? "waveform" : "mic.slash")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 28)
                .onTapGesture {
                    toggleListening()
                }

                // Status text and timer
                VStack(spacing: 6) {
                    Text(isListening ? "正在聆听..." : "已暂停")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.ompText)

                    Text(timeString)
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.ompTextTertiary)
                }
                .padding(.bottom, 24)

                // Live transcription card
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 10))
                        Text("实时语音转文字预览")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(Color.ompTextTertiary)

                    Text(recognizedText)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.ompText)
                        .lineLimit(4)
                }
                .padding(14)
                .frame(maxWidth: 420)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)

                Spacer()

                // Bottom Action Controls
                HStack(spacing: 18) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark")
                            Text("取消")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ompTextSecondary)
                        .frame(width: 100, height: 42)
                        .background(Color.ompFill, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        toggleListening()
                    } label: {
                        Image(systemName: isListening ? "pause.fill" : "play.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.ompText)
                            .frame(width: 52, height: 52)
                            .background(Color.ompFill, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        transferToDraft()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                            Text("填入输入框")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 42)
                        .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 28)
            }
            .background(Color.ompCanvas)
            .navigationTitle("语音模式 (Voice Mode)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                startAnimation()
                startTimer()
            }
            .onDisappear {
                stopTimer()
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    private var timeString: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func toggleListening() {
        isListening.toggle()
        if isListening {
            startAnimation()
            startTimer()
        } else {
            withAnimation(.spring) {
                orbScale = 1.0
                ringScale = 1.0
                ringOpacity = 0.0
            }
            stopTimer()
        }
    }

    private func startAnimation() {
        withAnimation(
            .easeInOut(duration: 1.4)
            .repeatForever(autoreverses: true)
        ) {
            orbScale = 1.14
        }

        withAnimation(
            .easeOut(duration: 1.8)
            .repeatForever(autoreverses: false)
        ) {
            ringScale = 1.4
            ringOpacity = 0.0
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsedSeconds += 1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func transferToDraft() {
        if model.draft.isEmpty {
            model.draft = recognizedText
        } else {
            model.draft += " " + recognizedText
        }
        dismiss()
    }
}
