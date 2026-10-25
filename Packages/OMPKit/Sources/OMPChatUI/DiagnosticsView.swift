import SwiftUI
import OMPCore
import OMPDesign

/// The 诊断 screen, shared by the macOS settings section and the iOS drawer.
///
/// Shows one row per health check plus the live event tail, which refreshes
/// itself from the ring buffer.
public struct DiagnosticsView: View {
    @Environment(ChatAppModel.self) private var model
    #if os(iOS)
    @Environment(RemoteSession.self) private var remoteSession
    #endif

    @State private var report: DiagnosticsReport?
    @State private var running = false
    @State private var events: [DiagnosticsEvent] = []
    @State private var copied = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    Task { await run() }
                } label: {
                    Label(running ? "诊断中…" : "运行诊断", systemImage: "stethoscope")
                }
                .disabled(running)
                .accessibilityIdentifier("diagnostics.run")

                Spacer()

                Button {
                    copyReport()
                } label: {
                    Label(copied ? "已复制" : "复制报告", systemImage: "doc.on.doc")
                }
                .disabled(report == nil)
                .accessibilityIdentifier("diagnostics.copy")

                ShareLink(item: report?.markdown() ?? "") {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .disabled(report == nil)
            }

            if let report {
                Text("\(report.platform) · \(report.osVersion) · v\(report.appVersion)")
                    .font(.caption)
                    .foregroundStyle(Color.ompTextTertiary)
                ForEach(report.checks) { check in
                    checkRow(check)
                }
            } else {
                Text("还没有运行过诊断。")
                    .font(.callout)
                    .foregroundStyle(Color.ompTextTertiary)
            }

            Divider()

            Text("实时事件")
                .font(.system(size: 13, weight: .semibold))
            if events.isEmpty {
                Text("暂无事件。")
                    .font(.caption)
                    .foregroundStyle(Color.ompTextTertiary)
            } else {
                ForEach(events.reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(event.level.rawValue)
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundStyle(levelColor(event.level))
                            .frame(width: 40, alignment: .leading)
                        Text(event.category)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(Color.ompTextTertiary)
                            .frame(width: 72, alignment: .leading)
                        Text(event.message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompText)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .accessibilityIdentifier("diagnostics.view")
        .task {
            events = DiagnosticsCenter.shared.recent(50)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                events = DiagnosticsCenter.shared.recent(50)
            }
        }
    }

    private func checkRow(_ check: DiagnosticsCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(marker(check.status))
                Text(check.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(check.status.rawValue)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Color.ompTextTertiary)
            }
            Text(check.detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
            if !check.hint.isEmpty, check.status != .ok {
                Text(check.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("diagnostics.check.\(check.id)")
    }

    private func marker(_ status: DiagnosticsStatus) -> String {
        switch status {
        case .ok: "✅"
        case .warn: "⚠️"
        case .fail: "❌"
        case .skip: "⏭"
        }
    }

    private func levelColor(_ level: DiagnosticsLevel) -> Color {
        switch level {
        case .debug: Color.ompTextTertiary
        case .info: Color.ompText
        case .warn: .orange
        case .error: .red
        }
    }

    private func run() async {
        #if os(iOS)
        let probe: (@Sendable () async -> Bool)? = {
            guard let sink = remoteSession.sink else { return nil }
            return { (try? await HostRPC.call(sink, op: "info").ok) ?? false }
        }()
        let snapshotAt = remoteSession.lastSnapshotAt
        #else
        let probe: (@Sendable () async -> Bool)? = nil
        let snapshotAt: Date? = nil
        #endif
        running = true
        report = await model.runDiagnostics(
            pairedHostProbe: probe,
            lastSnapshotAt: snapshotAt)
        events = DiagnosticsCenter.shared.recent(50)
    }

    private func copyReport() {
        guard let markdown = report?.markdown() else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        #else
        UIPasteboard.general.string = markdown
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
