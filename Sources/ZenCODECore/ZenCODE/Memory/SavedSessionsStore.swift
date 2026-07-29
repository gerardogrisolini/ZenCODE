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

    private static let fileTransactionCoordinator = FileTransactionCoordinator.shared

    private struct IndexFile: Codable {
        var version: Int
        var sessions: [SavedSessionIndexEntry]
    }

    private let fileManager: FileManager
    private let directoryURL: URL?

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
        let fileURL = sessionsFileURL()
        return Self.fileTransactionCoordinator.withLock(for: fileURL) {
            guard let index = try? readIndexFile(at: fileURL) else {
                return []
            }
            return index.sessions.sorted { $0.savedAt > $1.savedAt }
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

        let fileURL = sessionsFileURL()
        return try Self.fileTransactionCoordinator.withLock(for: fileURL) {
            var index = try readIndexFile(at: fileURL)
            index.sessions.removeAll { $0.projectPath == normalizedProjectPath }
            index.sessions.insert(entry, at: 0)
            index.sessions.sort { $0.savedAt > $1.savedAt }
            try writeIndexFile(index, to: fileURL)
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

    private func readIndexFile(at fileURL: URL) throws -> IndexFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return IndexFile(version: 1, sessions: [])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SavedSessionsStoreError.unreadableIndex(fileURL.path)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(IndexFile.self, from: data)
        } catch {
            throw SavedSessionsStoreError.invalidIndex(fileURL.path)
        }
    }

    private func writeIndexFile(_ index: IndexFile, to fileURL: URL) throws {
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

public enum SavedSessionsStoreError: LocalizedError {
    case unreadableIndex(String)
    case invalidIndex(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableIndex(path):
            return "Saved sessions index could not be read at \(path); it was left unchanged."
        case let .invalidIndex(path):
            return "Saved sessions index is invalid at \(path); it was left unchanged."
        }
    }
}
