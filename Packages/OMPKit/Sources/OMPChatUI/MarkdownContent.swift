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
                            .textSelection(.enabled)
                            .tint(Color.accentColor)
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
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows)
                }
            }
        }
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
            case code(language: String?, code: String)
            case table(headers: [String], rows: [[String]])
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
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        Text(header)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.ompText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(minWidth: 90, alignment: .leading)
                        if index < headers.count - 1 {
                            Divider().frame(height: 18).opacity(0.5)
                        }
                    }
                }
                .background(Color.ompFill)

                Divider()

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(Array(headers.indices), id: \.self) { colIndex in
                            let cellText = colIndex < row.count ? row[colIndex] : ""
                            Text(cellText)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Color.ompText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .frame(minWidth: 90, alignment: .leading)
                                .textSelection(.enabled)
                            if colIndex < headers.count - 1 {
                                Divider().frame(height: 16).opacity(0.3)
                            }
                        }
                    }
                    .background(rowIndex % 2 == 0 ? Color.ompCard : Color.ompFill.opacity(0.3))
                    if rowIndex < rows.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .background(Color.ompCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Color.ompBorder.opacity(0.7), lineWidth: 1)
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
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.ompTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.ompFill, in: Capsule())
                Spacer()
                Text("\(code.split(separator: "\n", omittingEmptySubsequences: false).count) 行")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
                Button {
                    withAnimation(Theme.Motion.quick) { collapsed.toggle() }
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button {
                    copyToPasteboard(code)
                    AudioFeedback.playSend(enabled: true)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
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
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)

            if !collapsed {
                Divider()

                // Long blocks stay a fixed height and scroll internally instead of
                // pushing the transcript endlessly (ChatGPT desktop behaviour).
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    HStack(alignment: .top, spacing: 10) {
                        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        VStack(alignment: .trailing, spacing: 3) {
                            ForEach(0..<lines.count, id: \.self) { i in
                                Text("\(i + 1)")
                                    .font(Theme.Typography.monospaced)
                                    .foregroundStyle(Color.ompTextTertiary.opacity(0.5))
                            }
                        }
                        .padding(.vertical, Theme.Spacing.m)
                        .padding(.leading, Theme.Spacing.m)

                        if isDiff {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    let isAdd = line.hasPrefix("+") && !line.hasPrefix("+++")
                                    let isDel = line.hasPrefix("-") && !line.hasPrefix("---")
                                    Text(line.isEmpty ? " " : line)
                                        .font(Theme.Typography.monospaced)
                                        .foregroundStyle(isAdd ? Color.green : (isDel ? Color.red : Color.ompText))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 4)
                                        .background(isAdd ? Color.green.opacity(0.12) : (isDel ? Color.red.opacity(0.12) : Color.clear), in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                            .padding(.vertical, Theme.Spacing.m)
                            .padding(.trailing, Theme.Spacing.m)
                            .textSelection(.enabled)
                        } else {
                            Text(code)
                                .font(Theme.Typography.monospaced)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .padding(.vertical, Theme.Spacing.m)
                                .padding(.trailing, Theme.Spacing.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .background(Color.ompSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Color.ompSeparator.opacity(0.6), lineWidth: 1)
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
