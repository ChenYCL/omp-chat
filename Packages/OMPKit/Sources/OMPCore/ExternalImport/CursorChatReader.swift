import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Reads one Cursor chat (`~/.cursor/chats/<hash>/<agent>/store.db`).
///
/// Shape verified 2026-10-27 against real databases (read-only): `meta`
/// holds a hex-encoded JSON document under key `"0"` with `name`,
/// `createdAt` (ms) and `latestRootBlobId`; `blobs` rows are hex text.
/// Message blobs are JSON `{"role":"user"|"assistant"|…, "content": …}`;
/// the root blob is a protobuf-style tree whose field 9 carries the
/// workspace `file://` URI. Everything else in the tree is ignored.
enum CursorChatReader {
    static func read(path: String, key: String) -> ExternalImportSession? {
        #if canImport(SQLite3)
        guard let database = open(path) else { return nil }
        defer { sqlite3_close(database) }
        var title: String?
        var createdAt: Date?
        var rootBlob: Data?
        if let statement = sqlStatement(database: database, sql: "SELECT value FROM meta WHERE key = '0'") {
            if sqlite3_step(statement) == SQLITE_ROW, let text = textColumn(statement, 0),
               let bytes = dataFromHex(text), let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                if let name = object["name"] as? String, !name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty, name != "New Agent" {
                    title = name
                }
                if let ms = object["createdAt"] as? Double {
                    createdAt = Date(timeIntervalSince1970: ms / 1000)
                }
                if let id = object["latestRootBlobId"] as? String {
                    rootBlob = blob(database: database, id: id)
                }
            }
            sqlite3_finalize(statement)
        }
        var messages: [ExternalImportMessage] = []
        if let statement = sqlStatement(database: database, sql: "SELECT data FROM blobs ORDER BY rowid LIMIT 5000") {
            while sqlite3_step(statement) == SQLITE_ROW {
                if messages.count >= 400 { break }
                guard let text = textColumn(statement, 0),
                      let bytes = dataFromHex(text),
                      let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                      let role = object["role"] as? String, role == "user" || role == "assistant" else { continue }
                for text in messageTexts(object["content"]) {
                    if let last = messages.last, last.role == role {
                        messages[messages.count - 1].text += "\n\n" + text
                    } else {
                        messages.append(ExternalImportMessage(role: role, text: text))
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        guard messages.contains(where: { $0.role == "user" }) else { return nil }
        let folder = rootBlob.flatMap(workspacePath)
        let fallback = String(messages.first(where: { $0.role == "user" })?.text.prefix(40) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ExternalImportSession(
            key: key, title: title ?? (fallback.isEmpty ? "未命名会话" : fallback),
            workingDirectory: folder, messages: messages, createdAt: createdAt, updatedAt: createdAt
        )
        #else
        return nil
        #endif
    }

    // MARK: SQLite plumbing

    #if canImport(SQLite3)
    static func open(_ path: String) -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        return database
    }

    static func sqlStatement(database: OpaquePointer?, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    static func textColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    static func blob(database: OpaquePointer?, id: String) -> Data? {
        guard let statement = sqlStatement(database: database, sql: "SELECT data FROM blobs WHERE id = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = textColumn(statement, 0) else { return nil }
        return dataFromHex(text)
    }

    static func dataFromHex(_ text: String) -> Data? {
        let characters = Array(text.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var data = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = hexValue(characters[index]), let low = hexValue(characters[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x61...0x66: byte - 0x61 + 10
        case 0x41...0x46: byte - 0x41 + 10
        default: nil
        }
    }
    #endif

    // MARK: Content

    /// User prompts: drop the `<user_info>…` context wrapper, unwrap
    /// `<user_query>…</user_query>`; plain strings pass through.
    static func messageTexts(_ content: Any?) -> [String] {
        var out: [String] = []
        if let text = content as? String {
            if let unwrapped = cleanUserText(text) { out.append(unwrapped) }
            return out
        }
        guard let parts = content as? [[String: Any]] else { return out }
        for part in parts where part["type"] as? String == "text" {
            guard let text = part["text"] as? String, let cleaned = cleanUserText(text) else { continue }
            out.append(cleaned)
        }
        return out
    }

    static func cleanUserText(_ text: String) -> String? {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return nil }
        if working.hasPrefix("<user_info>") {
            if let end = working.range(of: "</user_info>") {
                working = String(working[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return nil
            }
        }
        if working.hasPrefix("<timestamp>") {
            // Keep only what is inside <user_query>…</user_query>.
            guard let start = working.range(of: "<user_query>"), let end = working.range(of: "</user_query>"), start.upperBound <= end.lowerBound else {
                return nil
            }
            working = String(working[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return working.isEmpty ? nil : working
    }

    /// Field 9 of the root blob tree, a `file://…` workspace URI.
    static func workspacePath(_ blob: Data) -> String? {
        let bytes = [UInt8](blob)
        var index = 0
        while index < bytes.count {
            guard let key = readVarint(bytes, &index) else { return nil }
            let field = key >> 3
            let wire = key & 0x07
            switch wire {
            case 0:
                guard readVarint(bytes, &index) != nil else { return nil }
            case 2:
                guard let length = readVarint(bytes, &index), index + length <= bytes.count else { return nil }
                if field == 9, let uri = String(bytes: bytes[index..<index + length], encoding: .utf8),
                   uri.hasPrefix("file://"), let url = URL(string: uri), url.isFileURL {
                    return url.path
                }
                index += length
            default:
                return nil
            }
        }
        return nil
    }

    static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        var result = 0
        var shift = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
