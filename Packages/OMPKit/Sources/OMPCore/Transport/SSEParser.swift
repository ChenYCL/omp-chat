import Foundation

public struct SSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String
    public var id: String?
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// Incremental `text/event-stream` parser per the WHATWG spec subset that
/// OpenAI/Anthropic relays actually emit.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastID: String?
    private var pendingRetry: Int?

    public init() {}

    public mutating func consume(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let newline = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline.lowerBound)
            buffer.removeSubrange(buffer.startIndex...newline.lowerBound)
            guard let raw = String(data: lineData, encoding: .utf8) else { continue }
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let event = process(line: line) {
                events.append(event)
            }
        }
        return events
    }

    /// Flushes a trailing event that was never terminated by a blank line.
    public mutating func finish() -> SSEEvent? {
        guard !buffer.isEmpty else { return nil }
        let raw = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(line)
            if text.hasSuffix("\r") { text.removeLast() }
            if let event = process(line: text) {
                return event
            }
        }
        return flush()
    }

    private mutating func process(line: String) -> SSEEvent? {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") { return nil }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            var remainder = String(line[line.index(after: colon)...])
            if remainder.hasPrefix(" ") { remainder.removeFirst() }
            value = remainder
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
        case "id":
            lastID = value
        case "retry":
            if let parsed = Int(value) { pendingRetry = parsed }
        default:
            break
        }
        return nil
    }

    private mutating func flush() -> SSEEvent? {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            pendingRetry = nil
        }
        guard !dataLines.isEmpty || eventName != nil else { return nil }
        return SSEEvent(
            event: eventName,
            data: dataLines.joined(separator: "\n"),
            id: lastID,
            retry: pendingRetry
        )
    }
}
