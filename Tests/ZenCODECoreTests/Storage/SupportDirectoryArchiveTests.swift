//
//  SupportDirectoryArchiveTests.swift
//  ZenCODE
//
//  Created by ZenCODE on 2026-08-24.
//

import Foundation
@testable import ZenCODECore
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite
struct SupportDirectoryArchiveTests {
    private let fileManager = FileManager.default

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "ZenCODE-archive-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    /// Builds a representative support directory: nested directories, a
    /// hidden file, and a deep binary-ish payload.
    private func populateSupportDirectory(_ url: URL) throws -> [String: Data] {
        let files: [String: Data] = [
            "settings.json": Data("{\"models\":[]}".utf8),
            "agents.json": Data("{\"agents\":[]}".utf8),
            "AGENTS.md": Data("# Guidance".utf8),
            ".hidden-token": Data("secret".utf8),
            "memory/digest1/memory.graph.json": Data("{\"entries\":[]}".utf8),
            "sessions/project/checkpoint.json": Data(
                "{\"history\":[]}".utf8
            ),
            "features/feature.json": Data(
                String(repeating: "x", count: 4096).data(using: .utf8)!
            )
        ]
        for (path, data) in files {
            let fileURL = url.appendingPathComponent(path)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
        }
        return files
    }

    /// File paths under `url` minus the coordination artifacts the import
    /// machinery itself may create.
    private func dataPaths(in url: URL) throws -> Set<String> {
        let artifacts: Set<String> = [
            ".manifests.lock",
            ".manifests.transaction.json"
        ]
        return try relativePaths(in: url).subtracting(artifacts)
    }

    #if canImport(Darwin) || canImport(Glibc)
    /// stat(2) inode of a path, for asserting inode identity across renames.
    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber else {
            throw NSError(
                domain: "SupportDirectoryArchiveTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "missing systemFileNumber"]
            )
        }
        return number.uint64Value
    }
    #endif

    private func relativePaths(in url: URL) throws -> Set<String> {
        var paths = Set<String>()
        // Standardize both sides: on macOS the enumerator may return
        // `/private/var/...` children under a `/var/...` parent.
        let prefix = url.standardizedFileURL.path
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let itemURL = enumerator?.nextObject() as? URL {
            let values = try itemURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let itemPath = itemURL.standardizedFileURL.path
            paths.insert(String(itemPath.dropFirst(prefix.count + 1)))
        }
        return paths
    }

    private func makeArchive(
        label: String,
        mutate: (inout [String: Data]) -> Void = { _ in }
    ) throws -> (source: URL, archive: URL, files: [String: Data]) {
        let sourceURL = try makeTemporaryDirectory("\(label)-src")
        var files = try populateSupportDirectory(sourceURL)
        mutate(&files)
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString).tar.gz")
        _ = try SupportDirectoryArchive.export(
            from: sourceURL,
            to: archiveURL
        )
        return (sourceURL, archiveURL, files)
    }

    @Test
    func exportProducesCompressedTarArchiveWithManifest() throws {
        let (_, archiveURL, files) = try makeArchive(label: "gzip")

        #expect(fileManager.fileExists(atPath: archiveURL.path))
        #expect(archiveURL.path.hasSuffix(".tar.gz"))
        let archiveData = try Data(contentsOf: archiveURL)
        #expect(archiveData.starts(with: [0x1f, 0x8b]))
        #expect(archiveData.count < files.values.reduce(0) { $0 + $1.count })

        let manifest = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        #expect(Set(manifest.entries.map(\.path)) == Set(files.keys))
    }

    @Test
    func exportIncludesHiddenAndNestedFilesAndRoundTripRestoresThem() throws {
        let (sourceURL, archiveURL, files) = try makeArchive(label: "roundtrip")

        let destinationURL = try makeTemporaryDirectory("roundtrip-dst")
        let result = try SupportDirectoryArchive.import(
            from: archiveURL,
            into: destinationURL
        )
        #expect(result.fileCount == files.count)
        #expect(
            result.totalBytes == files.values.reduce(0) { $0 + UInt64($1.count) }
        )
        // The preserved coordination lock is the only extra path.
        #expect(try dataPaths(in: destinationURL) == Set(files.keys))
        for (path, data) in files {
            let restoredURL = destinationURL.appendingPathComponent(path)
            #expect(try Data(contentsOf: restoredURL) == data)
        }
        _ = sourceURL
    }

    @Test
    func importReplacesExistingDestinationEntirely() throws {
        let (sourceURL, archiveURL, files) = try makeArchive(label: "replace")
        let destinationURL = try makeTemporaryDirectory("replace-dst")
        try Data("stale".utf8).write(
            to: destinationURL.appendingPathComponent("old-file.txt")
        )
        try fileManager.createDirectory(
            at: destinationURL.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(
            to: destinationURL.appendingPathComponent("nested/old-file.txt")
        )

        _ = try SupportDirectoryArchive.import(
            from: archiveURL,
            into: destinationURL
        )

        // Preexisting data must not survive mixed with the archive content;
        // the preserved coordination lock is the only extra path.
        #expect(try dataPaths(in: destinationURL) == Set(files.keys))
        _ = sourceURL
    }

    @Test
    func exportExcludesCoordinationArtifactsAndSelf() throws {
        let sourceURL = try makeTemporaryDirectory("exclude")
        _ = try populateSupportDirectory(sourceURL)
        // A real pending transaction journal, published exactly the way the
        // live writers publish it (the export's lock acquisition would
        // recover — and remove — anything hand-written and malformed).
        let settingsURL = sourceURL.appendingPathComponent("settings.json")
        let settingsData = try Data(contentsOf: settingsURL)
        try SensitiveManifestCoordination.beginTransaction(
            [
                SensitiveManifestCoordination.Change(
                    url: settingsURL,
                    originalData: settingsData,
                    intendedData: settingsData
                )
            ],
            supportDirectoryURL: sourceURL
        )
        // An archive saved inside the source directory itself.
        let innerArchiveURL = sourceURL.appendingPathComponent("backup.tar.gz")
        _ = try SupportDirectoryArchive.export(
            from: sourceURL,
            to: innerArchiveURL
        )

        let manifest = try SupportDirectoryArchive.validate(
            archiveURL: innerArchiveURL
        )
        let paths = Set(manifest.entries.map(\.path))
        #expect(!paths.contains(".manifests.lock"))
        #expect(!paths.contains(".manifests.transaction.json"))
        #expect(!paths.contains("backup.tar.gz"))
        #expect(paths.contains("settings.json"))
        #expect(paths.contains(".hidden-token"))
    }

    @Test
    func exportReplacementKeepsTemporaryAndPublishedArchivesPrivate() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let sourceURL = try makeTemporaryDirectory("private-export-src")
        _ = try populateSupportDirectory(sourceURL)
        let archiveDirectoryURL = try makeTemporaryDirectory("private-export-dst")
        let archiveURL = archiveDirectoryURL.appendingPathComponent("backup.tar.gz")

        _ = try SupportDirectoryArchive.exportReplacingExisting(
            from: sourceURL,
            to: archiveURL,
            publishCheckpoint: {
                let temporaryURLs = try self.fileManager.contentsOfDirectory(
                    at: archiveDirectoryURL,
                    includingPropertiesForKeys: nil
                ).filter {
                    $0.lastPathComponent.hasPrefix(
                        SupportDirectoryArchive.exportTemporaryNamePrefix
                    )
                }
                #expect(temporaryURLs.count == 1)
                #expect(try self.posixMode(of: temporaryURLs[0]) == 0o600)
            }
        )

        #expect(try posixMode(of: archiveURL) == 0o600)
        #endif
    }

    @Test
    func exportRefusesExistingDestinationAndMissingSource() throws {
        let sourceURL = try makeTemporaryDirectory("refuse-src")
        _ = try populateSupportDirectory(sourceURL)
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("refuse-\(UUID().uuidString).tar.gz")
        _ = try SupportDirectoryArchive.export(from: sourceURL, to: archiveURL)

        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.export(
                from: sourceURL,
                to: archiveURL
            )
        }
        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.export(
                from: sourceURL.appendingPathComponent("missing"),
                to: fileManager.temporaryDirectory
                    .appendingPathComponent("refuse-\(UUID().uuidString).tar.gz")
            )
        }
    }

    // MARK: - Malicious / invalid archives

    /// Runs the same system archive utility used by production code to build
    /// deliberately crafted fixtures without an archive package dependency.
    private func createTarArchive(
        at archiveURL: URL,
        from stagingURL: URL,
        members: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "--create",
            "--gzip",
            "--file=\(archiveURL.path)",
            "--directory=\(stagingURL.path)",
            "--no-recursion"
        ] + members
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "SupportDirectoryArchiveTests.tar",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }
    }

    /// Builds an archive with an explicitly crafted manifest.
    private func makeCraftedArchive(
        label: String,
        manifestJSON: String,
        payload: [(String, Data)]
    ) throws -> URL {
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString).tar.gz")
        let stagingURL = try makeTemporaryDirectory("\(label)-fixture")
        defer { try? fileManager.removeItem(at: stagingURL) }

        try Data(manifestJSON.utf8).write(
            to: stagingURL.appendingPathComponent(
                SupportDirectoryArchive.manifestEntryPath
            )
        )
        var members = [SupportDirectoryArchive.manifestEntryPath]
        for (path, data) in payload {
            let components = path.split(separator: "/")
            guard !path.hasPrefix("/"),
                  !components.contains("..") else {
                continue
            }
            let fileURL = stagingURL.appendingPathComponent(path)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
            members.append(path)
        }
        try createTarArchive(
            at: archiveURL,
            from: stagingURL,
            members: members
        )
        return archiveURL
    }

    @Test
    func importRejectsNotATarFile() throws {
        let notTarURL = fileManager.temporaryDirectory
            .appendingPathComponent("nottar.gz-\(UUID().uuidString).tar.gz")
        try Data("definitely not a tar.gz".utf8).write(to: notTarURL)

        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.validate(archiveURL: notTarURL)
        }
        let destinationURL = try makeTemporaryDirectory("nottar.gz-dst")
        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.import(
                from: notTarURL,
                into: destinationURL
            )
        }
        #expect(try relativePaths(in: destinationURL).isEmpty)
    }

    @Test
    func importRejectsTraversalManifestPath() throws {
        let archiveURL = try makeCraftedArchive(
            label: "traversal",
            manifestJSON: """
                {"version":1,"entries":[
                  {"path":"../escape.txt","sha256":"\(Data("x".utf8).sha256Hex())","size":1}
                ]}
                """,
            payload: [("payload/../escape.txt", Data("x".utf8))]
        )
        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        }
    }

    @Test
    func importRejectsAbsolutePathManifestEntry() throws {
        let archiveURL = try makeCraftedArchive(
            label: "absolute",
            manifestJSON: """
                {"version":1,"entries":[
                  {"path":"/etc/passwd","sha256":"\(Data("x".utf8).sha256Hex())","size":1}
                ]}
                """,
            payload: [("payload//etc/passwd", Data("x".utf8))]
        )
        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        }
    }

    @Test
    func importRejectsUndeclaredTarEntry() throws {
        let archiveURL = try makeCraftedArchive(
            label: "extra",
            manifestJSON: """
                {"version":1,"entries":[]}
                """,
            payload: [("payload/undeclared.txt", Data("x".utf8))]
        )
        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        }
    }

    @Test
    func importRejectsChecksumMismatchWithoutTouchingDestination() throws {
        let data = Data("genuine content".utf8)
        let archiveURL = try makeCraftedArchive(
            label: "checksum",
            manifestJSON: """
                {"version":1,"entries":[
                  {"path":"settings.json","sha256":"\(Data("tampered".utf8).sha256Hex())","size":\(data.count)}
                ]}
                """,
            payload: [("payload/settings.json", data)]
        )
        let destinationURL = try makeTemporaryDirectory("checksum-dst")
        try Data("original".utf8).write(
            to: destinationURL.appendingPathComponent("keep.txt")
        )
        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.import(
                from: archiveURL,
                into: destinationURL
            )
        }
        // Pre-mutation validation: the existing file is untouched.
        #expect(
            try Data(
                contentsOf: destinationURL.appendingPathComponent("keep.txt")
            ) == Data("original".utf8)
        )
    }

    @Test
    func importRejectsSymlinkEntry() throws {
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("symlink-\(UUID().uuidString).tar.gz")
        let stagingURL = try makeTemporaryDirectory("symlink-fixture")
        defer { try? fileManager.removeItem(at: stagingURL) }
        let manifestJSON = """
            {"version":1,"entries":[
              {"path":"link","sha256":"\(Data("/tmp/target".utf8).sha256Hex())","size":11}
            ]}
            """
        try Data(manifestJSON.utf8).write(
            to: stagingURL.appendingPathComponent(
                SupportDirectoryArchive.manifestEntryPath
            )
        )
        let payloadURL = stagingURL.appendingPathComponent("payload")
        try fileManager.createDirectory(
            at: payloadURL,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: payloadURL.appendingPathComponent("link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp/target")
        )
        try createTarArchive(
            at: archiveURL,
            from: stagingURL,
            members: [SupportDirectoryArchive.manifestEntryPath, "payload/link"]
        )

        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        }
    }

    @Test
    func importRejectsUnsupportedManifestVersion() throws {
        let archiveURL = try makeCraftedArchive(
            label: "version",
            manifestJSON: """
                {"version":99,"entries":[]}
                """,
            payload: []
        )
        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        }
    }

    @Test
    func validationRejectsOversizedManifestBeforeReadingItIntoMemory() throws {
        // The JSON need not be valid: validation must reject the tar.gz metadata
        // bound before decompression and before JSONDecoder sees its content.
        let oversizedManifest = String(
            repeating: " ",
            count: Int(SupportDirectoryArchive.maximumManifestUncompressedSize) + 1
        )
        let archiveURL = try makeCraftedArchive(
            label: "oversized-manifest",
            manifestJSON: oversizedManifest,
            payload: []
        )

        #expect(
            throws: SupportDirectoryArchive.SupportDirectoryArchiveError.manifestSizeLimitExceeded(
                SupportDirectoryArchive.maximumManifestUncompressedSize + 1
            )
        ) {
            _ = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        }
    }

    @Test
    func importRejectsCorruptedPayload() throws {
        // Corrupt one byte of a valid archive's payload area.
        let (_, archiveURL, _) = try makeArchive(label: "corrupt")
        var bytes = try Data(contentsOf: archiveURL)
        // Flip a byte in the middle of the file, past the first local header.
        bytes[bytes.count / 2] ^= 0xFF
        let corruptedURL = fileManager.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).tar.gz")
        try bytes.write(to: corruptedURL)

        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.validate(archiveURL: corruptedURL)
        }
    }

    @Test
    func importRejectsMissingDeclaredEntry() throws {
        let archiveURL = try makeCraftedArchive(
            label: "missing",
            manifestJSON: """
                {"version":1,"entries":[
                  {"path":"gone.txt","sha256":"\(Data("x".utf8).sha256Hex())","size":1}
                ]}
                """,
            payload: []
        )
        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        }
    }

    @Test
    func importLeavesNoStagingArtifactsBehind() throws {
        let (_, archiveURL, _) = try makeArchive(label: "artifacts")
        let destinationParent = try makeTemporaryDirectory("artifacts-parent")
        let destinationURL = destinationParent.appendingPathComponent(
            "support",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: destinationURL.appendingPathComponent("old.txt")
        )

        _ = try SupportDirectoryArchive.import(
            from: archiveURL,
            into: destinationURL
        )

        let leftovers = try fileManager.contentsOfDirectory(
            atPath: destinationParent.path
        )
        #expect(leftovers == ["support"])
    }

    @Test
    func importedFilesArePrivate() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let (_, archiveURL, _) = try makeArchive(label: "permissions")
        let destinationURL = try makeTemporaryDirectory("permissions-dst")

        _ = try SupportDirectoryArchive.import(
            from: archiveURL,
            into: destinationURL
        )

        let settingsURL = destinationURL.appendingPathComponent("settings.json")
        let nestedURL = destinationURL
            .appendingPathComponent("memory/digest1/memory.graph.json")
        #expect(try posixMode(of: destinationURL) == 0o700)
        #expect(try posixMode(of: settingsURL) == 0o600)
        #expect(try posixMode(of: nestedURL) == 0o600)
        #endif
    }

    private func posixMode(of url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? Int else {
            throw NSError(
                domain: "SupportDirectoryArchiveTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing posixPermissions"]
            )
        }
        return permissions
    }

    // MARK: - Lock inode preservation

    #if canImport(Darwin) || canImport(Glibc)
    @Test
    func importPreservesCoordinationLockInode() throws {
        let (_, archiveURL, files) = try makeArchive(label: "lock-inode")
        let destinationURL = try makeTemporaryDirectory("lock-inode-dst")
        try Data("old".utf8).write(
            to: destinationURL.appendingPathComponent("old.txt")
        )
        // Materialize the coordination lock exactly as the live system does:
        // the import must preserve this specific inode, not create a new one.
        _ = try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: destinationURL
        ) {}
        let lockURL = SensitiveManifestCoordination.lockFileURL(in: destinationURL)
        let inodeBefore = try inode(of: lockURL)

        _ = try SupportDirectoryArchive.import(
            from: archiveURL,
            into: destinationURL
        )

        #expect(fileManager.fileExists(atPath: lockURL.path))
        #expect(try inode(of: lockURL) == inodeBefore)
        #expect(try dataPaths(in: destinationURL) == Set(files.keys))
    }

    @Test
    func concurrentLockHolderBlocksUntilImportPublishes() throws {
        let (_, archiveURL, files) = try makeArchive(label: "lock-concurrent")
        let destinationURL = try makeTemporaryDirectory("lock-concurrent-dst")
        _ = try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: destinationURL
        ) {}
        let lockURL = SensitiveManifestCoordination.lockFileURL(in: destinationURL)
        let inodeBefore = try inode(of: lockURL)

        // Hold the lock ourselves on the current inode, the way another
        // process would. While we hold it, an import into the same
        // destination must block instead of swapping the directory — that is
        // the mutual exclusion this machinery guarantees.
        let descriptor = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(
                domain: "SupportDirectoryArchiveTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "open failed"]
            )
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw NSError(
                domain: "SupportDirectoryArchiveTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "lock is held elsewhere"]
            )
        }

        let importBox = LockedImportBox()
        Thread.detachNewThread {
            do {
                _ = try SupportDirectoryArchive.import(
                    from: archiveURL,
                    into: destinationURL
                )
                importBox.state = .done
            } catch {
                importBox.state = .failed("\(error)")
            }
        }
        // Give the blocked import a moment; it must not have published or
        // failed while we still hold the lock on the old inode.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(importBox.state == .pending)
        #expect(try inode(of: lockURL) == inodeBefore)

        // Releasing the lock lets the import complete. On swap the lock inode
        // is preserved, so this very descriptor can re-acquire it — proving
        // cross-holder exclusion on one shared inode.
        flock(descriptor, LOCK_UN)
        var waited = 0
        while importBox.state == .pending && waited < 100 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 1
        }
        #expect(importBox.state == .done)
        #expect(try inode(of: lockURL) == inodeBefore)
        #expect(try dataPaths(in: destinationURL) == Set(files.keys))
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw NSError(
                domain: "SupportDirectoryArchiveTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "lock lost its exclusion after the swap"]
            )
        }
        flock(descriptor, LOCK_UN)
    }

    private final class LockedImportBox: @unchecked Sendable {
        enum State: Equatable {
            case pending
            case done
            case failed(String)
        }
        private let semaphore = DispatchSemaphore(value: 1)
        private var stored: State = .pending
        var state: State {
            get {
                semaphore.wait()
                defer { semaphore.signal() }
                return stored
            }
            set {
                semaphore.wait()
                defer { semaphore.signal() }
                stored = newValue
            }
        }
    }
    #endif

    // MARK: - Manifest overflow safety

    @Test
    func validationRejectsOverflowingManifestTotals() throws {
        let max = UInt64.max
        let overflowArchiveURL = try makeCraftedArchive(
            label: "overflow",
            manifestJSON: """
                {"version":1,"entries":[
                  {"path":"a.txt","sha256":"\(Data("a".utf8).sha256Hex())","size":\(max)},
                  {"path":"b.txt","sha256":"\(Data("b".utf8).sha256Hex())","size":\(max)}
                ]}
                """,
            payload: [
                ("payload/a.txt", Data("a".utf8)),
                ("payload/b.txt", Data("b".utf8))
            ]
        )
        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.validate(archiveURL: overflowArchiveURL)
        }
    }

    // MARK: - Source symlinks

    @Test
    func exportRejectsSourceSymlinksExplicitly() throws {
        let sourceURL = try makeTemporaryDirectory("symlink-src")
        _ = try populateSupportDirectory(sourceURL)
        try fileManager.createSymbolicLink(
            at: sourceURL.appendingPathComponent("sneaky-link"),
            withDestinationURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )

        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.export(
                from: sourceURL,
                to: fileManager.temporaryDirectory
                    .appendingPathComponent("symlink-\(UUID().uuidString).tar.gz")
            )
        }
    }

    // MARK: - Archive replacement

    @Test
    func exportReplacementOverwritesSafely() throws {
        let sourceURL = try makeTemporaryDirectory("replace-src")
        _ = try populateSupportDirectory(sourceURL)
        // A dedicated parent so the leftovers assertion cannot see artifacts
        // of other tests running in parallel under the shared temp root.
        let archiveDirectoryURL = try makeTemporaryDirectory("replace-dst")
        let archiveURL = archiveDirectoryURL.appendingPathComponent("backup.tar.gz")

        let first = try SupportDirectoryArchive.exportReplacingExisting(
            from: sourceURL,
            to: archiveURL
        )
        let second = try SupportDirectoryArchive.exportReplacingExisting(
            from: sourceURL,
            to: archiveURL
        )
        #expect(first.fileCount == second.fileCount)
        _ = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        // No temporary or quarantine leftovers next to the published archive.
        let siblings = try fileManager.contentsOfDirectory(
            atPath: archiveDirectoryURL.path
        )
        #expect(siblings == ["backup.tar.gz"])
    }

    @Test
    func exportReplacementExcludesNestedDestinationAndReservedArtifacts() throws {
        let sourceURL = try makeTemporaryDirectory("nested-replace-src")
        _ = try populateSupportDirectory(sourceURL)
        let archiveDirectoryURL = sourceURL.appendingPathComponent("backups/daily")
        try fileManager.createDirectory(
            at: archiveDirectoryURL,
            withIntermediateDirectories: true
        )
        let archiveURL = archiveDirectoryURL.appendingPathComponent("backup.tar.gz")
        // This pre-existing final archive is moved to quarantine only after
        // collection, so it specifically exercises exclusion from nested
        // source directories rather than just cleanup after publication.
        try Data("old backup".utf8).write(to: archiveURL)
        try Data("stale temporary".utf8).write(
            to: archiveDirectoryURL.appendingPathComponent(
                "\(SupportDirectoryArchive.exportTemporaryNamePrefix)stale.tmp"
            )
        )
        try Data("stale quarantine".utf8).write(
            to: archiveDirectoryURL.appendingPathComponent(
                ".zencode-import-replaced-stale.tar.gz"
            )
        )

        _ = try SupportDirectoryArchive.exportReplacingExisting(
            from: sourceURL,
            to: archiveURL
        )

        let manifest = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
        let paths = Set(manifest.entries.map(\.path))
        #expect(!paths.contains("backups/daily/backup.tar.gz"))
        #expect(!paths.contains(where: { $0.contains(".zencode-import-") }))
        #expect(paths.contains("settings.json"))
    }

    @Test
    func failedArchiveReplacementRestoresPreviousArchive() throws {
        let sourceURL = try makeTemporaryDirectory("replace-fail-src")
        _ = try populateSupportDirectory(sourceURL)
        let archiveDirectoryURL = try makeTemporaryDirectory("replace-fail-dst")
        let archiveURL = archiveDirectoryURL.appendingPathComponent("backup.tar.gz")
        _ = try SupportDirectoryArchive.exportReplacingExisting(
            from: sourceURL,
            to: archiveURL
        )
        let previousArchiveData = try Data(contentsOf: archiveURL)

        struct InjectedFailure: Error {}

        #expect(throws: InjectedFailure.self) {
            _ = try SupportDirectoryArchive.exportReplacingExisting(
                from: sourceURL,
                to: archiveURL,
                publishCheckpoint: { throw InjectedFailure() }
            )
        }

        // The previous archive is back, byte-identical, and no leftovers.
        #expect(try Data(contentsOf: archiveURL) == previousArchiveData)
        let siblings = try fileManager.contentsOfDirectory(
            atPath: archiveDirectoryURL.path
        )
        #expect(siblings == ["backup.tar.gz"])
    }

    // MARK: - Rollback

    @Test
    func failedExtractionRollsBackAndLeavesDestinationIntact() throws {
        let (sourceURL, archiveURL, _) = try makeArchive(label: "rollback-extract")
        let destinationURL = try makeTemporaryDirectory("rollback-extract-dst")
        try Data("original".utf8).write(
            to: destinationURL.appendingPathComponent("keep.txt")
        )

        struct InjectedFailure: Error {}

        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.import(
                from: archiveURL,
                into: destinationURL,
                extractionCheckpoint: { written in
                    if written == 1 {
                        throw InjectedFailure()
                    }
                }
            )
        }
        // The destination was never touched by the failed import; only the
        // coordination lock appears alongside the original content.
        #expect(
            try Data(
                contentsOf: destinationURL.appendingPathComponent("keep.txt")
            ) == Data("original".utf8)
        )
        #expect(
            try dataPaths(in: destinationURL) == ["keep.txt"]
        )
        _ = sourceURL
    }

    @Test
    func failedPublishRestoresThePreviousDirectory() throws {
        let (_, archiveURL, files) = try makeArchive(label: "rollback-publish")
        let destinationURL = try makeTemporaryDirectory("rollback-publish-dst")
        try Data("previous-state".utf8).write(
            to: destinationURL.appendingPathComponent("previous.txt")
        )

        struct InjectedFailure: Error {}

        #expect(throws: SupportDirectoryArchive.SupportDirectoryArchiveError.self) {
            _ = try SupportDirectoryArchive.import(
                from: archiveURL,
                into: destinationURL,
                publishCheckpoint: {
                    throw InjectedFailure()
                }
            )
        }
        // The quarantine was restored into place unchanged; only the
        // coordination lock appears alongside the original content.
        #expect(
            try Data(
                contentsOf: destinationURL.appendingPathComponent("previous.txt")
            ) == Data("previous-state".utf8)
        )
        #expect(
            try dataPaths(in: destinationURL) == ["previous.txt"]
        )
        #expect(files.isEmpty == false)
    }
}
