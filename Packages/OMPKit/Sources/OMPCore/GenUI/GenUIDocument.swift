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
    /// button: text sent as the next user message when tapped. `{{id}}`
    /// placeholders are filled with the current value of that field.
    public var send: String?
    /// input: hint shown while empty.
    public var placeholder: String?
    /// slider: range and step.
    public var min: Double?
    public var max: Double?
    public var step: Double?

    enum CodingKeys: String, CodingKey {
        case id, type, parent, tab, title, subtitle, text, label, value, delta, tone, style,
             icon, badge, kind, labels, series, columns, rows, items, options, progress, send,
             placeholder, min, max, step
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
        placeholder = string(.placeholder)
        func number(_ key: CodingKeys) -> Double? {
            let scalar = try? c.decodeIfPresent(GenUIScalar.self, forKey: key)
            return scalar?.number
        }
        min = number(.min)
        max = number(.max)
        step = number(.step)
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

// MARK: - Form state

/// Local, per-message state for `input` / `toggle` / `slider` / `select`
/// nodes (the DIL `useState` equivalent). Values live only on the device that
/// renders the block; a `button` reads them through `{{id}}` placeholders and
/// sends the filled text as the next user turn.
extension GenUIDocument {
    public static let formTypes: Set<String> = ["input", "toggle", "slider", "select"]

    /// Starting value of a form node: its own `value`, else a type default.
    /// Slider defaults are clamped into `min...max`; a select falls back to its
    /// first option when `value` is not one of them.
    public static func defaultValue(for node: GenUINode) -> String {
        switch node.type {
        case "toggle":
            let raw = node.value?.lowercased() ?? ""
            return ["true", "1", "yes", "on", "开"].contains(raw) ? "true" : "false"
        case "slider":
            let low = node.min ?? 0
            let high = Swift.max(node.max ?? 100, low)
            let start = node.value.flatMap { Double($0) } ?? low
            return formatNumber(Swift.min(Swift.max(start, low), high), step: node.step)
        case "select":
            let options = node.options ?? []
            if let value = node.value, options.contains(value) { return value }
            return options.first ?? ""
        default:
            return node.value ?? ""
        }
    }

    /// Defaults for every form node that has an id, keyed by id.
    public var formDefaults: [String: String] {
        var values: [String: String] = [:]
        for node in nodes where Self.formTypes.contains(node.type) && !node.id.hasPrefix("line-") {
            values[node.id] = Self.defaultValue(for: node)
        }
        return values
    }

    /// What a `{{id}}` placeholder receives for each field. A toggle with two
    /// `options` (`["否","是"]`) maps false/true to those words so the sent
    /// message reads naturally; every other field passes its value through.
    public func templateValues(_ values: [String: String]) -> [String: String] {
        var result = values
        for node in nodes where node.type == "toggle" {
            guard let options = node.options, options.count == 2, let raw = values[node.id] else { continue }
            result[node.id] = raw == "true" ? options[1] : options[0]
        }
        return result
    }

    /// Replaces `{{id}}` with `values[id]`. Unknown ids are left as written so
    /// a typo in the model's template stays visible instead of vanishing.
    public static func fill(_ template: String, values: [String: String]) -> String {
        var result = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let key = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = values[key] {
                result += value
            } else {
                result += rest[open.lowerBound..<close.upperBound]
            }
            rest = afterOpen[close.upperBound...]
        }
        result += rest
        return result
    }

    /// Whole numbers print without a fraction when the step is whole.
    public static func formatNumber(_ value: Double, step: Double?) -> String {
        let step = step ?? 1
        if step == step.rounded(), value == value.rounded() { return String(Int(value)) }
        let decimals = Swift.max(1, Swift.min(4, Int((-log10(step)).rounded(.up))))
        return String(format: "%.\(decimals)f", value)
    }
}
