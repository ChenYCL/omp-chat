import SwiftUI
import OMPCore
import OMPDesign

#if os(iOS)
// MARK: - IOSStatusChips
//
// Moshi-style floating status chips under the transcript tail:
// `∠ +N -N` (diff), `↑in ↓out` (token usage), `Ω 操作 · N` (tool calls).
// Capsule h22 r11, ompCard fill + 0.5pt ompBorder stroke, 9pt icon, 11pt
// medium text. Horizontally scrollable; the whole row collapses (zero
// height) when the conversation has neither diff, usage nor tool calls.

/// Floating status chips row for the iOS chat screen.
struct IOSStatusChips: View {
    @Environment(ChatAppModel.self) private var model
    @Binding var showingSubagents: Bool

    var body: some View {
        if hasAnyContent {
            // A bare ScrollView is greedy vertically: inside the chat's
            // bottom-aligned ZStack it stretched over the whole transcript and
            // swallowed every tap on message content (tabs, buttons, links).
            // The row is exactly one chip tall.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let diff = totalDiff {
                        IOSStatusChip {
                            Image(systemName: "angle")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.ompTextTertiary)
                            Text("+\(diff.added)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.ompFlat(rgb: 0x1F7A34))
                            Text("-\(diff.removed)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.ompFlat(rgb: 0xB3261E))
                        }
                    }

                    if let usage = lastUsage {
                        IOSStatusChip {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.ompTextTertiary)
                            Text(TokenFormat.compact(usage.inputTokens))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.ompTextSecondary)
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.ompTextTertiary)
                            Text(TokenFormat.compact(usage.outputTokens))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.ompTextSecondary)
                        }
                    }

                    if toolCount > 0 {
                        Button {
                            showingSubagents = true
                        } label: {
                            IOSStatusChip {
                                Image(systemName: "omega")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.ompTextTertiary)
                                Text("操作 · \(toolCount)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.ompTextSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 22)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasAnyContent: Bool {
        totalDiff != nil || lastUsage != nil || toolCount > 0
    }

    private var lastUsage: TokenUsage? {
        model.selectedConversation?.messages.compactMap(\.usage).last
    }

    private var toolCount: Int {
        guard let conversation = model.selectedConversation else { return 0 }
        return conversation.messages.reduce(0) { count, msg in
            count + msg.parts.filter {
                if case .toolCall = $0 { return true }
                return false
            }.count
        }
    }

    private var totalDiff: (added: Int, removed: Int)? {
        guard let conversation = model.selectedConversation else { return nil }
        var added = 0
        var removed = 0
        for msg in conversation.messages {
            for part in msg.parts {
                if case .toolResult(let result) = part {
                    for line in result.outputText.split(separator: "\n", omittingEmptySubsequences: false) {
                        if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
                        else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
                    }
                }
            }
        }
        return (added == 0 && removed == 0) ? nil : (added, removed)
    }
}

/// One capsule chip: h22, r11, ompCard + 0.5pt ompBorder, icon 9pt, text 11pt medium.
struct IOSStatusChip<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Color.ompCard, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.ompBorder, lineWidth: 0.5))
    }
}
#endif
