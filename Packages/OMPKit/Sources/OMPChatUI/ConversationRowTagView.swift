import SwiftUI
import OMPCore
import OMPDesign

/// The status capsule after a conversation row's title (Codex
/// `localTaskRow` tags): orange for what waits on the user, red for a
/// failure, neutral for scheduled-task provenance. `compact` drops the text
/// for secondary tags; the accessibility label always reads in full.
/// Identifier: `<scope>.row.status.<rawValue>`.
struct ConversationRowTagView: View {
    let tag: ConversationRowTag
    var compact = false
    /// `sidebar`, `drawer` or `remote`.
    let scope: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: tag.systemImage)
                .font(.system(size: 8, weight: .bold))
            if !compact {
                Text(tag.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 2.5)
        .background(background, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tag.accessibilityLabel)
        .accessibilityIdentifier("\(scope).row.status.\(tag.rawValue)")
    }

    private var tint: Color {
        switch tag {
        case .awaitingApproval, .needsInput: .orange
        case .systemError: .red
        case .automation, .attachedAutomation: Color.ompTextSecondary
        }
    }

    private var background: Color {
        switch tag {
        case .awaitingApproval, .needsInput: Color.orange.opacity(0.14)
        case .systemError: Color.red.opacity(0.12)
        case .automation, .attachedAutomation: Color.ompFill
        }
    }
}

/// Primary tag in full, then each secondary tag as an icon.
struct ConversationRowTags: View {
    let status: ConversationRowStatus
    let scope: String

    var body: some View {
        if let primary = status.primary {
            HStack(spacing: 3) {
                ConversationRowTagView(tag: primary, scope: scope)
                ForEach(Array(status.secondary), id: \.self) { tag in
                    ConversationRowTagView(tag: tag, compact: true, scope: scope)
                }
            }
        }
    }
}
