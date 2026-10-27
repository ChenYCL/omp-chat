import SwiftUI
import OMPCore

// MARK: - ExternalImport (设置 → 导入)

/// 设置 → 导入: scans Claude Code and Cursor on disk and imports the
/// selected items. macOS only; iOS has no access to those folders.
struct ExternalImportSettingsPane: View {
    @Environment(ChatAppModel.self) private var model

    var body: some View {
        #if os(macOS)
        ExternalImportSettingsContent()
        #else
        Text("从其他 AI 应用导入只能在 Mac 上进行：Claude Code 和 Cursor 的文件在这台电脑上。")
            .font(.system(size: 12))
            .foregroundStyle(Color.ompTextSecondary)
            .accessibilityIdentifier("settings.import.iosNote")
        #endif
    }
}

#if os(macOS)
struct ExternalImportSettingsContent: View {
    @Environment(ChatAppModel.self) private var model
    @State private var scan: ExternalImportScan?
    @State private var enabled: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var busy = false
    @State private var report: ExternalImportReport?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把其他 AI 应用里的配置、项目和最近的聊天带过来。源应用的文件不会被改动。")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                errorBanner(error)
            } else if scan == nil {
                ProgressView("正在检查…")
                    .font(.system(size: 12))
                    .accessibilityIdentifier("settings.import.scanning")
            } else if let scan, scan.isEmpty {
                emptyState(scan)
            } else if let scan {
                providerList(scan)
                actionBar
            }
            if let report {
                reportView(report)
            }
        }
        .task { await scanIfNeeded() }
        .accessibilityIdentifier("settings.import.pane")
    }

    private func errorBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("无法检查可导入的内容")
                .font(.system(size: 13, weight: .semibold))
            Text("请重试，以查找兼容的配置、项目和最近的聊天。")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
            Button("重试") { Task { await rescan() } }
                .accessibilityIdentifier("settings.import.retry")
        }
        .accessibilityIdentifier("settings.import.error")
    }

    private func emptyState(_ scan: ExternalImportScan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scan.providersFound.isEmpty ? "没有找到可导入的配置" : "没有新的可导入项")
                .font(.system(size: 13, weight: .semibold))
            Text("再检查一次")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
            Button("再检查一次") { Task { await rescan() } }
                .accessibilityIdentifier("settings.import.checkAgain")
        }
    }

    private func providerList(_ scan: ExternalImportScan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(scan.providersFound, id: \.rawValue) { provider in
                providerSection(provider, scan: scan)
            }
        }
    }

    private func providerSection(_ provider: ExternalImportProvider, scan: ExternalImportScan) -> some View {
        let available = scan.entries(provider: provider).filter(\.isAvailable)
        let allOn = !available.isEmpty && available.allSatisfy { enabled.contains($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { allOn },
                set: { on in
                    for entry in available { if on { enabled.insert(entry.id) } else { enabled.remove(entry.id) } }
                }
            )) {
                Text("导入 \(provider.displayName)")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("settings.import.provider.\(provider.rawValue)")
            ForEach(scan.groups(provider: provider)) { group in
                groupRow(group)
            }
        }
    }

    private func groupRow(_ group: ExternalImportScan.Group) -> some View {
        let available = group.rows.filter(\.isAvailable)
        let on = !available.isEmpty && available.allSatisfy { enabled.contains($0.id) }
        let isOpen = expanded.contains(group.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { on },
                    set: { value in
                        for row in available { if value { enabled.insert(row.id) } else { enabled.remove(row.id) } }
                    }
                )) {
                    Text("\(group.kind.title)（\(available.count)）")
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox)
                .disabled(available.isEmpty)
                .accessibilityIdentifier("settings.import.item.\(group.id)")
                if let tooltip = group.rows.compactMap(\.tooltip).first {
                    Text(tooltip)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompTextTertiary)
                        .help(tooltip)
                }
                Spacer()
                Button(isOpen ? "收起" : "详情") { toggle(group.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("settings.import.details.\(group.id)")
            }
            if isOpen {
                ForEach(group.rows) { row in
                    rowDetail(row)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func rowDetail(_ row: ExternalImportEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: row.isAvailable ? "checkmark.circle" : "minus.circle")
                .font(.system(size: 10))
                .foregroundStyle(row.isAvailable ? Color.green : Color.ompTextTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12))
                Text(row.skippedReason ?? row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(row.skippedReason == nil ? Color.ompTextSecondary : Color.ompTextTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 18)
        .accessibilityIdentifier("settings.import.row.\(row.id)")
    }

    private var actionBar: some View {
        HStack {
            Button(busy ? "正在导入" : "导入") { Task { await run() } }
                .disabled(busy || enabled.isEmpty)
                .accessibilityIdentifier("settings.import.run")
            if busy {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }

    private func reportView(_ report: ExternalImportReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已导入 \(report.importedCount) 项" + (report.failedCount > 0 ? " · \(report.failedCount) 项未能导入" : "") + (report.skippedCount > 0 ? " · \(report.skippedCount) 项跳过" : ""))
                .font(.system(size: 12.5, weight: .semibold))
                .accessibilityIdentifier("settings.import.result")
            if let summary = report.errorSummary {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                Button("重试") { Task { await run() } }
                    .accessibilityIdentifier("settings.import.result.retry")
            }
            ForEach(report.lines.filter { $0.note != nil }) { line in
                Text("\(line.title)：\(line.note ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(line.failed ? Color.red : Color.ompTextTertiary)
                    .lineLimit(2)
            }
        }
        .accessibilityIdentifier("settings.import.report")
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func scanIfNeeded() async {
        guard scan == nil else { return }
        await rescan()
    }

    private func rescan() async {
        error = nil
        report = nil
        let result = await model.scanExternalAgents()
        scan = result
        enabled = Set(result.entries.filter(\.isAvailable).map(\.id))
    }

    private func run() async {
        busy = true
        defer { busy = false }
        report = await model.runExternalImport(ExternalImportSelection(enabledEntryIDs: enabled))
        let fresh = await model.scanExternalAgents()
        scan = fresh
        enabled = Set(fresh.entries.filter(\.isAvailable).map(\.id))
    }
}

/// One-time prompt on first launch when something importable is found.
/// 暂不 remembers the choice in settings so it never comes back.
struct ExternalImportPrompt: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scan: ExternalImportScan
    var onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入其他 AI 设置")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityIdentifier("import.prompt.title")
            Text("在开始之前，是否把其他 AI 应用里的工作带过来？导入前可以先查看你的设置、项目和聊天。")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ompTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(appsFound)
                .font(.system(size: 12, weight: .medium))
                .accessibilityIdentifier("import.prompt.appsFound")
            Text("你现有的应用配置不会受影响。")
                .font(.system(size: 11))
                .foregroundStyle(Color.ompTextTertiary)
            HStack {
                Button("暂不") {
                    model.dismissExternalImportPrompt()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("import.prompt.skip")
                Spacer()
                Button("导入") {
                    dismiss()
                    onImport()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("import.prompt.import")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var appsFound: String {
        let count = scan.providersFound.count
        return count == 1 ? "发现 1 个应用" : "发现 \(count) 个应用"
    }
}
#endif
