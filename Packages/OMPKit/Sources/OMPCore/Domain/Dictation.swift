import Foundation

// MARK: - Errors

/// Why a dictation could not start or produce text (Codex `dictation.error.*`
/// and `composer.dictation.startError` / `transcribeError`), worded for the
/// composer.
public enum DictationError: Error, Equatable, Sendable, CaseIterable {
    /// Capture or the recognizer failed to come up for no reason we can name.
    case startFailed
    /// The recognizer failed on audio that was captured.
    case transcriptionFailed
    /// No on-device recognizer for the language, or none on this OS.
    case unsupported
    case microphonePermissionDenied
    case microphoneMissing
    /// Another app holds the microphone.
    case microphoneBusy
    /// Nothing recognisable was said.
    case audioTooShort
    /// Only the macOS 15 / iOS 18 recognizer asks for this permission.
    case speechPermissionDenied

    public var message: String {
        switch self {
        case .startFailed: return "无法开始听写"
        case .transcriptionFailed: return "无法识别这段录音"
        case .unsupported: return "这台设备不支持听写"
        case .microphonePermissionDenied: return "打开麦克风权限才能听写"
        case .microphoneMissing: return "连接麦克风后才能听写"
        case .microphoneBusy: return "请关闭正在使用麦克风的其他应用"
        case .audioTooShort: return "没听清，请再说一次"
        case .speechPermissionDenied: return "打开语音识别权限才能听写"
        }
    }

    /// The system settings page that fixes this error, if one does.
    public var settingsLink: DictationSettingsLink? {
        switch self {
        case .microphonePermissionDenied: return .microphone
        case .speechPermissionDenied: return .speechRecognition
        default: return nil
        }
    }

    /// Whether trying again can help. A device that cannot dictate or a
    /// permission that is off needs something else first.
    public var isRetryable: Bool {
        switch self {
        case .unsupported, .microphonePermissionDenied, .speechPermissionDenied: return false
        default: return true
        }
    }

    /// Maps the OSStatus an audio session activation or engine start threw.
    public static func audioStartFailure(osStatus: Int) -> DictationError {
        switch osStatus {
        // kAudioDevicePermissionsError (another process has hog mode) and the
        // AVAudioSession codes for losing the input to someone else:
        // insufficientPriority, cannotInterruptOthers, cannotStartRecording,
        // isBusy, siriIsRecording.
        case fourCharCode("!hog"), fourCharCode("!pri"), fourCharCode("!int"),
             fourCharCode("!rec"), fourCharCode("!act"), fourCharCode("siri"):
            return .microphoneBusy
        // kAudioHardwareBadDeviceError: the input device went away.
        case fourCharCode("!dev"):
            return .microphoneMissing
        default:
            return .startFailed
        }
    }

    /// Maps an `SFSpeechRecognitionTask` error, per Apple's table on
    /// `SFSpeechRecognitionTask.error`.
    public static func recognitionFailure(domain: String, code: Int) -> DictationError {
        switch (domain, code) {
        case ("kAFAssistantErrorDomain", 1110): return .audioTooShort  // Failed to recognize any speech.
        case ("kAFAssistantErrorDomain", 1700): return .speechPermissionDenied  // Request is not authorized.
        case ("kAFAssistantErrorDomain", 1100): return .startFailed  // An earlier instance is still active.
        case ("kLSRErrorDomain", 102): return .unsupported  // Assets are not installed.
        case ("kLSRErrorDomain", 201): return .unsupported  // Siri or Dictation is disabled.
        case ("kLSRErrorDomain", 300): return .startFailed  // Failed to initialize recognizer.
        default: return .transcriptionFailed
        }
    }

    /// The recognizer reporting that it was cancelled — our own doing, not a
    /// failure to show.
    public static func isCancellation(domain: String, code: Int) -> Bool {
        domain == "kLSRErrorDomain" && code == 301
    }

    static func fourCharCode(_ code: String) -> Int {
        code.utf8.reduce(0) { $0 << 8 | Int($1) }
    }
}

extension DictationError: LocalizedError {
    public var errorDescription: String? { message }
}

/// A system settings page a dictation error points at.
public enum DictationSettingsLink: Equatable, Sendable {
    case microphone
    case speechRecognition

    public var title: String {
        switch self {
        case .microphone: return "打开麦克风设置"
        case .speechRecognition: return "打开语音识别设置"
        }
    }

    /// The macOS System Settings privacy pane. iOS opens the app's own
    /// settings page, which holds both switches.
    public var macOSURL: URL {
        switch self {
        case .microphone: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .speechRecognition: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        }
    }
}

// MARK: - State machine

/// Where a dictation is. A live session runs starting → listening →
/// finishing → done; a recording transcribed afterwards (a file, or 重试 on
/// a kept recording) runs transcribing → done. Any active state can end in
/// failed or cancelled.
public enum DictationState: Equatable, Sendable {
    case idle
    /// Asking for permissions and loading the recognizer.
    case starting
    /// The microphone is open. `partial` is the recognizer's text so far.
    case listening(elapsed: TimeInterval, partial: String)
    /// The microphone is closed; the recognizer is settling the last words.
    case finishing(partial: String)
    /// A recording is being transcribed.
    case transcribing(partial: String)
    case done(String)
    /// `partial` is what was heard before the failure, possibly empty.
    case failed(DictationError, partial: String)
    case cancelled

    /// Starting, listening, finishing or transcribing.
    public var isActive: Bool {
        switch self {
        case .starting, .listening, .finishing, .transcribing: return true
        default: return false
        }
    }

    public var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    /// The recognizer's text so far (the result once done).
    public var partialText: String {
        switch self {
        case .listening(_, let partial), .finishing(let partial), .transcribing(let partial), .failed(_, let partial):
            return partial
        case .done(let text):
            return text
        case .idle, .starting, .cancelled:
            return ""
        }
    }

    /// What a failed dictation offers (Codex `dictation.recovery.*`).
    public var recovery: DictationRecovery? {
        guard case .failed(let error, let partial) = self else { return nil }
        let heard = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictationRecovery(error: error, text: DictationText.isMeaningful(heard) ? heard : nil)
    }
}

public enum DictationEvent: Equatable, Sendable {
    /// The user asked to dictate.
    case start
    /// A recording is handed to the recognizer.
    case transcribeRecording
    /// Microphone and recognizer are running.
    case ready
    /// The recognizer's text so far.
    case partial(String)
    /// Seconds since listening began.
    case tick(TimeInterval)
    /// The user asked for the text (停止 / 转写并发送).
    case stop
    /// The recognizer's last word.
    case final(String)
    case fail(DictationError)
    case cancel
    /// The user closed a finished, failed or cancelled dictation.
    case dismiss
}

/// What the owner of the audio and the recognizer must do after an event.
public enum DictationEffect: Equatable, Sendable {
    /// Close the microphone; the recognizer keeps going to settle the text.
    case stopCapture
    /// Release everything: microphone, recognizer and timers.
    case teardown
}

/// The pure dictation lifecycle. Events that make no sense in the current
/// state are ignored, so late callbacks from a session that already ended
/// cannot revive it.
public struct DictationMachine: Equatable, Sendable {
    /// Hard cap on one live session (Codex `maxRecordingLengthReached`).
    public static let defaultMaxDuration: TimeInterval = 120

    public let maxDuration: TimeInterval
    public private(set) var state: DictationState = .idle
    /// The last session stopped because it hit `maxDuration`.
    public private(set) var reachedMaxDuration = false

    public init(maxDuration: TimeInterval = DictationMachine.defaultMaxDuration) {
        self.maxDuration = maxDuration
    }

    @discardableResult
    public mutating func handle(_ event: DictationEvent) -> DictationEffect? {
        switch (state, event) {
        case (.idle, .start), (.done, .start), (.failed, .start), (.cancelled, .start):
            state = .starting
            reachedMaxDuration = false
            return nil

        case (.idle, .transcribeRecording), (.done, .transcribeRecording),
             (.failed, .transcribeRecording), (.cancelled, .transcribeRecording):
            state = .transcribing(partial: "")
            reachedMaxDuration = false
            return nil

        case (.starting, .ready):
            state = .listening(elapsed: 0, partial: "")
            return nil
        case (.idle, .ready), (.done, .ready), (.failed, .ready), (.cancelled, .ready):
            // Capture came up after the session ended (cancelled while
            // starting): release it at once.
            return .teardown

        // Stopping before anything was heard is cancelling (Codex: "Starting
        // dictation; click to cancel").
        case (.starting, .stop):
            state = .cancelled
            return .teardown

        case (.listening(let elapsed, _), .partial(let text)):
            state = .listening(elapsed: elapsed, partial: text)
            return nil
        case (.finishing, .partial(let text)):
            state = .finishing(partial: text)
            return nil
        case (.transcribing, .partial(let text)):
            state = .transcribing(partial: text)
            return nil

        case (.listening(let elapsed, let partial), .tick(let seconds)):
            let now = max(elapsed, seconds)
            if now >= maxDuration {
                state = .finishing(partial: partial)
                reachedMaxDuration = true
                return .stopCapture
            }
            state = .listening(elapsed: now, partial: partial)
            return nil

        case (.listening(_, let partial), .stop):
            state = .finishing(partial: partial)
            return .stopCapture

        case (.listening, .final(let text)), (.finishing, .final(let text)), (.transcribing, .final(let text)):
            let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if DictationText.isMeaningful(heard) {
                state = .done(heard)
            } else {
                let partial = state.partialText
                state = .failed(.audioTooShort, partial: DictationText.isMeaningful(partial) ? partial : "")
            }
            return .teardown

        case (let current, .fail(let error)) where current.isActive:
            state = .failed(error, partial: current.partialText)
            return .teardown

        case (let current, .cancel) where current.isActive:
            state = .cancelled
            return .teardown

        case (.done, .dismiss), (.failed, .dismiss), (.cancelled, .dismiss):
            state = .idle
            return nil

        default:
            return nil
        }
    }
}

// MARK: - Recovery

/// Codex `dictation.recovery.*`: what a failed dictation can still do.
public enum DictationRecoveryAction: String, CaseIterable, Sendable {
    case copyText
    case addToMessage
    case retry
    case dismiss

    public var title: String {
        switch self {
        case .copyText: return "复制文本"
        case .addToMessage: return "添加到消息"
        case .retry: return "重试"
        case .dismiss: return "关闭"
        }
    }
}

public struct DictationRecovery: Equatable, Sendable {
    public let error: DictationError
    /// What was heard before the failure; nil when nothing worth keeping.
    public let text: String?

    public init(error: DictationError, text: String?) {
        self.error = error
        self.text = text
    }

    /// Copy / add only with heard text, retry only when it can help,
    /// dismiss always.
    public var actions: [DictationRecoveryAction] {
        var actions: [DictationRecoveryAction] = []
        if text != nil { actions += [.copyText, .addToMessage] }
        if error.isRetryable { actions.append(.retry) }
        actions.append(.dismiss)
        return actions
    }
}

// MARK: - Text

/// How dictated text joins what is already there.
public enum DictationText {
    /// At least one letter or digit, in any script. Punctuation or
    /// whitespace alone is "didn't catch that".
    public static func isMeaningful(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Appends dictated text to a draft and never replaces it: the text is
    /// trimmed, joined by the draft's own trailing space or newline when it
    /// has one, else by a single space (none next to CJK). A blank draft
    /// becomes just the text; blank text leaves the draft alone.
    public static func merge(_ dictated: String, into draft: String) -> String {
        let text = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return draft }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return join(draft, text)
    }

    /// `left` then `right`, with one space at the seam unless either side
    /// already has whitespace there, either side is CJK (which is written
    /// without spaces), or `right` opens with closing punctuation.
    public static func join(_ left: String, _ right: String) -> String {
        guard let last = left.last else { return right }
        guard let first = right.first else { return left }
        if last.isWhitespace || first.isWhitespace || isCJK(last) || isCJK(first) || ",.!?;:)]}%…".contains(first) {
            return left + right
        }
        return left + " " + right
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x2E80...0x2FDF,   // radicals
             0x3000...0x303F,   // CJK symbols and punctuation
             0x3040...0x31FF,   // kana, bopomofo, hangul jamo, kanbun
             0x3400...0x4DBF,   // extension A
             0x4E00...0x9FFF,   // unified ideographs
             0xAC00...0xD7AF,   // hangul syllables
             0xF900...0xFAFF,   // compatibility ideographs
             0xFE30...0xFE4F,   // compatibility forms
             0xFF00...0xFFEF,   // fullwidth forms and punctuation
             0x20000...0x3134F: // extensions B and later
            return true
        default:
            return false
        }
    }
}

/// Live recognizer output: settled segments plus the tentative tail, which
/// each new hypothesis replaces.
public struct DictationTranscript: Equatable, Sendable {
    public private(set) var finalized = ""
    public private(set) var tentative = ""

    public init() {}

    public var text: String { DictationText.join(finalized, tentative) }

    public mutating func apply(_ segment: String, isFinal: Bool) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            finalized = DictationText.join(finalized, trimmed)
            tentative = ""
        } else {
            tentative = trimmed
        }
    }
}

// MARK: - Locale

/// Which language to dictate in.
public enum DictationLocale {
    public static let fallbacks = ["zh-CN", "en-US"]
    /// Regions where English as the first language usually means an English
    /// interface on a Chinese speaker's device.
    static let chineseRegions: Set<String> = ["CN", "HK", "TW", "MO", "SG"]

    /// Languages to try, best first. A language chosen in 设置 → 语音
    /// (`AppSettings.dictationLocale`) is the only one. Otherwise each
    /// preferred language with its own region, then with the language's
    /// usual region, then zh-CN and en-US; duplicates are dropped. When the
    /// first preferred language is English for a Chinese-speaking region
    /// (en-CN, en-HK, en-TW, en-MO, en-SG) and a Chinese one is also
    /// preferred, the Chinese one goes first: that English is the interface,
    /// not what the user speaks.
    public static func candidates(preferredLanguages: [String], chosen: String = "") -> [String] {
        let chosen = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosen.isEmpty { return [chosen] }
        var preferred = preferredLanguages
        if let first = preferred.first.map(Locale.Language.init(identifier:)),
           first.languageCode?.identifier == "en",
           let region = first.region?.identifier, chineseRegions.contains(region),
           let chinese = preferred.firstIndex(where: { Locale.Language(identifier: $0).languageCode?.identifier == "zh" }) {
            preferred.insert(preferred.remove(at: chinese), at: 0)
        }
        var result: [String] = []
        func add(_ identifier: String) {
            if !result.contains(identifier) { result.append(identifier) }
        }
        for entry in preferred {
            let language = Locale.Language(identifier: entry)
            guard let code = language.languageCode?.identifier else { continue }
            if let region = language.region?.identifier {
                add("\(code)-\(region)")
            }
            // zh-Hant's usual region is TW, zh-Hans's is CN, en's is US.
            let bare = language.script.map { "\(code)-\($0.identifier)" } ?? code
            if let region = Locale.Language(identifier: Locale.Language(identifier: bare).maximalIdentifier).region?.identifier {
                add("\(code)-\(region)")
            }
        }
        fallbacks.forEach(add)
        return result
    }

    /// The 听写语言 menu: zh-CN and en-US always, then the other languages
    /// the device reports, sorted; duplicates dropped.
    public static func menu(_ available: [String]) -> [String] {
        var result = fallbacks
        for identifier in available.sorted() where !identifier.isEmpty && !result.contains(identifier) {
            result.append(identifier)
        }
        return result
    }

    /// What 跟随系统 dictates in: the first of `candidates` whose language
    /// has an on-device model among `available` (identifiers with `-` or
    /// `_`). Matched by language, since the recognizer serves a region it
    /// lacks with one it has (en-CN → en_US). Nil when none has a model.
    public static func automatic(_ candidates: [String], available: [String]) -> String? {
        let languages = Set(available.compactMap { Locale(identifier: $0).language.languageCode?.identifier })
        return candidates.first { candidate in
            Locale(identifier: candidate).language.languageCode.map { languages.contains($0.identifier) } ?? false
        }
    }

    /// The 跟随系统 entry of the 听写语言 menu, naming the language it picks
    /// here: 跟随系统（中文）. Plain 跟随系统 while `available` is unknown
    /// (empty) or no candidate has a model.
    public static func followSystemTitle(preferredLanguages: [String], available: [String]) -> String {
        guard let locale = automatic(candidates(preferredLanguages: preferredLanguages), available: available),
              let name = languageName(locale) else { return "跟随系统" }
        return "跟随系统（\(name)）"
    }

    /// The language in its own words, for the dictation bar: 中文, English.
    public static func languageName(_ identifier: String) -> String? {
        let locale = Locale(identifier: identifier)
        guard let code = locale.language.languageCode?.identifier else { return nil }
        return locale.localizedString(forLanguageCode: code)
    }

    /// The language and region in their own words, for the settings menu.
    public static func displayName(_ identifier: String) -> String {
        let name = Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
        return "\(name) (\(identifier))"
    }

    /// The entry of `available` with the candidate's language and region;
    /// identifiers may use `-` or `_`.
    public static func match(_ candidate: String, in available: [String]) -> String? {
        let wanted = Locale(identifier: candidate)
        return available.first { identifier in
            let locale = Locale(identifier: identifier)
            return locale.language.languageCode == wanted.language.languageCode
                && locale.region == wanted.region
        }
    }
}

// MARK: - Meter and clock

public enum DictationLevel {
    /// Meter height in 0...1 for a buffer's RMS amplitude: −50 dBFS and
    /// below reads silent, 0 dBFS full.
    public static func normalized(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 50) / 50))
    }

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

public enum DictationClock {
    /// `m:ss`, whole seconds rounded down.
    public static func label(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
