#if os(macOS)
import AppKit
import SwiftUI
import OMPCore

/// The 文件 tab's editor. An `NSTextView` rather than SwiftUI's `TextEditor`,
/// which cannot scroll to a line — and opening `src/a.swift:42` from a
/// message has to land on line 42.
struct FileTextView: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    /// 1-based line to scroll to and select, applied once per `revealID`.
    var line: Int?
    var revealID: UUID

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        // Source text: no smart quotes, dashes or autocorrect.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.setAccessibilityIdentifier("panel.file.editor")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        // Never while a word is mid-composition: replacing the string would
        // drop the marked text.
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        textView.isEditable = editable
        guard context.coordinator.revealed != revealID else { return }
        context.coordinator.revealed = revealID
        // After layout, or there is no line rectangle to scroll to yet. A
        // file opened without a line starts at its top, not where the last
        // one was scrolled.
        DispatchQueue.main.async {
            let range = line.map { FileReference.utf16Range(ofLine: $0, in: textView.string) } ?? NSRange(location: 0, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            if line != nil, textView.window != nil { textView.showFindIndicator(for: range) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var revealed: UUID?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
#endif
