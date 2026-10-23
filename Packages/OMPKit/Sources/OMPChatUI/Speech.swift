import Foundation
import AVFoundation

/// Reads a reply aloud. One utterance at a time; speaking again stops the
/// current one (ChatGPT's read-aloud behaviour).
public enum Speech {
    private static let synthesizer = AVSpeechSynthesizer()

    public static func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: String(trimmed.prefix(4000)))
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    public static func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
