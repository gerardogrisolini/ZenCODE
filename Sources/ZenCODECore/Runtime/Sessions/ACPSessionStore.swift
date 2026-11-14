//
//  ACPSessionStore.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/11/26.
//

import Foundation
import ToolCore

/// The conversation of an ACP session as the agent keeps it between runs of
/// `zen --acp`, so that `session/load` and `session/resume` of a session the
/// process does not hold can restore it (see ``ACPSessionStore``).
///
/// Only what a restore cannot compose again is kept: the history and the
/// session's own selections. The system prompt, the dynamic context, the tool
/// grant, and the cache key are composed again when the session is restored.
struct ACPSavedSession: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    /// The id the client gave the session.
    let sessionID: String
    let workingDirectoryPath: String
    /// When the session was first saved; kept by every later save.
    let createdAt: Date
    let savedAt: Date
    /// The model the session was configured with (not the id a backend
    /// reports on the wire).
    let modelID: String?
    let agentID: String?
    /// Raw value of the session's ``AgentThinkingSelection``.
    let thinkingSelection: String?
    let preserveThinking: Bool
    let history: [AgentRuntimeMessage]

    init(
        version: Int = Self.currentVersion,
        sessionID: String,
        workingDirectoryPath: String,
        createdAt: Date,
        savedAt: Date,
        modelID: String?,
        agentID: String?,
        thinkingSelection: String?,
        preserveThinking: Bool,
        history: [AgentRuntimeMessage]
    ) {
        self.version = version
        self.sessionID = sessionID
        self.workingDirectoryPath = URL(fileURLWithPath: workingDirectoryPath)
            .standardizedFileURL
            .path
        self.createdAt = createdAt
        self.savedAt = savedAt
        self.modelID = modelID?.nilIfBlank
        self.agentID = agentID?.nilIfBlank
        self.thinkingSelection = thinkingSelection?.nilIfBlank
        self.preserveThinking = preserveThinking
        self.history = history
    }

    /// This record with `createdAt`, the creation date of an earlier save of
    /// the same session.
    func keepingCreationDate(_ createdAt: Date) -> ACPSavedSession {
        ACPSavedSession(
            version: version,
            sessionID: sessionID,
            workingDirectoryPath: workingDirectoryPath,
            createdAt: createdAt,
            savedAt: savedAt,
            modelID: modelID,
            agentID: agentID,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking,
            history: history
        )
    }
}

/// The records of the ACP sessions, one file per session, and the only place
/// that knows their layout on disk:
/// `<support directory>/acp-sessions/<project key>/<SHA-256 hex of the session id>.plist`,
/// a binary property list written atomically with mode 0600 (see
/// `SensitiveFilePermissions`). The session id comes from the client, so it
/// reaches the path only as its hash. The project key is the one of the saved
/// sessions and of the task graphs (``TerminalSessionStore/projectKey(for:)``).
///
/// The records are kept apart from the saved sessions of
/// ``TerminalSessionStore``: `/sessions` does not list them. Nothing prunes
/// or expires them, and `session/close` deletes nothing.
///
/// Reading is lenient: a missing record is `nil`, and a record that cannot be
/// read, is corrupted, has an unknown `version`, or names another session is
/// logged and also `nil`, so it never fails the restore that asked for it.
struct ACPSessionStore: Sendable {
    static let directoryName = "acp-sessions"
    static let fileExtension = "plist"

    /// The support directory, or `nil` for the one
    /// ``AppStorageDirectory/appSupportDirectoryURL(fileManager:)`` resolves
    /// on every use.
    let supportDirectoryURL: URL?

    init(supportDirectoryURL: URL? = nil) {
        self.supportDirectoryURL = supportDirectoryURL?.standardizedFileURL
    }

    /// Writes `session` as the record of its session, in the project of its
    /// working directory, and returns what was written: `session` with the
    /// `createdAt` of the record already saved for the same session, if any.
    @discardableResult
    func save(
        _ session: ACPSavedSession,
        fileManager: FileManager = .default
    ) throws -> ACPSavedSession {
        let workingDirectory = URL(fileURLWithPath: session.workingDirectoryPath)
        let record = savedCreationDate(
            sessionID: session.sessionID,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        ).map(session.keepingCreationDate) ?? session
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        try SensitiveFilePermissions.write(
            data,
            to: sessionFileURL(
                sessionID: session.sessionID,
                workingDirectory: workingDirectory,
                fileManager: fileManager
            ),
            fileManager: fileManager
        )
        return record
    }

    /// The record of the session `sessionID` in the project of
    /// `workingDirectory`; `nil` when there is none or it cannot be used.
    func load(
        sessionID: String,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> ACPSavedSession? {
        let fileURL = sessionFileURL(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            try SensitiveFilePermissions.hardenExistingFile(at: fileURL, fileManager: fileManager)
            let data = try Data(contentsOf: fileURL)
            let decoder = PropertyListDecoder()
            let version = try decoder.decode(VersionProbe.self, from: data).version
            guard version == ACPSavedSession.currentVersion else {
                Self.warnIgnoring(fileURL, reason: "unsupported version \(version)")
                return nil
            }
            let record = try decoder.decode(ACPSavedSession.self, from: data)
            guard record.sessionID == sessionID else {
                Self.warnIgnoring(fileURL, reason: "it belongs to another session")
                return nil
            }
            return record
        } catch {
            Self.warnIgnoring(fileURL, reason: error.localizedDescription)
            return nil
        }
    }

    /// When the record of the session `sessionID` was first saved; `nil`
    /// when there is no record of this version for that session. Every save
    /// asks for it, so only the header of the record is decoded, not its
    /// history, and a record that cannot be used is not reported: the save
    /// replaces it.
    private func savedCreationDate(
        sessionID: String,
        workingDirectory: URL,
        fileManager: FileManager
    ) -> Date? {
        let fileURL = sessionFileURL(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        guard let data = try? Data(contentsOf: fileURL),
              let header = try? PropertyListDecoder().decode(Header.self, from: data),
              header.version == ACPSavedSession.currentVersion,
              header.sessionID == sessionID else {
            return nil
        }
        return header.createdAt
    }

    /// The file of the record of the session `sessionID` in the project of
    /// `workingDirectory`, whether it exists or not.
    func sessionFileURL(
        sessionID: String,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        sessionsDirectoryURL(workingDirectory: workingDirectory, fileManager: fileManager)
            .appendingPathComponent(
                "\(Data(sessionID.utf8).sha256Hex()).\(Self.fileExtension)",
                isDirectory: false
            )
    }

    /// The directory of the records of the project of `workingDirectory`.
    func sessionsDirectoryURL(
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        (supportDirectoryURL
            ?? AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager))
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(
                TerminalSessionStore.projectKey(for: workingDirectory),
                isDirectory: true
            )
    }

    /// The part of a record read before the rest: a record of another
    /// version may not decode as this one.
    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// What a save needs of the record it replaces.
    private struct Header: Decodable {
        let version: Int
        let sessionID: String
        let createdAt: Date
    }

    private static func warnIgnoring(_ fileURL: URL, reason: String) {
        ZenLogger.warning(
            .sessionService,
            "Ignoring the saved ACP session \(fileURL.lastPathComponent): \(reason)"
        )
    }
}
