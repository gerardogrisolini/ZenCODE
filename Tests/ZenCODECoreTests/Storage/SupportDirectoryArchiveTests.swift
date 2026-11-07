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
    func exportSkipsFeatureBuildDirectoriesIncludingSymlinks() throws {
        let sourceURL = try makeTemporaryDirectory("feature-build")
        _ = try populateSupportDirectory(sourceURL)
        let featureURL = sourceURL.appendingPathComponent("features/demo", isDirectory: true)
        let buildURL = featureURL.appendingPathComponent(".build", isDirectory: true)
        let files = [
            "features/demo/feature.json",
            "features/demo/Package.swift",
            "features/demo/Sources/Demo/main.swift",
            "features/demo/.build/out/Products/Release/demo-feature",
            // `.build` directories anywhere but `features/<id>/.build` are kept.
            "features/demo/Sources/.build/kept.txt",
            "other/demo/.build/kept.txt",
            "features/.build/kept.txt",
            ".build/kept.txt"
        ]
        for path in files {
            let fileURL = sourceURL.appendingPathComponent(path)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(path.utf8).write(to: fileURL)
        }
        // The relative link SwiftPM creates; inside `features/<id>/.build` it is
        // never visited.
        try fileManager.createSymbolicLink(
            atPath: buildURL.appendingPathComponent("release").path,
            withDestinationPath: "out/Products/Release"
        )

        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("feature-build-\(UUID().uuidString).tar.gz")
        defer { try? fileManager.removeItem(at: archiveURL) }
        let result = try SupportDirectoryArchive.export(from: sourceURL, to: archiveURL)

        let paths = Set(try SupportDirectoryArchive.validate(archiveURL: archiveURL).entries.map(\.path))
        #expect(!paths.contains { $0.hasPrefix("features/demo/.build/") })
        #expect(paths.contains("features/demo/feature.json"))
        #expect(paths.contains("features/demo/Package.swift"))
        #expect(paths.contains("features/demo/Sources/Demo/main.swift"))
        #expect(paths.contains("features/demo/Sources/.build/kept.txt"))
        #expect(paths.contains("other/demo/.build/kept.txt"))
        #expect(paths.contains("features/.build/kept.txt"))
        #expect(paths.contains(".build/kept.txt"))
        #expect(paths.contains("settings.json"))
        #expect(result.skippedSymbolicLinks.isEmpty)
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

    // MARK: - Source symlinks

    @Test
    func exportSkipsAndReportsSourceSymlinks() throws {
        let sourceURL = try makeTemporaryDirectory("symlink-src")
        var files = try populateSupportDirectory(sourceURL)
        let nestedURL = sourceURL.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: nestedURL.appendingPathComponent("kept.txt"))
        files["nested/kept.txt"] = Data("kept".utf8)

        // A link to a directory outside the source: it must not be traversed.
        let outsidePath = NSTemporaryDirectory()
        try fileManager.createSymbolicLink(
            atPath: sourceURL.appendingPathComponent("sneaky-link").path,
            withDestinationPath: outsidePath
        )
        // A dangling relative link in a nested directory.
        try fileManager.createSymbolicLink(
            atPath: nestedURL.appendingPathComponent("dangling").path,
            withDestinationPath: "missing-target"
        )
        // A link to a regular file inside the source: the target is archived
        // once, under its own name, and the link is not.
        try fileManager.createSymbolicLink(
            atPath: sourceURL.appendingPathComponent("link-to-settings").path,
            withDestinationPath: "settings.json"
        )

        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("symlink-\(UUID().uuidString).tar.gz")
        defer { try? fileManager.removeItem(at: archiveURL) }
        let result = try SupportDirectoryArchive.export(from: sourceURL, to: archiveURL)

        let entries = try SupportDirectoryArchive.validate(archiveURL: archiveURL).entries
        let paths = entries.map(\.path)
        #expect(Set(paths) == Set(files.keys))
        #expect(paths.count == files.count)
        #expect(!paths.contains("sneaky-link"))
        #expect(!paths.contains { $0.hasPrefix("sneaky-link/") })
        #expect(!paths.contains("nested/dangling"))
        #expect(!paths.contains("link-to-settings"))
        #expect(paths.contains("settings.json"))
        #expect(paths.contains("nested/kept.txt"))
        #expect(result.fileCount == files.count)
        #expect(
            result.skippedSymbolicLinks == [
                .init(path: "link-to-settings", destination: "settings.json"),
                .init(path: "nested/dangling", destination: "missing-target"),
                .init(path: "sneaky-link", destination: outsidePath)
            ]
        )
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
}
