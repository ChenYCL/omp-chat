import Foundation

/// Bold / italic / underline as Markdown source. The composer is a plain text
/// view, so "formatting" means inserting markers around the selection, and
/// pressing the same button again removes them.
public enum MarkdownFormatting {
    public enum Style: String, Sendable, CaseIterable {
        case bold, italic, underline

        var open: String {
            switch self {
            case .bold: return "**"
            case .italic: return "*"
            case .underline: return "<u>"
            }
        }

        var close: String {
            switch self {
            case .bold: return "**"
            case .italic: return "*"
            case .underline: return "</u>"
            }
        }
    }

    /// Applies `style` to `selection` inside `text` and returns the new text
    /// plus where the selection should sit afterwards.
    ///
    /// - A non-empty selection is wrapped (`重点` → `**重点**`), or unwrapped
    ///   when that exact marker already surrounds it.
    /// - A caret inserts `****` with the caret in the middle, so the next word
    ///   typed is bold.
    public static func toggle(
        _ style: Style,
        in text: String,
        selection: NSRange?
    ) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        // No reported selection (the SwiftUI field cannot report one): treat the
        // whole draft as selected, which is how the pills and 格式 menu behave.
        let range = clamp(selection ?? NSRange(location: 0, length: ns.length), to: ns.length)

        if range.length == 0 {
            let open = style.open
            let close = style.close
            let insertion = open + close
            let result = ns.replacingCharacters(in: range, with: insertion) as NSString
            return (result as String, NSRange(location: range.location + open.utf16.count, length: 0))
        }

        let selected = ns.substring(with: range)
        let before = range.location
        let after = ns.length - (range.location + range.length)
        let openLength = style.open.utf16.count
        let closeLength = style.close.utf16.count

        // Already exactly wrapped inside the selection: `**x**` → `x` for
        // bold, `*x*` → `x` for italic. `**x**` is not italic, so italic wraps
        // it again into `***x***` instead of stripping a star from each side.
        if selected.hasPrefix(style.open), selected.hasSuffix(style.close),
           selected.utf16.count > openLength + closeLength,
           carriesOnly(selected, style: style) {
            let inner = (selected as NSString).substring(
                with: NSRange(location: openLength, length: selected.utf16.count - openLength - closeLength)
            )
            let result = (ns.replacingCharacters(in: range, with: inner)) as NSString
            return (result as String, NSRange(location: before, length: inner.utf16.count))
        }

        // Markers just outside the selection: `**|x|**` → `x`.
        let leftStart = before - openLength
        let rightEnd = range.location + range.length + closeLength
        if leftStart >= 0, rightEnd <= ns.length,
           ns.substring(with: NSRange(location: leftStart, length: openLength)) == style.open,
           ns.substring(with: NSRange(location: range.location + range.length, length: closeLength)) == style.close,
           !hasInnerMarker(selected, style: style) {
            let result = (ns.replacingCharacters(
                in: NSRange(location: leftStart, length: range.length + openLength + closeLength),
                with: selected
            )) as NSString
            return (result as String, NSRange(location: leftStart, length: range.length))
        }

        let wrapped = style.open + selected + style.close
        let result = ns.replacingCharacters(in: range, with: wrapped) as NSString
        _ = after
        return (result as String, NSRange(location: before + openLength, length: selected.utf16.count))
    }

    /// True when the text's edge markers are exactly this style's markers,
    /// not a mix that includes another style.
    private static func carriesOnly(_ text: String, style: Style) -> Bool {
        let leading = text.prefix { $0 == "*" }.count
        let trailing = text.reversed().prefix { $0 == "*" }.count
        guard style == .bold || style == .italic else {
            return text.hasPrefix(style.open) && text.hasSuffix(style.close)
        }
        switch style {
        case .bold: return leading % 2 == 0 && leading >= 2 && trailing % 2 == 0
        case .italic: return leading % 2 == 1 && trailing % 2 == 1
        default: return false
        }
    }

    /// True when the text already carries this marker at its own edges, which
    /// means the outer markers are the ones being toggled off.
    private static func hasInnerMarker(_ text: String, style: Style) -> Bool {
        guard style == .bold || style == .italic else { return false }
        let stars = text.prefix { $0 == "*" }.count
        return style == .bold ? stars >= 2 && stars % 2 == 0 : stars % 2 == 1
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        let maxLength = length - location
        let clamped = max(0, min(range.length, maxLength))
        return NSRange(location: location, length: clamped)
    }

    /// Block styles. The composer reports no caret, so these act on the
    /// current block: the last paragraph of the draft.
    public enum BlockStyle: Sendable, Equatable {
        case heading(Int)
        case paragraph
        case bulletedList
        case numberedList
        case link
    }

    /// Applies `style` to the last paragraph of `text` (everything after the
    /// last blank line). A heading sets the paragraph's first line to that
    /// many `#`s, replacing any level already there; the same level again
    /// removes it. Paragraph strips heading and list markers. A bulleted list
    /// toggles `- ` on every line, a numbered list toggles `1. 2. …`. Link is
    /// the exception: it wraps the whole draft, and an empty draft becomes
    /// `[链接文字](https://)`.
    public static func applyBlock(_ style: BlockStyle, to text: String) -> String {
        if case .link = style {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "[链接文字](https://)" : "[\(trimmed)](https://)"
        }

        let lines = text.components(separatedBy: "\n")
        guard let start = lastParagraphStart(in: lines) else {
            return applyToParagraph([], style: style).joined(separator: "\n")
        }
        var result = lines
        result.replaceSubrange(start..., with: applyToParagraph(Array(lines[start...]), style: style))
        return result.joined(separator: "\n")
    }

    /// Index of the first line of the last paragraph, or nil when the text is
    /// empty or only whitespace.
    private static func lastParagraphStart(in lines: [String]) -> Int? {
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        var index = lines.count - 1
        while index > 0, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index -= 1 }
        while index > 0, !lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty { index -= 1 }
        return index
    }

    private static func applyToParagraph(_ lines: [String], style: BlockStyle) -> [String] {
        switch style {
        case .heading(let level):
            let marks = String(repeating: "#", count: max(1, min(level, 6)))
            guard let first = lines.first else { return ["\(marks) "] }
            let (existing, body) = headingParts(first)
            // Pressing the level the line already has removes it.
            if existing == marks.count { return [body] + Array(lines.dropFirst()) }
            return ["\(marks) \(body)"] + Array(lines.dropFirst())
        case .paragraph:
            let stripped = lines.map(stripMarker)
            return stripped.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ? [] : stripped
        case .bulletedList:
            if !lines.isEmpty, lines.allSatisfy(isBullet) { return lines.map(stripMarker) }
            return listLines(lines).enumerated().map { "- \($0.element)" }
        case .numberedList:
            if !lines.isEmpty, isNumbered(lines) { return lines.map(stripMarker) }
            return listLines(lines).enumerated().map { "\($0.offset + 1). \($0.element)" }
        case .link:
            return lines
        }
    }

    /// `(level, rest)` when the line opens with `#`s, otherwise `(nil, line)`.
    private static func headingParts(_ line: String) -> (Int?, String) {
        var index = line.startIndex
        var count = 0
        while index < line.endIndex, line[index] == "#", count < 6 {
            count += 1
            index = line.index(after: index)
        }
        guard count > 0, index == line.endIndex || line[index] == " " else { return (nil, line) }
        if index < line.endIndex { index = line.index(after: index) }
        return (count, String(line[index...]))
    }

    /// Removes one heading, bullet or numbering marker from a line.
    private static func stripMarker(_ line: String) -> String {
        if headingParts(line).0 != nil { return headingParts(line).1 }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        guard let dot = line.firstIndex(of: "."), line.distance(from: line.startIndex, to: dot) <= 9 else { return line }
        let digits = line[..<dot]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return line }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return line }
        return String(line[line.index(after: after)...])
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ")
    }

    private static func isNumbered(_ lines: [String]) -> Bool {
        lines.enumerated().allSatisfy { offset, line in
            line.hasPrefix("\(offset + 1). ")
        }
    }

    /// Content lines of a list, markers stripped. An empty paragraph yields one
    /// blank entry so the marker still appears for the next keystroke.
    private static func listLines(_ lines: [String]) -> [String] {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(stripMarker)
        return content.isEmpty ? [""] : content
    }
}

/// Position arithmetic for in-chat search: which hit to move to next.
public enum SearchCursor {
    /// Next index in `0..<count` after `current`, wrapping both ways.
    /// `current == nil` means nothing was jumped to yet: "next" starts at the
    /// first hit and "previous" at the last.
    public static func step(from current: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let base = current ?? (step > 0 ? -1 : 0)
        return ((base + step) % count + count) % count
    }
}
