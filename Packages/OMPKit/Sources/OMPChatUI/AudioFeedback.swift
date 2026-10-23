import Foundation

#if os(macOS)
import AppKit

/// Tactile audio feedback chimes matching ChatGPT Desktop and Moshi
public enum AudioFeedback {
    public static func playSend() {
        NSSound(named: "Tink")?.play()
    }

    public static func playComplete() {
        NSSound(named: "Pop")?.play()
    }
}
#else
import AudioToolbox
import UIKit

/// Tactile audio and haptic feedback chimes matching Moshi / PaseoPro
public enum AudioFeedback {
    public static func playSend() {
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    public static func playComplete() {
        AudioServicesPlaySystemSound(1004)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
#endif
