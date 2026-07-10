//
//  SavedSessionsStore.swift
//  ZenCODE
//

import Foundation

public nonisolated struct SavedSessionIndexEntry: Codable, Hashable, Sendable {
    public let projectPath: String
    public let sessionName: String
    public let sessionID: String
    public let savedAt: Date

    public init(
        projectPath: String,
        sessionName: String,
        sessionID: String,
        savedAt: Date
    ) {
        self.projectPath = projectPath
        self.sessionName = sessionName
        self.sessionID = sessionID
        self.savedAt = savedAt
    }
}

/// Maintains the per-project saved-session index in `~/.zencode/sessions.json`.
public final class SavedSessionsStore {
    public static let filename = "sessions.json"

    private struct IndexFile: Codable {
        var version: Int
        var sessions: [SavedSessionIndexEntry]
    }

    private let fileManager: FileManager
    private let directoryURL: URL?
    private let writeLock = NSLock()

    public init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
    }

    public func sessionsFileURL() -> URL {
        directoryURLResolved()
            .appendingPathComponent(Self.filename)
            .standardizedFileURL
    }

    /// Returns all saved-session entries, most recently saved first.
    public func sessions() -> [SavedSessionIndexEntry] {
        writeLock.withLock {
            readIndexFile().sessions
                .sorted { $0.savedAt > $1.savedAt }
        }
    }

    /// Records the latest saved session for a project, replacing any previous
    /// entry for the same project path.
    @discardableResult
    public func recordSavedSession(
        projectPath: String,
        sessionName: String,
        sessionID: String,
        savedAt: Date
    ) throws -> SavedSessionIndexEntry {
        let normalizedProjectPath = URL(fileURLWithPath: projectPath)
            .standardizedFileURL
            .path
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSessionName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedProjectPath.isEmpty else {
            throw MemoryServiceError.missingField("projectPath")
        }
        guard !normalizedSessionName.isEmpty else {
            throw MemoryServiceError.missingField("sessionName")
        }
        guard !normalizedSessionID.isEmpty else {
            throw MemoryServiceError.missingField("sessionID")
        }

        let entry = SavedSessionIndexEntry(
            projectPath: normalizedProjectPath,
            sessionName: normalizedSessionName,
            sessionID: normalizedSessionID,
            savedAt: savedAt
        )

        return try writeLock.withLock {
            var index = readIndexFile()
            index.sessions.removeAll { $0.projectPath == normalizedProjectPath }
            index.sessions.insert(entry, at: 0)
            index.sessions.sort { $0.savedAt > $1.savedAt }
            try writeIndexFile(index)
            return entry
        }
    }

    // MARK: - Storage

    private func directoryURLResolved() -> URL {
        if let directoryURL {
            return directoryURL.standardizedFileURL
        }
        return AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
    }

    private func readIndexFile() -> IndexFile {
        let fileURL = sessionsFileURL()
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return IndexFile(version: 1, sessions: [])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(IndexFile.self, from: data))
            ?? IndexFile(version: 1, sessions: [])
    }

    private func writeIndexFile(_ index: IndexFile) throws {
        let fileURL = sessionsFileURL()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: fileURL, options: .atomic)
    }
}
