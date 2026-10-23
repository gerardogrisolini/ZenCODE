//
//  SupportDirectoryArchive.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Created by ZenCODE on 2026-08-24.
//

import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Single-file, compressed archive of the entire ZenCODE support directory.
///
/// `export` produces one gzip tar with a versioned `manifest.json` (relative
/// paths, SHA-256 digests, sizes) plus one entry per source file under
/// `payload/`. `import` validates the whole archive before mutating the
/// destination, then replaces it in one rename with rollback on failure. Both
/// hold the support directory's coordination lock, and the import swap
/// preserves the lock file's inode so mutual exclusion survives the rename.
///
/// The container is produced and read by the system `tar` through
/// `Foundation.Process`; paths are positional arguments or a NUL-separated
/// `--files-from` list, never interpolated into a shell string.
enum SupportDirectoryArchive {
    /// Format version written into every archive manifest.
    static let manifestVersion = 1
    static let manifestEntryPath = "manifest.json"
    static let payloadEntryPrefix = "payload/"
    /// Maximum number of file entries accepted from an archive.
    static let maximumEntryCount = 20_000
    /// Maximum total uncompressed payload accepted from an archive (2 GiB).
    static let maximumTotalUncompressedSize: UInt64 = 2 * 1024 * 1024 * 1024
    /// `manifest.json` is the only entry accumulated in memory during validation;
    /// the bound prevents an unbounded allocation before it is decoded.
    static let maximumManifestUncompressedSize: UInt64 = 8 * 1024 * 1024
    static let defaultArchiveFilename = "zencode-backup.tar.gz"

    enum SupportDirectoryArchiveError: LocalizedError, Equatable {
        case archiveExists(URL)
        case missingSourceDirectory(URL)
        case archiveNotReadable(String)
        case tarUnavailable(String)
        case invalidManifest(String)
        case unsupportedManifestVersion(Int)
        case traversal(String)
        case symlinkEntry(String)
        case sourceSymlink(String)
        case unexpectedEntry(String)
        case entryCountExceeded(Int)
        case sizeLimitExceeded(UInt64)
        case manifestSizeLimitExceeded(UInt64)
        case entryMissing(String)
        case checksumMismatch(String)
        case sizeMismatch(String)
        case importFailed(String)
        case rollbackFailed(commit: String, rollback: String)

        var errorDescription: String? {
            switch self {
            case let .archiveExists(url):
                return "An archive already exists at \(url.path)."
            case let .missingSourceDirectory(url):
                return "Nothing to export: the support directory does not exist at \(url.path)."
            case let .archiveNotReadable(reason):
                return "The archive is not a readable tar.gz file: \(reason)"
            case let .tarUnavailable(reason):
                return "The system tar utility is unavailable, so backup archives cannot be created or read: \(reason)"
            case let .invalidManifest(reason):
                return "The archive does not contain a valid backup manifest: \(reason)"
            case let .unsupportedManifestVersion(version):
                return "The archive manifest version \(version) is not supported by this ZenCODE release."
            case let .traversal(path):
                return "The archive contains an unsafe path: \(path)"
            case let .symlinkEntry(path):
                return "The archive contains a symbolic link entry: \(path)"
            case let .sourceSymlink(path):
                return "The support directory contains a symbolic link, which cannot be archived: \(path)"
            case let .unexpectedEntry(path):
                return "The archive contains an entry that is not declared in its manifest: \(path)"
            case let .entryCountExceeded(count):
                return "The archive declares too many entries (\(count))."
            case let .sizeLimitExceeded(bytes):
                return "The archive expands beyond the supported size limit (\(bytes) bytes)."
            case let .manifestSizeLimitExceeded(bytes):
                return "The archive manifest exceeds the supported size limit (\(bytes) bytes)."
            case let .entryMissing(path):
                return "The archive is missing a declared entry: \(path)"
            case let .checksumMismatch(path):
                return "The archive entry '\(path)' does not match its recorded checksum."
            case let .sizeMismatch(path):
                return "The archive entry '\(path)' does not match its recorded size."
            case let .importFailed(reason):
                return "The import failed: \(reason)"
            case let .rollbackFailed(commit, rollback):
                return "The import failed (\(commit)); restoring the previous data also failed: \(rollback)"
            }
        }
    }

    /// Description of one file in the archive manifest.
    struct ManifestEntry: Codable, Equatable {
        /// Path relative to the payload root. Never absolute, never `..`.
        let path: String
        /// SHA-256 digest of the uncompressed content, lowercase hex.
        let sha256: String
        /// Uncompressed size in bytes.
        let size: UInt64
    }

    /// Versioned manifest stored as `manifest.json` inside the archive.
    struct Manifest: Codable, Equatable {
        let version: Int
        let entries: [ManifestEntry]

        func archivePath(for entry: ManifestEntry) -> String {
            Self.archivePath(forPayloadPath: entry.path)
        }

        static func archivePath(forPayloadPath path: String) -> String {
            payloadEntryPrefix + path
        }

        /// Overflow-safe sum of the declared entry sizes.
        static func totalSize(of entries: [ManifestEntry]) throws -> UInt64 {
            var total: UInt64 = 0
            for entry in entries {
                let (sum, overflow) = total.addingReportingOverflow(entry.size)
                guard !overflow else {
                    throw SupportDirectoryArchiveError.sizeLimitExceeded(SupportDirectoryArchive.maximumTotalUncompressedSize)
                }
                total = sum
            }
            return total
        }
    }

    struct ExportResult: Equatable {
        let archiveURL: URL
        let fileCount: Int
        let totalBytes: UInt64
    }

    struct ImportResult: Equatable {
        let fileCount: Int
        let totalBytes: UInt64
    }

    // MARK: - Export

    /// Writes a single compressed archive of the whole support directory to
    /// `archiveURL`, which must not exist yet.
    ///
    /// Manifest collection and archive creation run under the exclusive
    /// coordination lock, so the archive is a coherent snapshot. Source symlinks
    /// are refused rather than silently skipped. Coordination artifacts (lock,
    /// journal, import staging) and an archive written inside the source
    /// directory are never included.
    static func export(
        from sourceDirectoryURL: URL,
        to archiveURL: URL,
        fileManager: FileManager = .default
    ) throws -> ExportResult {
        let sourceURL = sourceDirectoryURL.standardizedFileURL
        let destinationURL = archiveURL.standardizedFileURL
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw SupportDirectoryArchiveError.missingSourceDirectory(sourceURL)
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw SupportDirectoryArchiveError.archiveExists(destinationURL)
        }

        return try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: sourceURL,
            fileManager: fileManager
        ) {
            try writeArchive(
                sourceURL: sourceURL,
                archiveURL: destinationURL,
                additionalExcludedArchiveURL: nil,
                fileManager: fileManager
            )
        }
    }

    /// Lock-holding body of `export`.
    static func writeArchive(
        sourceURL: URL,
        archiveURL: URL,
        additionalExcludedArchiveURL: URL?,
        fileManager: FileManager
    ) throws -> ExportResult {
        let entries = try collectExportEntries(
            sourceURL: sourceURL,
            archiveURL: archiveURL,
            additionalExcludedArchiveURL: additionalExcludedArchiveURL,
            fileManager: fileManager
        )

        let manifest = Manifest(version: manifestVersion, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)

        // Stage manifest and file list in a fresh 0700 directory next to the
        // archive. tar reads NUL-separated member names from the list instead of
        // walking the directory, keeping exclusion rules and ordering explicit.
        let stagingURL = archiveURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(importStagingNamePrefix)export-metadata-\(UUID().uuidString)",
                isDirectory: true
            )
        var stagingCreated = false
        defer {
            if stagingCreated {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        do {
            try fileManager.createPrivateDirectory(at: stagingURL)
            stagingCreated = true
            let manifestURL = stagingURL
                .appendingPathComponent(manifestEntryPath)
            try manifestData.write(to: manifestURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: manifestURL.path
            )

            // Private snapshot tree: tar reads the exact bytes hashed above under
            // their final `payload/...` names. Copies, not hard links, which could
            // change if a writer ignores the coordination lock.
            let payloadRootURL = stagingURL.appendingPathComponent(
                String(payloadEntryPrefix.dropLast()),
                isDirectory: true
            )
            try fileManager.createPrivateDirectory(at: payloadRootURL)

            var fileList = Data()
            fileList.append(Data(manifestEntryPath.utf8))
            fileList.append(0)
            for entry in entries {
                let memberPath = Manifest.archivePath(forPayloadPath: entry.path)
                let stagedFileURL = stagingURL.appendingPathComponent(memberPath)
                try fileManager.createPrivateDirectory(at: stagedFileURL.deletingLastPathComponent())
                try fileManager.copyItem(
                    at: sourceURL.appendingPathComponent(entry.path),
                    to: stagedFileURL
                )
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: stagedFileURL.path
                )
                fileList.append(Data(memberPath.utf8))
                fileList.append(0)
            }

            // `--no-recursion` + an explicit list archives exactly the collected files.
            _ = try runTar(
                [
                    "--create",
                    "--gzip",
                    "--file=\(archiveURL.path)",
                    "--directory=\(stagingURL.path)",
                    "--no-recursion",
                    "--null",
                    "--files-from=-"
                ],
                standardInput: fileList,
                fileManager: fileManager
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: archiveURL.path
            )
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }

        return ExportResult(
            archiveURL: archiveURL,
            fileCount: entries.count,
            totalBytes: try Manifest.totalSize(of: entries)
        )
    }

    /// Prefix of `exportReplacingExisting` temporaries; in the reserved
    /// `.zencode-import-` namespace so a stale one is never captured in a backup.
    static let exportTemporaryNamePrefix = importStagingNamePrefix + "export-"

    /// Exports to a temporary sibling, then publishes it with a rollbackable
    /// replacement so overwriting an archive can never lose both files: the old
    /// archive is renamed aside and any failure restores it. `publishCheckpoint`
    /// is a test seam firing after the old archive was moved aside.
    static func exportReplacingExisting(
        from sourceDirectoryURL: URL,
        to archiveURL: URL,
        fileManager: FileManager = .default,
        publishCheckpoint: (() throws -> Void)? = nil
    ) throws -> ExportResult {
        let sourceURL = sourceDirectoryURL.standardizedFileURL
        let destinationURL = archiveURL.standardizedFileURL
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = parentURL.appendingPathComponent(
            "\(exportTemporaryNamePrefix)\(UUID().uuidString).tmp"
        )
        let exported: ExportResult
        do {
            exported = try SensitiveManifestCoordination.withExclusiveLock(
                supportDirectoryURL: sourceURL,
                fileManager: fileManager
            ) {
                try writeArchive(
                    sourceURL: sourceURL,
                    archiveURL: temporaryURL,
                    additionalExcludedArchiveURL: destinationURL,
                    fileManager: fileManager
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        let quarantineURL = parentURL.appendingPathComponent(
            "\(importStagingNamePrefix)replaced-\(UUID().uuidString).tar.gz"
        )
        var previousMovedAside = false
        defer {
            if previousMovedAside {
                try? fileManager.removeItem(at: quarantineURL)
            }
        }
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: quarantineURL)
                previousMovedAside = true
            }
            try publishCheckpoint?()
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            let commitError = error
            var rollbackFailures: [String] = []
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            if previousMovedAside {
                do {
                    try fileManager.moveItem(at: quarantineURL, to: destinationURL)
                    previousMovedAside = false
                } catch {
                    rollbackFailures.append(
                        "could not restore the previous archive: \(error.localizedDescription)"
                    )
                }
            }
            try? fileManager.removeItem(at: temporaryURL)
            guard rollbackFailures.isEmpty else {
                throw SupportDirectoryArchiveError.rollbackFailed(
                    commit: commitError.localizedDescription,
                    rollback: rollbackFailures.joined(separator: "; ")
                )
            }
            throw commitError
        }

        return ExportResult(
            archiveURL: destinationURL,
            fileCount: exported.fileCount,
            totalBytes: exported.totalBytes
        )
    }

    /// Records every regular file (hidden and nested) in sorted order.
    static func collectExportEntries(
        sourceURL: URL,
        archiveURL: URL,
        additionalExcludedArchiveURL: URL?,
        fileManager: FileManager
    ) throws -> [ManifestEntry] {
        var excludedPaths = Set(
            temporaryArtifactPaths(in: sourceURL).map(\.path)
        )
        if isDescendant(archiveURL, of: sourceURL) {
            excludedPaths.insert(archiveURL.path)
        }
        if let additionalExcludedArchiveURL,
           isDescendant(additionalExcludedArchiveURL, of: sourceURL) {
            excludedPaths.insert(additionalExcludedArchiveURL.path)
        }

        func relativePath(of path: String) -> String {
            path.dropFirst(sourceURL.path.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        var entries: [ManifestEntry] = []
        var pending = [sourceURL]
        while let directoryURL = pending.popLast() {
            let children = try fileManager.contentsOfDirectory(
                atPath: directoryURL.path
            )
            for child in children.sorted() {
                let childURL = directoryURL.appendingPathComponent(child)
                // Skip anything in the reserved `.zencode-import-` namespace (import
                // staging, export temporaries) left behind by another operation.
                guard !child.hasPrefix(importStagingNamePrefix) else {
                    continue
                }
                // Downloaded voice-mode programs and models are large and
                // re-downloadable from /setup; they never enter a backup.
                guard directoryURL != sourceURL
                    || child != SherpaOnnxVoiceInstallation.directoryName else {
                    continue
                }
                let values = try childURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
                )
                if values.isSymbolicLink == true {
                    throw SupportDirectoryArchiveError.sourceSymlink(relativePath(of: childURL.path))
                }
                if values.isDirectory == true {
                    pending.append(childURL)
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let standardizedPath = childURL.standardizedFileURL.path
                guard !excludedPaths.contains(standardizedPath) else {
                    continue
                }
                let data = try Data(contentsOf: childURL)
                entries.append(
                    ManifestEntry(
                        path: relativePath(of: standardizedPath),
                        sha256: data.sha256Hex(),
                        size: UInt64(data.count)
                    )
                )
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Whether `url` is inside `directory` (path-component boundary, so siblings
    /// with a common textual prefix do not match).
    static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return path.hasPrefix(directoryPath + "/")
    }

    /// Paths a concurrent export/import writes into the source directory and
    /// that must never be captured inside a backup.
    static func temporaryArtifactPaths(in sourceURL: URL) -> [URL] {
        [
            SensitiveManifestCoordination.lockFileURL(in: sourceURL),
            SensitiveManifestCoordination.journalFileURL(in: sourceURL)
        ]
    }

    static let importStagingNamePrefix = ".zencode-import-"
}

extension FileManager {
    /// Creates a 0700 directory (and intermediates) for archive staging.
    func createPrivateDirectory(at url: URL) throws {
        try createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }
}
