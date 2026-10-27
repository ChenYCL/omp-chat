import SwiftUI
import OMPCore
import OMPDesign

/// The composer's mic (Codex `composer.dictation.aria` 听写): dictates into
/// this conversation's draft.
struct DictationButton: View {
    @Environment(ChatAppModel.self) private var model
    /// Square the icon sits in: the footer's 28pt on the desktop, the
    /// composer height on the phone.
    var size: CGFloat
    var iconSize: CGFloat
    @State private var hovering = false

    var body: some View {
        Button {
            model.startDictation()
        } label: {
            Image(systemName: "mic")
                .font(.system(size: iconSize))
                .foregroundStyle(Color.ompTextSecondary)
                .frame(width: size, height: size)
                .background(hovering ? ompGhostHover : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Another conversation's dictation is still settling its text.
        .disabled(model.dictationState.isActive)
        .onHover { hovering = $0 }
        .help("听写")
        .accessibilityIdentifier("composer.dictation")
        .accessibilityLabel("听写")
    }
}

/// Takes the composer footer's place while dictating (Codex
/// `composer.dictationToolbar`): the live text above a row with the input
/// level, the time and 取消 / 停止 / 转写并发送; a status while starting or
/// settling; after a failure, the error with its fix and the recovery
/// actions. Escape cancels, or closes a failure.
struct DictationBar: View {
    @Environment(ChatAppModel.self) private var model
    /// Phone: icon-only buttons and a shorter meter.
    var compact = false
    var rowHeight: CGFloat

    var body: some View {
        let state = model.dictationState
        VStack(alignment: .leading, spacing: 4) {
            if let text = liveText(state) {
                Text(text.isEmpty ? "正在听…" : text)
                    .font(.system(size: compact ? 14 : 13))
                    .foregroundStyle(text.isEmpty ? Color.ompTextTertiary : Color.ompTextSecondary)
                    .lineLimit(compact ? 2 : 3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("composer.dictation.text")
            }
            HStack(spacing: 8) {
                controls(state)
            }
            .frame(minHeight: rowHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.dictation.bar")
    }

    /// What was heard: live while listening (empty shows 正在听…), and the
    /// text a failure can still copy or add.
    private func liveText(_ state: DictationState) -> String? {
        switch state {
        case .listening(_, let partial): return partial
        case .finishing(let partial), .transcribing(let partial): return partial.isEmpty ? nil : partial
        case .failed: return state.recovery?.text
        default: return nil
        }
    }

    @ViewBuilder
    private func controls(_ state: DictationState) -> some View {
        switch state {
        case .starting:
            ProgressView().controlSize(.small)
            status(model.dictation.isDownloadingModel ? "正在下载听写模型…" : "正在开始听写…")
            Spacer(minLength: 0)
            cancelButton("取消听写")
        case .listening(let elapsed, _):
            DictationLevelMeter(controller: model.dictation, bars: compact ? 14 : DictationController.meterBars)
            Text(DictationClock.label(elapsed))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ompTextSecondary)
                .accessibilityIdentifier("composer.dictation.elapsed")
            if let language = languageName {
                Text(language)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
                    .lineLimit(1)
                    .accessibilityIdentifier("composer.dictation.language")
            }
            Spacer(minLength: 0)
            cancelButton("取消听写")
            action("停止", systemImage: "stop.fill", id: "composer.dictation.stop") {
                model.stopDictation(send: false)
            }
            action("转写并发送", systemImage: "arrow.up", prominent: true, id: "composer.dictation.send") {
                model.stopDictation(send: true)
            }
        case .finishing:
            ProgressView().controlSize(.small)
            status("正在结束听写")
            Spacer(minLength: 0)
            cancelButton("取消转写")
        case .transcribing:
            ProgressView().controlSize(.small)
            status("正在转写")
            Spacer(minLength: 0)
            cancelButton("取消转写")
        case .failed(let error, _):
            failure(error, actions: state.recovery?.actions ?? [.dismiss])
        case .idle, .done, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private func failure(_ error: DictationError, actions: [DictationRecoveryAction]) -> some View {
        Image(systemName: "exclamationmark.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.orange)
        Text(error.message)
            .font(.system(size: compact ? 13 : 12.5))
            .foregroundStyle(Color.ompText)
            .lineLimit(2)
            .accessibilityIdentifier("composer.dictation.error")
        if let link = error.settingsLink {
            Button(link.title) {
                switch link {
                case .microphone: model.openMicrophoneSettings()
                case .speechRecognition: model.openSpeechRecognitionSettings()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .accessibilityIdentifier("composer.dictation.settings")
        }
        Spacer(minLength: 0)
        ForEach(actions.filter { $0 != .dismiss }, id: \.self) { recovery in
            action(recovery.title, systemImage: Self.symbol(recovery), id: "composer.dictation.recovery.\(recovery.rawValue)") {
                model.applyDictationRecovery(recovery)
            }
        }
        Button {
            model.applyDictationRecovery(.dismiss)
        } label: {
            closeIcon
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("关闭（Esc）")
        .accessibilityLabel(DictationRecoveryAction.dismiss.title)
        .accessibilityIdentifier("composer.dictation.recovery.dismiss")
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Color.ompTextSecondary)
            .lineLimit(1)
            .accessibilityIdentifier("composer.dictation.status")
    }

    private func cancelButton(_ title: String) -> some View {
        Button {
            model.cancelDictation()
        } label: {
            closeIcon
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("\(title)（Esc）")
        .accessibilityLabel(title)
        .accessibilityIdentifier("composer.dictation.cancel")
    }

    private var closeIcon: some View {
        Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.ompTextSecondary)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }

    /// A labelled capsule on the desktop, a round icon on the phone.
    private func action(
        _ title: String, systemImage: String, prominent: Bool = false, id: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Group {
                if compact {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(prominent ? Color.ompPrimarySolid : Color.ompFill, in: Circle())
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: systemImage)
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(title)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(prominent ? Color.ompPrimarySolid : Color.ompFill, in: Capsule())
                }
            }
            .foregroundStyle(prominent ? Color.ompInverseText : Color.ompText)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    /// The session's language in its own words (中文, English), so a wrong
    /// pick shows while speaking.
    private var languageName: String? {
        model.dictation.localeIdentifier.flatMap(DictationLocale.languageName)
    }

    private static func symbol(_ action: DictationRecoveryAction) -> String {
        switch action {
        case .copyText: return "doc.on.doc"
        case .addToMessage: return "text.append"
        case .retry: return "arrow.clockwise"
        case .dismiss: return "xmark"
        }
    }
}

/// Bars of the recent input level, newest on the right. Reads the levels
/// itself so only the meter redraws as they arrive.
struct DictationLevelMeter: View {
    let controller: DictationController
    var bars: Int

    var body: some View {
        let levels = controller.levels.suffix(bars)
        let padding = bars - levels.count
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                let level = index < padding ? 0 : CGFloat(levels[levels.startIndex + index - padding])
                Capsule()
                    .fill(Color.ompTextSecondary)
                    .frame(width: 2, height: 2 + level * 14)
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: controller.levels)
        .accessibilityElement()
        .accessibilityLabel("输入音量")
        .accessibilityValue("\(Int(((controller.levels.last ?? 0) * 100).rounded()))%")
        .accessibilityIdentifier("composer.dictation.level")
    }
}
