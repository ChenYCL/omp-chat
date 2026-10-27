import Foundation

/// What a composer mention points at (Codex `composer.atMentionList` /
/// `composer.skillMentionList`).
public enum MentionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case file, chat, tab, skill

    /// `$` invokes a skill; `@` attaches everything else.
    public var trigger: Character { self == .skill ? "$" : "@" }
}

/// One mention picked from the composer's list.
///
/// The composer shows it readably (`@说明.md`, `$review`; see
/// `MentionDraft`); what travels to the send path, the queue and the store
/// is a Markdown-link token in the shape Codex uses for linked mentions:
/// `[@说明.md](file:docs/说明.md)`, `[@标题](chat:<uuid>)`,
/// `[@标题](tab:<uuid>)`, `[$name](skill:/abs/SKILL.md)`.
/// Only the complete shape with a known kind and a valid target counts:
/// `a@b`, `@name`, `$5`, `[x](https://…)` and `[@x](file:///…)` stay text.
public struct ComposerMention: Hashable, Sendable {
    public var kind: MentionKind
    /// What the user reads after the trigger: a file name, a chat or tab
    /// title, a skill name.
    public var label: String
    /// File: a path relative to the working directory, or absolute. Chat
    /// and tab: the UUID. Skill: the absolute `SKILL.md` path.
    public var target: String

    /// Nil when `target` is not valid for `kind`.
    public init?(kind: MentionKind, label: String, target: String) {
        guard Self.isValidTarget(target, for: kind) else { return nil }
        self.kind = kind
        let flat = label.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        self.label = flat.isEmpty ? Self.fallbackLabel(kind: kind, target: target) : String(flat.prefix(Self.maxLabelLength))
        self.target = target
    }

    public var trigger: Character { kind.trigger }

    /// What the draft holds.
    public var token: String {
        "[\(trigger)\(Self.escapeLabel(label))](\(kind.rawValue):\(Self.encodeTarget(target)))"
    }

    /// What the sent message shows in its place.
    public var readable: String { "\(trigger)\(label)" }

    /// Same kind and target: the same thing, whatever its label.
    var key: String { "\(kind.rawValue):\(target)" }

    static let maxLabelLength = 120
    /// Longest encoded target a token may carry; longer is not a token.
    static let maxTargetLength = 4_096

    private static func fallbackLabel(kind: MentionKind, target: String) -> String {
        switch kind {
        case .file, .skill:
            let name = (target as NSString).lastPathComponent
            return name.isEmpty ? kind.rawValue : name
        case .chat: return "对话"
        case .tab: return "标签页"
        }
    }

    static func isValidTarget(_ target: String, for kind: MentionKind) -> Bool {
        guard !target.isEmpty, !target.contains("\0") else { return false }
        switch kind {
        case .chat, .tab:
            return UUID(uuidString: target) != nil
        case .skill:
            return target.hasPrefix("/") && (target as NSString).lastPathComponent == "SKILL.md"
        case .file:
            // `file:///…` is a URL someone wrote, never a token this app made.
            return !target.hasPrefix("//")
        }
    }

    // MARK: Encoding

    private static func escapeLabel(_ label: String) -> String {
        var out = ""
        for character in label {
            if character == "\\" || character == "[" || character == "]" { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Percent-encodes what would end or break the `(…)` part: `%` itself,
    /// parentheses, brackets, whitespace and control characters. Everything
    /// else, CJK included, stays readable.
    private static func encodeTarget(_ target: String) -> String {
        var out = ""
        for scalar in target.unicodeScalars {
            let breaks = "%()[]".unicodeScalars.contains(scalar)
                || scalar.properties.isWhitespace
                || scalar.properties.generalCategory == .control
            if breaks {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: Parsing

    /// A token found in a text, and the characters it spans.
    public struct Occurrence: Sendable {
        public var mention: ComposerMention
        public var range: Range<String.Index>
    }

    /// Every token in `text`, in order. A token preceded by a backslash is
    /// escaped text, not a mention.
    public static func occurrences(in text: String) -> [Occurrence] {
        var found: [Occurrence] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "[", !isEscaped(text, at: index), let parsed = token(in: text, at: index) {
                found.append(parsed)
                index = parsed.range.upperBound
            } else {
                index = text.index(after: index)
            }
        }
        return found
    }

    /// The mentions of `text` in order, each (kind, target) once.
    public static func mentions(in text: String) -> [ComposerMention] {
        var seen = Set<String>()
        return occurrences(in: text).map(\.mention).filter { seen.insert($0.key).inserted }
    }

    /// `text` with every token replaced by its readable `@label` / `$name`.
    public static func readable(_ text: String) -> String {
        replacing(in: text) { $0.mention.readable }
    }

    private static func replacing(in text: String, with replacement: (Occurrence) -> String) -> String {
        let found = occurrences(in: text)
        guard !found.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for occurrence in found {
            result += text[cursor..<occurrence.range.lowerBound]
            result += replacement(occurrence)
            cursor = occurrence.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    static func isEscaped(_ text: String, at index: String.Index) -> Bool {
        index > text.startIndex && text[text.index(before: index)] == "\\"
    }

    /// The token starting at the `[` at `start`, if the whole shape is there.
    private static func token(in text: String, at start: String.Index) -> Occurrence? {
        var index = text.index(after: start)
        guard index < text.endIndex else { return nil }
        let trigger = text[index]
        guard trigger == "@" || trigger == "$" else { return nil }
        index = text.index(after: index)

        // Label: up to the first unescaped `]`, on one line.
        var label = ""
        var closed = false
        while index < text.endIndex, label.count <= maxLabelLength {
            let character = text[index]
            if character.isNewline { return nil }
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                label.append(text[next])
                index = text.index(after: next)
                continue
            }
            if character == "[" { return nil }
            if character == "]" { closed = true; break }
            label.append(character)
            index = text.index(after: index)
        }
        guard closed, !label.isEmpty else { return nil }
        index = text.index(after: index)
        guard index < text.endIndex, text[index] == "(" else { return nil }
        index = text.index(after: index)

        // Kind, then `:`.
        var kindName = ""
        while index < text.endIndex, text[index].isASCII, text[index].isLetter, kindName.count <= 8 {
            kindName.append(text[index])
            index = text.index(after: index)
        }
        guard let kind = MentionKind(rawValue: kindName), kind.trigger == trigger,
              index < text.endIndex, text[index] == ":" else { return nil }
        index = text.index(after: index)

        // Target: up to `)`; never whitespace or another parenthesis.
        var encoded = ""
        var length = 0
        while index < text.endIndex, text[index] != ")" {
            let character = text[index]
            if character.isWhitespace || character.isNewline || character == "(" || character == "[" || character == "]" { return nil }
            length += 1
            if length > maxTargetLength { return nil }
            encoded.append(character)
            index = text.index(after: index)
        }
        guard index < text.endIndex, let target = encoded.removingPercentEncoding,
              let mention = ComposerMention(kind: kind, label: label, target: target) else { return nil }
        return Occurrence(mention: mention, range: start..<text.index(after: index))
    }

    // MARK: Typing

    /// The `@…` / `$…` being typed at the end of the draft: what the list
    /// searches for, and the characters a pick replaces.
    public struct ActiveQuery: Equatable, Sendable {
        public var trigger: Character
        public var query: String
        /// From the trigger to the end of the text.
        public var range: Range<String.Index>
        /// Where the trigger sits, in UTF-16 units; stable for one trigger
        /// while the query after it grows or shrinks.
        public var triggerOffset: Int
    }

    /// The query the caret (taken to be at the end, as the composer's text
    /// field exposes no caret) is typing, or nil.
    ///
    /// A trigger counts only at a word start: at the beginning, after
    /// whitespace, punctuation such as `(` or `，`, or a CJK character —
    /// Chinese is written without spaces, so `请看@说明` triggers. It does not
    /// count after a letter or digit (`a@b`, emails), after a backslash, `[`,
    /// or URL punctuation (`/`, `:`, `=`, `.` …), inside a word that holds
    /// `://`, or as `$` before a digit (`$5`).
    public static func activeQuery(in text: String) -> ActiveQuery? {
        guard let last = text.last, !last.isWhitespace, !last.isNewline else {
            return nil
        }
        var runStart = text.endIndex
        while runStart > text.startIndex {
            let previous = text.index(before: runStart)
            if text[previous].isWhitespace || text[previous].isNewline { break }
            runStart = previous
        }
        let run = text[runStart...]
        guard let at = run.lastIndex(where: { $0 == "@" || $0 == "$" }) else { return nil }
        let trigger = text[at]
        if at > text.startIndex {
            let previous = text[text.index(before: at)]
            if !isWordStart(after: previous) { return nil }
        }
        if text[runStart..<at].contains("://") { return nil }
        let query = String(text[text.index(after: at)...])
        if trigger == "$", let first = query.first, !first.isLetter { return nil }
        return ActiveQuery(trigger: trigger, query: query, range: at..<text.endIndex, triggerOffset: at.utf16Offset(in: text))
    }

    private static let blocksTrigger: Set<Character> = ["\\", "[", "]", ")", "_", "-", ".", "+", "%", "/", ":", "=", "&", "?", "#", "~", "@", "$", "'", "`"]

    static func isWordStart(after previous: Character) -> Bool {
        if previous.isWhitespace || previous.isNewline { return true }
        if blocksTrigger.contains(previous) { return false }
        if previous.unicodeScalars.contains(where: isCJK) { return true }
        return !(previous.isLetter || previous.isNumber)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, // kana
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: // hangul
            return true
        default:
            return false
        }
    }
}

extension ComposerMention: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, label, target
    }

    /// Validates like `init?(kind:label:target:)`: a stored mention with a
    /// target that is not valid for its kind fails to decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(MentionKind.self, forKey: .kind)
        let label = try container.decode(String.self, forKey: .label)
        let target = try container.decode(String.self, forKey: .target)
        guard let mention = ComposerMention(kind: kind, label: label, target: target) else {
            throw DecodingError.dataCorruptedError(forKey: .target, in: container, debugDescription: "提及的目标无效")
        }
        self = mention
    }
}

// MARK: - Draft

/// The composer's draft as the user sees it — `看 @说明.md 吧` — and the
/// mentions picked into it (Codex mention chips).
///
/// A picked mention counts while its readable form stands in the text as a
/// whole word: at a word start, as a trigger would be, and before
/// whitespace, punctuation, a CJK character or the end. Edited, it is plain
/// text again, for good once `pruned`. Tokens in the raw `[@x](file:x)`
/// shape (pasted, or set by a debug action) count wherever they stand.
/// `tokenized` is what the send path reads.
public struct MentionDraft: Equatable, Sendable {
    public var text: String
    /// Picked mentions, oldest first; no two share a readable form.
    public var picked: [ComposerMention]

    public init(text: String = "", picked: [ComposerMention] = []) {
        self.text = text
        self.picked = picked
    }

    /// A text holding tokens (a queued message going back to the
    /// composer), made readable, with its mentions picked.
    public init(tokenized: String) {
        self.init()
        appendTokenized(tokenized, separator: "")
    }

    // MARK: Reading

    /// Every mention in the text, in order: picked ones by their readable
    /// form, raw tokens by their shape.
    public var occurrences: [ComposerMention.Occurrence] {
        let tokens = ComposerMention.occurrences(in: text)
        return (tokens + readableOccurrences(skipping: tokens)).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The mentions the text holds, in order, each (kind, target) once.
    public var mentions: [ComposerMention] {
        var seen = Set<String>()
        return occurrences.map(\.mention).filter { seen.insert($0.key).inserted }
    }

    /// The draft without the picked mentions that no longer stand in it.
    public var pruned: MentionDraft {
        let live = Set(readableOccurrences(skipping: ComposerMention.occurrences(in: text)).map(\.mention.key))
        return MentionDraft(text: text, picked: picked.filter { live.contains($0.key) })
    }

    /// The text with each readable mention swapped for its token; raw
    /// tokens stay exactly as typed.
    public var tokenized: String {
        let found = readableOccurrences(skipping: ComposerMention.occurrences(in: text))
        guard !found.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for occurrence in found {
            result += text[cursor..<occurrence.range.lowerBound]
            result += occurrence.mention.token
            cursor = occurrence.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// The `@…` / `$…` being typed at the end, unless its trigger starts a
    /// mention already in the text: `看 @说明.md` with the space deleted is
    /// that mention, not a search.
    public var activeQuery: ComposerMention.ActiveQuery? {
        guard let query = ComposerMention.activeQuery(in: text) else { return nil }
        if occurrences.contains(where: { $0.range.contains(query.range.lowerBound) }) { return nil }
        return query
    }

    // MARK: Editing

    /// Puts `mention` in place of the query being typed, or at the end,
    /// then a space so typing goes on after it. A readable form another
    /// picked mention already has is relabelled — a file by its path,
    /// anything else numbered — so each form names one thing. Returns the
    /// mention as placed.
    @discardableResult
    public mutating func insert(_ mention: ComposerMention) -> ComposerMention {
        let query = activeQuery
        let placed = place(mention)
        if let query {
            text.replaceSubrange(query.range, with: placed.readable + " ")
        } else {
            let separator = text.isEmpty || text.last?.isWhitespace == true || text.last?.isNewline == true ? "" : " "
            text += separator + placed.readable + " "
        }
        return placed
    }

    /// Takes every appearance of `mention` (same kind and target) out of the
    /// text, each with one space after it, and out of `picked`.
    public mutating func remove(_ mention: ComposerMention) {
        var result = ""
        var cursor = text.startIndex
        for occurrence in occurrences where occurrence.mention.key == mention.key && occurrence.range.lowerBound >= cursor {
            result += text[cursor..<occurrence.range.lowerBound]
            cursor = occurrence.range.upperBound
            if cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
        }
        result += text[cursor...]
        text = result
        picked.removeAll { $0.key == mention.key }
    }

    /// Appends a text holding tokens, after `separator` unless the draft is
    /// empty. Each token becomes its readable form and is picked; a space
    /// goes in where the form would otherwise run into a neighbouring word.
    public mutating func appendTokenized(_ tokenized: String, separator: String) {
        guard !tokenized.isEmpty else { return }
        var result = text.isEmpty ? "" : text + separator
        let tokens = ComposerMention.occurrences(in: tokenized)
        var cursor = tokenized.startIndex
        for (index, occurrence) in tokens.enumerated() {
            result += tokenized[cursor..<occurrence.range.lowerBound]
            let placed = place(occurrence.mention)
            if let last = result.last, !ComposerMention.isWordStart(after: last) { result += " " }
            result += placed.readable
            cursor = occurrence.range.upperBound
            let nextIsToken = index + 1 < tokens.count && tokens[index + 1].range.lowerBound == cursor
            if cursor < tokenized.endIndex, nextIsToken || !Self.endsWord(tokenized, at: cursor) { result += " " }
        }
        result += tokenized[cursor...]
        text = result
    }

    /// `mention` as it joins `picked`: the picked one when it is already
    /// there, else relabelled until its readable form is free.
    private mutating func place(_ mention: ComposerMention) -> ComposerMention {
        if let existing = picked.first(where: { $0.key == mention.key }) { return existing }
        let taken = Set(picked.map(\.readable))
        var placed = mention
        if taken.contains(placed.readable), mention.kind == .file,
           let byPath = ComposerMention(kind: .file, label: mention.target, target: mention.target) {
            placed = byPath
        }
        // `taken` holds at most `picked.count` forms, so one of the next
        // `picked.count + 1` numbers is free.
        var number = 2
        while taken.contains(placed.readable), number <= picked.count + 2 {
            let base = String(mention.label.prefix(ComposerMention.maxLabelLength - 8))
            placed = ComposerMention(kind: mention.kind, label: "\(base) (\(number))", target: mention.target) ?? mention
            number += 1
        }
        picked.append(placed)
        return placed
    }

    // MARK: Matching

    /// Where picked mentions' readable forms stand as whole words, outside
    /// `tokens`. At one place the longest form wins.
    private func readableOccurrences(skipping tokens: [ComposerMention.Occurrence]) -> [ComposerMention.Occurrence] {
        guard !picked.isEmpty else { return [] }
        let candidates = picked.sorted { $0.readable.count > $1.readable.count }
        var found: [ComposerMention.Occurrence] = []
        var nextToken = 0
        var index = text.startIndex
        while index < text.endIndex {
            while nextToken < tokens.count, tokens[nextToken].range.upperBound <= index { nextToken += 1 }
            let tokenStart = nextToken < tokens.count ? tokens[nextToken].range.lowerBound : text.endIndex
            if index >= tokenStart {
                index = tokens[nextToken].range.upperBound
                continue
            }
            let character = text[index]
            if character == "@" || character == "$",
               index == text.startIndex || ComposerMention.isWordStart(after: text[text.index(before: index)]),
               let match = candidates.lazy.compactMap({ self.match($0, at: index, before: tokenStart) }).first {
                found.append(match)
                index = match.range.upperBound
            } else {
                index = text.index(after: index)
            }
        }
        return found
    }

    private func match(_ mention: ComposerMention, at start: String.Index, before limit: String.Index) -> ComposerMention.Occurrence? {
        var cursor = start
        for character in mention.readable {
            guard cursor < limit, text[cursor] == character else { return nil }
            cursor = text.index(after: cursor)
        }
        guard Self.endsWord(text, at: cursor) else { return nil }
        return ComposerMention.Occurrence(mention: mention, range: start..<cursor)
    }

    private static let continuesWord: Set<Character> = ["_", "-", "/", "\\", "@", "$", "%", "+", "=", "&", "#", "~", "`"]
    private static let sentenceMarks: Set<Character> = [".", ",", ":", ";", "!", "?"]

    /// Whether a mention ending just before `index` ends a word there.
    static func endsWord(_ text: String, at index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        let character = text[index]
        if character.isWhitespace || character.isNewline { return true }
        if character.unicodeScalars.contains(where: ComposerMention.isCJK) { return true }
        if character.isLetter || character.isNumber || continuesWord.contains(character) { return false }
        if sentenceMarks.contains(character) {
            // `@说明.md.` ends a sentence; `@说明.md.bak` names another file.
            let next = text.index(after: index)
            return next == text.endIndex || text[next].isWhitespace || text[next].isNewline
        }
        return true
    }
}

extension Skill {
    /// Where the `$` list says a skill comes from (official
    /// `composer.skillMentionList.*Source`). OMPChat bundles no skills, so
    /// 内置 never appears.
    public var mentionSourceLabel: String {
        switch scope {
        case .repository: "项目"
        case .user: "本地文件"
        case .plugin(let id): "插件：\(id) · \(GitInfo.tildified(directory))"
        }
    }
}

// MARK: - Resolution

/// How much a mention may add to a message, in UTF-8 bytes.
public struct MentionLimits: Equatable, Sendable {
    public var fileBytes: Int
    public var chatBytes: Int
    public var tabBytes: Int
    public var skillBytes: Int
    /// Everything one message's mentions add together.
    public var totalBytes: Int
    /// A chat mention quotes at most this many of its latest messages.
    public var chatMessages: Int

    public init(
        fileBytes: Int = 64 * 1024, chatBytes: Int = 16 * 1024, tabBytes: Int = 32 * 1024,
        skillBytes: Int = 32 * 1024, totalBytes: Int = 128 * 1024, chatMessages: Int = 20
    ) {
        self.fileBytes = fileBytes
        self.chatBytes = chatBytes
        self.tabBytes = tabBytes
        self.skillBytes = skillBytes
        self.totalBytes = totalBytes
        self.chatMessages = chatMessages
    }

    public static let standard = MentionLimits()
}

/// What mentions resolve against, gathered on the main actor; files and
/// skill bodies are read by `MentionResolver` itself.
public struct MentionSources: Sendable {
    public struct Chat: Sendable {
        public var title: String
        public var messages: [ChatMessage]
        public var isLocked: Bool

        public init(title: String, messages: [ChatMessage], isLocked: Bool = false) {
            self.title = title
            self.messages = messages
            self.isLocked = isLocked
        }
    }

    public struct Tab: Sendable {
        public var title: String
        public var url: String
        /// `document.body.innerText` of the tab's live page; nil when the
        /// page is not open.
        public var pageText: String?

        public init(title: String, url: String, pageText: String?) {
            self.title = title
            self.url = url
            self.pageText = pageText
        }
    }

    public var workingDirectory: String?
    public var home: String
    /// File targets the user picked from the list. Only these may name a
    /// file outside the working directory, and only as absolute paths.
    public var pickedTargets: Set<String>
    public var chats: [UUID: Chat]
    public var tabs: [UUID: Tab]
    public var skills: [Skill]

    public init(
        workingDirectory: String?, home: String, pickedTargets: Set<String> = [],
        chats: [UUID: Chat] = [:], tabs: [UUID: Tab] = [:], skills: [Skill] = []
    ) {
        self.workingDirectory = workingDirectory
        self.home = home
        self.pickedTargets = pickedTargets
        self.chats = chats
        self.tabs = tabs
        self.skills = skills
    }
}

/// A message's mentions turned into the context the model reads.
public struct MentionResolution: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public var mention: ComposerMention
        /// The message part: a header line, then the content fenced.
        public var text: String
        /// Cut short by its own cap or the total.
        public var truncated: Bool
    }

    public var blocks: [Block] = []
    /// Mentions left out or cut, one line each; nothing here stops a send.
    public var notes: [String] = []

    public init(blocks: [Block] = [], notes: [String] = []) {
        self.blocks = blocks
        self.notes = notes
    }

    public var isEmpty: Bool { blocks.isEmpty && notes.isEmpty }

    /// The text parts that follow the user's own text, the way folded pastes
    /// do: every block, then one part with the notes.
    public var attachments: [MentionAttachment] {
        var attachments = blocks.map { MentionAttachment(mention: $0.mention, text: $0.text, truncated: $0.truncated) }
        if !notes.isEmpty { attachments.append(MentionAttachment(notes: notes)) }
        return attachments
    }
}

/// One text part a message's mentions add after what the user wrote: a
/// resolved mention, or the 提及说明 note on the mentions left out or cut.
public struct MentionAttachment: Codable, Hashable, Sendable {
    /// The mention it resolves; nil for the note.
    public var mention: ComposerMention?
    /// The part the model reads.
    public var text: String
    /// Cut short by its own cap or the message's total.
    public var truncated: Bool
    /// The note's lines; empty for a mention.
    public var notes: [String]

    public init(mention: ComposerMention, text: String, truncated: Bool = false) {
        self.mention = mention
        self.text = text
        self.truncated = truncated
        self.notes = []
    }

    public init(notes: [String]) {
        self.mention = nil
        self.text = "\n\n提及说明：\n" + notes.map { "- " + $0 }.joined(separator: "\n")
        self.truncated = false
        self.notes = notes
    }
}

/// Marks one `.text` part of a sent user message as attached context — a
/// resolved mention, or the note on the ones left out — rather than what
/// the user wrote. The part stays `.text`, so every provider sends exactly
/// what it sent before; the mark only tells screens to show a chip or a
/// note line instead of the text.
public struct MessageMention: Codable, Hashable, Sendable {
    /// Index into `ChatMessage.parts`.
    public var part: Int
    /// UTF-8 length of that part when it was marked. A message rebuilt since
    /// no longer matches, and the part reads as ordinary text again.
    public var byteCount: Int
    /// The mention it resolves; nil for the note.
    public var mention: ComposerMention?
    public var truncated: Bool
    /// The note's lines; empty for a mention.
    public var notes: [String]

    public init(part: Int, attachment: MentionAttachment) {
        self.part = part
        self.byteCount = attachment.text.utf8.count
        self.mention = attachment.mention
        self.truncated = attachment.truncated
        self.notes = attachment.notes
    }
}

extension ChatMessage {
    /// The marks in `mentions` that still describe their part, by index.
    public var mentionParts: [Int: MessageMention] {
        var found: [Int: MessageMention] = [:]
        for mark in mentions where parts.indices.contains(mark.part) {
            guard case .text(let value) = parts[mark.part], value.utf8.count == mark.byteCount else { continue }
            found[mark.part] = mark
        }
        return found
    }

    /// What the user wrote: the text parts without the attached mention
    /// context. `concatenatedText` for a message without mentions; the model
    /// always reads `concatenatedText`.
    public var writtenText: String {
        let marked = mentionParts
        guard !marked.isEmpty else { return concatenatedText }
        return parts.enumerated().compactMap { index, part -> String? in
            guard marked[index] == nil, case .text(let value) = part else { return nil }
            return value
        }.joined()
    }

    /// The mentions attached to the message, in order, each with the text
    /// the model read for it.
    public var mentionAttachments: [MentionAttachment] {
        mentionParts.sorted { $0.key < $1.key }.compactMap { index, mark in
            guard let mention = mark.mention, case .text(let value) = parts[index] else { return nil }
            return MentionAttachment(mention: mention, text: value, truncated: mark.truncated)
        }
    }

    /// The 提及说明 lines: mentions that were left out or cut short.
    public var mentionNotes: [String] {
        mentionParts.sorted { $0.key < $1.key }.first { $0.value.mention == nil }?.value.notes ?? []
    }

    /// How the message reads quoted into another prompt (旁聊, a chat
    /// mention): what the user wrote, and one line naming what was attached,
    /// without the attached content.
    public var quotedText: String {
        let names = mentionAttachments.compactMap { $0.mention?.readable }
        guard !names.isEmpty else { return writtenText }
        return writtenText + "\n（这条消息附上了 " + names.joined(separator: "、") + " 的内容）"
    }
}

public enum MentionResolver {
    /// Resolves `mentions` in order, each (kind, target) once. Reads files
    /// and skill bodies, so call it off the main actor.
    public static func resolve(_ mentions: [ComposerMention], sources: MentionSources, limits: MentionLimits = .standard) -> MentionResolution {
        var resolution = MentionResolution()
        var used = 0
        var seen = Set<String>()
        var leftOut: [String] = []
        var cutByTotal: [String] = []
        for mention in mentions where seen.insert(mention.key).inserted {
            let remaining = limits.totalBytes - used
            let piece: Piece
            switch mention.kind {
            case .file: piece = file(mention, sources: sources, cap: limits.fileBytes, budget: remaining)
            case .chat: piece = chat(mention, sources: sources, cap: limits.chatBytes, budget: remaining, count: limits.chatMessages)
            case .tab: piece = tab(mention, sources: sources, cap: limits.tabBytes, budget: remaining)
            case .skill: piece = skill(mention, sources: sources, cap: limits.skillBytes, budget: remaining)
            }
            switch piece {
            case .refused(let note):
                resolution.notes.append(note)
            case .overBudget:
                leftOut.append(mention.readable)
            case .content(let content):
                used += content.body.utf8.count
                if content.cutByTotal { cutByTotal.append(mention.readable) }
                if let note = content.note { resolution.notes.append(note) }
                resolution.blocks.append(.init(
                    mention: mention, text: render(content),
                    truncated: content.truncated
                ))
            }
        }
        if !cutByTotal.isEmpty || !leftOut.isEmpty {
            var line = "提及的内容合计超过 \(kilobytes(limits.totalBytes)) 上限："
            if !cutByTotal.isEmpty { line += cutByTotal.joined(separator: "、") + " 只附上了开头" }
            if !cutByTotal.isEmpty, !leftOut.isEmpty { line += "，" }
            if !leftOut.isEmpty { line += leftOut.joined(separator: "、") + " 没有附上" }
            resolution.notes.append(line + "。")
        }
        return resolution
    }

    // MARK: Pieces

    private struct Content {
        var header: String
        var language: String?
        var body: String
        /// Shown in 提及说明 (truncation by the mention's own cap, a page
        /// that is not open).
        var note: String?
        var truncated = false
        var cutByTotal = false
    }

    private enum Piece {
        case content(Content)
        case refused(String)
        /// Nothing of the total is left for it.
        case overBudget
    }

    private static func file(_ mention: ComposerMention, sources: MentionSources, cap: Int, budget: Int) -> Piece {
        let shown = mention.target
        let path: String
        let directory = sources.workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
        if mention.target.hasPrefix("/") || mention.target.hasPrefix("~/") {
            guard let absolute = AgentPathPolicy.resolve(mention.target, workingDirectory: nil, home: sources.home) else {
                return .refused("文件 \(shown) 的路径无效，没有附上。")
            }
            let inside = directory.map { AgentPathPolicy.isInside(absolute, root: $0) } ?? false
            guard inside || sources.pickedTargets.contains(mention.target) else {
                return .refused("文件 \(shown) 不在工作目录里，只有从列表里选取的文件才会附上。")
            }
            path = absolute
        } else {
            guard let directory, let joined = AgentPathPolicy.resolve(mention.target, workingDirectory: directory, home: sources.home) else {
                return .refused("这个对话没有工作目录，文件 \(shown) 没有附上。")
            }
            guard AgentPathPolicy.isInside(joined, root: directory) else {
                return .refused("文件 \(shown) 在工作目录之外，没有附上。")
            }
            path = joined
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .refused("文件 \(shown) 已不存在，没有附上。")
        }
        if isDirectory.boolValue { return .refused("\(shown) 是文件夹，没有附上。") }
        guard budget > 0 else { return .overBudget }
        let limit = min(cap, budget)
        let text: String
        let size: Int
        switch readText(at: path, limit: limit) {
        case .text(let value, let total):
            text = value
            size = total
        case .binary:
            return .refused("文件 \(shown) 不是 UTF-8 文本（可能是二进制文件），没有附上。")
        case .unreadable:
            return .refused("文件 \(shown) 无法读取，没有附上。")
        }
        var content = Content(header: "提及的文件 `\(shown)`：", language: language(of: path), body: text)
        if size > limit {
            content.truncated = true
            if limit == cap {
                content.note = "文件 \(shown) 共 \(kilobytes(size))，只附上了前 \(kilobytes(cap))。"
            } else {
                content.cutByTotal = true
            }
        }
        return .content(content)
    }

    private static func chat(_ mention: ComposerMention, sources: MentionSources, cap: Int, budget: Int, count: Int) -> Piece {
        guard let id = UUID(uuidString: mention.target), let chat = sources.chats[id] else {
            return .refused("对话「\(mention.label)」已不存在，没有附上。")
        }
        if chat.isLocked { return .refused("对话「\(mention.label)」已锁定，没有附上。") }
        guard budget > 0 else { return .overBudget }
        let limit = min(cap, budget)
        let entries = chat.messages.compactMap(chatEntry).suffix(max(0, count))
        let title = singleLine(chat.title)
        guard !entries.isEmpty else {
            return .content(Content(header: "提及的对话「\(title)」：", body: "（这个对话还没有内容）"))
        }
        // Newest first until the cap; older messages drop whole.
        var kept: [String] = []
        var used = 0
        var cut = false
        for entry in entries.reversed() {
            let cost = entry.utf8.count + (kept.isEmpty ? 0 : 1)
            if used + cost <= limit {
                kept.append(entry)
                used += cost
            } else {
                if kept.isEmpty {
                    // The newest alone is over: keep its end, the part a
                    // follow-up is most likely about.
                    kept.append(suffix(entry, bytes: limit))
                }
                cut = true
                break
            }
        }
        var content = Content(
            header: "提及的对话「\(title)」（最近 \(kept.count) 条消息）：",
            body: kept.reversed().joined(separator: "\n")
        )
        if cut {
            content.truncated = true
            if limit == cap {
                content.note = "对话「\(title)」超过 \(kilobytes(cap))，只附上了最近的内容。"
            } else {
                content.cutByTotal = true
            }
        }
        return .content(content)
    }

    private static func tab(_ mention: ComposerMention, sources: MentionSources, cap: Int, budget: Int) -> Piece {
        guard let id = UUID(uuidString: mention.target), let tab = sources.tabs[id] else {
            return .refused("标签页「\(mention.label)」已关闭，没有附上。")
        }
        guard budget > 0 else { return .overBudget }
        let limit = min(cap, budget)
        let title = singleLine(tab.title)
        let address = "地址：\(tab.url)"
        guard let page = tab.pageText else {
            var content = Content(header: "提及的标签页「\(title)」：", body: prefix(address, bytes: limit))
            content.note = "标签页「\(title)」的页面没有在浏览器面板里打开，只附上了标题和地址。"
            return .content(content)
        }
        let text = page.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = address + "\n\n" + (text.isEmpty ? "（页面没有文字）" : text)
        var content = Content(header: "提及的标签页「\(title)」：", body: prefix(full, bytes: limit))
        if full.utf8.count > limit {
            content.truncated = true
            if limit == cap {
                content.note = "标签页「\(title)」的页面文字超过 \(kilobytes(cap))，只附上了开头。"
            } else {
                content.cutByTotal = true
            }
        }
        return .content(content)
    }

    private static func skill(_ mention: ComposerMention, sources: MentionSources, cap: Int, budget: Int) -> Piece {
        guard let skill = sources.skills.first(where: { $0.path == mention.target }) else {
            return .refused("技能 \(mention.readable) 已不存在，没有附上。")
        }
        guard budget > 0 else { return .overBudget }
        let limit = min(cap, budget)
        let text: String
        let size: Int
        switch readText(at: skill.path, limit: limit) {
        case .text(let value, let total):
            text = value
            size = total
        case .binary, .unreadable:
            return .refused("技能 \(mention.readable) 的 SKILL.md 无法读取，没有附上。")
        }
        var content = Content(
            header: "用户在这条消息里用 $\(skill.name) 显式调用了技能「\(skill.name)」（\(skill.mentionSourceLabel)，\(skill.path)）。"
                + "请按下面的 SKILL.md 去做，其中的相对路径以 \(skill.directory) 为准：",
            language: "markdown",
            body: text
        )
        if size > limit {
            content.truncated = true
            if limit == cap {
                content.note = "技能 $\(skill.name) 的 SKILL.md 共 \(kilobytes(size))，只附上了前 \(kilobytes(cap))。"
            } else {
                content.cutByTotal = true
            }
        }
        return .content(content)
    }

    // MARK: Helpers

    private static func render(_ content: Content) -> String {
        let fence = fence(for: content.body)
        return "\n\n\(content.header)\n\(fence)\(content.language ?? "")\n\(content.body)\n\(fence)"
    }

    /// Three backticks, or one more than the longest run in `body`, so the
    /// content cannot close its own fence.
    static func fence(for body: String) -> String {
        var longest = 0
        var run = 0
        for byte in body.utf8 {
            if byte == UInt8(ascii: "`") {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private enum Read {
        case text(String, totalBytes: Int)
        case binary
        case unreadable
    }

    /// The first `limit` bytes of the file as UTF-8 text. A NUL byte or
    /// bytes that are not UTF-8 make it binary; a character the limit cuts
    /// in half is dropped, not mistaken for binary.
    private static func readText(at path: String, limit: Int) -> Read {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue
        guard let data = try? handle.read(upToCount: max(0, limit)) ?? Data() else { return .unreadable }
        if data.contains(0) { return .binary }
        let total = max(size ?? data.count, data.count)
        if let text = String(data: data, encoding: .utf8) { return .text(text, totalBytes: total) }
        if total > data.count {
            for drop in 1...3 where data.count > drop {
                if let text = String(data: data.dropLast(drop), encoding: .utf8) { return .text(text, totalBytes: total) }
            }
        }
        return .binary
    }

    private static func language(of path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 12, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return ext
    }

    private static func chatEntry(_ message: ChatMessage) -> String? {
        let text = message.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch message.role {
        case .user: return "用户：\(text)"
        case .assistant: return "助手：\(text)"
        case .system, .tool: return nil
        }
    }

    private static func singleLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(flat.prefix(ComposerMention.maxLabelLength))
    }

    static func kilobytes(_ bytes: Int) -> String {
        "\((bytes + 1023) / 1024) KB"
    }

    /// The longest leading part of `text` within `bytes` UTF-8 bytes, cut
    /// between characters.
    static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let cost = text[index].utf8.count
            if used + cost > bytes { break }
            used += cost
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// The longest trailing part of `text` within `bytes` UTF-8 bytes.
    static func suffix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var used = 0
        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            let cost = text[previous].utf8.count
            if used + cost > bytes { break }
            used += cost
            start = previous
        }
        return String(text[start...])
    }
}
