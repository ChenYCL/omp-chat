// Dictation engine: decision and evidence (2026-10-27, Xcode 26.5 SDK, macOS 26.7).
//
// Audio never leaves the device.
//
// - macOS 26 / iOS 26 and later: SpeechAnalyzer + DictationTranscriber
//   (preset .progressiveLongDictation: volatile results plus punctuation).
//   Apple, "Asking Permission to Use Speech Recognition": the Speech
//   Recognition permission "only applies to speech recognition using
//   SFSpeechRecognizer. SpeechAnalyzer transcriber modules don't send audio
//   data of the user's voice to Apple's servers." Checked here with a command
//   line probe whose SFSpeechRecognizer.authorizationStatus() was
//   .notDetermined: DictationTranscriber transcribed `say -o` files in en-US
//   ("Hello world this is a dictation test") and zh-CN ("你好，这是一次听写测试")
//   with no prompt and no download. So this path asks for the microphone only.
//   DictationTranscriber.installedLocales here were en_US and zh_CN (the
//   system dictation models) while SpeechTranscriber had English only, which
//   is why the short-form dictation module is used: it covers Chinese without
//   a download. AssetInventory.status says .supported, not .installed, for
//   those installed-but-unreserved locales, so an installed locale skips the
//   asset request. A locale that is supported but not installed downloads its
//   model through AssetInventory (a model comes in, no audio goes out) while
//   the composer says 正在下载听写模型…; no supported locale → 这台设备不支持听写.
// - macOS 15 / iOS 18 (no SpeechAnalyzer): SFSpeechRecognizer with
//   requiresOnDeviceRecognition = true. That needs the Speech Recognition
//   permission (NSSpeechRecognitionUsageDescription is required even on
//   device) besides the microphone. A language whose recognizer has
//   supportsOnDeviceRecognition false is skipped like a missing one, and a
//   session with no on-device language left is unsupported instead of
//   falling back to Apple's servers (probe: zh-CN and en-US true, ja-JP
//   false).
// - Language: 设置 → 语音 → 听写语言 (AppSettings.dictationLocale) when chosen;
//   otherwise the first of the user's preferred languages the recognizer
//   serves, then zh-CN, then en-US (DictationLocale.candidates). The probe
//   Mac prefers [en-CN, zh-Hans-CN] and DictationTranscriber maps en-CN to
//   en_US, so English set for a Chinese-speaking region yields to a preferred
//   Chinese entry; this Mac dictates zh-CN by default.
// - Microphone: an AVAudioEngine input tap. The sandboxed macOS app needs the
//   com.apple.security.device.audio-input entitlement and
//   NSMicrophoneUsageDescription. iOS activates an AVAudioSession (.record)
//   and restores the previous category afterwards so read-aloud still plays.
// - Detection: no input device (AVCaptureDevice.default(for: .audio) nil, iOS
//   isInputAvailable false, or a zero-channel input format) → microphoneMissing;
//   permission denied or restricted → microphonePermissionDenied; another app
//   holding the input (OSStatus '!hog', '!pri', '!int', '!rec', '!act',
//   'siri' from session activation or engine start) → microphoneBusy; speech
//   permission denied (legacy path) → speechPermissionDenied; no on-device
//   model → unsupported. SFSpeechRecognitionTask errors follow Apple's table on
//   SFSpeechRecognitionTask.error (kAFAssistantErrorDomain 1110 "Failed to
//   recognize any speech" → audioTooShort).

import Foundation
import AVFoundation
import Speech
import Observation
import OMPCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Seams

/// Microphone capture behind dictation; one instance per session.
@MainActor
protocol DictationAudioCapture: AnyObject {
    /// Called when the system takes the input away: the device went, the
    /// route changed, an interruption began, or (iOS) the app went to the
    /// background.
    var onInterruption: (@MainActor () -> Void)? { get set }
    /// Checks there is an input device, then asks for microphone permission;
    /// the system prompt appears here the first time. Throws `DictationError`.
    func authorize() async throws
    /// Opens the input and returns the format its buffers come in. Throws
    /// `DictationError`.
    func prepare() throws -> AVAudioFormat
    /// Starts delivering buffers to `sink` on an audio thread. Throws
    /// `DictationError`.
    func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    /// Releases the input. Safe to call more than once and before `start`.
    func stop()
}

/// The speech recognizer behind dictation; one instance per session.
@MainActor
protocol DictationRecognizer: AnyObject {
    /// Picks the first candidate language this device recognises on device,
    /// makes sure it may run (permission, model) and returns it as a BCP-47
    /// identifier. `downloading` is called before a model download. Throws
    /// `DictationError`.
    func prepare(candidates: [String], downloading: @escaping @MainActor () -> Void) async throws -> String
    /// Opens a live session for buffers in `format`. `report` receives
    /// `.partial` text, and `.final` / `.fail` if recognition ends on its own.
    func begin(format: AVAudioFormat, report: @escaping @MainActor (DictationEvent) -> Void) async throws
    /// Feeds captured audio; called on an audio thread.
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    /// Ends the input and returns the whole text.
    func finish() async throws -> String
    /// Transcribes a recording in the prepared language; `report` receives
    /// `.partial` text.
    func transcribe(fileURL: URL, report: @escaping @MainActor (DictationEvent) -> Void) async throws -> String
    /// Drops the session. Safe to call more than once and after `finish`.
    func cancel()
}

// MARK: - Controller

/// Composer dictation (Codex `composer.dictation.*`): runs one session at a
/// time and drives `DictationMachine` from the microphone and the
/// recognizer. Every way out — stop, cancel, a failure, the length cap, an
/// interruption — releases the microphone.
@MainActor
@Observable
public final class DictationController {
    public private(set) var state: DictationState = .idle
    /// Active or failed, i.e. the composer shows the dictation bar. Changes
    /// only when that does, so the composer does not redraw on every tick.
    public private(set) var isEngaged = false
    /// Recent input levels in 0...1, newest last, for the meter.
    public private(set) var levels: [Float] = []
    /// The language's model is downloading before listening can start.
    public private(set) var isDownloadingModel = false
    /// Language of the current or last session (BCP-47, e.g. zh-CN).
    public private(set) var localeIdentifier: String?
    /// The audio of the failed transcription is kept, so 重试 can transcribe
    /// it again.
    public private(set) var canRetranscribe = false
    /// The last session stopped because it reached the length cap.
    public private(set) var reachedMaxDuration = false
    /// Receives the text each time a session ends in `.done`.
    @ObservationIgnored public var onTranscript: ((String) -> Void)?
    /// The language chosen in 设置 → 语音 (`AppSettings.dictationLocale`);
    /// empty follows the system's preferred languages.
    @ObservationIgnored public var chosenLocale = ""

    static let meterBars = 24

    @ObservationIgnored private var machine: DictationMachine
    @ObservationIgnored private let finishTimeout: Duration
    @ObservationIgnored private let preferredLanguages: () -> [String]
    @ObservationIgnored private let recordingDirectory: URL?
    @ObservationIgnored private let makeCapture: @MainActor () -> any DictationAudioCapture
    @ObservationIgnored private let makeRecognizer: @MainActor () -> any DictationRecognizer
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var capture: (any DictationAudioCapture)?
    @ObservationIgnored private var recognizer: (any DictationRecognizer)?
    @ObservationIgnored private var writer: DictationRecordingWriter?
    /// Audio of the current or last session; deleted when we wrote it.
    @ObservationIgnored private var recording: URL?
    @ObservationIgnored private var ownsRecording = false
    @ObservationIgnored private var purgedLeftovers = false
    @ObservationIgnored private var listeningSince: ContinuousClock.Instant?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?

    /// The real microphone and the newest on-device recognizer.
    public convenience init() {
        self.init(makeCapture: { EngineAudioCapture() }, makeRecognizer: DictationEngines.makeRecognizer)
    }

    /// Tests pass fakes, a short cap and their own recording folder; a nil
    /// folder keeps no audio.
    init(
        maxDuration: TimeInterval = DictationMachine.defaultMaxDuration,
        finishTimeout: Duration = .seconds(20),
        preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
        recordingDirectory: URL? = FileManager.default.temporaryDirectory,
        makeCapture: @escaping @MainActor () -> any DictationAudioCapture,
        makeRecognizer: @escaping @MainActor () -> any DictationRecognizer
    ) {
        machine = DictationMachine(maxDuration: maxDuration)
        self.finishTimeout = finishTimeout
        self.preferredLanguages = preferredLanguages
        self.recordingDirectory = recordingDirectory
        self.makeCapture = makeCapture
        self.makeRecognizer = makeRecognizer
    }

    // MARK: Session control

    /// 听写: asks for what it needs, then listens.
    public func start() {
        guard !state.isActive else { return }
        purgeLeftoverRecordings()
        discardRecording()
        session += 1
        let current = session
        localeIdentifier = nil
        apply(.start)
        let capture = makeCapture()
        let recognizer = makeRecognizer()
        self.capture = capture
        self.recognizer = recognizer
        capture.onInterruption = { [weak self] in self?.interrupted(session: current) }
        work = Task { [weak self] in
            await self?.listen(session: current, capture: capture, recognizer: recognizer)
        }
    }

    /// 停止 (Codex "Stop dictation"): closes the microphone and settles the
    /// text, which then goes to `onTranscript`. While starting, cancels.
    public func stop() {
        if state.isListening, let since = listeningSince {
            apply(.tick(Self.seconds(since: since)))
        }
        apply(.stop)
    }

    /// 取消: drops the session and everything heard.
    public func cancel() {
        apply(.cancel)
    }

    /// Closes a finished, failed or cancelled dictation, dropping kept audio.
    public func dismiss() {
        apply(.dismiss)
        discardRecording()
    }

    /// 重试 on a failed transcription: transcribes the kept audio again.
    /// Returns false when there is none.
    @discardableResult
    public func retranscribe() -> Bool {
        guard case .failed = state, canRetranscribe, let recording, let locale = localeIdentifier else { return false }
        let current = beginTranscription()
        Task { await runTranscription(recording, candidates: [locale], session: current) }
        return true
    }

    /// Transcribes a recording with the same recognizer and error mapping as
    /// live dictation; the text goes to `onTranscript`. `localeIdentifier`
    /// overrides the language choice. Returns the failure, nil on success or
    /// cancel; refused while a session is active.
    public func transcribe(fileURL: URL, localeIdentifier: String? = nil) async -> DictationError? {
        guard !state.isActive else { return .startFailed }
        discardRecording()
        recording = fileURL
        let candidates = localeIdentifier.map { [$0] } ?? languageCandidates()
        let current = beginTranscription()
        await runTranscription(fileURL, candidates: candidates, session: current)
        guard session == current, case .failed(let error, _) = state else { return nil }
        return error
    }

    // MARK: Lifecycle

    private func listen(session current: Int, capture: any DictationAudioCapture, recognizer: any DictationRecognizer) async {
        do {
            let locale = try await recognizer.prepare(
                candidates: languageCandidates(),
                downloading: { [weak self] in self?.modelDownloadStarted(session: current) }
            )
            guard isStarting(current) else { return }
            localeIdentifier = locale
            isDownloadingModel = false
            try await capture.authorize()
            guard isStarting(current) else { return }
            let format = try capture.prepare()
            try await recognizer.begin(format: format) { [weak self] event in
                self?.receive(event, session: current)
            }
            guard isStarting(current) else { return }
            let writer = recordingDirectory.flatMap { DictationRecordingWriter(directory: $0, format: format) }
            self.writer = writer
            if let writer {
                recording = writer.url
                ownsRecording = true
            }
            let meter = DictationLevelThrottle()
            try capture.start { [weak self] buffer in
                recognizer.append(buffer)
                writer?.write(buffer)
                guard let level = meter.level(for: buffer) else { return }
                Task { @MainActor in self?.pushLevel(level, session: current) }
            }
            listeningSince = .now
            receive(.ready, session: current)
            startTicker(session: current)
        } catch {
            receive(.fail(error as? DictationError ?? .startFailed), session: current)
        }
    }

    private func beginTranscription() -> Int {
        session += 1
        apply(.transcribeRecording)
        recognizer = makeRecognizer()
        return session
    }

    private func runTranscription(_ url: URL, candidates: [String], session current: Int) async {
        guard let recognizer else { return }
        do {
            let locale = try await recognizer.prepare(
                candidates: candidates,
                downloading: { [weak self] in self?.modelDownloadStarted(session: current) }
            )
            guard session == current, state.isActive else { return }
            localeIdentifier = locale
            isDownloadingModel = false
            let text = try await recognizer.transcribe(fileURL: url) { [weak self] event in
                self?.receive(event, session: current)
            }
            receive(.final(text), session: current)
        } catch {
            receive(.fail(error as? DictationError ?? .transcriptionFailed), session: current)
        }
    }

    /// The machine's answer to an event, carried out.
    private func apply(_ event: DictationEvent) {
        let effect = machine.handle(event)
        if state != machine.state { state = machine.state }
        let engaged: Bool
        if case .failed = machine.state { engaged = true } else { engaged = machine.state.isActive }
        if isEngaged != engaged { isEngaged = engaged }
        if reachedMaxDuration != machine.reachedMaxDuration { reachedMaxDuration = machine.reachedMaxDuration }
        switch effect {
        case .stopCapture?:
            releaseMicrophone()
            settleText()
        case .teardown?:
            teardown()
            if case .final = event, case .done(let text) = state { onTranscript?(text) }
        case nil:
            break
        }
    }

    /// Events from callbacks of an earlier session are dropped.
    private func receive(_ event: DictationEvent, session current: Int) {
        guard current == session else { return }
        apply(event)
    }

    private func isStarting(_ current: Int) -> Bool {
        current == session && state == .starting
    }

    private func languageCandidates() -> [String] {
        DictationLocale.candidates(preferredLanguages: preferredLanguages(), chosen: chosenLocale)
    }

    /// After the microphone closed: waits for the recognizer's last words,
    /// giving up after `finishTimeout` so the composer cannot hang.
    private func settleText() {
        guard let recognizer else {
            apply(.fail(.transcriptionFailed))
            return
        }
        let current = session
        let timeout = finishTimeout
        work = Task { [weak self] in
            do {
                let text = try await recognizer.finish()
                self?.receive(.final(text), session: current)
            } catch {
                self?.receive(.fail(error as? DictationError ?? .transcriptionFailed), session: current)
            }
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.receive(.fail(.transcriptionFailed), session: current)
        }
    }

    private func releaseMicrophone() {
        ticker?.cancel()
        ticker = nil
        capture?.stop()
        capture = nil
        writer?.close()
        writer = nil
        listeningSince = nil
        if !levels.isEmpty { levels = [] }
    }

    private func teardown() {
        releaseMicrophone()
        work?.cancel()
        work = nil
        deadline?.cancel()
        deadline = nil
        recognizer?.cancel()
        recognizer = nil
        if isDownloadingModel { isDownloadingModel = false }
        // The audio of a failed transcription stays for 重试.
        if case .failed(.transcriptionFailed, _) = state, recording != nil {
            canRetranscribe = true
        } else {
            discardRecording()
        }
    }

    private func discardRecording() {
        if let recording, ownsRecording {
            try? FileManager.default.removeItem(at: recording)
        }
        recording = nil
        ownsRecording = false
        if canRetranscribe { canRetranscribe = false }
    }

    /// Recordings a previous run left behind (the app quit on a failed
    /// transcription) are voice audio: removed before the first session.
    private func purgeLeftoverRecordings() {
        guard !purgedLeftovers, let directory = recordingDirectory else { return }
        purgedLeftovers = true
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(DictationRecordingWriter.namePrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func interrupted(session current: Int) {
        guard current == session else { return }
        switch state {
        case .listening: stop()
        case .starting: cancel()
        default: break
        }
    }

    private func modelDownloadStarted(session current: Int) {
        guard current == session, state.isActive else { return }
        isDownloadingModel = true
    }

    private func startTicker(session current: Int) {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.session == current, self.state.isListening, let since = self.listeningSince else { return }
                self.apply(.tick(Self.seconds(since: since)))
            }
        }
    }

    private func pushLevel(_ level: Float, session current: Int) {
        guard current == session, state.isListening else { return }
        var next = levels
        next.append(level)
        if next.count > Self.meterBars { next.removeFirst(next.count - Self.meterBars) }
        levels = next
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return TimeInterval(elapsed.components.seconds) + TimeInterval(elapsed.components.attoseconds) / 1e18
    }
}

// MARK: - Support

/// Turns tap buffers into meter levels, at most twenty a second.
final class DictationLevelThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: UInt64 = 0
    private static let interval: UInt64 = 50_000_000

    func level(for buffer: AVAudioPCMBuffer) -> Float? {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard now &- last >= Self.interval else { return nil }
        last = now
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        return DictationLevel.normalized(rms: DictationLevel.rms(samples))
    }
}

/// Keeps a session's audio in a temporary CAF file so a failed
/// transcription can be retried without speaking again.
final class DictationRecordingWriter: @unchecked Sendable {
    static let namePrefix = "ompchat-dictation-"

    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?

    init?(directory: URL, format: AVAudioFormat) {
        url = directory.appendingPathComponent("\(Self.namePrefix)\(UUID().uuidString).caf")
        guard let file = try? AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        ) else { return nil }
        self.file = file
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(from: buffer)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        file?.close()
        file = nil
    }
}

/// Opens the system settings page a dictation error points at.
enum DictationSystemSettings {
    @MainActor
    static func open(_ link: DictationSettingsLink) {
        #if os(macOS)
        NSWorkspace.shared.open(link.macOSURL)
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

enum DictationEngines {
    /// SpeechAnalyzer where the OS has it, else the on-device-only
    /// SFSpeechRecognizer.
    @MainActor
    static func makeRecognizer() -> any DictationRecognizer {
        if #available(macOS 26.0, iOS 26.0, *) {
            return AnalyzerDictationRecognizer()
        }
        return LegacyDictationRecognizer()
    }

    /// 设置 → 语音 → 听写语言: the languages with an on-device model and the
    /// 跟随系统 entry naming the one it picks here, e.g. 跟随系统（中文）.
    /// Off the main actor: the model catalog may take a while.
    nonisolated static func languageMenu() async -> (locales: [String], followSystem: String) {
        let locales = await onDeviceLocales()
        return (locales, DictationLocale.followSystemTitle(preferredLanguages: Locale.preferredLanguages, available: locales))
    }

    /// Languages this device can dictate in without uploading audio (BCP-47).
    private nonisolated static func onDeviceLocales() async -> [String] {
        if #available(macOS 26.0, iOS 26.0, *) {
            return await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        }
        return await Task.detached {
            SFSpeechRecognizer.supportedLocales()
                .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
                .map { $0.identifier(.bcp47) }
        }.value
    }
}

// MARK: - Microphone

/// AVAudioEngine input tap.
@MainActor
final class EngineAudioCapture: DictationAudioCapture {
    var onInterruption: (@MainActor () -> Void)?
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    #if os(iOS)
    private var savedSession: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?
    #endif

    func authorize() async throws {
        #if os(macOS)
        guard AVCaptureDevice.default(for: .audio) != nil else { throw DictationError.microphoneMissing }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw DictationError.microphonePermissionDenied }
        default:
            throw DictationError.microphonePermissionDenied
        }
        #else
        guard AVAudioSession.sharedInstance().isInputAvailable else { throw DictationError.microphoneMissing }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphonePermissionDenied }
        default:
            throw DictationError.microphonePermissionDenied
        }
        #endif
    }

    func prepare() throws -> AVAudioFormat {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        savedSession = (audioSession.category, audioSession.mode, audioSession.categoryOptions)
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            stop()
            throw DictationError.audioStartFailure(osStatus: (error as NSError).code)
        }
        #endif
        let engine = AVAudioEngine()
        self.engine = engine
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            throw DictationError.microphoneMissing
        }
        return format
    }

    func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard let engine else { throw DictationError.startFailed }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
            sink(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw DictationError.audioStartFailure(osStatus: (error as NSError).code)
        }
        observeInterruptions(of: engine)
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        #if os(iOS)
        if let saved = savedSession {
            savedSession = nil
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            try? audioSession.setCategory(saved.category, mode: saved.mode, options: saved.options)
        }
        #endif
    }

    private func observeInterruptions(of engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onInterruption?() }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.onInterruption?() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onInterruption?() }
        })
        #endif
    }
}

// MARK: - Recognizers

/// macOS 26 / iOS 26: SpeechAnalyzer with the on-device dictation model.
@available(macOS 26.0, iOS 26.0, *)
@MainActor
final class AnalyzerDictationRecognizer: DictationRecognizer {
    private var locale: Locale?
    private var analyzer: SpeechAnalyzer?
    private var results: Task<String, Error>?
    private nonisolated let feed = AnalyzerFeed()

    private static func module(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    }

    func prepare(candidates: [String], downloading: @escaping @MainActor () -> Void) async throws -> String {
        let installed = await DictationTranscriber.installedLocales.map(\.identifier)
        var chosen: Locale?
        var isInstalled = false
        for candidate in candidates {
            if let match = DictationLocale.match(candidate, in: installed) {
                chosen = Locale(identifier: match)
                isInstalled = true
                break
            }
            if let supported = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: candidate)) {
                chosen = supported
                break
            }
        }
        guard let chosen else { throw DictationError.unsupported }
        if !isInstalled {
            let module = Self.module(chosen)
            switch await AssetInventory.status(forModules: [module]) {
            case .unsupported:
                throw DictationError.unsupported
            case .installed:
                break
            default:
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                        downloading()
                        try await request.downloadAndInstall()
                    }
                } catch {
                    throw DictationError.startFailed
                }
            }
        }
        locale = chosen
        return chosen.identifier(.bcp47)
    }

    func begin(format: AVAudioFormat, report: @escaping @MainActor (DictationEvent) -> Void) async throws {
        guard let locale else { throw DictationError.startFailed }
        let module = Self.module(locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: format),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw DictationError.startFailed
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        feed.open(input, converter: converter, format: target)
        self.analyzer = analyzer
        results = Task { try await Self.collect(module, report: report, live: true) }
        do {
            try await analyzer.prepareToAnalyze(in: target)
            try await analyzer.start(inputSequence: stream)
        } catch {
            throw DictationError.startFailed
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        feed.append(buffer)
    }

    func finish() async throws -> String {
        feed.end()
        guard let analyzer, let results else { throw DictationError.transcriptionFailed }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value
        } catch {
            results.cancel()
            throw error as? DictationError ?? .transcriptionFailed
        }
    }

    func transcribe(fileURL: URL, report: @escaping @MainActor (DictationEvent) -> Void) async throws -> String {
        guard let locale else { throw DictationError.startFailed }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw DictationError.transcriptionFailed
        }
        let module = Self.module(locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        let results = Task { try await Self.collect(module, report: report, live: false) }
        self.results = results
        do {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            return try await results.value
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error as? DictationError ?? .transcriptionFailed
        }
    }

    func cancel() {
        feed.end()
        results?.cancel()
        results = nil
        if let analyzer {
            self.analyzer = nil
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Reads the module's results to the end. A live session that breaks
    /// tells the controller at once rather than at 停止.
    private static func collect(
        _ module: DictationTranscriber,
        report: @escaping @MainActor (DictationEvent) -> Void,
        live: Bool
    ) async throws -> String {
        var transcript = DictationTranscript()
        do {
            for try await result in module.results {
                transcript.apply(String(result.text.characters), isFinal: result.isFinal)
                report(.partial(transcript.text))
            }
        } catch {
            if live, !(error is CancellationError) { report(.fail(.transcriptionFailed)) }
            throw error
        }
        return transcript.text
    }
}

/// The analyzer's input stream, fed from the audio thread: each tap buffer
/// converted to the format the model wants.
@available(macOS 26.0, iOS 26.0, *)
final class AnalyzerFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?

    func open(_ input: AsyncStream<AnalyzerInput>.Continuation, converter: AVAudioConverter, format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        self.input = input
        self.converter = converter
        self.format = format
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let input, let converter, let format else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: output))
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        input?.finish()
        input = nil
        converter = nil
        format = nil
    }
}

/// macOS 15 / iOS 18: SFSpeechRecognizer, on device only.
@MainActor
final class LegacyDictationRecognizer: DictationRecognizer {
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var report: (@MainActor (DictationEvent) -> Void)?
    private var waiter: CheckedContinuation<String, Error>?
    private var outcome: Result<String, Error>?
    /// The caller is waiting for the end (finish or a file), so an ending is
    /// an answer rather than news for the live session.
    private var ending = false
    private nonisolated let feed = LegacyFeed()

    func prepare(candidates: [String], downloading: @escaping @MainActor () -> Void) async throws -> String {
        // The first language recognised on device, as the analyzer path
        // picks; one only Apple's servers know is skipped, never a reason to
        // upload.
        guard let chosen = candidates.lazy.compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) })
            .first(where: \.supportsOnDeviceRecognition) else {
            throw DictationError.unsupported
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw DictationError.speechPermissionDenied }
        default:
            throw DictationError.speechPermissionDenied
        }
        guard chosen.isAvailable else { throw DictationError.startFailed }
        chosen.queue = .main
        recognizer = chosen
        return chosen.locale.identifier(.bcp47)
    }

    func begin(format: AVAudioFormat, report: @escaping @MainActor (DictationEvent) -> Void) async throws {
        guard let recognizer else { throw DictationError.startFailed }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        feed.open(request)
        start(request, with: recognizer, report: report)
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        feed.append(buffer)
    }

    func finish() async throws -> String {
        ending = true
        feed.end()
        return try await answer()
    }

    func transcribe(fileURL: URL, report: @escaping @MainActor (DictationEvent) -> Void) async throws -> String {
        guard let recognizer else { throw DictationError.startFailed }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        ending = true
        start(request, with: recognizer, report: report)
        return try await answer()
    }

    func cancel() {
        ending = true
        task?.cancel()
        task = nil
        feed.end()
        settle(.failure(CancellationError()))
    }

    private func start(_ request: SFSpeechRecognitionRequest, with recognizer: SFSpeechRecognizer, report: @escaping @MainActor (DictationEvent) -> Void) {
        self.report = report
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Delivered on `recognizer.queue`, set to main in prepare.
            MainActor.assumeIsolated { self?.handle(result, error) }
        }
    }

    private func handle(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                settle(.success(text))
                return
            }
            report?(.partial(text))
        }
        if let error {
            let failure = error as NSError
            if DictationError.isCancellation(domain: failure.domain, code: failure.code) {
                settle(.failure(CancellationError()))
            } else {
                settle(.failure(DictationError.recognitionFailure(domain: failure.domain, code: failure.code)))
            }
        }
    }

    private func answer() async throws -> String {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    private func settle(_ result: Result<String, Error>) {
        if let waiter {
            self.waiter = nil
            outcome = result
            waiter.resume(with: result)
            return
        }
        guard outcome == nil else { return }
        outcome = result
        guard !ending else { return }
        // Ended on its own while the microphone is still open.
        switch result {
        case .success(let text): report?(.final(text))
        case .failure(let error as DictationError): report?(.fail(error))
        case .failure: break
        }
    }
}

/// The live request, fed from the audio thread.
final class LegacyFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func open(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = nil
    }
}
