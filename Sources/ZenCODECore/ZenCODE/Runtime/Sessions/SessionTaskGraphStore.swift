//
//  SessionTaskGraphStore.swift
//  ZenCODE
//

import Crypto
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
    case corrupted(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported task graph checkpoint schema version: \(version)."
        case let .snapshotTooLarge(size):
            return "Task graph checkpoint is too large (\(size) bytes)."
        case let .lockFailed(path):
            return "Could not lock task graph checkpoint at \(path)."
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
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try withLock(for: fileURL, exclusive: true, fileManager: fileManager) {
            try data.write(to: fileURL, options: .atomic)
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
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try withLock(for: fileURL, exclusive: false, fileManager: fileManager) {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > maximumSnapshotBytes {
                throw SessionTaskGraphStoreError.snapshotTooLarge(size.intValue)
            }

            do {
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
            withIntermediateDirectories: true
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
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
