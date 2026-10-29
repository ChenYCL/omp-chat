import SwiftUI
import OMPCore

// Pure data mapping + plain SwiftUI views: nothing here is iOS-specific, so
// it stays cross-platform and is covered by `swift test` on macOS even
// though only the iOS remote console (`RemoteConsoleScreen.swift`) uses it.
/// Chip view-model derived from `RelayMentionAttachment`: plain data so the
/// mapping from wire message to chip labels is covered by a unit test
/// without needing SwiftUI or a live view hierarchy.
public struct RemoteMentionChipInfo: Equatable, Identifiable, Sendable {
    public var id: Int
    public var title: String
    public var icon: String
    public var truncated: Bool

    public init(id: Int, title: String, icon: String, truncated: Bool) {
        self.id = id
        self.title = title
        self.icon = icon
        self.truncated = truncated
    }
}

/// Maps a mirrored `RelayMessage` to what the remote console renders for its
/// mentions: one chip per attachment plus the 提及说明 note lines, unchanged.
enum RemoteMentionMapper {
    /// One chip per `RelayMessage.attached` entry, same icon set as the
    /// desktop `MentionAttachmentChips.icon(_:)` (`MessageRow.swift`).
    static func chips(for message: RelayMessage) -> [RemoteMentionChipInfo] {
        (message.attached ?? []).enumerated().map { index, attachment in
            RemoteMentionChipInfo(
                id: index,
                title: attachment.title,
                icon: icon(for: attachment.kind),
                truncated: attachment.truncated
            )
        }
    }

    /// The 提及说明 lines; empty when the message attached nothing or cut
    /// nothing out.
    static func notes(for message: RelayMessage) -> [String] {
        message.mentionNotes ?? []
    }

    private static func icon(for kind: String?) -> String {
        switch kind {
        case "file": "doc.text"
        case "chat": "bubble.left"
        case "tab": "globe"
        case "skill": "sparkles"
        default: "info.circle"
        }
    }
}

/// Compact read-only chips for the mentions a message attached. The resolved
/// content stays on the Mac (`MessageRow.swift` owns the real detail), so
/// tapping a chip only confirms that and never fakes content on the phone.
struct RemoteMentionChipsView: View {
    let chips: [RemoteMentionChipInfo]
    @State private var expanded: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteMentionChipFlow(spacing: 6) {
                ForEach(chips) { chip in
                    chipButton(chip)
                }
            }
            if let expanded, chips.contains(where: { $0.id == expanded }) {
                Text("注：内容在 Mac 上查看")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.ompCard.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier("remote.message.attached.detail")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.message.attached")
        .accessibilityLabel("附上的内容：" + chips.map(\.title).joined(separator: "、"))
    }

    private func chipButton(_ chip: RemoteMentionChipInfo) -> some View {
        let open = expanded == chip.id
        return Button {
            expanded = open ? nil : chip.id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: chip.icon)
                    .font(.system(size: 10))
                Text(chip.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if chip.truncated {
                    Image(systemName: "scissors")
                        .font(.system(size: 9))
                }
            }
            .foregroundStyle(Color.ompTextSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 200)
            .background(Color.ompCard, in: Capsule())
            .overlay(Capsule().strokeBorder(open ? Color.accentColor.opacity(0.5) : Color.ompBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Small secondary note block for the 提及说明 lines (mentions left out or
/// cut short), mirroring `MessageRow.mentionNotes(_:)` at phone scale.
struct RemoteMentionNotesView: View {
    let notes: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(notes.joined(separator: "\n"))
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.ompTextSecondary)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote.message.notes")
    }
}

/// Lays chips out left to right, wrapping onto new rows. Independent copy of
/// `MessageRow.swift`'s `MentionChipFlow` (file-private there) so the remote
/// console has no cross-file dependency on desktop-only chip internals.
private struct RemoteMentionChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let points = arrange(sizes, width: bounds.width).points
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y),
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    private func arrange(_ sizes: [CGSize], width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}

