import SwiftUI
import Charts
import OMPCore
import OMPDesign

extension EnvironmentValues {
    /// Sends a `button` node's text as the next user message. `nil` where the
    /// message cannot act (e.g. a read-only mirror), which disables buttons.
    @Entry var genUISend: (@MainActor @Sendable (String) -> Void)? = nil
    /// True inside a `dark` card, so descendants use the inverse palette.
    @Entry var genUIInverted: Bool = false
    /// Form state of the enclosing omp-ui block.
    @Entry var genUIForm: GenUIForm? = nil
}

/// Values the user has edited in one omp-ui block. Unedited fields read their
/// document default, so a value the model streams in later still shows up
/// until the user touches that field.
@MainActor
@Observable
final class GenUIForm {
    var edited: [String: String] = [:]

    func value(_ node: GenUINode) -> String {
        edited[node.id] ?? GenUIDocument.defaultValue(for: node)
    }

    func binding(_ node: GenUINode) -> Binding<String> {
        Binding(get: { self.value(node) }, set: { self.edited[node.id] = $0 })
    }

    /// Current values of every form field in `document`.
    func values(in document: GenUIDocument) -> [String: String] {
        document.formDefaults.merging(edited) { _, new in new }
    }
}

/// Native renderer for ```omp-ui blocks. Re-parsed on every streamed token;
/// the line format means each completed line appears immediately.
public struct GenUIView: View {
    private let source: String
    private let document: GenUIDocument
    @State private var showSource = false
    @State private var form = GenUIForm()

    public init(source: String) {
        self.source = source
        self.document = GenUIDocument.parse(source)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showSource {
                CodeBlockView(language: "omp-ui", code: source)
            } else if document.nodes.isEmpty {
                ShimmerText(text: "正在生成界面", font: .system(size: 13, weight: .medium))
            } else {
                GenUIChildren(nodes: document.roots, document: document, depth: 0)
                    .environment(\.genUIForm, form)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !document.invalidLines.isEmpty {
                Label("\(document.invalidLines.count) 行无法解析", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.ompFlat(rgb: 0xDE4A43))
            }
            Spacer(minLength: 0)
            Button(showSource ? "查看界面" : "查看源码") { showSource.toggle() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ompTextTertiary)
        }
        .font(.system(size: 11))
    }
}

// MARK: - Palette

struct GenUIPalette {
    let inverted: Bool

    var primary: Color { inverted ? .ompInverseText : .ompText }
    var secondary: Color { inverted ? Color.ompInverseText.opacity(0.68) : .ompTextSecondary }
    var tertiary: Color { inverted ? Color.ompInverseText.opacity(0.5) : .ompTextTertiary }
    var fill: Color { inverted ? Color.ompInverseText.opacity(0.08) : .ompFill }
    var border: Color { inverted ? Color.ompInverseText.opacity(0.12) : .ompBorder }

    /// Official diff/status colours; on an inverted surface the light/dark
    /// variants swap so contrast holds in both appearances.
    func tone(_ tone: String?, fallbackFrom delta: String? = nil) -> Color {
        var resolved = tone
        if resolved == nil, let first = delta?.trimmingCharacters(in: .whitespaces).first {
            resolved = first == "+" ? "positive" : (first == "-" || first == "−") ? "negative" : nil
        }
        switch resolved {
        case "positive", "up", "success", "ok":
            return inverted ? .ompDynamic(light: 0x42DEC2, dark: 0x055F51) : .ompDynamic(light: 0x055F51, dark: 0x42DEC2)
        case "negative", "down", "error", "danger":
            return .ompFlat(rgb: 0xDE4A43)
        case "warning":
            return inverted ? .ompDynamic(light: 0xFEE096, dark: 0x7D3F09) : .ompDynamic(light: 0x7D3F09, dark: 0xFEE096)
        default:
            return secondary
        }
    }
}

// MARK: - Tree

/// Lays out siblings; consecutive metrics share a grid row and consecutive
/// buttons share a row, as in a dashboard.
struct GenUIChildren: View {
    let nodes: [GenUINode]
    let document: GenUIDocument
    let depth: Int

    private struct Group: Identifiable {
        enum Kind { case single, metrics, buttons }
        let kind: Kind
        let nodes: [GenUINode]
        var id: String { nodes[0].id }
    }

    private var groups: [Group] {
        var result: [Group] = []
        for node in nodes {
            let kind: Group.Kind = node.type == "metric" ? .metrics : node.type == "button" ? .buttons : .single
            if kind != .single, let last = result.last, last.kind == kind {
                result[result.count - 1] = Group(kind: kind, nodes: last.nodes + [node])
            } else {
                result.append(Group(kind: kind, nodes: [node]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
                switch group.kind {
                case .metrics:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(group.nodes) { GenUIMetric(node: $0) }
                    }
                case .buttons:
                    HStack(spacing: 8) {
                        ForEach(group.nodes) { GenUIButton(node: $0, document: document) }
                    }
                case .single:
                    GenUINodeView(node: group.nodes[0], document: document, depth: depth)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GenUINodeView: View {
    let node: GenUINode
    let document: GenUIDocument
    let depth: Int
    @Environment(\.genUIInverted) private var inverted

    /// Bounds recursion for parent cycles the id check cannot see.
    private static let maxDepth = 8

    var body: some View {
        if depth > Self.maxDepth {
            EmptyView()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let palette = GenUIPalette(inverted: inverted)
        switch node.type {
        case "card":
            GenUICard(node: node, document: document, depth: depth)
        case "stack":
            let children = document.children(of: node.id)
            if node.style == "horizontal" {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(children) { child in
                        AnyView(GenUINodeView(node: child, document: document, depth: depth + 1))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                AnyView(GenUIChildren(nodes: children, document: document, depth: depth + 1))
            }
        case "tabs":
            GenUITabs(node: node, document: document, depth: depth)
        case "metric":
            GenUIMetric(node: node)
        case "button":
            GenUIButton(node: node, document: document)
        case "input", "toggle", "slider", "select":
            GenUIField(node: node, palette: palette)
        case "chart":
            GenUIChart(node: node)
        case "table":
            if let columns = node.columns, !columns.isEmpty {
                MarkdownTableView(headers: columns, rows: node.rows ?? [])
            }
        case "text":
            if let text = node.text ?? node.label, !text.isEmpty {
                GenUIText(text: text, style: node.style, palette: palette)
            }
        case "list":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((node.items ?? []).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let icon = node.icon {
                            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(palette.secondary)
                        } else {
                            Circle().fill(palette.tertiary).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        }
                        GenUIText(text: item, style: nil, palette: palette)
                    }
                }
            }
        case "progress":
            GenUIProgress(node: node, palette: palette)
        case "badge":
            if let text = node.text ?? node.label {
                GenUIBadge(text: text, color: palette.tone(node.tone))
            }
        case "divider":
            Rectangle().fill(palette.border).frame(height: 1)
        default:
            // Unknown types are skipped rather than guessed at; "查看源码"
            // still shows the raw line.
            EmptyView()
        }
    }
}

// MARK: - Components

struct GenUICard: View {
    let node: GenUINode
    let document: GenUIDocument
    let depth: Int
    @Environment(\.genUIInverted) private var inherited

    private var dark: Bool { node.style == "dark" || node.style == "hero" }

    var body: some View {
        let inverted = dark || inherited
        let palette = GenUIPalette(inverted: inverted)
        VStack(alignment: .leading, spacing: 14) {
            if node.title != nil || node.subtitle != nil || node.badge != nil || node.icon != nil {
                HStack(alignment: .top, spacing: 10) {
                    if let icon = node.icon {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.primary)
                            .frame(width: 34, height: 34)
                            .background(palette.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = node.title {
                            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.primary)
                        }
                        if let subtitle = node.subtitle {
                            Text(subtitle).font(.system(size: 12)).foregroundStyle(palette.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let badge = node.badge {
                        GenUIBadge(text: badge, color: palette.tone(node.tone ?? "positive"))
                    }
                }
            }
            AnyView(GenUIChildren(nodes: document.children(of: node.id), document: document, depth: depth + 1))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            dark ? Color.ompPrimarySolid : (inherited ? palette.fill : Color.ompCard),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            if !dark {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.border, lineWidth: 0.5)
            }
        }
        .environment(\.genUIInverted, inverted)
    }
}

struct GenUIMetric: View {
    let node: GenUINode
    @Environment(\.genUIInverted) private var inverted

    var body: some View {
        let palette = GenUIPalette(inverted: inverted)
        VStack(alignment: .leading, spacing: 6) {
            if let icon = node.icon {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(palette.secondary)
            }
            Text(node.value ?? "—")
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let label = node.label ?? node.title {
                Text(label).font(.system(size: 12)).foregroundStyle(palette.secondary).lineLimit(2)
            }
            if let delta = node.delta {
                Text(delta)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.tone(node.tone, fallbackFrom: delta))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct GenUIText: View {
    let text: String
    let style: String?
    let palette: GenUIPalette

    var body: some View {
        Group {
            if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(font)
        .foregroundStyle(style == "caption" ? palette.tertiary : palette.primary)
        .lineSpacing(style == "title" ? 2 : 4)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private var font: Font {
        switch style {
        case "title": .system(size: 24, weight: .bold)
        case "headline": .system(size: 17, weight: .semibold)
        case "caption": .system(size: 12)
        default: .system(size: 15)
        }
    }
}

struct GenUIBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct GenUIProgress: View {
    let node: GenUINode
    let palette: GenUIPalette

    var body: some View {
        let fraction = min(max(node.progress ?? 0, 0), 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let label = node.label ?? node.title {
                    Text(label).font(.system(size: 13)).foregroundStyle(palette.primary)
                }
                Spacer(minLength: 8)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(palette.secondary)
            }
            ProgressView(value: fraction)
                .tint(node.tone == nil ? palette.primary : palette.tone(node.tone))
        }
    }
}

struct GenUIButton: View {
    let node: GenUINode
    let document: GenUIDocument
    @Environment(\.genUISend) private var send
    @Environment(\.genUIInverted) private var inverted
    @Environment(\.genUIForm) private var form

    /// The `send` template with `{{id}}` filled from the block's fields.
    private var message: String {
        let template = node.send ?? ""
        guard let form else { return template }
        return GenUIDocument.fill(template, values: form.values(in: document))
    }

    var body: some View {
        let title = node.label ?? node.text ?? node.send ?? ""
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = send != nil && !text.isEmpty
        let primary = node.style == "primary"
        if !title.isEmpty {
            Button {
                if let send, !text.isEmpty { send(text) }
            } label: {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(primary ? (inverted ? Color.ompPrimarySolid : Color.ompInverseText) : GenUIPalette(inverted: inverted).primary)
                    .background(
                        primary ? (inverted ? Color.ompInverseText : Color.ompPrimarySolid) : GenUIPalette(inverted: inverted).fill,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .help(text.isEmpty ? "" : "发送：\(text)")
        }
    }
}

/// `input` / `toggle` / `slider` / `select`: edits the block's local form
/// state. Nothing is sent until a button that references the field is tapped.
struct GenUIField: View {
    let node: GenUINode
    let palette: GenUIPalette
    @Environment(\.genUIForm) private var form

    var body: some View {
        if let form {
            control(form)
        }
    }

    private var title: String? { node.label ?? node.title }
    /// On the control itself (not its label stack) so UI tests can drive it.
    private var identifier: String { "genui.\(node.id)" }

    @ViewBuilder
    private func control(_ form: GenUIForm) -> some View {
        switch node.type {
        case "toggle":
            Toggle(isOn: Binding(
                get: { form.value(node) == "true" },
                set: { form.binding(node).wrappedValue = $0 ? "true" : "false" }
            )) {
                Text(title ?? node.id).font(.system(size: 14)).foregroundStyle(palette.primary)
            }
            .accessibilityIdentifier(identifier)
        case "slider":
            let low = node.min ?? 0
            let high = Swift.max(node.max ?? 100, low + (node.step ?? 1))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title ?? node.id).font(.system(size: 13)).foregroundStyle(palette.primary)
                    Spacer(minLength: 8)
                    Text(form.value(node))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(palette.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(form.value(node)) ?? low },
                        set: { form.binding(node).wrappedValue = GenUIDocument.formatNumber($0, step: node.step) }
                    ),
                    in: low...high,
                    step: node.step ?? 1
                )
                .accessibilityIdentifier(identifier)
            }
        case "select":
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title).font(.system(size: 13)).foregroundStyle(palette.primary)
                }
                // SwiftUI buttons rather than a segmented Picker: inside the
                // transcript the UIKit segmented control never took a tap
                // (measured in UI tests), while the same buttons used by
                // `tabs` do.
                let current = form.value(node)
                HStack(spacing: 2) {
                    ForEach(node.options ?? [], id: \.self) { option in
                        let selected = option == current
                        Button { form.binding(node).wrappedValue = option } label: {
                            Text(option)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? palette.primary : palette.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background {
                                    if selected {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(palette.inverted ? palette.fill : Color.ompCard)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(identifier).\(option)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(palette.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title).font(.system(size: 13)).foregroundStyle(palette.primary)
                }
                // Single line so Return (完成) ends editing: with the keyboard
                // open, taps on the select below were not delivered.
                TextField(node.placeholder ?? "", text: form.binding(node))
                    .submitLabel(.done)
                    .accessibilityIdentifier(identifier)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

struct GenUITabs: View {
    let node: GenUINode
    let document: GenUIDocument
    let depth: Int
    @State private var selection: String?
    @Environment(\.genUIInverted) private var inverted

    var body: some View {
        let palette = GenUIPalette(inverted: inverted)
        let children = document.children(of: node.id)
        let options = node.options ?? children.compactMap(\.tab).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let current = selection ?? options.first
        let segmented = node.style == "segmented"
        VStack(alignment: .leading, spacing: 12) {
            if !options.isEmpty {
                HStack(spacing: segmented ? 2 : 4) {
                    ForEach(options, id: \.self) { option in
                        let selected = option == current
                        Button { selection = option } label: {
                            Text(option)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? palette.primary : palette.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background {
                                    if selected {
                                        if segmented {
                                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(inverted ? palette.fill : Color.ompCard)
                                        } else {
                                            Capsule().fill(palette.fill)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(segmented ? 3 : 0)
                .background {
                    if segmented {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.fill)
                    }
                }
            }
            AnyView(GenUIChildren(
                nodes: children.filter { $0.tab == nil || $0.tab == current },
                document: document,
                depth: depth + 1
            ))
        }
    }
}

struct GenUIChart: View {
    let node: GenUINode
    @Environment(\.genUIInverted) private var inverted

    private struct Point: Identifiable {
        let id: String
        let series: String
        let label: String
        let value: Double
    }

    private var points: [Point] {
        let labels = node.labels ?? []
        return (node.series ?? []).enumerated().flatMap { seriesIndex, series in
            let name = series.name.isEmpty ? "系列 \(seriesIndex + 1)" : series.name
            return series.values.enumerated().map { index, value in
                Point(
                    id: "\(seriesIndex)-\(index)",
                    series: name,
                    label: index < labels.count ? labels[index] : "\(index + 1)",
                    value: value
                )
            }
        }
    }

    var body: some View {
        let palette = GenUIPalette(inverted: inverted)
        let data = points
        let multiple = Set(data.map(\.series)).count > 1
        VStack(alignment: .leading, spacing: 8) {
            if let title = node.title {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.primary)
            }
            if let subtitle = node.subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            if data.isEmpty {
                Text("暂无数据").font(.system(size: 12)).foregroundStyle(palette.tertiary)
            } else {
                Chart {
                    if node.kind == "bar" {
                        ForEach(data) { point in
                            BarMark(x: .value("项目", point.label), y: .value("数值", point.value))
                                .foregroundStyle(by: .value("系列", point.series))
                                .position(by: .value("系列", point.series))
                                .cornerRadius(3)
                        }
                    } else {
                        ForEach(data) { point in
                            LineMark(x: .value("项目", point.label), y: .value("数值", point.value))
                                .foregroundStyle(by: .value("系列", point.series))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("项目", point.label), y: .value("数值", point.value))
                                .foregroundStyle(by: .value("系列", point.series))
                                .symbolSize(24)
                        }
                    }
                }
                .chartLegend(multiple ? .visible : .hidden)
                .frame(height: 180)
                .padding(12)
                .background(Color.ompCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ompBorder, lineWidth: 0.5))
            }
        }
    }
}
