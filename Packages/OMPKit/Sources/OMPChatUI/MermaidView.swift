import SwiftUI
import OMPCore
import OMPDesign

/// Draws the Mermaid subset `MermaidDocument` understands. Unsupported
/// diagrams never reach this view: the caller keeps showing the source.
struct MermaidView: View {
    let document: MermaidDocument

    var body: some View {
        switch document.diagram {
        case .flowchart(let chart): MermaidFlowchartView(chart: chart)
        case .sequence(let sequence): MermaidSequenceView(sequence: sequence)
        }
    }
}

// MARK: - Flowchart

private struct MermaidFlowchartView: View {
    let chart: MermaidDocument.Flowchart

    /// Depth per node. A back edge (one that would point at an already deeper
    /// node, i.e. a cycle) does not raise anything: the chart keeps a readable
    /// shape and the cycle is still drawn as a line.
    private var depths: [String: Int] {
        var depth: [String: Int] = [:]
        for node in chart.nodes { depth[node.id] = 0 }
        for _ in 0..<max(chart.nodes.count, 1) {
            var changed = false
            for edge in chart.edges {
                let from = depth[edge.from] ?? 0
                let to = depth[edge.to] ?? 0
                if from + 1 > to, from + 1 < chart.nodes.count {
                    depth[edge.to] = from + 1
                    changed = true
                }
            }
            if !changed { break }
        }
        return depth
    }

    private struct Placement {
        var frames: [String: CGRect]
        var size: CGSize
    }

    private static let boxHeight: CGFloat = 30
    private static let gap: CGFloat = 34
    private static let padding: CGFloat = 14

    /// Boxes are measured from their label, then placed level by level.
    private var placement: Placement {
        let depth = depths
        let horizontal = chart.direction == .leftRight
        var buckets: [Int: [MermaidDocument.Node]] = [:]
        for node in chart.nodes { buckets[depth[node.id] ?? 0, default: []].append(node) }
        let levelKeys = buckets.keys.sorted()
        let levelCount = max(levelKeys.count, 1)
        let maxPerLevel = max(buckets.values.map(\.count).max() ?? 1, 1)

        func boxSize(_ node: MermaidDocument.Node) -> CGSize {
            let width = min(max(CGFloat(node.label.count) * 13 + 26, 64), 190)
            return CGSize(width: width, height: Self.boxHeight)
        }

        var widest: CGFloat = 64
        for node in chart.nodes { widest = max(widest, boxSize(node).width) }

        var frames: [String: CGRect] = [:]
        for (levelIndex, key) in levelKeys.enumerated() {
            let nodes = buckets[key] ?? []
            for (index, node) in nodes.enumerated() {
                let size = boxSize(node)
                let centerAlong: CGFloat
                if horizontal {
                    // Column index across, rows within the column.
                    let span = CGFloat(maxPerLevel) * (Self.boxHeight + 14)
                    centerAlong = Self.padding + Self.boxHeight / 2
                        + CGFloat(index) * (Self.boxHeight + 14)
                        + (span - CGFloat(nodes.count) * (Self.boxHeight + 14)) / 2
                } else {
                    let span = CGFloat(maxPerLevel) * (widest + Self.gap)
                    centerAlong = Self.padding + widest / 2
                        + CGFloat(index) * (widest + Self.gap)
                        + (span - CGFloat(nodes.count) * (widest + Self.gap)) / 2
                }
                let across: CGFloat
                if horizontal {
                    across = Self.padding + CGFloat(levelIndex) * (widest + Self.gap)
                } else {
                    across = Self.padding + CGFloat(levelIndex) * (Self.boxHeight + Self.gap)
                }
                let origin: CGPoint
                if horizontal {
                    origin = CGPoint(x: across, y: centerAlong - Self.boxHeight / 2)
                } else {
                    origin = CGPoint(x: centerAlong - size.width / 2, y: across)
                }
                frames[node.id] = CGRect(origin: origin, size: size)
            }
        }

        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for frame in frames.values {
            maxX = max(maxX, frame.maxX)
            maxY = max(maxY, frame.maxY)
        }
        // Room for cycle edges: they run along a gutter outside the boxes.
        let hasCycle = !chart.edges.isEmpty
        let extra: CGFloat = hasCycle ? 26 : 0
        let size = CGSize(width: maxX + Self.padding + (chart.direction == .topDown ? extra : 0),
                          height: maxY + Self.padding + (chart.direction == .leftRight ? extra : 0))
        return Placement(frames: frames, size: size)
    }

    /// True when the edge points back to an earlier (or same) level, i.e. the
    /// chart has a cycle. Those are routed around the boxes instead of through
    /// them, or they would read as a forward arrow.
    private func isBackEdge(_ edge: MermaidDocument.Edge) -> Bool {
        let depth = depths
        return (depth[edge.to] ?? 0) <= (depth[edge.from] ?? 0)
    }

    var body: some View {
        let layout = placement
        ScrollView(chart.direction == .leftRight ? .horizontal : .vertical) {
            Canvas { context, _ in
                let palette = DiagramPalette()
                for edge in chart.edges {
                    guard let from = layout.frames[edge.from], let to = layout.frames[edge.to] else { continue }
                    if isBackEdge(edge) {
                        drawBackEdge(edge, from: from, to: to, bounds: layout.size,
                                     horizontal: chart.direction == .leftRight,
                                     context: &context, palette: palette)
                    } else {
                        drawEdge(edge, from: from, to: to, context: &context, palette: palette)
                    }
                }
                for node in chart.nodes {
                    guard let frame = layout.frames[node.id] else { continue }
                    drawNode(node, in: frame, context: &context, palette: palette)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ompFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func drawNode(
        _ node: MermaidDocument.Node, in frame: CGRect,
        context: inout GraphicsContext, palette: DiagramPalette
    ) {
        let path: Path
        switch node.shape {
        case .box: path = Path(roundedRect: frame, cornerRadius: 4)
        case .rounded: path = Path(roundedRect: frame, cornerRadius: frame.height / 2)
        case .circle: path = Path(ellipseIn: frame)
        case .diamond: path = Path(roundedRect: frame.insetBy(dx: 6, dy: 0), cornerRadius: 3)
        }
        context.fill(path, with: .color(palette.card))
        context.stroke(path, with: .color(palette.border), lineWidth: 1)
        let label = Text(node.label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.text)
        context.draw(label, at: CGPoint(x: frame.midX, y: frame.midY), anchor: .center)
    }

    private func drawEdge(
        _ edge: MermaidDocument.Edge, from: CGRect, to: CGRect,
        context: inout GraphicsContext, palette: DiagramPalette
    ) {
        let start = borderPoint(of: from, towards: CGPoint(x: to.midX, y: to.midY))
        let end = borderPoint(of: to, towards: CGPoint(x: from.midX, y: from.midY))

        var path = Path()
        path.move(to: start)
        if abs(start.x - end.x) < 1 || abs(start.y - end.y) < 1 {
            path.addLine(to: end)
        } else {
            // An elbow keeps the line orthogonal, like Mermaid's own routing.
            let mid = CGPoint(x: start.x, y: end.y)
            path.addLine(to: mid)
            path.addLine(to: end)
        }
        context.stroke(
            path,
            with: .color(palette.border),
            style: StrokeStyle(lineWidth: 1.4, dash: edge.dashed ? [4, 3] : [])
        )
        // Arrow head at the target border.
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 7
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 7),
                                 y: end.y - length * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 7),
                                 y: end.y - length * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(palette.border))

        if let label = edge.label, !label.isEmpty {
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            context.draw(
                Text(label).font(.system(size: 10)).foregroundStyle(palette.text),
                at: CGPoint(x: mid.x, y: mid.y - 8), anchor: .center
            )
        }
    }

    /// A cycle edge: leaves the box on the far side, runs along a gutter
    /// outside the boxes, and comes back in. Dashed so it is obviously not a
    /// forward step.
    private func drawBackEdge(
        _ edge: MermaidDocument.Edge, from: CGRect, to: CGRect, bounds: CGSize,
        horizontal: Bool, context: inout GraphicsContext, palette: DiagramPalette
    ) {
        var gutter: CGFloat
        if horizontal {
            gutter = bounds.height - 8
        } else {
            gutter = bounds.width - 8
        }
        guard gutter > 4 else { return }
        let start = horizontal
            ? CGPoint(x: from.midX, y: from.maxY)
            : CGPoint(x: from.maxX, y: from.midY)
        let end = horizontal
            ? CGPoint(x: to.midX, y: to.maxY)
            : CGPoint(x: to.maxX, y: to.midY)

        var path = Path()
        path.move(to: start)
        if horizontal {
            path.addLine(to: CGPoint(x: start.x, y: gutter))
            path.addLine(to: CGPoint(x: end.x, y: gutter))
            path.addLine(to: end)
        } else {
            path.addLine(to: CGPoint(x: gutter, y: start.y))
            path.addLine(to: CGPoint(x: gutter, y: end.y))
            path.addLine(to: end)
        }
        context.stroke(path, with: .color(palette.border),
                       style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        let angle = horizontal ? -CGFloat.pi / 2 : CGFloat.pi
        let length: CGFloat = 6
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 7),
                                 y: end.y - length * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 7),
                                 y: end.y - length * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(palette.border))
        if let label = edge.label, !label.isEmpty {
            context.draw(
                Text(label).font(.system(size: 10)).foregroundStyle(palette.text),
                at: CGPoint(x: (start.x + end.x) / 2, y: gutter - 8), anchor: .center
            )
        }
    }

    /// Where the line from the box's centre towards `target` leaves the box.
    private func borderPoint(of rect: CGRect, towards target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let halfW = rect.width / 2
        let halfH = rect.height / 2
        let scaleX = dx == 0 ? .greatestFiniteMagnitude : abs(halfW / dx)
        let scaleY = dy == 0 ? .greatestFiniteMagnitude : abs(halfH / dy)
        let scale = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}

private struct DiagramPalette {
    var card: Color { Color.ompCard }
    var border: Color { Color.ompTextTertiary }
    var text: Color { Color.ompText }
}

// MARK: - Sequence

private struct MermaidSequenceView: View {
    let sequence: MermaidDocument.Sequence

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    ForEach(sequence.participants, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.ompText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.ompCard, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.ompBorder, lineWidth: 1)
                            )
                    }
                }
                ForEach(Array(sequence.messages.enumerated()), id: \.offset) { _, message in
                    HStack(spacing: 6) {
                        Text(message.isReturn ? "⟵" : "⟶")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.ompTextSecondary)
                        Text("\(message.from) → \(message.to)")
                            .font(.system(size: 10.5).monospaced())
                            .foregroundStyle(Color.ompTextTertiary)
                        Text(message.text)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompText)
                            .lineLimit(2)
                    }
                    .padding(.leading, message.isReturn ? 14 : 0)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ompFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
