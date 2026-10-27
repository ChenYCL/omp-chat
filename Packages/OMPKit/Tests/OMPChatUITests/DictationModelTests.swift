import XCTest
import OMPCore
@testable import OMPChatUI

/// Dictation as the composer uses it: where the text lands, 转写并发送, a
/// conversation switch mid-sentence, and the recovery actions.
@MainActor
final class DictationModelTests: XCTestCase {
    private func makeModel() async -> ChatAppModel {
        let model = ChatAppModel(
            store: InMemoryConversationStore(),
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: FileManager.default.temporaryDirectory),
            transport: URLSessionTransport()
        )
        await model.bootstrap()
        return model
    }

    @discardableResult
    private func useFakes(
        _ model: ChatAppModel, maxDuration: TimeInterval = 120, recordings: URL? = nil
    ) -> (FakeDictationCapture, FakeDictationRecognizer) {
        let capture = FakeDictationCapture()
        let recognizer = FakeDictationRecognizer()
        model.dictation = DictationHarness.controller(capture, recognizer, maxDuration: maxDuration, recordings: recordings)
        return (capture, recognizer)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        try await FollowUpHarness.waitUntil(5, condition)
    }

    func testTextLandsAfterWhatWasTypedWhileListening() async throws {
        let model = await makeModel()
        useFakes(model)
        model.draft = "开头"

        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        XCTAssertTrue(model.showsDictationBar)
        model.draft = "开头，再补一句"
        model.stopDictation(send: false)
        try await waitUntil { model.dictationState == .done("你好世界") }

        XCTAssertEqual(model.draft, "开头，再补一句你好世界", "接在听写期间打的字后面，不覆盖")
        XCTAssertFalse(model.showsDictationBar)
    }

    func testTheLanguageChosenInSettingsIsTheOnlyOneTried() async throws {
        let model = await makeModel()
        let (_, recognizer) = useFakes(model)
        var settings = model.settings
        settings.dictationLocale = "en-US"
        await model.saveSettings(settings)

        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        XCTAssertEqual(recognizer.candidates.last, ["en-US"])
        XCTAssertEqual(model.dictation.localeIdentifier, "en-US")
        model.cancelDictation()

        settings.dictationLocale = ""
        await model.saveSettings(settings)
        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        XCTAssertEqual(recognizer.candidates.last, ["zh-CN", "en-US"], "跟随系统")
        model.cancelDictation()
    }

    func testLatinDraftGetsOneSeparatingSpace() async throws {
        let model = await makeModel()
        let (_, recognizer) = useFakes(model)
        recognizer.finalText = "call Bob"
        model.draft = "Note:"

        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        model.stopDictation(send: false)
        try await waitUntil { model.dictationState == .done("call Bob") }
        XCTAssertEqual(model.draft, "Note: call Bob")
    }

    func testTranscribeAndSendSendsThroughTheNormalPath() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("收到"))])
        let (model, id) = try await FollowUpHarness.makeModel(transport, libraryRoot: FileManager.default.temporaryDirectory)
        let (_, recognizer) = useFakes(model)
        recognizer.finalText = "帮我看看日志"

        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        model.stopDictation(send: true)
        try await waitUntil { transport.requestCount == 1 && !model.isStreaming }

        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[0]).last, ["user", "帮我看看日志"])
        XCTAssertEqual(model.draft, "", "发出后输入框清空")
        XCTAssertEqual(model.conversations.first { $0.id == id }?.messages.last?.concatenatedText, "收到")
    }

    func testSwitchingConversationsReleasesTheMicAndKeepsTheTextWhereItWasSaid() async throws {
        let model = await makeModel()
        let (capture, _) = useFakes(model)
        let first = try XCTUnwrap(model.selectedConversationID)
        model.draft = "第一个对话"

        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        let second = model.newConversation().id
        XCTAssertFalse(capture.holdsMicrophone, "换对话立刻放开麦克风")
        XCTAssertFalse(model.showsDictationBar, "别的对话不显示这次听写")
        try await waitUntil { model.dictationState == .done("你好世界") }
        XCTAssertEqual(model.draft, "", "新对话的草稿不受影响")

        model.selectedConversationID = first
        XCTAssertEqual(model.draft, "第一个对话你好世界", "说的话落在原对话的草稿里")
        model.selectedConversationID = second
        XCTAssertEqual(model.draft, "")
    }

    func testSwitchingWhileStartingCancels() async throws {
        let model = await makeModel()
        let (capture, _) = useFakes(model)
        capture.authorizeGate = TestGate()

        model.startDictation()
        try await waitUntil { capture.authorizeCount == 1 }
        model.newConversation()
        XCTAssertEqual(model.dictationState, .cancelled)
        XCTAssertFalse(capture.holdsMicrophone)
    }

    func testTranscribeAndSendIntoAConversationLeftBehindDoesNotSend() async throws {
        let transport = FollowUpTransport([])
        let (model, first) = try await FollowUpHarness.makeModel(transport, libraryRoot: FileManager.default.temporaryDirectory)
        let (_, recognizer) = useFakes(model)
        let gate = TestGate()
        recognizer.finishGate = gate

        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        model.stopDictation(send: true)
        model.newConversation()
        gate.release()
        try await waitUntil { model.dictationState == .done("你好世界") }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transport.requestCount, 0, "离开的对话不会被代发")
        model.selectedConversationID = first
        XCTAssertEqual(model.draft, "你好世界")
    }

    func testCapReportsTheLimit() async throws {
        let model = await makeModel()
        useFakes(model, maxDuration: 0.3)

        model.startDictation()
        try await waitUntil { model.dictationState == .done("你好世界") }
        XCTAssertEqual(model.draft, "你好世界")
        XCTAssertEqual(model.statusMessage, "已达到最长录音时长")
    }

    func testAddToMessageAppendsWhatWasHeardAndCloses() async throws {
        let model = await makeModel()
        let (_, recognizer) = useFakes(model)
        model.draft = "草稿"

        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        recognizer.hear("没说完的话")
        recognizer.breakDown(.transcriptionFailed)
        XCTAssertTrue(model.showsDictationBar, "失败留在作曲栏")

        model.applyDictationRecovery(.addToMessage)
        XCTAssertEqual(model.draft, "草稿没说完的话")
        XCTAssertEqual(model.dictationState, .idle)
        XCTAssertFalse(model.showsDictationBar)
    }

    func testRetryTranscribesTheKeptAudioIntoTheDraft() async throws {
        let model = await makeModel()
        let folder = try DictationHarness.temporaryFolder()
        let (capture, recognizer) = useFakes(model, recordings: folder)
        recognizer.finishError = DictationError.transcriptionFailed

        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        capture.speak()
        model.stopDictation(send: false)
        try await waitUntil { model.dictationState == .failed(.transcriptionFailed, partial: "") }

        recognizer.finishError = nil
        model.applyDictationRecovery(.retry)
        try await waitUntil { model.dictationState == .done("录音里的话") }
        XCTAssertEqual(model.draft, "录音里的话")
        XCTAssertEqual(capture.startCount, 1, "重试转写留下的录音，不重新开麦克风")
    }

    func testRetryAfterNothingWasHeardListensAgain() async throws {
        let model = await makeModel()
        let (capture, recognizer) = useFakes(model)
        recognizer.finalText = ""

        model.startDictation()
        try await waitUntil { model.dictationState.isListening }
        model.stopDictation(send: false)
        try await waitUntil { model.dictationState == .failed(.audioTooShort, partial: "") }

        model.applyDictationRecovery(.retry)
        try await waitUntil { model.dictationState.isListening }
        XCTAssertEqual(capture.startCount, 2)
        model.cancelDictation()
    }

    func testActionsTheFailureDoesNotOfferAreIgnored() async throws {
        let model = await makeModel()
        let (capture, _) = useFakes(model)
        capture.authorizeError = .microphonePermissionDenied
        model.draft = "原样"

        model.startDictation()
        try await waitUntil { model.dictationState == .failed(.microphonePermissionDenied, partial: "") }
        model.applyDictationRecovery(.retry)
        model.applyDictationRecovery(.addToMessage)
        XCTAssertEqual(model.dictationState, .failed(.microphonePermissionDenied, partial: ""), "权限没开，重试没有意义")
        XCTAssertEqual(capture.authorizeCount, 1)
        XCTAssertEqual(model.draft, "原样")

        model.applyDictationRecovery(.dismiss)
        XCTAssertEqual(model.dictationState, .idle)
    }

    func testToggleStartsStopsAndCancelsAStartingSession() async throws {
        let model = await makeModel()
        let (capture, _) = useFakes(model)

        model.toggleDictation()
        try await waitUntil { model.dictationState.isListening }
        model.toggleDictation()
        try await waitUntil { model.dictationState == .done("你好世界") }
        XCTAssertEqual(model.draft, "你好世界")

        capture.authorizeGate = TestGate()
        model.toggleDictation()
        XCTAssertEqual(model.dictationState, .starting)
        model.toggleDictation()
        XCTAssertEqual(model.dictationState, .cancelled)
    }

    func testTranscribeIntoDraftReturnsTheErrorTextOrNil() async throws {
        let model = await makeModel()
        let (_, recognizer) = useFakes(model)
        let file = try DictationHarness.temporaryFolder().appendingPathComponent("say.aiff")
        try Data([0]).write(to: file)
        model.draft = "前面"

        let ok = await model.transcribeIntoDraft(fileURL: file, localeIdentifier: "zh-CN")
        XCTAssertNil(ok)
        XCTAssertEqual(model.draft, "前面录音里的话")

        recognizer.fileText = "  "
        let failure = await model.transcribeIntoDraft(fileURL: file)
        XCTAssertEqual(failure, "没听清，请再说一次")
        XCTAssertEqual(model.draft, "前面录音里的话", "没听清时草稿不变")
    }
}
