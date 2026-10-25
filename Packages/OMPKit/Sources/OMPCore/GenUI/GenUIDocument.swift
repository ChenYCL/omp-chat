import Foundation

/// Generative UI ("omp-ui"): a component tree the model writes inside a
/// ```omp-ui fenced block, one JSON object per line.
///
/// Line-delimited on purpose: while a reply streams, every completed line is a
/// complete component, so the interface grows line by line instead of waiting
/// for one large JSON document to close. A later line that reuses an `id`
/// replaces the earlier node in place (e.g. a progress value that updates).
public struct GenUINode: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var type: String
    public var parent: String?
    /// Which tab of the parent `tabs` node this child belongs to.
    public var tab: String?
    public var title: String?
    public var subtitle: String?
    public var text: String?
    public var label: String?
    public var value: String?
    public var delta: String?
    /// positive / negative / warning / neutral.
    public var tone: String?
    /// Variant: card `dark`, text `title|headline|caption`, tabs `segmented`,
    /// button `primary`, stack `horizontal`.
    public var style: String?
    /// SF Symbol name.
    public var icon: String?
    public var badge: String?
    /// chart: `line` | `bar`.
    public var kind: String?
    public var labels: [String]?
    public var series: [GenUISeries]?
    public var columns: [String]?
    public var rows: [[String]]?
    public var items: [String]?
    public var options: [String]?
    /// progress: 0...1.
    public var progress: Double?
    /// button: text sent as the next user message when tapped.
    public var send: String?

    enum CodingKeys: String, CodingKey {
        case id, type, parent, tab, title, subtitle, text, label, value, delta, tone, style,
             icon, badge, kind, labels, series, columns, rows, items, options, progress, send
    }

    public init(id: String, type: String, parent: String? = nil) {
        self.id = id
        self.type = type
        self.parent = parent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` flattens the optional, so a malformed field reads as absent
        // instead of failing the whole component.
        func string(_ key: CodingKeys) -> String? {
            let scalar = try? c.decodeIfPresent(GenUIScalar.self, forKey: key)
            return scalar?.text
        }
        func strings(_ key: CodingKeys) -> [String]? {
            let list = try? c.decodeIfPresent([GenUIScalar].self, forKey: key)
            return list?.map(\.text)
        }
        guard let type = string(.type), !type.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "missing type")
        }
        self.type = type.lowercased()
        id = string(.id) ?? ""
        parent = string(.parent)
        tab = string(.tab)
        title = string(.title)
        subtitle = string(.subtitle)
        text = string(.text)
        label = string(.label)
        value = string(.value)
        delta = string(.delta)
        tone = string(.tone)?.lowercased()
        style = string(.style)?.lowercased()
        icon = string(.icon)
        badge = string(.badge)
        kind = string(.kind)?.lowercased()
        labels = strings(.labels)
        series = try? c.decodeIfPresent([GenUISeries].self, forKey: .series)
        columns = strings(.columns)
        let table = try? c.decodeIfPresent([[GenUIScalar]].self, forKey: .rows)
        rows = table?.map { $0.map(\.text) }
        items = strings(.items)
        options = strings(.options)
        let fraction = try? c.decodeIfPresent(GenUIScalar.self, forKey: .progress)
        progress = fraction?.number
        send = string(.send)
    }
}

public struct GenUISeries: Decodable, Sendable, Equatable {
    public var name: String
    public var values: [Double]

    public init(name: String, values: [Double]) {
        self.name = name
        self.values = values
    }

    enum CodingKeys: String, CodingKey { case name, values, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let label = try? c.decodeIfPresent(GenUIScalar.self, forKey: .name)
        name = label?.text ?? ""
        let primary = try? c.decodeIfPresent([GenUIScalar].self, forKey: .values)
        let fallback = try? c.decodeIfPresent([GenUIScalar].self, forKey: .data)
        let raw = primary ?? fallback ?? []
        values = raw.compactMap(\.number)
    }
}

/// Models write `"value": 24.8` as often as `"value": "24.8K"`; accept both.
struct GenUIScalar: Decodable, Sendable {
    let text: String
    let number: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            text = s
            number = Double(s.trimmingCharacters(in: .whitespaces))
        } else if let i = try? c.decode(Int.self) {
            text = String(i)
            number = Double(i)
        } else if let d = try? c.decode(Double.self) {
            text = d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
            number = d
        } else if let b = try? c.decode(Bool.self) {
            text = b ? "true" : "false"
            number = nil
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a scalar")
        }
    }
}

public struct GenUIDocument: Sendable, Equatable {
    /// Upper bound so a runaway reply cannot build an unbounded view tree.
    public static let maxNodes = 300

    public private(set) var nodes: [GenUINode] = []
    /// 1-based numbers of complete lines that could not be parsed. The final
    /// line is never listed: mid-stream it is usually just unfinished.
    public private(set) var invalidLines: [Int] = []

    public static func isGenUILanguage(_ language: String?) -> Bool {
        guard let tag = language?.lowercased() else { return false }
        return tag == "omp-ui" || tag == "genui"
    }

    public static func parse(_ source: String) -> GenUIDocument {
        var doc = GenUIDocument()
        var index: [String: Int] = [:]
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let decoder = JSONDecoder()
        for (offset, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard var node = try? decoder.decode(GenUINode.self, from: Data(line.utf8)) else {
                if offset < lines.count - 1 { doc.invalidLines.append(offset + 1) }
                continue
            }
            if node.id.isEmpty { node.id = "line-\(offset + 1)" }
            if let existing = index[node.id] {
                doc.nodes[existing] = node
            } else if doc.nodes.count < maxNodes {
                index[node.id] = doc.nodes.count
                doc.nodes.append(node)
            }
        }
        return doc
    }

    /// Top-level nodes: no parent, or a parent that has not arrived (yet).
    public var roots: [GenUINode] {
        let ids = Set(nodes.map(\.id))
        return nodes.filter { node in
            guard let parent = node.parent else { return true }
            return parent == node.id || !ids.contains(parent)
        }
    }

    public func children(of id: String) -> [GenUINode] {
        nodes.filter { $0.parent == id && $0.id != id }
    }
}
