//
//  SupportDirectoryArchive.swift
//  ZenCODE
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
/// `export` produces one gzip-compressed tar file with a versioned
/// `manifest.json` (relative paths, SHA-256 digests and sizes) plus one entry
/// per source file under `payload/`. `import` validates the whole archive —
/// structure, paths, types, sizes and digests — *before* mutating the
/// destination, then replaces it in one rename with rollback on failure.
/// Both operations hold the support directory's coordination lock, and the
/// import swap preserves the lock file's inode so mutual exclusion survives
/// the rename.
///
/// The tar.gz container is produced and read by the system `tar` binary
/// through `Foundation.Process`. Paths are always passed as positional
/// arguments or through a NUL-separated `--files-from` list — never
/// interpolated into a shell string — so archive contents cannot inject
/// shell syntax. `tar` ships with macOS (bsdtar) and with every Linux
/// distribution ZenCODE supports (GNU tar), which keeps the container a
/// standard, genuinely compressed format on both platforms without a
/// third-party dependency.
enum SupportDirectoryArchive {
    /// Format version written into every archive manifest.
    static let manifestVersion = 1
    static let manifestEntryPath = "manifest.json"
    static let payloadEntryPrefix = "payload/"
    /// Maximum number of file entries accepted from an archive.
    static let maximumEntryCount = 20_000
    /// Maximum total uncompressed payload accepted from an archive. The
    /// support directory holds configuration and conversation state, not
    /// datasets, so 2 GiB bounds pathological archives while staying far away
    /// from any real backup.
    static let maximumTotalUncompressedSize: UInt64 = 2 * 1024 * 1024 * 1024
    /// `manifest.json` is the only entry accumulated in memory during
    /// validation. A backup with the maximum supported number of entries fits
    /// comfortably below this, while the explicit bound prevents a compressed
    /// manifest from forcing an unbounded allocation before it is decoded.
    static let maximumManifestUncompressedSize: UInt64 = 8 * 1024 * 1024
    static let archiveFileExtension = "tar.gz"
    static let defaultArchiveFilename = "zencode-backup.tar.gz"
    /// Name of the tool invoked through `Process` for every archive
    /// operation. Resolved from `PATH`; see `tarToolName(for:)`.
    static let tarToolName = "tar"

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

        /// Relative payload path of an archive member, when it is a payload
        /// entry (as opposed to the manifest itself).
        static func payloadPath(ofArchivePath archivePath: String) -> String? {
            guard archivePath.hasPrefix(payloadEntryPrefix) else { return nil }
            return String(archivePath.dropFirst(payloadEntryPrefix.count))
        }

        /// Overflow-safe sum of the declared entry sizes.
        static func totalSize(of entries: [ManifestEntry]) throws -> UInt64 {
            var total: UInt64 = 0
            for entry in entries {
                let (sum, overflow) = total.addingReportingOverflow(entry.size)
                guard !overflow else {
                    throw SupportDirectoryArchiveError.sizeLimitExceeded(
                        SupportDirectoryArchive.maximumTotalUncompressedSize
                    )
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

    // MARK: - Process plumbing

    /// Bytes read from stdout/stderr of a tar process in one chunk.
    private static let processChunkSize = 1 << 16

    /// Resolves the tar executable's path via `/usr/bin:/bin:/usr/local/bin`
    /// without spawning a shell. Returns `nil` when no candidate exists.
    ///
    /// A fixed search path keeps behavior deterministic across environments
    /// where `PATH` is empty or attacker-controlled; `/usr/bin/tar` is the
    /// canonical location on macOS and Linux.
    private static func locateTarExecutable(
        fileManager: FileManager
    ) -> URL? {
        let candidates = [
            "/usr/bin/tar",
            "/bin/tar",
            "/usr/local/bin/tar",
            "/opt/homebrew/bin/tar"
        ]
        for candidate in candidates where fileManager.isExecutableFile(
            atPath: candidate
        ) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Runs a tar invocation, passing every path as a positional argument —
    /// never through a shell — and returning stdout. Throws
    /// `archiveNotReadable` for any nonzero exit, with the collected stderr
    /// as the reason.
    private static func runTar(
        _ arguments: [String],
        standardInput: Data? = nil,
        fileManager: FileManager
    ) throws -> Data {
        guard let executableURL = locateTarExecutable(fileManager: fileManager)
        else {
            throw SupportDirectoryArchiveError.tarUnavailable(
                "no executable tar was found in the standard system paths"
            )
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        if let standardInput {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            try process.run()
            // Feed the file list while the child consumes it, so arbitrarily
            // large manifests never block on a full pipe buffer.
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                // A write failure (e.g. the child exited early) surfaces
                // through the child's exit status below.
            }
        } else {
            try process.run()
        }

        var collected = Data()
        var errorCollected = Data()
        let stdoutHandle = standardOutput.fileHandleForReading
        let stderrHandle = standardError.fileHandleForReading
        while true {
            let chunk = try stdoutHandle.read(upToCount: processChunkSize)
            let errorChunk = try stderrHandle.read(upToCount: processChunkSize)
            if let chunk { collected.append(chunk) }
            if let errorChunk { errorCollected.append(errorChunk) }
            if chunk == nil && errorChunk == nil { break }
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let reason = String(
                decoding: errorCollected.prefix(2048),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SupportDirectoryArchiveError.archiveNotReadable(
                reason.isEmpty ? "tar exited with status \(process.terminationStatus)" : reason
            )
        }
        return collected
    }

    // MARK: - Export

    /// Writes a single compressed archive of the whole support directory to
    /// `archiveURL`, which must not exist yet.
    ///
    /// The whole export — manifest collection and archive creation — runs
    /// under the support directory's exclusive coordination lock, so writers
    /// cannot mutate files between the digest scan and the tar invocation
    /// and the archive is a coherent snapshot. Source symlinks are refused
    /// instead of being silently skipped, because a backup that silently
    /// drops a file is worse than an explicit error.
    ///
    /// The manifest is recorded first so the archive stays self-describing.
    /// Temporary coordination artifacts of an in-progress operation (lock,
    /// transaction journal, import staging) are never included; if the
    /// archive itself is written inside the source directory it is excluded
    /// as well.
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
    private static func writeArchive(
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
        // archive. tar reads member names from the list (NUL-separated, so
        // any byte sequence except NUL in a filename is safe) instead of
        // walking the directory, which keeps exclusion rules and ordering
        // fully explicit and deterministic.
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
            try fileManager.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            stagingCreated = true
            let manifestURL = stagingURL
                .appendingPathComponent(manifestEntryPath)
            try manifestData.write(to: manifestURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: manifestURL.path
            )

            // Materialize a private snapshot tree. Tar then reads the exact
            // bytes hashed above and every member already has its final
            // `payload/...` name. Copies are intentional: a hard link could
            // still change if a writer ignores the coordination lock.
            let payloadRootURL = stagingURL.appendingPathComponent(
                String(payloadEntryPrefix.dropLast()),
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: payloadRootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )

            var fileList = Data()
            fileList.append(Data(manifestEntryPath.utf8))
            fileList.append(0)
            for entry in entries {
                let memberPath = Manifest.archivePath(forPayloadPath: entry.path)
                let stagedFileURL = stagingURL.appendingPathComponent(memberPath)
                try fileManager.createDirectory(
                    at: stagedFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
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

            // `--no-recursion` + an explicit file list means exactly the
            // collected files are archived: no directory entries and no
            // surprise walks.
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

    /// Prefix of the temporary files `exportReplacingExisting` writes next to
    /// the final archive. Kept in the reserved `.zencode-import-` namespace so
    /// a stale temporary left behind by a failed export is never captured in a
    /// later backup of a directory that contains the destination.
    static let exportTemporaryNamePrefix = importStagingNamePrefix + "export-"

    /// Exports to a temporary sibling first and then publishes it with a
    /// rollbackable replacement, so overwriting an existing archive can never
    /// lose both files at once.
    ///
    /// The existing archive — when present — is renamed aside, the fresh
    /// archive is renamed into place, and any failure in between restores the
    /// previous archive before the error propagates. `publishCheckpoint` is a
    /// test seam firing after the old archive has been moved aside.
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
                    archiveURL: archiveTemporaryURLForReplacement(
                        temporaryURL
                    ),
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

    /// Identity helper keeping the temporary archive path explicit.
    private static func archiveTemporaryURLForReplacement(
        _ url: URL
    ) -> URL {
        url
    }

    /// Walks the source directory and records every regular file, including
    /// hidden and nested ones, in deterministic sorted order.
    private static func collectExportEntries(
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

        var entries: [ManifestEntry] = []
        var pending = [sourceURL]
        while let directoryURL = pending.popLast() {
            let children = try fileManager.contentsOfDirectory(
                atPath: directoryURL.path
            )
            for child in children.sorted() {
                let childURL = directoryURL.appendingPathComponent(child)
                // Skip import staging areas and export temporaries — anything
                // in the reserved `.zencode-import-` namespace — that a
                // concurrent or previously failed operation left behind
                // inside the source tree, whatever node type they are.
                guard !child.hasPrefix(importStagingNamePrefix) else {
                    continue
                }
                let values = try childURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
                )
                if values.isSymbolicLink == true {
                    let relativePath = childURL.path.dropFirst(sourceURL.path.count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    throw SupportDirectoryArchiveError.sourceSymlink(relativePath)
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
                let relativePath = standardizedPath.dropFirst(sourceURL.path.count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                entries.append(
                    ManifestEntry(
                        path: relativePath,
                        sha256: data.sha256Hex(),
                        size: UInt64(data.count)
                    )
                )
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Whether `url` is a file inside `directory`, using a path-component
    /// boundary so siblings with a common textual prefix are not matched.
    private static func isDescendant(_ url: URL, of directory: URL) -> Bool {
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

    /// The staging directories an import creates next to a destination
    /// directory, exposed so export can exclude them from a snapshot taken
    /// while an import into the same location is running.
    static func importStagingDirectoryNames() -> Set<String> {
        [importStagingNamePrefix + "staging", importStagingNamePrefix + "quarantine"]
    }

    private static let importStagingNamePrefix = ".zencode-import-"

    // MARK: - Validation

    /// One member parsed from `tar --list --verbose`.
    private struct MemberRecord {
        let path: String
        let typeFlag: Character
        let declaredSize: UInt64
    }

    /// Parses `tar --list --verbose` lines into member records.
    ///
    /// GNU tar and bsdtar share the same `-tv` shape:
    /// `-rw-r--r-- 0 owner group size date name` for files and
    /// `lrwxrwxrwx 0 owner group size date name -> target` for links. The
    /// permission block is always 10 characters starting with the type
    /// character, which is the only part relied upon.
    private static func parseMemberRecords(
        from listing: Data
    ) throws -> [MemberRecord] {
        let text = String(decoding: listing, as: UTF8.self)
        var records: [MemberRecord] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 10 else {
                throw SupportDirectoryArchiveError.archiveNotReadable(
                    "unreadable member line: \(line.prefix(120))"
                )
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
                throw SupportDirectoryArchiveError.archiveNotReadable(
                    "unreadable member line: \(line.prefix(120))"
                )
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

    private static func listMembers(
        archiveURL: URL,
        fileManager: FileManager
    ) throws -> [MemberRecord] {
        let listing = try runTar(
            ["--list", "--verbose", "--gzip", "--file=\(archiveURL.standardizedFileURL.path)"],
            fileManager: fileManager
        )
        return try parseMemberRecords(from: listing)
    }

    private static func validate(
        records: [MemberRecord],
        archiveURL: URL,
        fileManager: FileManager
    ) throws -> Manifest {
        guard let manifestRecord = records.first(where: {
            $0.path == manifestEntryPath
        }) else {
            throw SupportDirectoryArchiveError.invalidManifest(
                "\(manifestEntryPath) member is missing"
            )
        }
        guard manifestRecord.typeFlag == "-" else {
            throw SupportDirectoryArchiveError.invalidManifest(
                "\(manifestEntryPath) is not a regular file"
            )
        }
        guard manifestRecord.declaredSize <= maximumManifestUncompressedSize else {
            throw SupportDirectoryArchiveError.manifestSizeLimitExceeded(
                manifestRecord.declaredSize
            )
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
            throw SupportDirectoryArchiveError.invalidManifest(
                error.localizedDescription
            )
        }
        guard manifest.version == manifestVersion else {
            throw SupportDirectoryArchiveError.unsupportedManifestVersion(
                manifest.version
            )
        }
        guard manifest.entries.count <= maximumEntryCount else {
            throw SupportDirectoryArchiveError.entryCountExceeded(
                manifest.entries.count
            )
        }
        let totalSize = try Manifest.totalSize(of: manifest.entries)
        var seenPaths = Set<String>()
        for entry in manifest.entries {
            try validateManifestEntryPath(entry.path)
            guard seenPaths.insert(entry.path).inserted else {
                throw SupportDirectoryArchiveError.invalidManifest(
                    "duplicate entry path: \(entry.path)"
                )
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
                throw SupportDirectoryArchiveError.invalidManifest(
                    "duplicate archive member: \(record.path)"
                )
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
            case "d":
                throw SupportDirectoryArchiveError.unexpectedEntry(record.path)
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

    private static func validateManifestEntryPath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\") else {
            throw SupportDirectoryArchiveError.traversal(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            throw SupportDirectoryArchiveError.traversal(path)
        }
        for component in components {
            guard component != ".", component != ".." else {
                throw SupportDirectoryArchiveError.traversal(path)
            }
        }
        // Coordination artifacts are private to the live directory: a backup
        // never contains them (export excludes them), so a manifest declaring
        // one is crafted or corrupted. Accepting it could publish a stale
        // transaction journal or a foreign lock file alongside the payload.
        guard !reservedArtifactPathComponents().contains(path) else {
            throw SupportDirectoryArchiveError.unexpectedEntry(path)
        }
        for component in components
        where component.hasPrefix(importStagingNamePrefix) {
            throw SupportDirectoryArchiveError.unexpectedEntry(path)
        }
    }

    /// Paths that must never appear inside an imported payload.
    private static func reservedArtifactPathComponents() -> Set<String> {
        [
            SensitiveManifestCoordination.lockFilename,
            SensitiveManifestCoordination.journalFilename
        ]
    }

    /// Streams one member's bytes from the archive via `tar --to-stdout`.
    private static func extractMemberData(
        archiveURL: URL,
        memberPath: String,
        fileManager: FileManager
    ) throws -> Data {
        try runTar(
            [
                "--extract",
                "--to-stdout",
                "--gzip",
                "--file=\(archiveURL.standardizedFileURL.path)",
                memberPath
            ],
            fileManager: fileManager
        )
    }

    // MARK: - Import

    /// Validates and restores an archive into the destination support
    /// directory, replacing whatever is there.
    ///
    /// The whole archive is validated first; only then is the destination
    /// mutated, under the exclusive coordination lock. The existing directory
    /// is moved aside, the validated payload is written to a fresh staging
    /// directory, and the staging directory is renamed into place. Before the
    /// rename the staging directory receives a hard link to the current
    /// `.manifests.lock`, so after the swap the lock keeps the same inode and
    /// concurrent lock holders (in this or another process) keep a single,
    /// shared exclusion boundary. Any failure moves the previous directory
    /// back before the error propagates.
    ///
    /// `extractionCheckpoint` fires after each staged file (passing the count
    /// written so far) and `publishCheckpoint` fires after the destination is
    /// moved aside; both are test seams that can throw to exercise failure
    /// paths deterministically.
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

    private static func replaceDestinationWithArchive(
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
            try fileManager.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            stagingCreated = true
            try extractPayload(
                archiveURL: archiveURL,
                manifest: manifest,
                to: stagingURL,
                fileManager: fileManager,
                extractionCheckpoint: extractionCheckpoint
            )
        } catch {
            throw SupportDirectoryArchiveError.importFailed(
                error.localizedDescription
            )
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
            // Preserve the coordination lock's inode across the swap. The
            // staging directory becomes the destination through a rename, and
            // a lock file created fresh after the swap would be a different
            // inode — breaking mutual exclusion with any concurrent holder.
            // Hard-linking the current lock into staging keeps one shared
            // inode: flock sees the same file object, and the quarantine's
            // unlink only removes one link. On filesystems without hard-link
            // support (or platforms without the call) the import refuses to
            // proceed, because publishing without a shared inode would be
            // unsafe. If the destination has no lock yet, staging creates one
            // as usual; the first `withExclusiveLock` in this very import
            // guarantees the destination lock exists.
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
            throw SupportDirectoryArchiveError.importFailed(
                commitError.localizedDescription
            )
        }

        return ImportResult(
            fileCount: manifest.entries.count,
            totalBytes: try Manifest.totalSize(of: manifest.entries)
        )
    }

    /// Hard-links the destination's current `.manifests.lock` into the staging
    /// directory so the published directory keeps the lock's inode.
    ///
    /// The import runs inside `withExclusiveLock`, which creates the lock if
    /// needed, so it always exists by the time this runs. A manifest can
    /// never declare coordination-artifact paths (validation rejects them),
    /// so a staging lock file only appears defensively: if one is somehow
    /// present it is removed first so the hard link becomes the only name.
    private static func preserveLockInodeIntoStaging(
        stagingURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let lockURL = SensitiveManifestCoordination.lockFileURL(in: destinationURL)
        guard fileManager.fileExists(atPath: lockURL.path) else {
            // The exclusive lock in `import` creates it; missing here means
            // an unexpected filesystem state, so fail rather than publish a
            // directory with a fresh (different-inode) lock.
            throw SupportDirectoryArchiveError.importFailed(
                "coordination lock is missing at \(lockURL.path)"
            )
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
        throw SupportDirectoryArchiveError.importFailed(
            "preserving the coordination lock inode is unsupported on this platform"
        )
        #endif
    }

    /// Extracts the manifest-declared payload into `stagingURL`, verifying
    /// each entry's size and digest while it streams to disk.
    private static func extractPayload(
        archiveURL: URL,
        manifest: Manifest,
        to stagingURL: URL,
        fileManager: FileManager,
        extractionCheckpoint: ((Int) throws -> Void)?
    ) throws {
        // Payload members are extracted one at a time with an explicit
        // member name, streamed through stdout into an O_EXCL-created file,
        // and digest-verified on the fly. This never lets tar choose paths or
        // create files itself, so traversal, symlink, and extra-entry risks
        // are structurally excluded rather than filtered after the fact.
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
            try fileManager.createDirectory(
                at: destinationFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
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

    /// Streams one archive member to a file via `tar --to-stdout`, computing
    /// its digest on the fly and verifying the recorded size and checksum
    /// before the caller sees it.
    private static func extractMemberToFile(
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
            throw SupportDirectoryArchiveError.importFailed(
                "could not create \(destinationURL.path)"
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let data = try runTar(
                [
                    "--extract",
                    "--to-stdout",
                    "--gzip",
                    "--file=\(archiveURL.path)",
                    memberPath
                ],
                fileManager: fileManager
            )
            guard data.count == declared.size else {
                throw SupportDirectoryArchiveError.sizeMismatch(declared.path)
            }
            guard data.sha256Hex() == declared.sha256 else {
                throw SupportDirectoryArchiveError.checksumMismatch(declared.path)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        #else
        throw SupportDirectoryArchiveError.importFailed(
            "payload extraction is unsupported on this platform"
        )
        #endif
    }

    private static func makeUniqueStagingURL(
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
