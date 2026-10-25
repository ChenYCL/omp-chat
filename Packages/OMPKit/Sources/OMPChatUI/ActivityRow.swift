import SwiftUI
import OMPCore
import OMPDesign

// MARK: - Shared tool-call presentation helpers

/// Maps real tool-call names/arguments to Codex-style activity descriptions.
/// Only derives text from data actually present in the call; unknown tools
/// fall back to their raw name.
enum ActivityLog {
    static let pathKeys = ["file_path", "filepath", "filename", "notebook_path", "path", "file"]
    static let queryKeys = ["query", "pattern", "q", "search", "regex", "keyword", "term"]
    static let commandKeys = ["command", "cmd", "script", "instruction"]

    static func isRead(_ name: String) -> Bool {
        ["read", "view", "cat", "load"].contains { name.contains($0) }
    }

    static func isSearch(_ name: String) -> Bool {
        ["search", "grep", "find", "glob", "lookup", "query"].contains { name.contains($0) }
    }

    static func isRun(_ name: String) -> Bool {
        ["command", "bash", "shell", "zsh", "exec", "run", "terminal"].contains { name.contains($0) }
    }

    static func isEdit(_ name: String) -> Bool {
        ["write", "edit", "create", "patch", "replace", "apply", "save", "insert", "str_"].contains { name.contains($0) }
    }

    /// One-line description: 已读 <file> / 已搜索 <query> / 已运行 <cmd> / 已编辑 <file>.
    static func summary(for call: ToolCall, result: ToolResult?) -> String {
        let name = call.name.isEmpty ? (result?.name ?? "") : call.name
        let lowered = name.lowercased()
        if isRead(lowered), let target = argumentValue(in: call.argumentsJSON, keys: pathKeys) {
            return "已读 \(baseName(target))"
        }
        if isSearch(lowered), let query = argumentValue(in: call.argumentsJSON, keys: queryKeys) {
            return "已搜索 \(trim(firstLine(query), 40))"
        }
        if isRun(lowered), let command = argumentValue(in: call.argumentsJSON, keys: commandKeys) {
            return "已运行 \(trim(firstLine(command), 60))"
        }
        if isEdit(lowered), let file = argumentValue(in: call.argumentsJSON, keys: pathKeys) {
            return "已编辑 \(baseName(file))"
        }
        return name.isEmpty ? "工具调用" : name
    }

    /// File path for edit-like calls that carry one, for FileChangeCard.
    static func editedFilePath(in call: ToolCall) -> String? {
        guard isEdit(call.name.lowercased()) else { return nil }
        return argumentValue(in: call.argumentsJSON, keys: pathKeys)
    }

    /// Counts `+`/`-` prefixed lines in tool output, like a diff stat.
    static func toolDiff(_ result: ToolResult) -> (added: Int, removed: Int)? {
        var added = 0
        var removed = 0
        for line in result.outputText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        return (added == 0 && removed == 0) ? nil : (added, removed)
    }

    static func argumentValue(in argumentsJSON: String, keys: [String]) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        for key in keys {
            if let value = dictionary.first(where: { $0.key.lowercased() == key })?.value as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstLine(_ value: String) -> String {
        value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
    }

    private static func baseName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func trim(_ value: String, _ limit: Int) -> String {
        guard value.count > limit else { return value }
        return value.prefix(limit) + "…"
    }
}

/// Run = orange mini spinner, success = green check, failure = red cross.
public struct ToolStatusIcon: View {
    let result: ToolResult?

    public init(result: ToolResult?) {
        self.result = result
    }

    public var body: some View {
        if result == nil {
            ProgressView()
                .controlSize(.mini)
                .tint(Color.ompDynamic(light: 0xAB1616, dark: 0xFDB9AB))
        } else if let result, result.isError {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ompFlat(rgb: 0xDE4A43))
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ompDynamic(light: 0x055F51, dark: 0x42DEC2))
        }
    }
}

/// Codex activity row: single 26pt line, tap to expand the full arguments and
/// output on an `ompFill` panel.
public struct ActivityRow: View {
    let call: ToolCall
    let result: ToolResult?

    @State private var expanded = false

    public init(call: ToolCall, result: ToolResult?) {
        self.call = call
        self.result = result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Theme.Motion.quick) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    ToolStatusIcon(result: result)
                    Text(ActivityLog.summary(for: call, result: result))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let result, let delta = ActivityLog.toolDiff(result) {
                        DiffChip(added: delta.added, removed: delta.removed)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.ompTextTertiary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                details
            }
        }
    }

    /// Full arguments + output, mono 12.5pt on ompFill, errors in red.
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !call.argumentsJSON.isEmpty {
                Text(call.argumentsJSON)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Color.ompTextSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result, !result.outputText.isEmpty {
                Text(result.outputText)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(result.isError ? Color.ompFlat(rgb: 0xDE4A43) : Color.ompTextSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous))
    }
}

/// One edit-like tool call that carries a file path, rendered as a bordered
/// 40pt card before the action bar.
public struct FileChange: Identifiable {
    public let id: String
    public let call: ToolCall
    public let result: ToolResult?

    public init(id: String, call: ToolCall, result: ToolResult?) {
        self.id = id
        self.call = call
        self.result = result
    }
}

public struct FileChangeCard: View {
    let change: FileChange

    public init(change: FileChange) {
        self.change = change
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
            Text(ActivityLog.editedFilePath(in: change.call) ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.ompText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // The reference card shows an "Undo" affordance, but the data model
            // has no revert capability — rendering it as a dead label would be
            // a fake control, so the row exposes the real diff and detail only.
            if let result = change.result, let delta = ActivityLog.toolDiff(result) {
                DiffChip(added: delta.added, removed: delta.removed)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(Color.ompTextTertiary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(Color.ompCard, in: RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.officialMD, style: .continuous)
                .strokeBorder(Color.ompBorder, lineWidth: 1)
        )
    }
}
