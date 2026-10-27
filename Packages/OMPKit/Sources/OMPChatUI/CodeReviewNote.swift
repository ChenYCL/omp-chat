import SwiftUI
import OMPCore
import OMPDesign

/// The note above a 「用 Codex 审查」 thread: its findings live only in this
/// chat (official `codeReviewPlugin.manualReview.chatOnlyDisclosure`), and,
/// once the review reply is over without one, that no report came
/// (`codeReviewPlugin.manualReview.unreported`).
struct CodeReviewNote: View {
    let outcome: CodeReviewPrompt.Outcome

    var body: some View {
        VStack(spacing: 4) {
            Label("这些发现只在这个对话里，没有保存到代码审查", systemImage: "checklist")
                .foregroundStyle(Color.ompTextTertiary)
            if outcome == .unreported {
                Label("代码审查结束了，但没有给出报告", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.orange)
            }
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("codeReview.note")
    }
}
