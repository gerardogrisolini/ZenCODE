import Foundation
import SQLite3

/// Read-only access to the Messages history (`~/Library/Messages/chat.db`).
/// Messages.app has no scripting interface for reading conversations, so the
/// local SQLite store is the only source; it requires Full Disk Access for the
/// application hosting ZenCODE.
enum MessagesDatabase {
    static let scanWindow = 3_000

    struct ReadResult: Sendable {
        let texts: [TextMessageInfo]
        let scannedLimitReached: Bool
    }

    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }

    static let fullDiskAccessHint = "Reading the Messages history requires Full Disk Access for the application hosting ZenCODE (Terminal, iTerm, Xcode, ...): System Settings > Privacy & Security > Full Disk Access, then restart that application."

    /// Reports whether the history can be opened without throwing.
    static func accessibility() -> String {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return "missing"
        }
        do {
            let db = try open()
            sqlite3_close(db)
            return "readable"
        } catch {
            return "denied"
        }
    }

    static func read(selector: String?, since: Date?, query: String?, limit: Int) throws -> ReadResult {
        let db = try open()
        defer { sqlite3_close(db) }

        var sql = """
        SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody, m.cache_has_attachments, m.service, m.is_read,
               h.id, c.chat_identifier, c.display_name
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.item_type = 0
        """
        var bindings: [SQLiteBinding] = []
        if let selector = normalizedSelector(selector) {
            sql += " AND (c.chat_identifier = ? COLLATE NOCASE OR c.guid = ? OR h.id = ? COLLATE NOCASE)"
            bindings.append(.text(selector))
            bindings.append(.text(selector))
            bindings.append(.text(selector))
        }
        if let since {
            sql += " AND m.date > ?"
            bindings.append(.integer(Int64(since.timeIntervalSinceReferenceDate * 1_000_000_000)))
        }
        sql += " ORDER BY m.date DESC LIMIT ?"
        let rowLimit = query == nil ? limit : scanWindow
        bindings.append(.integer(Int64(rowLimit)))

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MacOSControlError.operationFailed("Could not query the Messages history: \(String(cString: sqlite3_errmsg(db))).")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case let .text(value):
                sqlite3_bind_text(statement, position, value, -1, transient)
            case let .integer(value):
                sqlite3_bind_int64(statement, position, value)
            }
        }

        var texts: [TextMessageInfo] = []
        var scanned = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            scanned += 1
            let rowID = Int(sqlite3_column_int64(statement, 0))
            let rawDate = sqlite3_column_int64(statement, 1)
            let isFromMe = sqlite3_column_int(statement, 2) == 1
            var text = columnText(statement, 3)
            if text == nil, sqlite3_column_type(statement, 4) == SQLITE_BLOB,
               let pointer = sqlite3_column_blob(statement, 4) {
                let length = Int(sqlite3_column_bytes(statement, 4))
                text = AttributedBodyDecoder.text(from: Data(bytes: pointer, count: length))
            }
            let hasAttachments = sqlite3_column_int(statement, 5) == 1
            let service = columnText(statement, 6)
            let isRead = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 7) == 1
            let handle = columnText(statement, 8)
            let chatIdentifier = columnText(statement, 9)
            let chatName = columnText(statement, 10)

            if let query {
                guard let text, text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                    continue
                }
            }
            texts.append(TextMessageInfo(
                id: rowID,
                chat_identifier: chatIdentifier,
                chat_name: (chatName?.isEmpty ?? true) ? nil : chatName,
                sender: isFromMe ? "me" : (handle ?? "unknown"),
                is_from_me: isFromMe,
                date: MacOSDate.format(date(fromRaw: rawDate)),
                text: text,
                service: service,
                has_attachments: hasAttachments,
                is_read: isFromMe ? nil : isRead
            ))
            if texts.count >= limit {
                break
            }
        }
        // Chronological order reads naturally as a conversation.
        return ReadResult(texts: texts.reversed(), scannedLimitReached: query != nil && scanned >= scanWindow && texts.count < limit)
    }

    // MARK: - Helpers

    private enum SQLiteBinding {
        case text(String)
        case integer(Int64)
    }

    private static func open() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw MacOSControlError.notFound("The Messages history was not found at \(databaseURL.path).")
        }
        var db: OpaquePointer?
        let uri = "file:\(databaseURL.path)?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
            if let db { sqlite3_close(db) }
            if rc == SQLITE_AUTH || rc == SQLITE_CANTOPEN || message.lowercased().contains("authorization denied") {
                throw MacOSControlError.permissionRequired("Cannot open the Messages history (\(message)). \(fullDiskAccessHint)")
            }
            throw MacOSControlError.operationFailed("Cannot open the Messages history: \(message).")
        }
        // A readable header check surfaces permission errors deterministically.
        var statement: OpaquePointer?
        let probe = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &statement, nil)
        let stepped = statement.map { sqlite3_step($0) } ?? SQLITE_ERROR
        sqlite3_finalize(statement)
        guard probe == SQLITE_OK, stepped == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw MacOSControlError.permissionRequired("Cannot read the Messages history (\(message)). \(fullDiskAccessHint)")
        }
        return db
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    /// `message.date` is stored as nanoseconds since 2001-01-01 on current
    /// macOS releases and as seconds on legacy rows.
    private static func date(fromRaw raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Accepts Messages.app chat ids (`iMessage;-;+39...`, `any;-;name@x`),
    /// chat.db guids, plain handles, or group chat identifiers.
    private static func normalizedSelector(_ selector: String?) -> String? {
        guard let selector = selector?.trimmingCharacters(in: .whitespacesAndNewlines), !selector.isEmpty else {
            return nil
        }
        if selector.contains(";-;") || selector.contains(";+;") {
            return selector.components(separatedBy: ";").last ?? selector
        }
        return selector
    }
}

/// Extracts the plain text stored in `message.attributedBody`, a typedstream
/// archive of an NSAttributedString used when the `text` column is NULL.
enum AttributedBodyDecoder {
    static func text(from data: Data) -> String? {
        if let heuristic = heuristicText(from: data), !heuristic.isEmpty {
            return heuristic
        }
        if let unarchiver = NSUnarchiver(forReadingWith: data),
           let attributed = unarchiver.decodeObject() as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    /// The string payload follows the `NSString` class marker and a `+` tag;
    /// its byte length uses the typedstream integer encoding.
    private static func heuristicText(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = bytes.firstRange(of: Array("NSString".utf8)) else { return nil }
        var index = marker.upperBound
        while index < bytes.count, bytes[index] != 0x2B {
            index += 1
        }
        index += 1
        guard index < bytes.count else { return nil }
        var length = Int(bytes[index])
        index += 1
        switch length {
        case 0x81:
            guard index + 2 <= bytes.count else { return nil }
            length = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
        case 0x82:
            guard index + 4 <= bytes.count else { return nil }
            length = Int(bytes[index]) | (Int(bytes[index + 1]) << 8) | (Int(bytes[index + 2]) << 16) | (Int(bytes[index + 3]) << 24)
            index += 4
        case 0x83...0xFF:
            return nil
        default:
            break
        }
        guard length > 0, index + length <= bytes.count else { return nil }
        return String(bytes: bytes[index ..< index + length], encoding: .utf8)
    }
}
