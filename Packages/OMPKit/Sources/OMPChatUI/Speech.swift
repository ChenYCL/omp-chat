import Foundation
import AVFoundation

/// ChatGPT-style read-aloud manager with delegate tracking,
/// animated stop button, and automatic state reset.
@MainActor
public final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = SpeechManager()
    private let synthesizer = AVSpeechSynthesizer()
    @Published public private(set) var speakingMessageID: UUID?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, messageID: UUID? = nil) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            if speakingMessageID == messageID && messageID != nil {
                speakingMessageID = nil
                return
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            speakingMessageID = nil
            return
        }
        speakingMessageID = messageID
        let utterance = AVSpeechUtterance(string: String(trimmed.prefix(4000)))
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingMessageID = nil
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakingMessageID = nil
        }
    }
}

public enum Speech {
    @MainActor
    public static func speak(_ text: String, messageID: UUID? = nil) {
        SpeechManager.shared.speak(text, messageID: messageID)
    }

    @MainActor
    public static func stop() {
        SpeechManager.shared.stop()
    }
}
