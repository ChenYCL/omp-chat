import XCTest
@testable import OMPCore

/// The dictation lifecycle: every way in and out, the length cap, and late
/// callbacks that must not revive a finished session.
final class DictationMachineTests: XCTestCase {
    func testLiveSessionRunsStartingListeningFinishingDone() {
        var machine = DictationMachine()
        XCTAssertNil(machine.handle(.start))
        XCTAssertEqual(machine.state, .starting)
        XCTAssertNil(machine.handle(.ready))
        XCTAssertEqual(machine.state, .listening(elapsed: 0, partial: ""))
        machine.handle(.partial("你好"))
        machine.handle(.tick(1.5))
        XCTAssertEqual(machine.state, .listening(elapsed: 1.5, partial: "你好"))

        XCTAssertEqual(machine.handle(.stop), .stopCapture, "停止先关麦克风，识别器继续收尾")
        XCTAssertEqual(machine.state, .finishing(partial: "你好"))
        machine.handle(.partial("你好世"))
        XCTAssertEqual(machine.state, .finishing(partial: "你好世"))
        XCTAssertEqual(machine.handle(.final("  你好世界 \n")), .teardown)
        XCTAssertEqual(machine.state, .done("你好世界"), "结果去掉首尾空白")
    }

    func testRecordingRunsTranscribingDone() {
        var machine = DictationMachine()
        machine.handle(.transcribeRecording)
        XCTAssertEqual(machine.state, .transcribing(partial: ""))
        machine.handle(.partial("第一"))
        XCTAssertEqual(machine.state, .transcribing(partial: "第一"))
        XCTAssertEqual(machine.handle(.final("第一句")), .teardown)
        XCTAssertEqual(machine.state, .done("第一句"))
    }

    func testCancelWhileStartingTearsDownAndALateReadyIsReleased() {
        var machine = DictationMachine()
        machine.handle(.start)
        XCTAssertEqual(machine.handle(.cancel), .teardown)
        XCTAssertEqual(machine.state, .cancelled)
        XCTAssertEqual(machine.handle(.ready), .teardown, "取消后才起来的麦克风要立刻释放")
        XCTAssertEqual(machine.state, .cancelled, "迟到的就绪不会复活会话")
    }

    func testStopWhileStartingCancels() {
        var machine = DictationMachine()
        machine.handle(.start)
        XCTAssertEqual(machine.handle(.stop), .teardown)
        XCTAssertEqual(machine.state, .cancelled)
    }

    func testCancelWhileListeningOrFinishingDropsTheText() {
        var listening = DictationMachine()
        listening.handle(.start)
        listening.handle(.ready)
        listening.handle(.partial("不要了"))
        XCTAssertEqual(listening.handle(.cancel), .teardown)
        XCTAssertEqual(listening.state, .cancelled)

        var finishing = DictationMachine()
        finishing.handle(.start)
        finishing.handle(.ready)
        finishing.handle(.stop)
        XCTAssertEqual(finishing.handle(.cancel), .teardown)
        XCTAssertNil(finishing.handle(.final("迟到的结果")), "取消后的结果被忽略")
        XCTAssertEqual(finishing.state, .cancelled)
    }

    func testNothingHeardIsAudioTooShort() {
        for silence in ["", "   \n", "。", " ... "] {
            var machine = DictationMachine()
            machine.handle(.start)
            machine.handle(.ready)
            machine.handle(.stop)
            XCTAssertEqual(machine.handle(.final(silence)), .teardown)
            XCTAssertEqual(machine.state, .failed(.audioTooShort, partial: ""), "「\(silence)」不算听到了")
        }
    }

    func testCapStopsTheMicrophoneAtTheLimitAndResetsOnTheNextSession() {
        var machine = DictationMachine(maxDuration: 120)
        machine.handle(.start)
        machine.handle(.ready)
        machine.handle(.partial("很长"))
        XCTAssertNil(machine.handle(.tick(119.9)))
        XCTAssertFalse(machine.reachedMaxDuration)
        XCTAssertEqual(machine.handle(.tick(120)), .stopCapture)
        XCTAssertEqual(machine.state, .finishing(partial: "很长"), "到两分钟自动收尾，不丢已说的话")
        XCTAssertTrue(machine.reachedMaxDuration)
        XCTAssertNil(machine.handle(.stop), "已经在收尾，再按停止无事发生")

        machine.handle(.final("很长的话"))
        machine.handle(.start)
        XCTAssertFalse(machine.reachedMaxDuration, "新一次听写重新计时")
    }

    func testTicksNeverRunTimeBackwards() {
        var machine = DictationMachine()
        machine.handle(.start)
        machine.handle(.ready)
        machine.handle(.tick(5))
        machine.handle(.tick(3))
        XCTAssertEqual(machine.state, .listening(elapsed: 5, partial: ""))
    }

    func testFailureKeepsWhatWasHeard() {
        var machine = DictationMachine()
        machine.handle(.start)
        machine.handle(.ready)
        machine.handle(.partial("说了一半"))
        XCTAssertEqual(machine.handle(.fail(.transcriptionFailed)), .teardown)
        XCTAssertEqual(machine.state, .failed(.transcriptionFailed, partial: "说了一半"))
        XCTAssertNil(machine.handle(.fail(.startFailed)), "失败之后的第二个错误被忽略")
        XCTAssertEqual(machine.state, .failed(.transcriptionFailed, partial: "说了一半"))
    }

    func testEventsOutsideASessionAreIgnored() {
        var machine = DictationMachine()
        for event: DictationEvent in [.stop, .cancel, .fail(.startFailed), .final("x"), .partial("x"), .tick(3)] {
            XCTAssertNil(machine.handle(event))
            XCTAssertEqual(machine.state, .idle)
        }
        machine.handle(.start)
        machine.handle(.ready)
        XCTAssertNil(machine.handle(.start), "听写中再按听写不会重开")
        XCTAssertNil(machine.handle(.dismiss), "听写中不能被关闭")
        XCTAssertTrue(machine.state.isListening)
    }

    func testDismissReturnsToIdleFromEveryEnd() {
        let ends: [DictationEvent] = [.final("好"), .fail(.microphoneBusy), .cancel]
        for end in ends {
            var machine = DictationMachine()
            machine.handle(.start)
            machine.handle(.ready)
            machine.handle(end)
            machine.handle(.dismiss)
            XCTAssertEqual(machine.state, .idle)
        }
    }

    func testANewSessionCanStartAfterEveryEnd() {
        let ends: [DictationEvent] = [.final("好"), .fail(.microphoneBusy), .cancel]
        for end in ends {
            var machine = DictationMachine()
            machine.handle(.start)
            machine.handle(.ready)
            machine.handle(end)
            machine.handle(.start)
            XCTAssertEqual(machine.state, .starting)
        }
    }
}

final class DictationErrorTests: XCTestCase {
    func testEveryErrorReadsAsTheComposerShowsIt() {
        let expected: [DictationError: String] = [
            .startFailed: "无法开始听写",
            .transcriptionFailed: "无法识别这段录音",
            .unsupported: "这台设备不支持听写",
            .microphonePermissionDenied: "打开麦克风权限才能听写",
            .microphoneMissing: "连接麦克风后才能听写",
            .microphoneBusy: "请关闭正在使用麦克风的其他应用",
            .audioTooShort: "没听清，请再说一次",
            .speechPermissionDenied: "打开语音识别权限才能听写",
        ]
        XCTAssertEqual(Set(expected.keys), Set(DictationError.allCases))
        for error in DictationError.allCases {
            XCTAssertEqual(error.message, expected[error])
            XCTAssertEqual(error.localizedDescription, expected[error], "错误横幅读到同一句")
        }
    }

    func testPermissionErrorsLinkToTheirSettingsAndAreNotRetried() {
        XCTAssertEqual(DictationError.microphonePermissionDenied.settingsLink, .microphone)
        XCTAssertEqual(DictationError.speechPermissionDenied.settingsLink, .speechRecognition)
        for error in DictationError.allCases where error != .microphonePermissionDenied && error != .speechPermissionDenied {
            XCTAssertNil(error.settingsLink, "\(error)")
        }
        let notRetryable = DictationError.allCases.filter { !$0.isRetryable }
        XCTAssertEqual(Set(notRetryable), [.unsupported, .microphonePermissionDenied, .speechPermissionDenied])
        XCTAssertEqual(DictationSettingsLink.microphone.macOSURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func testAudioStartFailuresMapToTheMicrophoneProblem() {
        // OSStatus values as AVAudioSession / Core Audio report them.
        let busy: [Int] = [
            560492391,   // '!hog' kAudioDevicePermissionsError
            561017449,   // '!pri' insufficientPriority
            560557684,   // '!int' cannotInterruptOthers
            561145187,   // '!rec' cannotStartRecording
            560030580,   // '!act' isBusy
            1936290409,  // 'siri' siriIsRecording
        ]
        for code in busy {
            XCTAssertEqual(DictationError.audioStartFailure(osStatus: code), .microphoneBusy, "\(code)")
        }
        XCTAssertEqual(DictationError.audioStartFailure(osStatus: 560227702), .microphoneMissing, "'!dev' bad device")
        for code in [0, -50, -10868, 2003329396] {
            XCTAssertEqual(DictationError.audioStartFailure(osStatus: code), .startFailed, "\(code)")
        }
    }

    func testRecognitionFailuresFollowApplesTable() {
        let assistant = "kAFAssistantErrorDomain"
        let local = "kLSRErrorDomain"
        XCTAssertEqual(DictationError.recognitionFailure(domain: assistant, code: 1110), .audioTooShort)
        XCTAssertEqual(DictationError.recognitionFailure(domain: assistant, code: 1700), .speechPermissionDenied)
        XCTAssertEqual(DictationError.recognitionFailure(domain: assistant, code: 1100), .startFailed)
        XCTAssertEqual(DictationError.recognitionFailure(domain: local, code: 102), .unsupported)
        XCTAssertEqual(DictationError.recognitionFailure(domain: local, code: 201), .unsupported)
        XCTAssertEqual(DictationError.recognitionFailure(domain: local, code: 300), .startFailed)
        XCTAssertEqual(DictationError.recognitionFailure(domain: assistant, code: 1101), .transcriptionFailed)
        XCTAssertEqual(DictationError.recognitionFailure(domain: NSCocoaErrorDomain, code: 1110), .transcriptionFailed,
                       "同一个码换了域不算没说话")
        XCTAssertTrue(DictationError.isCancellation(domain: local, code: 301))
        XCTAssertFalse(DictationError.isCancellation(domain: assistant, code: 301))
    }
}

final class DictationTextTests: XCTestCase {
    func testDictationIntoAnEmptyOrBlankDraftIsJustTheText() {
        XCTAssertEqual(DictationText.merge("  你好世界 \n", into: ""), "你好世界")
        XCTAssertEqual(DictationText.merge("hello", into: "  \n"), "hello")
    }

    func testDictationAppendsWithOneSpaceAndNeverReplaces() {
        XCTAssertEqual(DictationText.merge("world", into: "Hello"), "Hello world")
        XCTAssertEqual(DictationText.merge(" world ", into: "Hello "), "Hello world", "草稿已有空格时不再加")
    }

    func testTheDraftsOwnNewlineIsTheSeparator() {
        XCTAssertEqual(DictationText.merge("second", into: "first\n"), "first\nsecond")
        XCTAssertEqual(DictationText.merge("第二行", into: "第一行\n\n"), "第一行\n\n第二行", "草稿的换行原样保留")
    }

    func testChineseJoinsWithoutASpace() {
        XCTAssertEqual(DictationText.merge("继续说", into: "你好。"), "你好。继续说")
        XCTAssertEqual(DictationText.merge("你好", into: "hello"), "hello你好")
        XCTAssertEqual(DictationText.merge("OK", into: "好的"), "好的OK")
    }

    func testBlankDictationLeavesTheDraftAlone() {
        XCTAssertEqual(DictationText.merge(" \n ", into: "草稿 "), "草稿 ")
    }

    func testClosingPunctuationAttachesWithoutASpace() {
        XCTAssertEqual(DictationText.join("test", ", then"), "test, then")
        XCTAssertEqual(DictationText.join("done", "."), "done.")
    }

    func testOnlyLettersOrDigitsCountAsHeard() {
        XCTAssertTrue(DictationText.isMeaningful("好"))
        XCTAssertTrue(DictationText.isMeaningful("42"))
        XCTAssertFalse(DictationText.isMeaningful("，。！？ ..."))
        XCTAssertFalse(DictationText.isMeaningful(""))
    }

    func testTranscriptKeepsSettledSegmentsAndReplacesTheTentativeTail() {
        var transcript = DictationTranscript()
        transcript.apply("Hello", isFinal: false)
        transcript.apply("Hello wor", isFinal: false)
        XCTAssertEqual(transcript.text, "Hello wor", "新假设替换旧假设")
        transcript.apply("Hello world.", isFinal: true)
        XCTAssertEqual(transcript.text, "Hello world.")
        transcript.apply(" How", isFinal: false)
        XCTAssertEqual(transcript.text, "Hello world. How")
        transcript.apply("How are you?", isFinal: true)
        XCTAssertEqual(transcript.text, "Hello world. How are you?")

        var chinese = DictationTranscript()
        chinese.apply("你好，", isFinal: true)
        chinese.apply("世界", isFinal: true)
        XCTAssertEqual(chinese.text, "你好，世界")
    }
}

final class DictationRecoveryTests: XCTestCase {
    func testFailedTranscriptionWithHeardTextOffersEveryAction() {
        let state = DictationState.failed(.transcriptionFailed, partial: " 说了一半 ")
        XCTAssertEqual(state.recovery, DictationRecovery(error: .transcriptionFailed, text: "说了一半"))
        XCTAssertEqual(state.recovery?.actions, [.copyText, .addToMessage, .retry, .dismiss])
    }

    func testNothingHeardOffersNoCopyOrAdd() {
        XCTAssertEqual(DictationState.failed(.audioTooShort, partial: "").recovery?.actions, [.retry, .dismiss])
        XCTAssertNil(DictationState.failed(.transcriptionFailed, partial: "。").recovery?.text, "只有标点不算文字")
    }

    func testPermissionAndUnsupportedFailuresCannotBeRetried() {
        XCTAssertEqual(DictationState.failed(.microphonePermissionDenied, partial: "").recovery?.actions, [.dismiss])
        XCTAssertEqual(DictationState.failed(.unsupported, partial: "有字").recovery?.actions, [.copyText, .addToMessage, .dismiss])
    }

    func testOnlyFailuresHaveARecovery() {
        let others: [DictationState] = [.idle, .starting, .listening(elapsed: 1, partial: "x"), .finishing(partial: "x"),
                                        .transcribing(partial: "x"), .done("x"), .cancelled]
        for state in others { XCTAssertNil(state.recovery, "\(state)") }
    }

    func testActionTitles() {
        XCTAssertEqual(DictationRecoveryAction.allCases.map(\.title), ["复制文本", "添加到消息", "重试", "关闭"])
    }
}

final class DictationLocaleTests: XCTestCase {
    func testPreferredLanguagesComeFirstThenChineseAndEnglish() {
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["en-US", "zh-Hans-CN"]), ["en-US", "zh-CN"])
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["en-GB"]), ["en-GB", "en-US", "zh-CN"])
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["zh-Hant-TW"]), ["zh-TW", "zh-CN", "en-US"])
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["zh-Hant"]), ["zh-TW", "zh-CN", "en-US"])
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["ja"]), ["ja-JP", "zh-CN", "en-US"])
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: []), ["zh-CN", "en-US"])
    }

    func testEnglishInterfaceInAChineseRegionYieldsToPreferredChinese() {
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["en-CN", "zh-Hans-CN"]), ["zh-CN", "en-CN", "en-US"],
                       "英文界面、中国地区、也设了中文：先听中文")
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["en-HK", "ja-JP", "zh-Hant-HK"]),
                       ["zh-HK", "zh-TW", "en-HK", "en-US", "ja-JP", "zh-CN"], "繁体中文用户落到自己的中文")
        for region in ["TW", "MO", "SG"] {
            XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["en-\(region)", "zh-Hans-CN"]).first, "zh-CN", region)
        }
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["en-CN"]), ["en-CN", "en-US", "zh-CN"],
                       "没设中文就照系统的英文")
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["en-GB", "zh-Hans-CN"]).first, "en-GB",
                       "英国英文是真在说英文")
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["ja-JP", "en-CN", "zh-Hans-CN"]).first, "ja-JP",
                       "只看第一个首选语言")
    }

    func testAChosenLanguageIsTheOnlyCandidate() {
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["en-CN", "zh-Hans-CN"], chosen: "en-US"), ["en-US"])
        XCTAssertEqual(DictationLocale.candidates(preferredLanguages: ["ja-JP"], chosen: " \n"), ["ja-JP", "zh-CN", "en-US"],
                       "空白等于跟随系统")
    }

    func testMenuOffersChineseAndEnglishFirst() {
        XCTAssertEqual(DictationLocale.menu([]), ["zh-CN", "en-US"])
        XCTAssertEqual(DictationLocale.menu(["ja-JP", "en-US", "", "de-DE", "ja-JP"]), ["zh-CN", "en-US", "de-DE", "ja-JP"])
    }

    func testFollowSystemNamesTheLanguageItPicksOnThisDevice() {
        let onDevice = ["en-US", "zh-CN", "zh-TW", "de-DE"]
        XCTAssertEqual(DictationLocale.followSystemTitle(preferredLanguages: ["en-CN", "zh-Hans-CN"], available: onDevice),
                       "跟随系统（中文）", "这台 Mac 的首选语言：英文界面、中国地区、也设了中文")
        XCTAssertEqual(DictationLocale.followSystemTitle(preferredLanguages: ["en-US", "zh-Hans-CN"], available: onDevice),
                       "跟随系统（English）")
        XCTAssertEqual(DictationLocale.followSystemTitle(preferredLanguages: ["ja-JP"], available: onDevice),
                       "跟随系统（中文）", "日语没有设备端模型，落到 zh-CN")
        XCTAssertEqual(DictationLocale.followSystemTitle(preferredLanguages: ["en-CN", "zh-Hans-CN"], available: []),
                       "跟随系统", "列表还没读到时不猜")
        XCTAssertEqual(DictationLocale.followSystemTitle(preferredLanguages: ["ja-JP"], available: ["fr-FR"]),
                       "跟随系统", "没有一种语言有模型")
    }

    func testAutomaticMatchesByLanguageInCandidateOrder() {
        XCTAssertEqual(DictationLocale.automatic(["en-CN", "zh-CN"], available: ["zh_CN", "en_US"]), "en-CN",
                       "识别器用 en_US 服务 en-CN，按语言匹配")
        XCTAssertEqual(DictationLocale.automatic(["ja-JP", "zh-CN", "en-US"], available: ["en_US", "zh_CN"]), "zh-CN")
        XCTAssertNil(DictationLocale.automatic(["ja-JP"], available: ["en_US"]))
        XCTAssertNil(DictationLocale.automatic([], available: ["en_US"]))
    }

    func testLanguageNameIsInItsOwnWords() {
        XCTAssertEqual(DictationLocale.languageName("zh-CN"), "中文")
        XCTAssertEqual(DictationLocale.languageName("en-US"), "English")
    }

    func testDictationLanguageSettingSurvivesOldDocumentsAndRoundTrips() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":1,"speechVoiceLanguage":"zh-CN"}"#.utf8))
        XCTAssertEqual(old.dictationLocale, "", "旧工作区没有这个字段，按跟随系统")
        var settings = AppSettings()
        settings.dictationLocale = "zh-CN"
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.dictationLocale, "zh-CN")
    }

    func testMatchNeedsLanguageAndRegion() {
        XCTAssertEqual(DictationLocale.match("zh-CN", in: ["en_US", "zh_CN"]), "zh_CN")
        XCTAssertEqual(DictationLocale.match("en-US", in: ["en_GB", "en-US"]), "en-US")
        XCTAssertNil(DictationLocale.match("zh-TW", in: ["zh_CN"]))
        XCTAssertNil(DictationLocale.match("en-CN", in: ["en_US"]))
    }
}

final class DictationMeterTests: XCTestCase {
    func testLevelSpansMinusFiftyToZeroDecibels() {
        XCTAssertEqual(DictationLevel.normalized(rms: 0), 0)
        XCTAssertEqual(DictationLevel.normalized(rms: 0.001), 0, "−60 dBFS reads silent")
        XCTAssertEqual(DictationLevel.normalized(rms: 1), 1)
        XCTAssertEqual(DictationLevel.normalized(rms: 2), 1, "clipped input stays full")
        XCTAssertEqual(DictationLevel.normalized(rms: 0.0316228), 0.4, accuracy: 0.001, "−30 dBFS")
        XCTAssertEqual(DictationLevel.normalized(rms: .nan), 0)
    }

    func testRMS() {
        let samples: [Float] = [1, -1, 1, -1]
        samples.withUnsafeBufferPointer { XCTAssertEqual(DictationLevel.rms($0), 1) }
        [Float]().withUnsafeBufferPointer { XCTAssertEqual(DictationLevel.rms($0), 0) }
    }

    func testClockShowsWholeSeconds() {
        XCTAssertEqual(DictationClock.label(0), "0:00")
        XCTAssertEqual(DictationClock.label(59.9), "0:59")
        XCTAssertEqual(DictationClock.label(120), "2:00")
        XCTAssertEqual(DictationClock.label(-1), "0:00")
    }
}
