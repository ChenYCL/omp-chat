import SwiftUI
import OMPDesign

/// Lightweight markdown: fenced code blocks are split out so they can render
/// as selectable monospaced cards; everything else uses inline markdown.
public struct MarkdownText: View {
    private let segments: [Segment]

    public init(_ text: String) {
        self.segments = Segment.parse(text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .text(let value):
                    if let attributed = Self.inlineAttributed(value) {
                        Text(attributed)
                            .font(Theme.Typography.body)
                            .lineSpacing(10)
                            .textSelection(.enabled)
                            .tint(Color.ompDynamic(light: 0x3A83F7, dark: 0x63A8F8))
                            .environment(\.openURL, OpenURLAction { url in
                                #if os(macOS)
                                NSWorkspace.shared.open(url)
                                #else
                                return .systemAction
                                #endif
                                return .handled
                            })
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(value)
                            .font(Theme.Typography.body)
                            .lineSpacing(10)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .heading(let level, let text):
                    Text(Self.inlineAttributed(text) ?? AttributedString(text))
                        .font(.system(size: Self.headingSize(level), weight: .semibold))
                        .foregroundStyle(Color.ompText)
                        .lineSpacing(Self.headingSize(level) * 0.2)
                        .textSelection(.enabled)
                        .padding(.top, 16)
                        .padding(.bottom, 2)
                        .fixedSize(horizontal: false, vertical: true)
                case .bulletList(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Color.ompTextSecondary)
                                inlineText(item)
                            }
                        }
                    }
                    .padding(.leading, 6)
                case .numberedList(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Color.ompTextSecondary)
                                    .monospacedDigit()
                                inlineText(item)
                            }
                        }
                    }
                    .padding(.leading, 6)
                case .quote(let text):
                    HStack(alignment: .top, spacing: 0) {
                        Rectangle()
                            .fill(Color.ompBorder)
                            .frame(width: 2)
                        inlineText(text, color: Color.ompTextSecondary)
                            .padding(.leading, 14)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows)
                case .math(let equation):
                    MarkdownMathView(equation: equation)
                }
            }
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 26
        case 2: 20
        case 3: 18
        default: 16
        }
    }

    /// Inline-styled body text (bold/italic/code/link) at the official 16pt/1.625.
    @ViewBuilder
    private func inlineText(_ value: String, color: Color = .ompText) -> some View {
        Group {
            if let attributed = Self.inlineAttributed(value) {
                Text(attributed)
            } else {
                Text(value)
            }
        }
        .font(Theme.Typography.body)
        .foregroundStyle(color)
        .lineSpacing(10)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func inlineAttributed(_ value: String) -> AttributedString? {
        try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    struct Segment: Identifiable, Equatable {
        enum Kind: Equatable {
            case text(String)
            case heading(level: Int, text: String)
            case bulletList([String])
            case numberedList([String])
            case quote(String)
            case code(language: String?, code: String)
            case table(headers: [String], rows: [[String]])
            case math(equation: String)
        }
        let id: Int
        let kind: Kind

        static func parse(_ raw: String) -> [Segment] {
            var segments: [Segment] = []
            var textBuffer: [String] = []

            func flushText() {
                let text = textBuffer.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(Segment(id: segments.count, kind: .text(text)))
                }
                textBuffer.removeAll(keepingCapacity: true)
            }

            func splitRow(_ line: String) -> [String] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return [] }
                return trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }

            let allLines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var i = 0
            while i < allLines.count {
                let line = allLines[i]
                if line.hasPrefix("```") {
                    flushText()
                    let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    let lang = tag.isEmpty ? nil : tag
                    var codeLines: [String] = []
                    i += 1
                    while i < allLines.count && !allLines[i].hasPrefix("```") {
                        codeLines.append(allLines[i])
                        i += 1
                    }
                    segments.append(Segment(id: segments.count, kind: .code(language: lang, code: codeLines.joined(separator: "\n"))))
                    if i < allLines.count { i += 1 }
                    continue
                }

                let headerCells = splitRow(line)
                if !headerCells.isEmpty && i + 1 < allLines.count {
                    let dividerCells = splitRow(allLines[i + 1])
                    if dividerCells.count == headerCells.count && dividerCells.allSatisfy({ $0.contains("-") }) {
                        flushText()
                        var rows: [[String]] = []
                        i += 2
                        while i < allLines.count {
                            let dataCells = splitRow(allLines[i])
                            if dataCells.isEmpty { break }
                            rows.append(dataCells)
                            i += 1
                        }
                        segments.append(Segment(id: segments.count, kind: .table(headers: headerCells, rows: rows)))
                        continue
                    }
                }

                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.hasPrefix("$$") {
                    if trimmedLine.hasSuffix("$$") && trimmedLine.count > 4 {
                        flushText()
                        let eq = String(trimmedLine.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                        segments.append(Segment(id: segments.count, kind: .math(equation: eq)))
                        i += 1
                        continue
                    }
                    flushText()
                    var mathLines: [String] = []
                    if trimmedLine.count > 2 {
                        mathLines.append(String(trimmedLine.dropFirst(2)))
                    }
                    i += 1
                    while i < allLines.count && !allLines[i].trimmingCharacters(in: .whitespaces).contains("$$") {
                        mathLines.append(allLines[i])
                        i += 1
                    }
                    if i < allLines.count {
                        let closing = allLines[i].trimmingCharacters(in: .whitespaces)
                        if let endIdx = closing.range(of: "$$")?.lowerBound {
                            mathLines.append(String(closing[..<endIdx]))
                        }
                        i += 1
                    }
                    let eq = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    segments.append(Segment(id: segments.count, kind: .math(equation: eq)))
                    continue
                }

                // Block-level markdown: headings, bullet/numbered lists, quotes.
                let content = trimmedLine
                if content.hasPrefix("#") {
                    let hashes = content.prefix { $0 == "#" }.count
                    if (1...6).contains(hashes) {
                        let rest = content.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                        if !rest.isEmpty {
                            flushText()
                            segments.append(Segment(id: segments.count, kind: .heading(level: hashes, text: rest)))
                            i += 1
                            continue
                        }
                    }
                }
                if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") {
                    flushText()
                    var items: [String] = []
                    while i < allLines.count {
                        let row = allLines[i].trimmingCharacters(in: .whitespaces)
                        guard row.hasPrefix("- ") || row.hasPrefix("* ") || row.hasPrefix("+ ") else { break }
                        items.append(String(row.dropFirst(2)))
                        i += 1
                    }
                    segments.append(Segment(id: segments.count, kind: .bulletList(items)))
                    continue
                }
                if let firstDot = content.firstIndex(of: "."), content.distance(from: content.startIndex, to: firstDot) <= 2,
                   content[content.startIndex..<firstDot].allSatisfy({ $0.isNumber }) {
                    flushText()
                    var items: [String] = []
                    while i < allLines.count {
                        let row = allLines[i].trimmingCharacters(in: .whitespaces)
                        guard let dot = row.firstIndex(of: "."),
                              row.distance(from: row.startIndex, to: dot) <= 2,
                              row[row.startIndex..<dot].allSatisfy({ $0.isNumber }),
                              row.index(after: dot) < row.endIndex,
                              row[row.index(after: dot)] == " " else { break }
                        items.append(String(row[row.index(dot, offsetBy: 2)...]))
                        i += 1
                    }
                    segments.append(Segment(id: segments.count, kind: .numberedList(items)))
                    continue
                }
                if content.hasPrefix("> ") {
                    flushText()
                    var quoteLines: [String] = []
                    while i < allLines.count {
                        let row = allLines[i].trimmingCharacters(in: .whitespaces)
                        guard row.hasPrefix("> ") || row == ">" else { break }
                        quoteLines.append(row == ">" ? "" : String(row.dropFirst(2)))
                        i += 1
                    }
                    segments.append(Segment(id: segments.count, kind: .quote(quoteLines.joined(separator: "\n"))))
                    continue
                }

                textBuffer.append(line)
                i += 1
            }
            flushText()
            return segments
        }
    }
}

public struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            // `Grid` keeps every column the same width across header and rows,
            // which plain HStacks cannot do inside a horizontal ScrollView.
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        Text(header)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.ompTextSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(alignment: .bottom) {
                                Rectangle().fill(Color.ompBorder).frame(height: 1)
                            }
                            .background(Color.ompFill.opacity(0.55))
                            .overlay(alignment: .leading) {
                                if index > 0 {
                                    Rectangle().fill(Color.ompBorder).frame(width: 1)
                                }
                            }
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(headers.indices), id: \.self) { colIndex in
                            let cellText = colIndex < row.count ? row[colIndex] : ""
                            Text(cellText)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.ompText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .overlay(alignment: .leading) {
                                    if colIndex > 0 {
                                        Rectangle().fill(Color.ompBorder.opacity(0.6)).frame(width: 1)
                                    }
                                }
                                .background(alignment: .bottom) {
                                    if rowIndex < rows.count - 1 {
                                        Rectangle().fill(Color.ompBorder).frame(height: 1)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .background(Color.ompCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.officialLG, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.officialLG, style: .continuous)
                .strokeBorder(Color.ompBorder, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }
}

/// Mathematical formula display view for block LaTeX equations ($$...$$)
public struct MarkdownMathView: View {
    let equation: String
    @State private var copied = false

    public init(equation: String) {
        self.equation = equation
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Spacer()
                Text(equation)
                    .font(.system(size: 16, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Color.ompText)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                Spacer()

                Button {
                    copyToPasteboard("$$\n" + equation + "\n$$")
                    AudioFeedback.playSend(enabled: true)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copied ? Color.green : Color.ompTextTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 4)
        .background(Color.ompFill.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Color.ompBorder.opacity(0.6), lineWidth: 1)
        )
    }
}



public struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false
    @State private var collapsed = false
    @State private var showingPreview = false
    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Text(language?.uppercased() ?? "CODE")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.ompTextTertiary)
                Spacer()
                Text("\(code.split(separator: "\n", omittingEmptySubsequences: false).count) 行")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
                Button {
                    withAnimation(Theme.Motion.quick) { collapsed.toggle() }
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Menu {
                    Button {
                        copyToPasteboard(code)
                        AudioFeedback.playSend(enabled: true)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Label("复制代码文本", systemImage: "doc.on.doc")
                    }
                    Button {
                        let lang = language ?? ""
                        let md = "```\(lang)\n\(code)\n```"
                        copyToPasteboard(md)
                        AudioFeedback.playSend(enabled: true)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Label("复制为 Markdown 代码块", systemImage: "doc.plaintext")
                    }
                } label: {
                    Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                if isRenderable {
                    Button {
                        showingPreview = true
                    } label: {
                        Label("工件预览", systemImage: "play.circle")
                            .font(.caption2)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.Layout.rowHeight)

            if !collapsed {
                Divider()

                // Long blocks stay a fixed height and scroll internally instead of
                // pushing the transcript endlessly (ChatGPT desktop behaviour).
                let allLines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .trailing, spacing: 3) {
                            ForEach(0..<allLines.count, id: \.self) { i in
                                Text("\(i + 1)")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Color.ompTextTertiary.opacity(0.6))
                            }
                        }
                        .frame(width: 40, alignment: .trailing)
                        .padding(.vertical, 14)
                        .padding(.leading, 8)

                        if isDiff {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(allLines.enumerated()), id: \.offset) { _, line in
                                    let isAdd = line.hasPrefix("+") && !line.hasPrefix("+++")
                                    let isDel = line.hasPrefix("-") && !line.hasPrefix("---")
                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(isAdd ? Color.green : (isDel ? Color.red : Color.ompText))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 4)
                                        .background(isAdd ? Color.green.opacity(0.12) : (isDel ? Color.red.opacity(0.12) : Color.clear), in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                            .padding(.vertical, 14)
                            .padding(.trailing, 14)
                            .textSelection(.enabled)
                        } else {
                            Text(code)
                                .font(.system(size: 13, design: .monospaced))
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .padding(.vertical, 14)
                                .padding(.trailing, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .background(Color.ompFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.officialLG, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.officialLG, style: .continuous)
                .strokeBorder(Color.ompBorder, lineWidth: 0.5)
        )
        .sheet(isPresented: $showingPreview) {
            ArtifactPreviewSheet(language: language, code: code)
        }
    }

    private var isRenderable: Bool {
        let lang = language?.lowercased() ?? ""
        return lang == "html" || lang == "svg" || lang == "xml" || lang == "web"
    }

    private var isDiff: Bool {
        let lang = language?.lowercased() ?? ""
        if lang == "diff" || lang == "patch" { return true }
        let lines = code.split(separator: "\n", maxSplits: 10).map(String.init)
        let diffCount = lines.filter { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }.count
        return diffCount >= 2
    }
}

import WebKit

public struct ArtifactPreviewSheet: View {
    let language: String?
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var viewMode: ViewMode = .preview

    enum ViewMode: String, CaseIterable {
        case preview = "渲染效果"
        case source = "源代码"
    }

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                if viewMode == .preview {
                    HTMLPreviewView(html: wrappedHTML)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(code)
                            .font(Theme.Typography.monospaced)
                            .padding(16)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.ompSecondaryBackground)
                }
            }
            .navigationTitle("工件预览 (Artifacts)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyToPasteboard(code)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 520)
        #endif
    }

    private var wrappedHTML: String {
        let lang = language?.lowercased() ?? ""
        if lang == "svg" {
            return """
            <!DOCTYPE html>
            <html>
            <head><meta name="viewport" content="width=device-width, initial-scale=1.0"><style>body { margin: 0; display: flex; align-items: center; justify-content: center; min-height: 100vh; background: #fafafa; }</style></head>
            <body>\(code)</body>
            </html>
            """
        }
        return code
    }
}

#if os(macOS)
import AppKit

struct HTMLPreviewView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: nil)
    }
}

func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
#else
import UIKit

struct HTMLPreviewView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.loadHTMLString(html, baseURL: nil)
    }
}

func copyToPasteboard(_ value: String) {
    UIPasteboard.general.string = value
}
#endif
