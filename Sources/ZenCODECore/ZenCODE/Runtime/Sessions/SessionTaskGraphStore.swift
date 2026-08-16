//
//  SessionTaskGraphStore.swift
//  ZenCODE
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SessionTaskGraphStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case snapshotTooLarge(Int)
    case lockFailed(String)
    case staleCheckpoint(String)
    case corrupted(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported task graph checkpoint schema version: \(version)."
        case let .snapshotTooLarge(size):
            return "Task graph checkpoint is too large (\(size) bytes)."
        case let .lockFailed(path):
            return "Could not lock task graph checkpoint at \(path)."
        case let .staleCheckpoint(sessionID):
            return "Task graph checkpoint for session \(sessionID) changed in another runtime instance."
        case let .corrupted(path, reason):
            return "Task graph checkpoint at \(path) is corrupted: \(reason)"
        }
    }
}

public struct SessionTaskGraphStore: Sendable {
    public static let maximumSnapshotBytes = 8 * 1_024 * 1_024

    public let supportDirectoryURL: URL?
    public let maximumSnapshotBytes: Int

    public init(
        supportDirectoryURL: URL? = nil,
        maximumSnapshotBytes: Int = Self.maximumSnapshotBytes
    ) {
        self.supportDirectoryURL = supportDirectoryURL?.standardizedFileURL
        self.maximumSnapshotBytes = max(1, maximumSnapshotBytes)
    }

    public func save(
        _ checkpoint: SessionTaskGraphCheckpoint,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard checkpoint.schemaVersion == SessionTaskGraphCheckpoint.currentSchemaVersion else {
            throw SessionTaskGraphStoreError.unsupportedSchema(checkpoint.schemaVersion)
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(checkpoint)
        guard data.count <= maximumSnapshotBytes else {
            throw SessionTaskGraphStoreError.snapshotTooLarge(data.count)
        }

        let fileURL = checkpointFileURL(
            sessionID: checkpoint.sessionID,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        try withLock(for: fileURL, exclusive: true, fileManager: fileManager) {
            try SensitiveFilePermissions.write(data, to: fileURL, fileManager: fileManager)
        }
    }

    /// Atomically replaces `expected` with `checkpoint` under the checkpoint's
    /// cross-process lock. A mismatch fails closed instead of allowing a stale
    /// orchestrator instance to erase a newer graph update.
    public func compareAndSwap(
        _ checkpoint: SessionTaskGraphCheckpoint,
        replacing expected: SessionTaskGraphCheckpoint?,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard checkpoint.schemaVersion == SessionTaskGraphCheckpoint.currentSchemaVersion else {
            throw SessionTaskGraphStoreError.unsupportedSchema(checkpoint.schemaVersion)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(checkpoint)
        guard data.count <= maximumSnapshotBytes else {
            throw SessionTaskGraphStoreError.snapshotTooLarge(data.count)
        }

        let fileURL = checkpointFileURL(
            sessionID: checkpoint.sessionID,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        try withLock(for: fileURL, exclusive: true, fileManager: fileManager) {
            let current = try loadUnlocked(
                from: fileURL,
                sessionID: checkpoint.sessionID,
                fileManager: fileManager
            )
            guard current == expected else {
                throw SessionTaskGraphStoreError.staleCheckpoint(checkpoint.sessionID)
            }
            try SensitiveFilePermissions.write(data, to: fileURL, fileManager: fileManager)
        }
    }

    public func load(
        sessionID: String,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> SessionTaskGraphCheckpoint? {
        let fileURL = checkpointFileURL(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        return try withLock(for: fileURL, exclusive: false, fileManager: fileManager) {
            try loadUnlocked(from: fileURL, sessionID: sessionID, fileManager: fileManager)
        }
    }

    private func loadUnlocked(
        from fileURL: URL,
        sessionID: String,
        fileManager: FileManager
    ) throws -> SessionTaskGraphCheckpoint? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        try SensitiveFilePermissions.hardenExistingFile(at: fileURL, fileManager: fileManager)
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > maximumSnapshotBytes {
                throw SessionTaskGraphStoreError.snapshotTooLarge(size.intValue)
            }

            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard data.count <= maximumSnapshotBytes else {
                throw SessionTaskGraphStoreError.snapshotTooLarge(data.count)
            }
            let checkpoint = try PropertyListDecoder().decode(
                SessionTaskGraphCheckpoint.self,
                from: data
            )
            guard checkpoint.schemaVersion == SessionTaskGraphCheckpoint.currentSchemaVersion else {
                throw SessionTaskGraphStoreError.unsupportedSchema(checkpoint.schemaVersion)
            }
            guard checkpoint.sessionID == sessionID else {
                throw SessionTaskGraphStoreError.corrupted(
                    path: fileURL.path,
                    reason: "session identifier mismatch"
                )
            }
            return checkpoint
        } catch let error as SessionTaskGraphStoreError {
            if case .corrupted = error {
                copyCorruptCheckpoint(fileURL, fileManager: fileManager)
            }
            throw error
        } catch {
            copyCorruptCheckpoint(fileURL, fileManager: fileManager)
            throw SessionTaskGraphStoreError.corrupted(
                path: fileURL.path,
                reason: String(describing: error)
            )
        }
    }

    /// Enumerates every valid checkpoint persisted for a working directory,
    /// regardless of session identifier. Corrupt, oversized, or
    /// schema-mismatched files are skipped best-effort so a single bad file
    /// cannot prevent detection of the remaining work. Used at startup to find
    /// incomplete task graphs from previous sessions.
    public func loadCheckpoints(
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> [SessionTaskGraphCheckpoint] {
        let directoryURL = taskGraphsDirectoryURL(
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
        } catch {
            return []
        }

        var results: [SessionTaskGraphCheckpoint] = []
        for entry in entries {
            // Skip lock directories and recovered corrupt copies.
            guard entry.hasSuffix(".plist"),
                  !entry.contains(".lock"),
                  !entry.contains(".corrupt-") else {
                continue
            }
            let fileURL = directoryURL.appendingPathComponent(entry, isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            let data: Data
            do {
                data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            } catch {
                ZenLogger.warning(
                    .taskLifecycle,
                    "Failed to read task graph checkpoint \(entry): \(error.localizedDescription)"
                )
                continue
            }
            guard data.count <= maximumSnapshotBytes else {
                continue
            }
            let checkpoint: SessionTaskGraphCheckpoint
            do {
                checkpoint = try PropertyListDecoder().decode(
                    SessionTaskGraphCheckpoint.self,
                    from: data
                )
            } catch {
                ZenLogger.warning(
                    .taskLifecycle,
                    "Failed to decode task graph checkpoint \(entry): \(error.localizedDescription)"
                )
                continue
            }
            guard checkpoint.schemaVersion == SessionTaskGraphCheckpoint.currentSchemaVersion else {
                continue
            }
            results.append(checkpoint)
        }
        return results
    }

    @discardableResult
    public func delete(
        sessionID: String,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let fileURL = checkpointFileURL(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        try SensitiveFilePermissions.hardenExistingFile(at: fileURL, fileManager: fileManager)
        return try withLock(for: fileURL, exclusive: true, fileManager: fileManager) {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return false
            }
            try fileManager.removeItem(at: fileURL)
            return true
        }
    }

    public func checkpointFileURL(
        sessionID: String,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        taskGraphsDirectoryURL(
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        .appendingPathComponent("\(Self.key(for: sessionID)).plist", isDirectory: false)
    }

    public func taskGraphsDirectoryURL(
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        (supportDirectoryURL
            ?? AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager))
            .appendingPathComponent("task-graphs", isDirectory: true)
            .appendingPathComponent(
                TerminalSessionStore.projectKey(for: workingDirectory),
                isDirectory: true
            )
    }

    private func withLock<T>(
        for fileURL: URL,
        exclusive: Bool,
        fileManager: FileManager,
        operation: () throws -> T
    ) throws -> T {
        let lockURL = fileURL.appendingPathExtension("lock")
        try fileManager.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: lockURL.deletingLastPathComponent().path
        )

#if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SessionTaskGraphStoreError.lockFailed(lockURL.path)
        }
        defer { _ = close(descriptor) }

        guard flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else {
            throw SessionTaskGraphStoreError.lockFailed(lockURL.path)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
#endif

        return try operation()
    }

    private func copyCorruptCheckpoint(
        _ fileURL: URL,
        fileManager: FileManager
    ) {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let destination = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp).plist")
        guard !fileManager.fileExists(atPath: destination.path) else {
            return
        }
        try? fileManager.copyItem(at: fileURL, to: destination)
    }

    private static func key(for value: String) -> String {
        Data(value.utf8).sha256Hex()
    }
}
