import SwiftUI
import OMPCore
import OMPDesign

/// Collapsed Codex activity strip: one summary row ("<N> 个操作" + total diff
/// chip), expanding into bare ActivityRows (no dividers, 2pt gaps). The card
/// itself has no fill and no border, matching the reference transcript.
public struct OperationCard: View {
    let calls: [ToolCall]
    let results: [ToolResult]

    @State private var expanded = false

    public init(calls: [ToolCall], results: [ToolResult]) {
        self.calls = calls
        self.results = results
    }

    private var running: Bool { calls.count > results.count }

    private func result(for call: ToolCall) -> ToolResult? {
        results.first { $0.callID == call.id }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if expanded {
                ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                    ActivityRow(call: call, result: result(for: call))
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(Theme.Motion.quick) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.ompTextTertiary)
                if running {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.ompDynamic(light: 0xAB1616, dark: 0xFDB9AB))
                } else {
                    ToolStatusIcon(result: results.last)
                }
                Text("\(calls.count) 个操作")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ompTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let summary = diffSummary {
                    DiffChip(added: summary.added, removed: summary.removed)
                }
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var diffSummary: (added: Int, removed: Int)? {
        var added = 0
        var removed = 0
        for result in results {
            guard let delta = ActivityLog.toolDiff(result) else { continue }
            added += delta.added
            removed += delta.removed
        }
        return (added == 0 && removed == 0) ? nil : (added, removed)
    }
}

/// Green/red stat chip, e.g. `+12 -3` (official diff accent colours).
public struct DiffChip: View {
    let added: Int
    let removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    public var body: some View {
        HStack(spacing: 4) {
            if added > 0 {
                Text("+\(added)")
                    .foregroundStyle(Color.ompDynamic(light: 0x055F51, dark: 0x42DEC2))
            }
            if removed > 0 {
                Text("-\(removed)")
                    .foregroundStyle(Color.ompFlat(rgb: 0xDE4A43))
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .monospacedDigit()
    }
}
