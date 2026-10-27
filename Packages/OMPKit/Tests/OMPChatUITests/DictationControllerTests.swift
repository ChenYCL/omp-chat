import XCTest
import AVFoundation
import OMPCore
@testable import OMPChatUI

/// A microphone that never touches audio hardware. `holdsMicrophone` is what
/// every exit path must leave false.
@MainActor
final class FakeDictationCapture: DictationAudioCapture {
    var onInterruption: (@MainActor () -> Void)?
    var authorizeError: DictationError?
    var startError: DictationError?
    /// Holds `authorize` (the permission prompt) until released.
    var authorizeGate: TestGate?
    private(set) var authorizeCount = 0
    private(set) var startCount = 0
    private(set) var isPrepared = false
    private(set) var isRunning = false
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    var holdsMicrophone: Bool { isPrepared || isRunning }

    func authorize() async throws {
        authorizeCount += 1
        if let gate = authorizeGate {
            while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
        }
        if let authorizeError { throw authorizeError }
    }

    func prepare() throws -> AVAudioFormat {
        isPrepared = true
        return format
    }

    func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        if let startError { throw startError }
        startCount += 1
        isRunning = true
        self.sink = sink
    }

    func stop() {
        isPrepared = false
        isRunning = false
        sink = nil
    }

    /// Delivers a tenth of a second of a 440 Hz tone, as the input tap would.
    func speak(amplitude: Float = 0.5) {
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            samples[index] = amplitude * sin(2 * .pi * 440 * Float(index) / Float(format.sampleRate))
        }
        sink?(buffer)
    }
}

final class AppendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}

/// A recognizer scripted by the test. Never loads a speech model.
@MainActor
final class FakeDictationRecognizer: DictationRecognizer {
    var prepareError: DictationError?
    var beginError: DictationError?
    var finalText = "你好世界"
    var finishError: Error?
    /// Holds `finish` until released; never released means it never answers.
    var finishGate: TestGate?
    var fileText = "录音里的话"
    var downloadsModel = false
    /// Holds `prepare` after a download began, until released.
    var prepareGate: TestGate?
    private(set) var candidates: [[String]] = []
    private(set) var cancelCount = 0
    private(set) var finishCount = 0
    private(set) var transcribedFiles: [URL] = []
    private var report: (@MainActor (DictationEvent) -> Void)?
    nonisolated let appended = AppendCounter()

    func prepare(candidates: [String], downloading: @escaping @MainActor () -> Void) async throws -> String {
        self.candidates.append(candidates)
        if downloadsModel { downloading() }
        if let gate = prepareGate {
            while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
        }
        if let prepareError { throw prepareError }
        return candidates.first ?? "zh-CN"
    }

    func begin(format: AVAudioFormat, report: @escaping @MainActor (DictationEvent) -> Void) async throws {
        if let beginError { throw beginError }
        self.report = report
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        appended.add()
    }

    func finish() async throws -> String {
        finishCount += 1
        if let gate = finishGate {
            while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
        }
        if let finishError { throw finishError }
        return finalText
    }

    func transcribe(fileURL: URL, report: @escaping @MainActor (DictationEvent) -> Void) async throws -> String {
        transcribedFiles.append(fileURL)
        report(.partial("录音"))
        if let finishError { throw finishError }
        return fileText
    }

    func cancel() {
        cancelCount += 1
    }

    /// What the live engine says mid-session: a hypothesis, or a failure.
    func hear(_ text: String) { report?(.partial(text)) }
    func breakDown(_ error: DictationError) { report?(.fail(error)) }
}

@MainActor
enum DictationHarness {
    static func controller(
        _ capture: FakeDictationCapture,
        _ recognizer: FakeDictationRecognizer,
        maxDuration: TimeInterval = 120,
        finishTimeout: Duration = .seconds(5),
        recordings: URL? = nil
    ) -> DictationController {
        DictationController(
            maxDuration: maxDuration,
            finishTimeout: finishTimeout,
            preferredLanguages: { ["zh-Hans-CN"] },
            recordingDirectory: recordings,
            makeCapture: { capture },
            makeRecognizer: { recognizer }
        )
    }

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func recordings(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(DictationRecordingWriter.namePrefix) }
    }
}

/// The controller over a fake microphone and recognizer: the microphone is
/// released on every way out, and the text arrives exactly once.
@MainActor
final class DictationControllerTests: XCTestCase {
    private func listening(_ controller: DictationController) async throws {
        controller.start()
        try await FollowUpHarness.waitUntil { controller.state.isListening }
    }

    func testStopSettlesTheTextAndReleasesTheMicrophone() async throws {
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        let controller = DictationHarness.controller(capture, recognizer)
        var delivered: [String] = []
        controller.onTranscript = { delivered.append($0) }

        try await listening(controller)
        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(controller.localeIdentifier, "zh-CN")
        XCTAssertEqual(recognizer.candidates.first, ["zh-CN", "en-US"], "首选语言，再中文、英文")
        capture.speak()
        recognizer.hear("你好")
        XCTAssertEqual(controller.state, .listening(elapsed: 0, partial: "你好"))
        XCTAssertGreaterThan(recognizer.appended.value, 0, "麦克风的音频喂给了识别器")

        controller.stop()
        XCTAssertFalse(capture.holdsMicrophone, "停止的瞬间就放开麦克风")
        try await FollowUpHarness.waitUntil { controller.state == .done("你好世界") }
        XCTAssertEqual(delivered, ["你好世界"])
        XCTAssertEqual(recognizer.finishCount, 1)
        XCTAssertFalse(controller.isEngaged)
    }

    func testCancelWhileStartingNeverOpensTheMicrophone() async throws {
        let capture = FakeDictationCapture()
        let gate = TestGate()
        capture.authorizeGate = gate
        let recognizer = FakeDictationRecognizer()
        let controller = DictationHarness.controller(capture, recognizer)
        var delivered: [String] = []
        controller.onTranscript = { delivered.append($0) }

        controller.start()
        try await FollowUpHarness.waitUntil { capture.authorizeCount == 1 }
        XCTAssertEqual(controller.state, .starting)
        controller.cancel()
        XCTAssertEqual(controller.state, .cancelled)
        gate.release()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(capture.startCount, 0, "权限回来时会话已取消，不再开麦克风")
        XCTAssertFalse(capture.holdsMicrophone)
        XCTAssertGreaterThan(recognizer.cancelCount, 0)
        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testCancelWhileListeningDropsEverything() async throws {
        let folder = try DictationHarness.temporaryFolder()
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        let controller = DictationHarness.controller(capture, recognizer, recordings: folder)
        var delivered: [String] = []
        controller.onTranscript = { delivered.append($0) }

        try await listening(controller)
        capture.speak()
        recognizer.hear("不要了")
        XCTAssertEqual(DictationHarness.recordings(in: folder).count, 1)
        controller.cancel()

        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertFalse(capture.holdsMicrophone)
        XCTAssertEqual(recognizer.finishCount, 0)
        XCTAssertGreaterThan(recognizer.cancelCount, 0)
        XCTAssertTrue(DictationHarness.recordings(in: folder).isEmpty, "取消后录音文件删掉")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(delivered.isEmpty)
    }

    func testStopWithNothingSaidIsAudioTooShort() async throws {
        for silence in ["", "。"] {
            let capture = FakeDictationCapture()
            let recognizer = FakeDictationRecognizer()
            recognizer.finalText = silence
            let controller = DictationHarness.controller(capture, recognizer)
            var delivered: [String] = []
            controller.onTranscript = { delivered.append($0) }

            try await listening(controller)
            controller.stop()
            try await FollowUpHarness.waitUntil { controller.state == .failed(.audioTooShort, partial: "") }
            XCTAssertFalse(capture.holdsMicrophone)
            XCTAssertTrue(delivered.isEmpty)
            XCTAssertEqual(controller.state.recovery?.actions, [.retry, .dismiss])
        }
    }

    func testUnsupportedLanguageFailsBeforeAskingForTheMicrophone() async throws {
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        recognizer.prepareError = .unsupported
        let controller = DictationHarness.controller(capture, recognizer)

        controller.start()
        try await FollowUpHarness.waitUntil { controller.state == .failed(.unsupported, partial: "") }
        XCTAssertEqual(capture.authorizeCount, 0, "不支持的设备不弹麦克风权限")
        XCTAssertFalse(capture.holdsMicrophone)
    }

    func testDeniedMicrophoneFailsWithoutOpeningIt() async throws {
        let capture = FakeDictationCapture()
        capture.authorizeError = .microphonePermissionDenied
        let recognizer = FakeDictationRecognizer()
        let controller = DictationHarness.controller(capture, recognizer)

        controller.start()
        try await FollowUpHarness.waitUntil { controller.state == .failed(.microphonePermissionDenied, partial: "") }
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertFalse(capture.holdsMicrophone)
        XCTAssertGreaterThan(recognizer.cancelCount, 0)
        XCTAssertTrue(controller.isEngaged, "失败留在作曲栏里，带着去设置的入口")
    }

    func testInputThatWillNotStartIsReleased() async throws {
        let capture = FakeDictationCapture()
        capture.startError = .microphoneBusy
        let recognizer = FakeDictationRecognizer()
        let controller = DictationHarness.controller(capture, recognizer)

        controller.start()
        try await FollowUpHarness.waitUntil { controller.state == .failed(.microphoneBusy, partial: "") }
        XCTAssertFalse(capture.holdsMicrophone, "打开过的输入在失败后释放")
        XCTAssertGreaterThan(recognizer.cancelCount, 0)
    }

    func testRecognizerThatWillNotStartReleasesThePreparedInput() async throws {
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        recognizer.beginError = .startFailed
        let controller = DictationHarness.controller(capture, recognizer)

        controller.start()
        try await FollowUpHarness.waitUntil { controller.state == .failed(.startFailed, partial: "") }
        XCTAssertFalse(capture.holdsMicrophone)
        XCTAssertEqual(capture.startCount, 0)
    }

    func testRecognizerBreakingMidSessionFailsAtOnceAndKeepsTheText() async throws {
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        let controller = DictationHarness.controller(capture, recognizer)

        try await listening(controller)
        recognizer.hear("说了一半")
        recognizer.breakDown(.transcriptionFailed)

        XCTAssertEqual(controller.state, .failed(.transcriptionFailed, partial: "说了一半"))
        XCTAssertFalse(capture.holdsMicrophone)
        XCTAssertEqual(controller.state.recovery?.text, "说了一半")
    }

    func testLengthCapStopsAndStillDeliversTheText() async throws {
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        let controller = DictationHarness.controller(capture, recognizer, maxDuration: 0.3)
        var delivered: [String] = []
        controller.onTranscript = { delivered.append($0) }

        try await listening(controller)
        try await FollowUpHarness.waitUntil(3) { controller.state == .done("你好世界") }
        XCTAssertTrue(controller.reachedMaxDuration)
        XCTAssertFalse(capture.holdsMicrophone)
        XCTAssertEqual(delivered, ["你好世界"])
    }

    func testInterruptionStopsAndKeepsTheText() async throws {
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        let controller = DictationHarness.controller(capture, recognizer)

        try await listening(controller)
        capture.onInterruption?()
        XCTAssertFalse(capture.holdsMicrophone, "系统收回麦克风时立即放手")
        try await FollowUpHarness.waitUntil { controller.state == .done("你好世界") }
    }

    func testARecognizerThatNeverAnswersTimesOut() async throws {
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        recognizer.finishGate = TestGate()
        let controller = DictationHarness.controller(capture, recognizer, finishTimeout: .milliseconds(100))

        try await listening(controller)
        recognizer.hear("卡住")
        controller.stop()
        try await FollowUpHarness.waitUntil { controller.state == .failed(.transcriptionFailed, partial: "卡住") }
        XCTAssertGreaterThan(recognizer.cancelCount, 0)
        XCTAssertFalse(capture.holdsMicrophone)
    }

    func testFailedTranscriptionKeepsTheAudioForRetryThenDeletesIt() async throws {
        let folder = try DictationHarness.temporaryFolder()
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        recognizer.finishError = DictationError.transcriptionFailed
        let controller = DictationHarness.controller(capture, recognizer, recordings: folder)
        var delivered: [String] = []
        controller.onTranscript = { delivered.append($0) }

        try await listening(controller)
        capture.speak()
        controller.stop()
        try await FollowUpHarness.waitUntil { controller.state == .failed(.transcriptionFailed, partial: "") }
        XCTAssertTrue(controller.canRetranscribe)
        let kept = DictationHarness.recordings(in: folder)
        XCTAssertEqual(kept.count, 1, "失败的录音留着重试")

        recognizer.finishError = nil
        XCTAssertTrue(controller.retranscribe())
        XCTAssertEqual(controller.state, .transcribing(partial: ""))
        try await FollowUpHarness.waitUntil { controller.state == .done("录音里的话") }
        XCTAssertEqual(recognizer.transcribedFiles.map(\.lastPathComponent), kept)
        XCTAssertEqual(recognizer.candidates.last, ["zh-CN"], "重试沿用原来的语言")
        XCTAssertEqual(delivered, ["录音里的话"])
        XCTAssertTrue(DictationHarness.recordings(in: folder).isEmpty, "转写成功后录音删掉")
        XCTAssertFalse(controller.canRetranscribe)
    }

    func testDismissDeletesKeptAudio() async throws {
        let folder = try DictationHarness.temporaryFolder()
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        recognizer.finishError = DictationError.transcriptionFailed
        let controller = DictationHarness.controller(capture, recognizer, recordings: folder)

        try await listening(controller)
        capture.speak()
        controller.stop()
        try await FollowUpHarness.waitUntil { controller.canRetranscribe }
        controller.dismiss()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(DictationHarness.recordings(in: folder).isEmpty)
        XCTAssertFalse(controller.retranscribe(), "关闭后没有可重试的录音")
    }

    func testLeftoverRecordingsFromAnEarlierRunAreRemoved() async throws {
        let folder = try DictationHarness.temporaryFolder()
        let leftover = folder.appendingPathComponent("\(DictationRecordingWriter.namePrefix)old.caf")
        let unrelated = folder.appendingPathComponent("keep.caf")
        try Data([1]).write(to: leftover)
        try Data([1]).write(to: unrelated)
        let controller = DictationHarness.controller(FakeDictationCapture(), FakeDictationRecognizer(), recordings: folder)

        try await listening(controller)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        controller.cancel()
    }

    func testFileTranscriptionUsesTheGivenLanguageAndLeavesTheFile() async throws {
        let folder = try DictationHarness.temporaryFolder()
        let file = folder.appendingPathComponent("say.aiff")
        try Data([0]).write(to: file)
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        let controller = DictationHarness.controller(capture, recognizer)
        var delivered: [String] = []
        controller.onTranscript = { delivered.append($0) }

        let error = await controller.transcribe(fileURL: file, localeIdentifier: "en-US")
        XCTAssertNil(error)
        XCTAssertEqual(recognizer.candidates, [["en-US"]])
        XCTAssertEqual(controller.state, .done("录音里的话"))
        XCTAssertEqual(delivered, ["录音里的话"])
        XCTAssertEqual(capture.authorizeCount, 0, "转写文件不碰麦克风")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "别人的录音文件不删")
    }

    func testFileTranscriptionFailureIsReturnedAndCanBeRetried() async throws {
        let file = try DictationHarness.temporaryFolder().appendingPathComponent("say.aiff")
        try Data([0]).write(to: file)
        let recognizer = FakeDictationRecognizer()
        recognizer.finishError = DictationError.transcriptionFailed
        let controller = DictationHarness.controller(FakeDictationCapture(), recognizer)

        let error = await controller.transcribe(fileURL: file)
        XCTAssertEqual(error, .transcriptionFailed)
        XCTAssertEqual(controller.state, .failed(.transcriptionFailed, partial: "录音"))
        XCTAssertTrue(controller.canRetranscribe)
        recognizer.finishError = nil
        XCTAssertTrue(controller.retranscribe())
        try await FollowUpHarness.waitUntil { controller.state == .done("录音里的话") }
        XCTAssertEqual(recognizer.transcribedFiles, [file, file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFileTranscriptionIsRefusedWhileListening() async throws {
        let capture = FakeDictationCapture()
        let controller = DictationHarness.controller(capture, FakeDictationRecognizer())
        try await listening(controller)

        let error = await controller.transcribe(fileURL: URL(fileURLWithPath: "/tmp/none.aiff"))
        XCTAssertEqual(error, .startFailed)
        XCTAssertTrue(controller.state.isListening, "正在听写的会话不受影响")
        XCTAssertTrue(capture.isRunning)
        controller.cancel()
    }

    func testMeterFollowsTheInputAndClearsWhenTheMicrophoneCloses() async throws {
        let capture = FakeDictationCapture()
        let controller = DictationHarness.controller(capture, FakeDictationRecognizer())
        try await listening(controller)

        capture.speak(amplitude: 0.5)
        try await FollowUpHarness.waitUntil { !controller.levels.isEmpty }
        XCTAssertEqual(controller.levels.last ?? 0, 0.82, accuracy: 0.02, "0.5 振幅正弦 ≈ −9 dBFS")
        controller.stop()
        XCTAssertTrue(controller.levels.isEmpty)
    }

    func testModelDownloadShowsWhileStartingAndClearsOnCancel() async throws {
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        recognizer.downloadsModel = true
        let gate = TestGate()
        recognizer.prepareGate = gate
        let controller = DictationHarness.controller(capture, recognizer)

        controller.start()
        try await FollowUpHarness.waitUntil { controller.isDownloadingModel }
        XCTAssertEqual(controller.state, .starting, "下载模型属于「正在开始听写」")
        XCTAssertEqual(capture.authorizeCount, 0, "模型就绪前不弹麦克风权限")
        controller.cancel()
        XCTAssertFalse(controller.isDownloadingModel)
        gate.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.authorizeCount, 0)
        XCTAssertEqual(controller.state, .cancelled)
    }
}
