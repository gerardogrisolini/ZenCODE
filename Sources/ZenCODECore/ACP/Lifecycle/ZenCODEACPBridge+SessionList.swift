//
//  ZenCODEACPBridge+SessionList.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/11/26.
//

import Foundation
import ToolCore

/// The sessions `session/list` lists: the saved sessions that ACP saved by
/// itself (``TerminalSavedSession/acpAutosaveChannel``), exactly the ones
/// `session/delete` deletes, so a deleted session is never listed again. One
/// entry per session id, the most recently saved file of the id giving it;
/// the most recently saved session first, sessions saved at the same moment
/// in ascending order of their id, an order in which no two entries are
/// equal, so a page ends at a key and the next page starts strictly after it.
struct ACPSessionList: Equatable, Sendable {
    /// The most entries a page of `session/list` holds.
    static let pageSize = 50

    /// A session of the list, as its saved session describes it.
    struct Entry: Equatable, Sendable {
        let sessionID: String
        /// The working directory the session was saved in.
        let workingDirectoryPath: String
        /// The name of the saved session.
        let title: String
        let savedAt: Date

        init(sessionID: String, workingDirectoryPath: String, title: String, savedAt: Date) {
            self.sessionID = sessionID
            self.workingDirectoryPath = workingDirectoryPath
            self.title = title
            self.savedAt = savedAt
        }

        init(file: TerminalSavedSessionFile) {
            self.init(
                sessionID: file.header.sessionID,
                workingDirectoryPath: file.header.workingDirectoryPath,
                title: file.header.name,
                savedAt: file.header.savedAt
            )
        }

        /// Whether the entry comes after the key `cursor` in the order of the list.
        func follows(_ cursor: Cursor) -> Bool {
            if savedAt != cursor.savedAt {
                return savedAt < cursor.savedAt
            }
            return sessionID > cursor.sessionID
        }
    }

    /// Where a page ends: the sort key of its last entry, `savedAt` without
    /// loss of precision and the session id. The client sees an opaque token
    /// (``token``): the base64url, without padding, of the JSON object
    /// `{"savedAt": <the 16 hexadecimal digits of the bit pattern of
    /// savedAt.timeIntervalSinceReferenceDate>, "sessionId": <the id>}`.
    struct Cursor: Equatable, Sendable {
        let savedAt: Date
        let sessionID: String

        init(after entry: Entry) {
            savedAt = entry.savedAt
            sessionID = entry.sessionID
        }

        /// The cursor `token` encodes; `nil` for a token that no page gave.
        init?(token: String) {
            guard !token.isEmpty,
                  token.unicodeScalars.allSatisfy(Self.isBase64URLScalar),
                  token.utf8.count % 4 != 1 else {
                return nil
            }
            var base64 = token
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
            guard let data = Data(base64Encoded: base64),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  payload.savedAt.utf8.count == 16,
                  payload.savedAt.unicodeScalars.allSatisfy(Self.isHexScalar),
                  let bitPattern = UInt64(payload.savedAt, radix: 16),
                  !payload.sessionId.isEmpty else {
                return nil
            }
            let interval = Double(bitPattern: bitPattern)
            guard interval.isFinite else {
                return nil
            }
            savedAt = Date(timeIntervalSinceReferenceDate: interval)
            sessionID = payload.sessionId
        }

        /// The token the client sends back as `cursor`.
        var token: String {
            let hex = String(savedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            let payload = Payload(
                savedAt: String(repeating: "0", count: 16 - hex.utf8.count) + hex,
                sessionId: sessionID
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            // Two strings always encode.
            let data = (try? encoder.encode(payload)) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        private struct Payload: Codable {
            let savedAt: String
            let sessionId: String
        }

        private static func isBase64URLScalar(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", "_":
                return true
            default:
                return false
            }
        }

        private static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "0"..."9", "a"..."f", "A"..."F":
                return true
            default:
                return false
            }
        }
    }

    /// A page of the list, and the cursor of the next one while entries remain.
    struct Page: Equatable, Sendable {
        let entries: [Entry]
        let nextCursor: Cursor?
    }

    /// Every entry of the list, in its order.
    let entries: [Entry]

    /// The list of the saved session files `files`, one entry per session id.
    init(files: [TerminalSavedSessionFile]) {
        var newestFiles: [String: TerminalSavedSessionFile] = [:]
        for file in files {
            if let current = newestFiles[file.header.sessionID], !Self.isNewer(file, than: current) {
                continue
            }
            newestFiles[file.header.sessionID] = file
        }
        entries = newestFiles.values.map(Entry.init(file:)).sorted(by: Self.precedes)
    }

    /// The `size` entries that follow `cursor`, or the first ones without it.
    func page(after cursor: Cursor?, size: Int = Self.pageSize) -> Page {
        let remaining = cursor.map { cursor in entries.filter { $0.follows(cursor) } } ?? entries
        let pageEntries = Array(remaining.prefix(size))
        let nextCursor = remaining.count > pageEntries.count ? pageEntries.last.map(Cursor.init(after:)) : nil
        return Page(entries: pageEntries, nextCursor: nextCursor)
    }

    /// The order of the list: the most recently saved first, then by session id.
    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.savedAt != rhs.savedAt {
            return lhs.savedAt > rhs.savedAt
        }
        return lhs.sessionID < rhs.sessionID
    }

    /// Which of two files of one session id gives its entry: the most
    /// recently saved, then the name `session/load` would prefer between
    /// them, then the path, so the choice never depends on the listing order.
    private static func isNewer(_ file: TerminalSavedSessionFile, than other: TerminalSavedSessionFile) -> Bool {
        if file.header.savedAt != other.header.savedAt {
            return file.header.savedAt > other.header.savedAt
        }
        let byName = file.header.name.localizedStandardCompare(other.header.name)
        if byName != .orderedSame {
            return byName == .orderedAscending
        }
        return file.url.path < other.url.path
    }
}

extension ZenCODEACPBridge {
    /// `session/list` (ACP v1): one page of the sessions a client can reopen
    /// with `session/load` or `session/resume` (``ACPSessionList``), as
    /// `{ sessions, nextCursor? }`, each session with its `sessionId`, `cwd`,
    /// `title` (the name of its saved session), and `updatedAt` (when it was
    /// last saved, ISO 8601). With a `cwd`, only the sessions saved in that
    /// working directory, resolved as `session/new` and `session/load`
    /// resolve it, and every `cwd` of the reply is the one the client sent.
    /// It only reads the headers of the saved sessions: it needs no
    /// configuration, and creates, restores, or changes nothing, the live
    /// sessions included; a live session that never saved a turn is not listed.
    func listSessions(id: JSONValue?, params: [String: Any]) async throws {
        try ensureNotShutDown()
        let requestedWorkingDirectory = try Self.sessionListWorkingDirectory(from: params)
        let cursor = try Self.sessionListCursor(from: params)
        let files = TerminalSessionStore.autosavedSessionFiles(
            autosaveChannel: TerminalSavedSession.acpAutosaveChannel,
            workingDirectory: requestedWorkingDirectory.map {
                AgentConfiguration.resolvedWorkingDirectory(rawValue: $0, applyLaunchDirectoryFallback: false)
            }
        )
        let page = ACPSessionList(files: files).page(after: cursor)
        let formatter = ISO8601DateFormatter()
        var result: [String: JSONValue] = [
            "sessions": .array(page.entries.map { entry in
                .object([
                    "sessionId": .string(entry.sessionID),
                    "cwd": .string(requestedWorkingDirectory ?? entry.workingDirectoryPath),
                    "title": .string(entry.title),
                    "updatedAt": .string(formatter.string(from: entry.savedAt)),
                ])
            }),
        ]
        if let nextCursor = page.nextCursor {
            result["nextCursor"] = .string(nextCursor.token)
        }
        await writer.sendResultIfRequest(id: id, result: .object(result))
    }

    /// The `cwd` of `session/list`, read as the other methods read it but
    /// without falling back to a directory: `nil` when the request has none,
    /// which lists every project. A `cwd` that is not a string with an
    /// absolute path is invalid.
    static func sessionListWorkingDirectory(from params: [String: Any]) throws -> String? {
        if let value = params["cwd"], !(value is NSNull), (value as? String)?.nilIfBlank == nil {
            throw ACPError.invalidParams("session/list params.cwd must be an absolute path.")
        }
        guard let path = workingDirectory(from: params) else {
            return nil
        }
        guard path.hasPrefix("/") else {
            throw ACPError.invalidParams("session/list params.cwd must be an absolute path: \(path)")
        }
        return path
    }

    /// The `cursor` of `session/list`: `nil` for the first page; a cursor
    /// that is not a string a previous reply gave is invalid.
    static func sessionListCursor(from params: [String: Any]) throws -> ACPSessionList.Cursor? {
        guard let value = params["cursor"], !(value is NSNull) else {
            return nil
        }
        guard let token = value as? String, let cursor = ACPSessionList.Cursor(token: token) else {
            throw ACPError.invalidParams("session/list params.cursor is not a cursor a session/list reply gave.")
        }
        return cursor
    }
}
