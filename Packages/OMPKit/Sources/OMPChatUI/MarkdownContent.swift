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
        }

        let id: Int
        let kind: Kind

        static func parse(_ raw: String) -> [Segment] {
            var segments: [Segment] = []
            var buffer: [String] = []
            var codeBuffer: [String] = []
            var language: String?
            var inCode = false

            func flushText() {
                let text = buffer.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(Segment(id: segments.count, kind: .text(text)))
                }
                buffer.removeAll(keepingCapacity: true)
            }

            for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                let string = String(line)
                if string.hasPrefix("```") {
                    if inCode {
                        segments.append(Segment(
                            id: segments.count,
                            kind: .code(language: language, code: codeBuffer.joined(separator: "\n"))
                        ))
                        codeBuffer.removeAll(keepingCapacity: true)
                        language = nil
                        inCode = false
                    } else {
                        flushText()
                        let tag = string.dropFirst(3).trimmingCharacters(in: .whitespaces)
                        language = tag.isEmpty ? nil : tag
                        inCode = true
                    }
                    continue
                }
                if inCode { codeBuffer.append(string) } else { buffer.append(string) }
            }
            if inCode {
                segments.append(Segment(
                    id: segments.count,
                    kind: .code(language: language, code: codeBuffer.joined(separator: "\n"))
                ))
            } else {
                flushText()
            }
            return segments
        }
    }
}

public struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false
    @State private var collapsed = false

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
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)

            if !collapsed {
                Divider()

                // Long blocks stay a fixed height and scroll internally instead of
                // pushing the transcript endlessly (ChatGPT desktop behaviour).
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(code)
                        .font(Theme.Typography.monospaced)
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}

#if os(macOS)
import AppKit
func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
#else
import UIKit
func copyToPasteboard(_ value: String) {
    UIPasteboard.general.string = value
}
#endif
