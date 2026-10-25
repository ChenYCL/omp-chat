import Foundation

/// Outcome of one health check.
public enum DiagnosticsStatus: String, Codable, Sendable {
    case ok
    case warn
    case fail
    case skip
}

/// One health check result. `skip` is used only when the check genuinely
/// cannot run (wrong platform, feature not configured), and `detail` then
/// says why.
public struct DiagnosticsCheckResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var status: DiagnosticsStatus
    public var detail: String
    /// What to do when the check is not `ok`; empty otherwise.
    public var hint: String

    public init(
        id: String,
        title: String,
        status: DiagnosticsStatus,
        detail: String,
        hint: String = ""
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.hint = hint
    }
}

/// Everything the diagnostics UI and `GET /debug/report` render: app identity
/// plus the check results plus the tail of the event log.
public struct DiagnosticsReport: Codable, Sendable, Equatable {
    public var appVersion: String
    public var platform: String
    public var osVersion: String
    public var timestamp: Date
    public var checks: [DiagnosticsCheckResult]
    public var events: [DiagnosticsEvent]

    public init(
        appVersion: String,
        platform: String,
        osVersion: String,
        timestamp: Date = Date(),
        checks: [DiagnosticsCheckResult],
        events: [DiagnosticsEvent]
    ) {
        self.appVersion = appVersion
        self.platform = platform
        self.osVersion = osVersion
        self.timestamp = timestamp
        self.checks = checks
        self.events = events
    }

    public static var currentPlatform: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #else
        "unknown"
        #endif
    }

    public static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    // MARK: - Rendering

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    public func markdown() -> String {
        let stamp = Self.isoFormatter().string(from: timestamp)
        var lines: [String] = []
        lines.append("# OMPChat 诊断报告")
        lines.append("")
        lines.append("- 版本：\(appVersion)")
        lines.append("- 平台：\(platform)")
        lines.append("- 系统：\(osVersion)")
        lines.append("- 时间：\(stamp)")
        lines.append("")
        lines.append("## 检查")
        lines.append("")
        lines.append("| 状态 | 检查 | 详情 |")
        lines.append("| --- | --- | --- |")
        for check in checks {
            lines.append("| \(check.status.rawValue) | \(check.title) | \(Self.escape(check.detail)) |")
            if !check.hint.isEmpty, check.status != .ok, check.status != .skip {
                lines.append("|  | 建议 | \(Self.escape(check.hint)) |")
            }
        }
        lines.append("")
        lines.append("## 最近事件")
        lines.append("")
        if events.isEmpty {
            lines.append("（无）")
        } else {
            for event in events {
                let when = Self.isoFormatter().string(from: event.timestamp)
                lines.append("- `\(event.seq)` \(when) [\(event.level.rawValue)] \(event.category): \(event.message)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func jsonString() -> String {
        guard let data = try? jsonData() else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
