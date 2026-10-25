import SwiftUI
import OMPCore
import OMPDesign

/// Collapsible "operations" card like Moshi's tool panel: a header row with a
/// count, then one row per tool call showing command, status and a diff chip.
public struct OperationCard: View {
    let calls: [ToolCall]
    let results: [ToolResult]

    @State private var expanded = false

    public init(calls: [ToolCall], results: [ToolResult]) {
        self.calls = calls
        self.results = results
    }

    private var running: Bool { calls.count > results.count }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().opacity(0.5)
                ForEach(Array(calls.enumerated()), id: \.offset) { index, call in
                    row(call, result: results.first { $0.callID == call.id })
                    if index < calls.count - 1 { Divider().opacity(0.4) }
                }
            }
        }
        .ompSurface(radius: Theme.Radius.officialLG, fill: .ompFill, border: .ompBorder)
    }

    private var header: some View {
        Button {
            withAnimation(Theme.Motion.quick) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.ompTextTertiary)
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor(results.count == calls.count ? results.last : nil))
                Text("操作")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.ompText)
                Text("\(calls.count)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
                if running {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if let summary = diffSummary {
                    DiffChip(added: summary.added, removed: summary.removed)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ call: ToolCall, result: ToolResult?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon(result))
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor(result))
                Text(call.name.isEmpty ? "工具调用" : call.name)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.ompText)
                    .lineLimit(1)
                Spacer()
                if let result, let delta = diff(of: result) {
                    DiffChip(added: delta.added, removed: delta.removed)
                }
            }
            if !call.argumentsJSON.isEmpty {
                Text(call.argumentsJSON)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Color.ompTextSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let result, !result.outputText.isEmpty {
                Text(result.outputText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(result.isError ? Color.ompFlat(rgb: 0xDE4A43) : Color.ompTextSecondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func statusIcon(_ result: ToolResult?) -> String {
        guard let result else { return "circle.dotted" }
        return result.isError ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    /// Official chat accent colours: success `#055f51`/`#42dec2`,
    /// failure `#de4a43`, still running `#ab1616`/`#fdb9ab` (orange accent).
    private func statusColor(_ result: ToolResult?) -> Color {
        guard let result else {
            return Color.ompDynamic(light: 0xAB1616, dark: 0xFDB9AB)
        }
        return result.isError
            ? Color.ompFlat(rgb: 0xDE4A43)
            : Color.ompDynamic(light: 0x055F51, dark: 0x42DEC2)
    }

    /// Counts `+`/`-` prefixed lines in tool output, like a diff stat.
    private func diff(of result: ToolResult) -> (added: Int, removed: Int)? {
        var added = 0
        var removed = 0
        for line in result.outputText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        return (added == 0 && removed == 0) ? nil : (added, removed)
    }

    private var diffSummary: (added: Int, removed: Int)? {
        var added = 0
        var removed = 0
        for result in results {
            guard let delta = diff(of: result) else { continue }
            added += delta.added
            removed += delta.removed
        }
        return (added == 0 && removed == 0) ? nil : (added, removed)
    }
}

/// Green/red stat chip, e.g. `+12 -3`.
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
                    .foregroundStyle(Color.green)
            }
            if removed > 0 {
                Text("-\(removed)")
                    .foregroundStyle(Color.red)
            }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.ompCard, in: Capsule())
    }
}
