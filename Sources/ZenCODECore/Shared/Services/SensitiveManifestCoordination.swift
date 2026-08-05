//
//  SensitiveManifestCoordination.swift
//  ZenCODE
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum SensitiveManifestCoordinationError: LocalizedError {
    case lockFailed(String)
    case invalidJournal(String)
    case recoveryConflict(String)

    var errorDescription: String? {
        switch self {
        case let .lockFailed(path):
            return "Could not lock sensitive manifests at \(path)."
        case let .invalidJournal(reason):
            return "Invalid sensitive manifest transaction journal: \(reason)"
        case let .recoveryConflict(path):
            return "Refusing to recover over independently changed manifest: \(path)"
        }
    }
}

/// Cross-process serialization boundary shared by settings.json and agents.json
/// writers. Per-file writes remain atomic; this lock prevents coordinated setup
/// commits from interleaving with ordinary credential/profile updates.
enum SensitiveManifestCoordination {
    private static let lockFilename = ".manifests.lock"
    private static let journalFilename = ".manifests.transaction.json"

    struct Change: Sendable {
        let url: URL
        let originalData: Data?
        let intendedData: Data?
    }

    private struct Journal: Codable {
        static let currentVersion = 1

        struct Entry: Codable {
            let path: String
            let originalData: Data?
            let intendedData: Data?
        }

        let version: Int
        let entries: [Entry]
    }

    static func withExclusiveLock<T>(
        supportDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        operation: () throws -> T
    ) throws -> T {
        let directory = supportDirectoryURL?.standardizedFileURL
            ?? AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        let lockURL = directory.appendingPathComponent(lockFilename)
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SensitiveManifestCoordinationError.lockFailed(lockURL.path)
        }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw SensitiveManifestCoordinationError.lockFailed(lockURL.path)
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SensitiveManifestCoordinationError.lockFailed(lockURL.path)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        #endif

        try recoverInterruptedTransaction(
            in: directory,
            fileManager: fileManager
        )
        return try operation()
    }

    /// Publishes a recovery journal. Production callers encode rollback-first
    /// entries: `originalData` is the attempted state accepted by CAS and
    /// `intendedData` is the pre-transaction state recovery must restore.
    static func beginTransaction(
        _ changes: [Change],
        supportDirectoryURL: URL,
        fileManager: FileManager = .default,
        directorySynchronizer: ((URL) throws -> Void)? = nil
    ) throws {
        guard !changes.isEmpty else { return }
        let directory = supportDirectoryURL.standardizedFileURL
        let entries = try changes.map { change -> Journal.Entry in
            let url = change.url.standardizedFileURL
            guard url.deletingLastPathComponent().path == directory.path else {
                throw SensitiveManifestCoordinationError.invalidJournal(
                    "target escapes the support directory: \(url.path)"
                )
            }
            return Journal.Entry(
                path: url.path,
                originalData: change.originalData,
                intendedData: change.intendedData
            )
        }
        let journal = Journal(version: Journal.currentVersion, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let journalData = try encoder.encode(journal)
        let url = journalURL(in: directory)
        do {
            try SensitiveFilePermissions.writeDurably(
                journalData,
                to: url,
                fileManager: fileManager,
                directorySynchronizer: directorySynchronizer
            )
        } catch {
            #if canImport(Darwin) || canImport(Glibc)
            let publicationError = error
            // `write` itself ends at rename; therefore a byte-identical journal
            // proves the failure came from the post-rename directory barrier.
            guard fileManager.fileExists(atPath: url.path),
                  (try? Data(contentsOf: url)) == journalData else {
                throw publicationError
            }
            let synchronize = directorySynchronizer
                ?? SensitiveFilePermissions.synchronizeDirectory
            do {
                // A transient metadata error can be resolved without exposing
                // an indeterminate transaction outcome to the caller.
                try synchronize(directory)
                return
            } catch {
                // Production journals are rollback-first. Leaving the
                // byte-identical journal visible is safe even when its metadata
                // durability remains indeterminate; deleting it here could
                // remove the only recovery record after effects have started.
                throw publicationError
            }
            #else
            throw error
            #endif
        }
    }

    static func ensureTransaction(
        _ changes: [Change],
        supportDirectoryURL: URL,
        fileManager: FileManager = .default,
        directorySynchronizer: ((URL) throws -> Void)? = nil
    ) throws {
        let directory = supportDirectoryURL.standardizedFileURL
        let url = journalURL(in: directory)
        if fileManager.fileExists(atPath: url.path) {
            try SensitiveFilePermissions.hardenExistingFile(
                at: url,
                fileManager: fileManager
            )
            return
        }
        try beginTransaction(
            changes,
            supportDirectoryURL: directory,
            fileManager: fileManager,
            directorySynchronizer: directorySynchronizer
        )
    }

    static func clearTransaction(
        supportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let url = journalURL(in: supportDirectoryURL.standardizedFileURL)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        #if canImport(Darwin) || canImport(Glibc)
        try SensitiveFilePermissions.synchronizeDirectory(
            at: supportDirectoryURL.standardizedFileURL
        )
        #endif
    }

    private static func recoverInterruptedTransaction(
        in directory: URL,
        fileManager: FileManager
    ) throws {
        let journalURL = journalURL(in: directory)
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        try SensitiveFilePermissions.hardenExistingFile(
            at: journalURL,
            fileManager: fileManager
        )
        let journal: Journal
        do {
            journal = try JSONDecoder().decode(
                Journal.self,
                from: Data(contentsOf: journalURL)
            )
        } catch {
            throw SensitiveManifestCoordinationError.invalidJournal(
                error.localizedDescription
            )
        }
        guard journal.version == Journal.currentVersion,
              !journal.entries.isEmpty else {
            throw SensitiveManifestCoordinationError.invalidJournal(
                "unsupported version or empty transaction"
            )
        }

        for entry in journal.entries {
            let url = URL(fileURLWithPath: entry.path).standardizedFileURL
            guard url.deletingLastPathComponent().path == directory.path else {
                throw SensitiveManifestCoordinationError.invalidJournal(
                    "target escapes the support directory: \(url.path)"
                )
            }
            let currentData = try dataIfPresent(at: url, fileManager: fileManager)
            guard currentData == entry.originalData || currentData == entry.intendedData else {
                throw SensitiveManifestCoordinationError.recoveryConflict(url.path)
            }
        }

        // A durable journal means finalization had begun. Recovery rolls the
        // complete validated transaction forward, regardless of which rename
        // was the last one visible before process termination.
        for entry in journal.entries {
            let url = URL(fileURLWithPath: entry.path).standardizedFileURL
            if let intendedData = entry.intendedData {
                try SensitiveFilePermissions.writeDurably(
                    intendedData,
                    to: url,
                    fileManager: fileManager
                )
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        #if canImport(Darwin) || canImport(Glibc)
        try SensitiveFilePermissions.synchronizeDirectory(at: directory)
        #endif
        try fileManager.removeItem(at: journalURL)
        #if canImport(Darwin) || canImport(Glibc)
        try SensitiveFilePermissions.synchronizeDirectory(at: directory)
        #endif
    }

    private static func journalURL(in directory: URL) -> URL {
        directory.appendingPathComponent(journalFilename)
    }

    private static func dataIfPresent(
        at url: URL,
        fileManager: FileManager
    ) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try SensitiveFilePermissions.hardenExistingFile(
            at: url,
            fileManager: fileManager
        )
        return try Data(contentsOf: url)
    }
}
