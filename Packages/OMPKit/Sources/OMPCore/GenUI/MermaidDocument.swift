import Foundation

/// A small, honest subset of Mermaid: `flowchart`/`graph` (nodes + edges) and
/// `sequenceDiagram` (participants + messages). Anything else is not guessed
/// at — `parse` returns nil and the caller falls back to showing the source.
public struct MermaidDocument: Sendable, Equatable {
    public enum Direction: String, Sendable { case topDown, leftRight }
    public enum Diagram: Sendable, Equatable {
        case flowchart(Flowchart)
        case sequence(Sequence)
    }

    public struct Flowchart: Sendable, Equatable {
        public var direction: Direction
        public var nodes: [Node]
        public var edges: [Edge]
    }

    public struct Node: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var shape: Shape
        public enum Shape: String, Sendable { case box, rounded, diamond, circle }
    }

    public struct Edge: Sendable, Equatable {
        public var from: String
        public var to: String
        public var label: String?
        public var dashed: Bool
    }

    public struct Sequence: Sendable, Equatable {
        public var participants: [String]
        public var messages: [Message]
    }

    public struct Message: Sendable, Equatable {
        public var from: String
        public var to: String
        public var text: String
        public var dashed: Bool
        public var isReturn: Bool
    }

    public var diagram: Diagram

    /// Returns nil when the source is not one of the supported diagram types.
    public static func parse(_ source: String) -> MermaidDocument? {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first else { return nil }
        let head = header.lowercased()
        if head.hasPrefix("flowchart") || head.hasPrefix("graph") {
            return flowchart(lines: Array(lines.dropFirst()), header: header)
        }
        if head.hasPrefix("sequencediagram") {
            return sequence(lines: Array(lines.dropFirst()))
        }
        return nil
    }

    // MARK: - Flowchart

    private static func flowchart(lines: [String], header: String) -> MermaidDocument? {
        let direction: Direction = header.lowercased().hasSuffix("lr") ? .leftRight : .topDown
        var nodes: [String: Node] = [:]
        var order: [String] = []
        var edges: [Edge] = []

        func note(_ node: Node) {
            if nodes[node.id] == nil { order.append(node.id) }
            // A later mention with a label wins: `A[开始]` after a bare `A`.
            if nodes[node.id] == nil || node.label != node.id { nodes[node.id] = node }
        }

        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("subgraph") || line == "end" { continue }
            if lower.hasPrefix("style ") || lower.hasPrefix("classdef") || lower.hasPrefix("class ")
                || lower.hasPrefix("linkstyle") || lower.hasPrefix("click ") { continue }
            guard let chain = parseChain(line) else { continue }
            for endpoint in chain.endpoints { note(endpoint) }
            edges.append(contentsOf: chain.edges)
        }
        let list = order.compactMap { nodes[$0] }
        guard !list.isEmpty else { return nil }
        return MermaidDocument(diagram: .flowchart(Flowchart(direction: direction, nodes: list, edges: edges)))
    }

    /// `A[x] -->|是| B{y} --> C`: endpoints in order plus the edges between
    /// consecutive ones. A line without an arrow is a bare node declaration.
    struct Chain {
        var endpoints: [Node]
        var edges: [Edge]
    }

    static func parseChain(_ line: String) -> Chain? {
        var endpoints: [Node] = []
        var edges: [Edge] = []
        var rest = Substring(line)
        var pending: (dashed: Bool, label: String?)?

        func flushArrow(to token: Substring) {
            let text = token.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            for candidate in ["-.->", "-->", "==>", "---", "--"] where text == candidate {
                pending = (candidate.contains(".") || candidate == "--", nil)
                return
            }
            pending = (text.contains("."), nil)
        }

        while !rest.isEmpty {
            // The next arrow, or the end of the line.
            let arrowRange = rest.range(of: "-.->")
                ?? rest.range(of: "-->")
                ?? rest.range(of: "==>")
                ?? rest.range(of: "---")

            guard let range = arrowRange else {
                if let node = parseEndpoint(String(rest)) { endpoints.append(node) }
                break
            }
            let before = rest[..<range.lowerBound]
            if let node = parseEndpoint(String(before)) {
                endpoints.append(node)
            }
            let arrow = rest[range.lowerBound..<range.upperBound].description
            rest = rest[range.upperBound...]
            var label: String?
            if let bar = rest.firstIndex(of: "|"),
               rest[..<bar].trimmingCharacters(in: .whitespaces).isEmpty,
               let close = rest[rest.index(after: bar)...].firstIndex(of: "|") {
                label = String(rest[rest.index(after: bar)..<close]).trimmingCharacters(in: .whitespaces)
                rest = rest[rest.index(after: close)...]
            }
            pending = (arrow.contains("."), label)
            // The destination: everything up to the next arrow.
            let nextRange = rest.range(of: "-.->") ?? rest.range(of: "-->")
                ?? rest.range(of: "==>") ?? rest.range(of: "---")
            let destText = nextRange.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            if let dest = parseEndpoint(destText) {
                endpoints.append(dest)
                if let source = endpoints.dropLast().last {
                    edges.append(Edge(from: source.id, to: dest.id, label: pending?.label ?? label,
                                      dashed: pending?.dashed ?? false))
                }
                rest = nextRange.map { rest[$0.lowerBound...] } ?? ""
            } else {
                break
            }
        }
        guard !endpoints.isEmpty else { return nil }
        return Chain(endpoints: endpoints, edges: edges)
    }

    /// `A`, `A[文字]`, `A(文字)`, `A{判断}`, `A((圆))`.
    static func parseEndpoint(_ token: String) -> Node? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isLetter || first.isNumber || first == "_" else { return nil }
        var id = ""
        var rest = Substring(trimmed)
        while let ch = rest.first, ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
            id.append(ch)
            rest = rest.dropFirst()
        }
        guard !id.isEmpty else { return nil }
        let body = rest.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return Node(id: id, label: id, shape: .box) }
        let shape: Node.Shape
        let label: String
        if body.hasPrefix("((") && body.hasSuffix("))") {
            shape = .circle; label = String(body.dropFirst(2).dropLast(2))
        } else if body.hasPrefix("{") && body.hasSuffix("}") {
            shape = .diamond; label = String(body.dropFirst().dropLast())
        } else if body.hasPrefix("(") && body.hasSuffix(")") {
            shape = .rounded; label = String(body.dropFirst().dropLast())
        } else if body.hasPrefix("[") && body.hasSuffix("]") {
            shape = .box; label = String(body.dropFirst().dropLast())
        } else {
            return nil
        }
        let text = label.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
        return Node(id: id, label: text.isEmpty ? id : text, shape: shape)
    }

    // MARK: - Sequence

    private static func sequence(lines: [String]) -> MermaidDocument? {
        var participants: [String] = []
        var aliases: [String: String] = [:]
        var messages: [Message] = []

        func note(_ id: String) {
            if !participants.contains(id) { participants.append(id) }
        }
        func display(_ raw: String) -> String {
            let key = raw.trimmingCharacters(in: .whitespaces)
            return aliases[key] ?? key
        }

        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
                let body = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
                let parts = body.components(separatedBy: " as ")
                let id = parts[0].trimmingCharacters(in: .whitespaces)
                if parts.count == 2 { aliases[id] = parts[1].trimmingCharacters(in: .whitespaces) }
                note(id)
                continue
            }
            if lower.hasPrefix("note ") || lower.hasPrefix("loop ") || line == "end"
                || lower.hasPrefix("alt ") || lower.hasPrefix("else") || lower.hasPrefix("opt ")
                || lower.hasPrefix("activate ") || lower.hasPrefix("deactivate ") { continue }
            // Longest arrows first: "-->>" contains "->>", so the wrong order
            // leaves a stray "-" on the sender's name.
            guard let arrow = line.range(of: "-->>") ?? line.range(of: "->>")
                ?? line.range(of: "-->") ?? line.range(of: "->") else { continue }
            let from = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            var rest = line[arrow.upperBound...]
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let to = rest[..<colon].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: colon)...]
            guard !from.isEmpty, !to.isEmpty else { continue }
            note(from)
            note(to)
            let dashed = line[arrow.lowerBound..<arrow.upperBound].contains("--")
            messages.append(Message(
                from: display(from), to: display(to),
                text: rest.trimmingCharacters(in: .whitespaces),
                dashed: dashed, isReturn: dashed
            ))
        }
        guard !participants.isEmpty, !messages.isEmpty else { return nil }
        let names = participants.map(display)
        return MermaidDocument(diagram: .sequence(Sequence(participants: names, messages: messages)))
    }
}
