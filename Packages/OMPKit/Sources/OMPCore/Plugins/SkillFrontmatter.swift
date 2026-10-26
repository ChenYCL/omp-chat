import Foundation

/// The YAML that `SKILL.md` frontmatter and `agents/openai.yaml` use: block
/// maps, block lists, plain / single-quoted / double-quoted scalars, and
/// literal (`|`) and folded (`>`) block scalars with chomping indicators.
/// Flow collections (`[a, b]`, `{a: b}`) are kept as raw text; anchors, tags
/// and multi-document streams are not supported.
///
/// Like Codex's frontmatter repair, a plain value may contain `: ` (prose
/// such as `description: Build for AWS: ECS`): everything after the key's
/// first `: ` is the value.
enum MiniYAML {
    indirect enum Value: Equatable {
        /// A plain (unquoted) scalar; may still be a number, bool or null.
        case plain(String)
        /// A quoted or block scalar: always a string.
        case string(String)
        case map([String: Value])
        case list([Value])
        /// A flow collection, unparsed.
        case flow(String)

        /// The scalar as a string, or nil for null; throws for anything
        /// that YAML would type as a number, bool or collection.
        func stringValue(field: String) throws -> String? {
            switch self {
            case .string(let text):
                return text
            case .plain(let text):
                if ["", "~", "null", "Null", "NULL"].contains(text) { return nil }
                if MiniYAML.isTypedPlain(text) { throw ParseError(message: "\(field) 必须是字符串") }
                return text
            case .map, .list, .flow:
                throw ParseError(message: "\(field) 必须是字符串")
            }
        }

        var boolValue: Bool? {
            guard case .plain(let text) = self else { return nil }
            switch text {
            case "true", "True", "TRUE": return true
            case "false", "False", "FALSE": return false
            default: return nil
            }
        }

        subscript(key: String) -> Value? {
            guard case .map(let map) = self else { return nil }
            return map[key]
        }
    }

    struct ParseError: Error, Equatable {
        var message: String
    }

    static func isTypedPlain(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if ["true", "false", ".inf", "-.inf", "+.inf", ".nan"].contains(lowered) { return true }
        if Int(text) != nil { return true }
        if text.hasPrefix("0x"), Int(text.dropFirst(2), radix: 16) != nil { return true }
        if text.hasPrefix("0o"), Int(text.dropFirst(2), radix: 8) != nil { return true }
        if text.first.map({ $0.isNumber || $0 == "-" || $0 == "+" || $0 == "." }) == true, Double(text) != nil { return true }
        return false
    }

    /// Parses a YAML document whose top level is a block map.
    static func parse(_ text: String) throws -> [String: Value] {
        var parser = Parser(text: text)
        return try parser.document()
    }

    private struct Line {
        var number: Int
        var indent: Int
        /// Text after the indent.
        var text: String
        /// The whole line as written.
        var raw: String
        var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
        var isComment: Bool { text.hasPrefix("#") }
    }

    private struct Parser {
        var lines: [Line]
        var index = 0

        init(text: String) {
            lines = text.components(separatedBy: "\n").enumerated().map { offset, raw in
                let indent = raw.prefix(while: { $0 == " " }).count
                return Line(number: offset + 1, indent: indent, text: String(raw.dropFirst(indent)), raw: raw)
            }
        }

        mutating func document() throws -> [String: Value] {
            skipEmpty()
            guard index < lines.count else { return [:] }
            let map = try mapping(indent: lines[index].indent)
            skipEmpty()
            if index < lines.count {
                throw ParseError(message: "第 \(lines[index].number) 行缩进不对")
            }
            return map
        }

        private mutating func skipEmpty() {
            while index < lines.count, lines[index].isBlank || lines[index].isComment { index += 1 }
        }

        private func checkTabs(_ line: Line) throws {
            if line.text.hasPrefix("\t") { throw ParseError(message: "第 \(line.number) 行的缩进不能用 Tab") }
        }

        private mutating func mapping(indent: Int) throws -> [String: Value] {
            var map: [String: Value] = [:]
            while true {
                skipEmpty()
                guard index < lines.count else { break }
                let line = lines[index]
                try checkTabs(line)
                if line.indent < indent { break }
                if line.indent > indent { throw ParseError(message: "第 \(line.number) 行缩进不对") }
                if line.text.hasPrefix("- ") || line.text == "-" {
                    throw ParseError(message: "第 \(line.number) 行出现了列表项，这里应是「键: 值」")
                }
                guard let (key, rest) = Self.splitKey(line.text) else {
                    throw ParseError(message: "第 \(line.number) 行不是「键: 值」")
                }
                if map[key] != nil { throw ParseError(message: "第 \(line.number) 行的键「\(key)」重复") }
                index += 1
                map[key] = try value(rest: rest, parentIndent: indent, line: line)
            }
            return map
        }

        private mutating func sequence(indent: Int) throws -> [Value] {
            var items: [Value] = []
            while true {
                skipEmpty()
                guard index < lines.count else { break }
                let line = lines[index]
                try checkTabs(line)
                guard line.indent == indent, line.text.hasPrefix("- ") || line.text == "-" else {
                    if line.indent > indent { throw ParseError(message: "第 \(line.number) 行缩进不对") }
                    break
                }
                let rest = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    index += 1
                    items.append(try nested(parentIndent: indent, line: line) ?? .plain(""))
                } else if Self.splitKey(rest) != nil, !rest.hasPrefix("\""), !rest.hasPrefix("'") {
                    // `- key: value` opens a map whose keys sit two columns in.
                    let column = indent + 2 + (line.text.dropFirst(2).prefix(while: { $0 == " " }).count)
                    lines[index] = Line(number: line.number, indent: column, text: rest, raw: line.raw)
                    items.append(.map(try mapping(indent: column)))
                } else {
                    index += 1
                    items.append(try value(rest: rest, parentIndent: indent, line: line))
                }
            }
            return items
        }

        /// A value that starts on the next lines, or nil when there is none.
        private mutating func nested(parentIndent: Int, line: Line) throws -> Value? {
            skipEmpty()
            guard index < lines.count else { return nil }
            let next = lines[index]
            if next.indent > parentIndent {
                if next.text.hasPrefix("- ") || next.text == "-" { return .list(try sequence(indent: next.indent)) }
                return .map(try mapping(indent: next.indent))
            }
            // A list may sit at its key's own indent.
            if next.indent == parentIndent, next.text.hasPrefix("- ") || next.text == "-" {
                return .list(try sequence(indent: next.indent))
            }
            return nil
        }

        private mutating func value(rest: String, parentIndent: Int, line: Line) throws -> Value {
            let text = rest.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") {
                return try nested(parentIndent: parentIndent, line: line) ?? .plain("")
            }
            if text.hasPrefix("|") || text.hasPrefix(">") {
                return .string(try blockScalar(header: text, parentIndent: parentIndent, line: line))
            }
            if text.hasPrefix("\"") || text.hasPrefix("'") {
                return .string(try quoted(text, line: line))
            }
            if text.hasPrefix("[") || text.hasPrefix("{") {
                return .flow(Self.stripComment(text))
            }
            return .plain(plain(Self.stripComment(text), parentIndent: parentIndent))
        }

        /// A plain scalar, with any more-indented continuation lines folded in.
        private mutating func plain(_ first: String, parentIndent: Int) -> String {
            var parts = [first]
            var pendingBreaks = 0
            while index < lines.count {
                let line = lines[index]
                if line.isBlank { pendingBreaks += 1; index += 1; continue }
                guard line.indent > parentIndent, !line.isComment else { break }
                parts.append(pendingBreaks > 0 ? String(repeating: "\n", count: pendingBreaks) : " ")
                parts.append(Self.stripComment(line.text.trimmingCharacters(in: .whitespaces)))
                pendingBreaks = 0
                index += 1
            }
            return parts.joined()
        }

        private mutating func blockScalar(header: String, parentIndent: Int, line: Line) throws -> String {
            let indicators = Self.stripComment(String(header.dropFirst())).trimmingCharacters(in: .whitespaces)
            let literal = header.hasPrefix("|")
            var chomp: Character = " "
            var explicitIndent: Int?
            for character in indicators {
                if character == "-" || character == "+" {
                    chomp = character
                } else if let digit = character.wholeNumberValue, digit > 0 {
                    explicitIndent = digit
                } else {
                    throw ParseError(message: "第 \(line.number) 行的块标量标记「\(header)」不对")
                }
            }

            var contentIndent = explicitIndent.map { parentIndent + $0 }
            var body: [String] = []
            while index < lines.count {
                let next = lines[index]
                if next.isBlank {
                    body.append(String(next.raw.dropFirst(min(next.raw.count, contentIndent ?? 0))))
                    index += 1
                    continue
                }
                if contentIndent == nil {
                    guard next.indent > parentIndent else { break }
                    contentIndent = next.indent
                }
                guard let contentIndent, next.indent >= contentIndent else { break }
                body.append(String(next.raw.dropFirst(contentIndent)))
                index += 1
            }
            // Trailing blank lines belong to chomping, not to the content.
            var trailing = 0
            while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                body.removeLast()
                trailing += 1
            }
            var text: String
            if literal {
                text = body.joined(separator: "\n")
            } else {
                text = ""
                var previousWasText = false
                for (offset, piece) in body.enumerated() {
                    let blank = piece.trimmingCharacters(in: .whitespaces).isEmpty
                    let moreIndented = piece.hasPrefix(" ")
                    if offset > 0 {
                        if blank {
                            text += "\n"
                        } else if previousWasText, !moreIndented {
                            text += " "
                        } else if !previousWasText {
                            // A break before text that follows blank lines was
                            // already written by those blank lines.
                        } else {
                            text += "\n"
                        }
                    }
                    if !blank { text += piece }
                    previousWasText = !blank && !moreIndented
                }
            }
            switch chomp {
            case "-": break
            case "+": if !body.isEmpty { text += "\n" + String(repeating: "\n", count: trailing) }
            default: if !body.isEmpty { text += "\n" }
            }
            return text
        }

        /// A quoted scalar that may continue on later lines.
        private mutating func quoted(_ first: String, line: Line) throws -> String {
            let quote = first.first!
            var source = String(first.dropFirst())
            while true {
                if let (content, rest) = Self.closingQuote(in: source, quote: quote) {
                    let trailing = Self.stripComment(rest).trimmingCharacters(in: .whitespaces)
                    guard trailing.isEmpty else { throw ParseError(message: "第 \(line.number) 行引号后面还有多余内容") }
                    return try Self.unescape(content, quote: quote, line: line)
                }
                guard index < lines.count else { throw ParseError(message: "第 \(line.number) 行的引号没有闭合") }
                source += "\n" + lines[index].raw
                index += 1
            }
        }

        // MARK: Lexing helpers

        /// `key: rest` (or `key:` at the end), with the key optionally quoted.
        static func splitKey(_ text: String) -> (String, String)? {
            if let quote = text.first, quote == "\"" || quote == "'" {
                guard let (key, rest) = closingQuote(in: String(text.dropFirst()), quote: quote),
                      rest.hasPrefix(":"), rest.count == 1 || rest.dropFirst().first == " " else { return nil }
                return (key, String(rest.dropFirst()))
            }
            var previous: Character?
            for (offset, character) in text.enumerated() {
                if character == "#", previous == " " { return nil }
                if character == ":" {
                    let after = text.index(text.startIndex, offsetBy: offset + 1)
                    if after == text.endIndex || text[after] == " " {
                        let key = String(text.prefix(offset)).trimmingCharacters(in: .whitespaces)
                        return key.isEmpty ? nil : (key, String(text[after...]))
                    }
                }
                previous = character
            }
            return nil
        }

        /// Content before the closing quote and what follows it.
        static func closingQuote(in text: String, quote: Character) -> (String, String)? {
            var content = ""
            var iterator = Array(text)
            var position = 0
            while position < iterator.count {
                let character = iterator[position]
                if quote == "\"", character == "\\", position + 1 < iterator.count {
                    content.append(character)
                    content.append(iterator[position + 1])
                    position += 2
                    continue
                }
                if character == quote {
                    if quote == "'", position + 1 < iterator.count, iterator[position + 1] == "'" {
                        content.append("''")
                        position += 2
                        continue
                    }
                    iterator.removeFirst(position + 1)
                    return (content, String(iterator))
                }
                content.append(character)
                position += 1
            }
            return nil
        }

        static func stripComment(_ text: String) -> String {
            var previous: Character = " "
            for (offset, character) in text.enumerated() {
                if character == "#", previous == " " || previous == "\t" {
                    return String(text.prefix(offset)).trimmingCharacters(in: .whitespaces)
                }
                previous = character
            }
            return text.trimmingCharacters(in: .whitespaces)
        }

        /// Folds line breaks (one break → space, n breaks → n−1 newlines)
        /// and resolves escapes.
        static func unescape(_ content: String, quote: Character, line: Line) throws -> String {
            let folded = fold(content)
            if quote == "'" { return folded.replacingOccurrences(of: "''", with: "'") }
            var result = ""
            var characters = Array(folded)[...]
            while let character = characters.popFirst() {
                guard character == "\\" else { result.append(character); continue }
                guard let escape = characters.popFirst() else { break }
                switch escape {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "0": result.append("\0")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case " ": result.append(" ")
                case "x", "u", "U":
                    let length = escape == "x" ? 2 : (escape == "u" ? 4 : 8)
                    let hex = String(characters.prefix(length))
                    characters = characters.dropFirst(length)
                    guard hex.count == length, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                        throw ParseError(message: "第 \(line.number) 行的转义「\\\(escape)\(hex)」不对")
                    }
                    result.unicodeScalars.append(scalar)
                default:
                    throw ParseError(message: "第 \(line.number) 行的转义「\\\(escape)」不对")
                }
            }
            return result
        }

        private static func fold(_ content: String) -> String {
            guard content.contains("\n") else { return content }
            let pieces = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            var result = pieces[0]
            var breaks = 0
            for piece in pieces.dropFirst() {
                if piece.isEmpty { breaks += 1; continue }
                result += breaks == 0 ? " " : String(repeating: "\n", count: breaks)
                result += piece
                breaks = 0
            }
            return result
        }
    }
}
