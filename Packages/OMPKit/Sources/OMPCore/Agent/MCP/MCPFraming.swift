import Foundation

/// Splits a byte stream into the newline-delimited messages of the MCP stdio
/// transport. Reads arrive in arbitrary chunks: one message may span several
/// chunks and one chunk may hold several messages.
public struct MCPLineFramer: Sendable {
    public enum Output: Equatable, Sendable {
        case line(Data)
        /// A line longer than the cap was dropped; its length in bytes.
        case oversize(Int)
    }

    /// Screenshots arrive base64-encoded inside one line, so the cap is
    /// generous; it only stops a runaway server from exhausting memory.
    public static let defaultMaxLineBytes = 32 * 1024 * 1024

    public let maxLineBytes: Int
    private var buffer = Data()
    /// Inside an oversize line: bytes are counted and thrown away until its
    /// newline arrives.
    private var discarding = false
    private var discarded = 0

    public init(maxLineBytes: Int = MCPLineFramer.defaultMaxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    public mutating func push(_ chunk: Data) -> [Output] {
        var outputs: [Output] = []
        var start = chunk.startIndex
        while start < chunk.endIndex {
            guard let newline = chunk[start...].firstIndex(of: 0x0A) else {
                accumulate(chunk[start...])
                break
            }
            accumulate(chunk[start..<newline])
            if discarding {
                outputs.append(.oversize(discarded))
                discarding = false
                discarded = 0
            } else if let line = Self.trimmed(buffer) {
                outputs.append(.line(line))
            }
            buffer = Data()
            start = chunk.index(after: newline)
        }
        return outputs
    }

    /// End of stream: an unterminated last line still counts.
    public mutating func finish() -> [Output] {
        defer {
            buffer = Data()
            discarding = false
            discarded = 0
        }
        if discarding { return [.oversize(discarded)] }
        return Self.trimmed(buffer).map { [.line($0)] } ?? []
    }

    private mutating func accumulate(_ piece: Data) {
        if discarding {
            discarded += piece.count
        } else if buffer.count + piece.count > maxLineBytes {
            discarding = true
            discarded = buffer.count + piece.count
            buffer = Data()
        } else {
            buffer.append(piece)
        }
    }

    /// The line without a trailing CR; nil when only whitespace is left.
    private static func trimmed(_ line: Data) -> Data? {
        var end = line.endIndex
        while end > line.startIndex, [0x0D, 0x20, 0x09].contains(line[line.index(before: end)]) {
            end = line.index(before: end)
        }
        guard end > line.startIndex else { return nil }
        return Data(line[line.startIndex..<end])
    }
}

/// The last `capacity` lines of a text stream (a server's stderr). A line
/// split across reads is kept whole; an endless line is cut into pieces of
/// `maxLineBytes` so it cannot grow without bound.
public struct MCPLogRing: Sendable {
    public let capacity: Int
    public static let maxLineBytes = 4096

    private var lines: [String] = []
    private var partial = Data()

    public init(capacity: Int = 200) {
        self.capacity = capacity
    }

    public mutating func append(_ chunk: Data) {
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            partial.append(chunk[start..<newline])
            push(partial)
            partial = Data()
            start = chunk.index(after: newline)
        }
        partial.append(chunk[start...])
        while partial.count > Self.maxLineBytes {
            push(partial.prefix(Self.maxLineBytes))
            partial = Data(partial.dropFirst(Self.maxLineBytes))
        }
    }

    /// A line the client itself adds (e.g. a dropped oversize message).
    public mutating func note(_ line: String) {
        push(Data(line.utf8))
    }

    /// Oldest first, the unterminated tail included.
    public var tail: [String] {
        guard !partial.isEmpty else { return lines }
        return Array((lines + [Self.text(partial)]).suffix(capacity))
    }

    private mutating func push(_ line: Data) {
        lines.append(Self.text(line))
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    private static func text(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}
