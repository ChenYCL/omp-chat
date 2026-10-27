import Foundation

/// Scan-side helpers the scanner builds entries with.
extension ExternalImportScan {
    /// Appends a kind's rows when there is anything to show, even all-skipped
    /// rows: the user should see why a category is unavailable.
    mutating func sessionsAppend(provider: ExternalImportProvider, kind: ExternalImportItemKind, rows: [ExternalImportEntry]) {
        guard !rows.isEmpty else { return }
        entries.append(contentsOf: rows)
    }

    /// The global instructions entry: CLAUDE.md (or a Cursor equivalent —
    /// Cursor has none on disk, so this is only used by Claude Code today)
    /// becomes a fenced block appended to OMPChat's 全局自定义指令.
    mutating func instructionsEntry(provider: ExternalImportProvider, tooltip: String?, globalFile: String, existing: String, sourceName: String) {
        guard let raw = ExternalImportScanner.readBounded(globalFile),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let heading = "## 从 \(provider.displayName) 导入"
        if existing.contains(heading) {
            if existing.contains(raw) {
                entries.append(ExternalImportEntry(
                    id: "\(provider.rawValue).instructions", provider: provider, kind: .instructions,
                    title: "全局指令（\(sourceName)）",
                    detail: "追加到 OMPChat 全局自定义指令", count: 1,
                    skippedReason: "已导入过同样的内容，跳过", tooltip: tooltip, operation: nil
                ))
            } else {
                entries.append(ExternalImportEntry(
                    id: "\(provider.rawValue).instructions", provider: provider, kind: .instructions,
                    title: "全局指令（\(sourceName)）",
                    detail: "追加到 OMPChat 全局自定义指令", count: 1,
                    skippedReason: "已有一份旧的导入内容（源文件后来改过）。先在 设置 → 个性化 里整理旧内容，再重新扫描", tooltip: tooltip, operation: nil
                ))
            }
            return
        }
        let imports = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@") && $0.count > 1 && !$0.contains(" ") }
        var block = "\(heading)\n\n" + raw
        if let last = block.last, !last.isNewline { block += "\n" }
        if !imports.isEmpty {
            block += "\n> 注：原文里的 @ 引用（\(imports.count) 处）按原样保留，没有展开成对应文件的内容。\n"
        }
        entries.append(ExternalImportEntry(
            id: "\(provider.rawValue).instructions", provider: provider, kind: .instructions,
            title: "全局指令（\(sourceName)）",
            detail: "以「从 \(provider.displayName) 导入」标题追加到 OMPChat 全局自定义指令，原文不展开 @ 引用", count: 1,
            skippedReason: nil, tooltip: tooltip,
            operation: .appendInstructions(sourceName: sourceName, block: block)
        ))
    }
}
