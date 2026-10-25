import Foundation
import os

/// Severity of one diagnostics event.
public enum DiagnosticsLevel: String, Codable, Sendable, CaseIterable {
    case debug
    case info
    case warn
    case error

    var osType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warn: .error
        case .error: .fault
        }
    }
}

/// One recorded diagnostics event.
///
/// `message` and `fields` are stored already masked: credentials never reach
/// the ring buffer, the JSONL file or the debug HTTP routes.
public struct DiagnosticsEvent: Codable, Sendable, Equatable, Identifiable {
    public var seq: UInt64
    public var timestamp: Date
    public var category: String
    public var level: DiagnosticsLevel
    public var message: String
    public var fields: [String: String]

    public var id: UInt64 { seq }
}

/// Thread-safe process-wide diagnostics log.
///
/// Keeps a fixed-size ring buffer with monotonically increasing sequence
/// numbers, mirrors every event to `os.Logger` and appends one JSON line to
/// `<store dir>/diagnostics/events.jsonl`, rotating the file at 1 MB and
/// keeping a single previous generation.
public final class DiagnosticsCenter: @unchecked Sendable {
    public static let shared = DiagnosticsCenter()

    public static let capacity = 500
    public static let rotateBytes = 1_048_576
    public static let subsystem = "com.ace.ompchat"

    private let lock = NSLock()
    private var buffer: [DiagnosticsEvent] = []
    private var nextSeq: UInt64 = 1
    private let logger = Logger(subsystem: DiagnosticsCenter.subsystem, category: "diagnostics")
    private let encoder: JSONEncoder
    private var logDirectoryOverride: URL?
    private var diskEnabled = true

    public init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    /// Records one event. `message` and every field value are masked before
    /// anything is retained, logged or written.
    public func record(
        _ category: String,
        _ level: DiagnosticsLevel,
        _ message: String,
        fields: [String: String] = [:]
    ) {
        let maskedMessage = DiagnosticsMask.mask(message)
        var maskedFields: [String: String] = [:]
        for (key, value) in fields {
            maskedFields[key] = DiagnosticsMask.mask(value)
        }

        let event: DiagnosticsEvent = lock.withLock {
            let event = DiagnosticsEvent(
                seq: nextSeq,
                timestamp: Date(),
                category: category,
                level: level,
                message: maskedMessage,
                fields: maskedFields
            )
            nextSeq += 1
            buffer.append(event)
            if buffer.count > Self.capacity {
                buffer.removeFirst(buffer.count - Self.capacity)
            }
            return event
        }

        logger.log(level: level.osType, "[\(category, privacy: .public)] \(maskedMessage, privacy: .public)")
        if diskEnabled { appendToDisk(event) }
    }

    /// Events with `seq` strictly greater than `since`, oldest first.
    public func events(since: UInt64 = 0) -> [DiagnosticsEvent] {
        lock.withLock { buffer.filter { $0.seq > since } }
    }

    /// The most recent `limit` events, oldest first.
    public func recent(_ limit: Int) -> [DiagnosticsEvent] {
        lock.withLock { Array(buffer.suffix(max(0, limit))) }
    }

    /// Highest sequence number issued so far, or 0 before the first event.
    public var lastSeq: UInt64 {
        lock.withLock { nextSeq &- 1 }
    }

    /// Directory the JSONL log is written into. Honours `OMPCHAT_STORE_DIR`
    /// the same way the conversation store does.
    public static func defaultLogDirectory() -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["OMPCHAT_STORE_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            base = support.appendingPathComponent("OMPChat", isDirectory: true)
        }
        return base.appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// Redirects the JSONL log (tests). `nil` restores the default location.
    public func setLogDirectory(_ url: URL?) {
        lock.withLock { logDirectoryOverride = url }
    }

    /// Turns disk mirroring off (tests that must not touch the real store).
    public func setDiskEnabled(_ enabled: Bool) {
        lock.withLock { diskEnabled = enabled }
    }

    /// Drops the ring buffer and restarts sequence numbering. Does not touch
    /// the JSONL file. Intended for tests.
    public func resetBuffer() {
        lock.withLock {
            buffer.removeAll()
            nextSeq = 1
        }
    }

    /// Current JSONL path, accounting for any test override.
    public func logFileURL() -> URL {
        logDirectory().appendingPathComponent("events.jsonl")
    }

    // MARK: - Disk

    private func logDirectory() -> URL {
        lock.withLock { logDirectoryOverride } ?? Self.defaultLogDirectory()
    }

    private func appendToDisk(_ event: DiagnosticsEvent) {
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        let directory = logDirectory()
        let file = directory.appendingPathComponent("events.jsonl")
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded(file: file, incoming: line.count, manager: manager)
            if manager.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file, options: .atomic)
            }
        } catch {
            // Disk failure must never break the caller; the ring buffer and
            // os.Logger already hold the event.
        }
    }

    private func rotateIfNeeded(file: URL, incoming: Int, manager: FileManager) {
        guard let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue else { return }
        guard size + incoming > Self.rotateBytes else { return }
        let previous = file.deletingLastPathComponent().appendingPathComponent("events.1.jsonl")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: file, to: previous)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Masks credentials before they reach memory, disk, logs or HTTP routes.
public enum DiagnosticsMask {
    /// Replacements applied to free text. Order matters: the header form is
    /// matched before the bare `token`/`key` forms.
    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"(?i)(authorization\s*[:=]\s*)(\S+)"#, "$1***"),
            (#"(?i)(bearer\s+)\S+"#, "$1***"),
            (#"(?i)((?:api[_-]?key|token|secret|password|room(?:code)?)\s*[:=]\s*)\S+"#, "$1***"),
            (#"sk-[A-Za-z0-9_\-]{8,}"#, "sk-***"),
        ]
        return specs.compactMap { spec in
            guard let regex = try? NSRegularExpression(pattern: spec.0) else { return nil }
            return (regex, spec.1)
        }
    }()

    public static func mask(_ text: String) -> String {
        var result = text
        for (regex, template) in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// Shows only the first and last two characters of a secret, or `***`
    /// when it is too short to hint at safely.
    public static func hint(_ secret: String) -> String {
        guard secret.count >= 8 else { return secret.isEmpty ? "" : "***" }
        return "\(secret.prefix(2))…\(secret.suffix(2))"
    }
}
