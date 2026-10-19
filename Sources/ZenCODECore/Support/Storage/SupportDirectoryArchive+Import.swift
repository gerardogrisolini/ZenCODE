//
//  SupportDirectoryArchive+Import.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension SupportDirectoryArchive {
    // MARK: - Validation

    /// One member parsed from `tar --list --verbose`.
    struct MemberRecord {
        let path: String
        let typeFlag: Character
        let declaredSize: UInt64
    }

    /// Parses `tar --list --verbose` lines (GNU tar and bsdtar share the `-tv`
    /// shape; only the 10-character permission block's type character is relied on).
    static func parseMemberRecords(
        from listing: Data
    ) throws -> [MemberRecord] {
        let text = String(decoding: listing, as: UTF8.self)
        var records: [MemberRecord] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 10 else {
                throw SupportDirectoryArchiveError.archiveNotReadable("unreadable member line: \(line.prefix(120))")
            }
            let permissionBlock = line.prefix(10)
            let typeFlag = permissionBlock.first ?? "?"
            let fields = line.dropFirst(10).split(
                separator: " ",
                omittingEmptySubsequences: true
            )

            // bsdtar:  links owner group size Mon DD HH:MM name
            // GNU tar: owner/group size YYYY-MM-DD HH:MM name
            // A numeric first field distinguishes bsdtar's link count.
            let isBSDTarListing = fields.first.flatMap { UInt64($0) } != nil
            let sizeIndex = isBSDTarListing ? 3 : 1
            let nameIndex = isBSDTarListing ? 7 : 4
            guard fields.indices.contains(sizeIndex),
                  fields.count > nameIndex,
                  let size = UInt64(fields[sizeIndex]) else {
                throw SupportDirectoryArchiveError.archiveNotReadable("unreadable member line: \(line.prefix(120))")
            }
            let path = fields[nameIndex...].joined(separator: " ")
            // Both implementations print " -> target" for symbolic links.
            let cleanPath = path.components(separatedBy: " -> ").first ?? path
            records.append(
                MemberRecord(
                    path: cleanPath,
                    typeFlag: typeFlag,
                    declaredSize: size
                )
            )
        }
        return records
    }

    /// Reads and fully validates the archive without touching the
    /// destination. Returns the decoded manifest on success.
    static func validate(
        archiveURL: URL,
        fileManager: FileManager = .default
    ) throws -> Manifest {
        let records = try listMembers(
            archiveURL: archiveURL,
            fileManager: fileManager
        )
        return try validate(records: records, archiveURL: archiveURL, fileManager: fileManager)
    }

    static func listMembers(
        archiveURL: URL,
        fileManager: FileManager
    ) throws -> [MemberRecord] {
        let listing = try runTar(
            ["--list", "--verbose", "--gzip", "--file=\(archiveURL.standardizedFileURL.path)"],
            fileManager: fileManager
        )
        return try parseMemberRecords(from: listing)
    }

    static func validate(
        records: [MemberRecord],
        archiveURL: URL,
        fileManager: FileManager
    ) throws -> Manifest {
        guard let manifestRecord = records.first(where: {
            $0.path == manifestEntryPath
        }) else {
            throw SupportDirectoryArchiveError.invalidManifest("\(manifestEntryPath) member is missing")
        }
        guard manifestRecord.typeFlag == "-" else {
            throw SupportDirectoryArchiveError.invalidManifest("\(manifestEntryPath) is not a regular file")
        }
        guard manifestRecord.declaredSize <= maximumManifestUncompressedSize else {
            throw SupportDirectoryArchiveError.manifestSizeLimitExceeded(manifestRecord.declaredSize)
        }

        let manifestData = try extractMemberData(
            archiveURL: archiveURL,
            memberPath: manifestEntryPath,
            fileManager: fileManager
        )
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw SupportDirectoryArchiveError.invalidManifest(error.localizedDescription)
        }
        guard manifest.version == manifestVersion else {
            throw SupportDirectoryArchiveError.unsupportedManifestVersion(manifest.version)
        }
        guard manifest.entries.count <= maximumEntryCount else {
            throw SupportDirectoryArchiveError.entryCountExceeded(manifest.entries.count)
        }
        let totalSize = try Manifest.totalSize(of: manifest.entries)
        var seenPaths = Set<String>()
        for entry in manifest.entries {
            try validateManifestEntryPath(entry.path)
            guard seenPaths.insert(entry.path).inserted else {
                throw SupportDirectoryArchiveError.invalidManifest("duplicate entry path: \(entry.path)")
            }
        }
        guard totalSize <= maximumTotalUncompressedSize else {
            throw SupportDirectoryArchiveError.sizeLimitExceeded(totalSize)
        }

        // Every archive member must be declared and individually well-formed.
        let entriesByArchivePath = Dictionary(
            manifest.entries.map { (manifest.archivePath(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenArchivePaths = Set<String>()
        for record in records {
            guard seenArchivePaths.insert(record.path).inserted else {
                throw SupportDirectoryArchiveError.invalidManifest("duplicate archive member: \(record.path)")
            }
            if record.path == manifestEntryPath {
                continue
            }
            guard let declared = entriesByArchivePath[record.path] else {
                throw SupportDirectoryArchiveError.unexpectedEntry(record.path)
            }
            switch record.typeFlag {
            case "-":
                guard record.declaredSize == declared.size else {
                    throw SupportDirectoryArchiveError.sizeMismatch(record.path)
                }
            case "l", "h":
                throw SupportDirectoryArchiveError.symlinkEntry(record.path)
            default:
                throw SupportDirectoryArchiveError.unexpectedEntry(record.path)
            }
        }
        for entry in manifest.entries {
            let archivePath = manifest.archivePath(for: entry)
            guard seenArchivePaths.contains(archivePath) else {
                throw SupportDirectoryArchiveError.entryMissing(archivePath)
            }
        }
        return manifest
    }

    static func validateManifestEntryPath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\") else {
            throw SupportDirectoryArchiveError.traversal(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw SupportDirectoryArchiveError.traversal(path)
        }
        // Coordination artifacts are private to the live directory and never in a
        // backup, so a manifest declaring one is crafted or corrupted.
        guard !reservedArtifactPathComponents().contains(path) else {
            throw SupportDirectoryArchiveError.unexpectedEntry(path)
        }
        guard !components.contains(where: { $0.hasPrefix(importStagingNamePrefix) }) else {
            throw SupportDirectoryArchiveError.unexpectedEntry(path)
        }
    }

    /// Paths that must never appear inside an imported payload.
    static func reservedArtifactPathComponents() -> Set<String> {
        [
            SensitiveManifestCoordination.lockFilename,
            SensitiveManifestCoordination.journalFilename
        ]
    }

    /// Streams one member's bytes from the archive via `tar --to-stdout`.
    static func extractMemberData(
        archiveURL: URL,
        memberPath: String,
        fileManager: FileManager
    ) throws -> Data {
        try runTar(
            extractArguments(archivePath: archiveURL.standardizedFileURL.path, member: memberPath),
            fileManager: fileManager
        )
    }

    static func extractArguments(archivePath: String, member: String) -> [String] {
        ["--extract", "--to-stdout", "--gzip", "--file=\(archivePath)", member]
    }

    // MARK: - Import

    /// Validates and restores an archive into the destination support directory,
    /// replacing whatever is there.
    ///
    /// The whole archive is validated first; only then, under the exclusive
    /// coordination lock, is the existing directory moved aside, the payload
    /// written to a fresh staging directory and that renamed into place. The
    /// staging directory first receives a hard link to the current
    /// `.manifests.lock` so concurrent lock holders keep one shared exclusion
    /// boundary. Any failure moves the previous directory back.
    ///
    /// `extractionCheckpoint` (after each staged file) and `publishCheckpoint`
    /// (after the destination is moved aside) are test seams that may throw.
    static func `import`(
        from archiveURL: URL,
        into destinationDirectoryURL: URL,
        fileManager: FileManager = .default,
        extractionCheckpoint: ((Int) throws -> Void)? = nil,
        publishCheckpoint: (() throws -> Void)? = nil
    ) throws -> ImportResult {
        let archiveURL = archiveURL.standardizedFileURL
        let destinationURL = destinationDirectoryURL.standardizedFileURL
        let manifest = try validate(
            archiveURL: archiveURL,
            fileManager: fileManager
        )

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )

        return try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: destinationURL,
            fileManager: fileManager
        ) {
            try replaceDestinationWithArchive(
                archiveURL: archiveURL,
                manifest: manifest,
                destinationURL: destinationURL,
                fileManager: fileManager,
                extractionCheckpoint: extractionCheckpoint,
                publishCheckpoint: publishCheckpoint
            )
        }
    }

    static func replaceDestinationWithArchive(
        archiveURL: URL,
        manifest: Manifest,
        destinationURL: URL,
        fileManager: FileManager,
        extractionCheckpoint: ((Int) throws -> Void)?,
        publishCheckpoint: (() throws -> Void)?
    ) throws -> ImportResult {
        let stagingURL = try makeUniqueStagingURL(
            siblingOf: destinationURL,
            suffix: "staging",
            fileManager: fileManager
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
            try extractPayload(
                archiveURL: archiveURL,
                manifest: manifest,
                to: stagingURL,
                fileManager: fileManager,
                extractionCheckpoint: extractionCheckpoint
            )
        } catch {
            throw SupportDirectoryArchiveError.importFailed(error.localizedDescription)
        }

        let quarantineURL = try makeUniqueStagingURL(
            siblingOf: destinationURL,
            suffix: "quarantine",
            fileManager: fileManager
        )
        var destinationMovedAside = false
        defer {
            if destinationMovedAside {
                try? fileManager.removeItem(at: quarantineURL)
            }
        }

        do {
            // Preserve the lock's inode across the swap: a lock file created after
            // the rename would be a different inode and break mutual exclusion.
            // Hard-linking the current lock into staging keeps one shared inode
            // (the quarantine's unlink removes only one link). Without hard-link
            // support the import refuses, as publishing without it is unsafe.
            try preserveLockInodeIntoStaging(
                stagingURL: stagingURL,
                destinationURL: destinationURL,
                fileManager: fileManager
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: quarantineURL)
                destinationMovedAside = true
            }
            try publishCheckpoint?()
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            stagingCreated = false
        } catch {
            let commitError = error
            var rollbackFailures: [String] = []
            if destinationMovedAside {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: destinationURL)
                }
                do {
                    try fileManager.moveItem(at: quarantineURL, to: destinationURL)
                    destinationMovedAside = false
                } catch {
                    rollbackFailures.append(
                        "could not restore the previous directory: \(error.localizedDescription)"
                    )
                }
            }
            guard rollbackFailures.isEmpty else {
                throw SupportDirectoryArchiveError.rollbackFailed(
                    commit: commitError.localizedDescription,
                    rollback: rollbackFailures.joined(separator: "; ")
                )
            }
            throw SupportDirectoryArchiveError.importFailed(commitError.localizedDescription)
        }

        return ImportResult(
            fileCount: manifest.entries.count,
            totalBytes: try Manifest.totalSize(of: manifest.entries)
        )
    }

    /// Hard-links the destination's `.manifests.lock` into the staging directory
    /// so the published directory keeps the lock's inode. The lock exists because
    /// the import runs inside `withExclusiveLock`; validation rejects manifests
    /// declaring coordination artifacts, so a staging lock only appears
    /// defensively and is removed first so the link is its only name.
    static func preserveLockInodeIntoStaging(
        stagingURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let lockURL = SensitiveManifestCoordination.lockFileURL(in: destinationURL)
        guard fileManager.fileExists(atPath: lockURL.path) else {
            // Created by the exclusive lock in `import`; missing means an
            // unexpected state, so fail rather than publish a fresh-inode lock.
            throw SupportDirectoryArchiveError.importFailed("coordination lock is missing at \(lockURL.path)")
        }
        let stagingLockURL = SensitiveManifestCoordination.lockFileURL(in: stagingURL)
        if fileManager.fileExists(atPath: stagingLockURL.path) {
            try fileManager.removeItem(at: stagingLockURL)
        }
        #if canImport(Darwin)
        guard Darwin.link(lockURL.path, stagingLockURL.path) == 0 else {
            throw SupportDirectoryArchiveError.importFailed(
                "could not preserve the coordination lock inode at \(stagingLockURL.path): \(String(cString: Darwin.strerror(Darwin.errno)))"
            )
        }
        #elseif canImport(Glibc)
        guard Glibc.link(lockURL.path, stagingLockURL.path) == 0 else {
            throw SupportDirectoryArchiveError.importFailed(
                "could not preserve the coordination lock inode at \(stagingLockURL.path): \(String(cString: Glibc.strerror(Glibc.errno)))"
            )
        }
        #else
        // Without link(2) there is no portable way to keep the lock inode
        // stable across the swap; refuse instead of publishing unsafe state.
        throw SupportDirectoryArchiveError.importFailed("preserving the coordination lock inode is unsupported on this platform")
        #endif
    }

    /// Extracts the manifest-declared payload into `stagingURL`, verifying
    /// each entry's size and digest while it streams to disk.
    static func extractPayload(
        archiveURL: URL,
        manifest: Manifest,
        to stagingURL: URL,
        fileManager: FileManager,
        extractionCheckpoint: ((Int) throws -> Void)?
    ) throws {
        // Members are extracted one at a time by explicit name, streamed into an
        // O_EXCL-created file and digest-verified on the fly: tar never chooses
        // paths, so traversal, symlink and extra-entry risks are excluded.
        var written = 0
        for entry in manifest.entries {
            let archivePath = manifest.archivePath(for: entry)
            let destinationFileURL = stagingURL.appendingPathComponent(entry.path)
            let standardizedDestination = destinationFileURL.standardizedFileURL
            guard standardizedDestination.path.hasPrefix(
                stagingURL.standardizedFileURL.path + "/"
            ) else {
                throw SupportDirectoryArchiveError.traversal(entry.path)
            }
            try fileManager.createPrivateDirectory(at: destinationFileURL.deletingLastPathComponent())
            try extractMemberToFile(
                archiveURL: archiveURL,
                memberPath: archivePath,
                to: destinationFileURL,
                declared: entry,
                fileManager: fileManager
            )
            written += 1
            try extractionCheckpoint?(written)
        }
    }

    /// Streams one archive member to a file via `tar --to-stdout`, writing
    /// each chunk as it arrives while computing the digest incrementally, and
    /// verifying the recorded size and checksum. A failing member aborts the
    /// child and removes the partial file.
    static func extractMemberToFile(
        archiveURL: URL,
        memberPath: String,
        to destinationURL: URL,
        declared: ManifestEntry,
        fileManager: FileManager
    ) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw SupportDirectoryArchiveError.importFailed("could not create \(destinationURL.path)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var hasher = SHA256()
            var received: UInt64 = 0
            let declaredSize = declared.size
            try runTar(
                extractArguments(archivePath: archiveURL.path, member: memberPath),
                fileManager: fileManager
            ) { chunk in
                // The declared sizes are bounded by the manifest validation,
                // so enforcing the per-member size here also bounds the total.
                received += UInt64(chunk.count)
                guard received <= declaredSize else {
                    throw SupportDirectoryArchiveError.sizeMismatch(declared.path)
                }
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
            }
            guard received == declaredSize else {
                throw SupportDirectoryArchiveError.sizeMismatch(declared.path)
            }
            let digest = hasher.finalize()
                .map { String(format: "%02x", $0) }.joined()
            guard digest == declared.sha256 else {
                throw SupportDirectoryArchiveError.checksumMismatch(declared.path)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            // The file was created here with O_EXCL, so removing it is safe.
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
        #else
        throw SupportDirectoryArchiveError.importFailed("payload extraction is unsupported on this platform")
        #endif
    }

    static func makeUniqueStagingURL(
        siblingOf destinationURL: URL,
        suffix: String,
        fileManager: FileManager
    ) throws -> URL {
        // The UUID keeps concurrent imports into sibling destinations — and
        // parallel tests sharing a temporary parent — from colliding on one
        // staging directory.
        let parentURL = destinationURL.deletingLastPathComponent()
        return parentURL.appendingPathComponent(
            "\(importStagingNamePrefix)\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
