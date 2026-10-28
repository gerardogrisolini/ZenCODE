//
//  ZenCRONPackageSyncTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

/// `ZenCRONInstallation.syncPackage`: the stable working copy that `/setup`
/// builds. Everything happens in UUID named temporary directories.
@Suite("ZenCRON package sync")
struct ZenCRONPackageSyncTests {
    @Test
    func theWorkingCopyReceivesTheWholePackageExceptBuildState() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let copy = root.appendingPathComponent("zencron/package", isDirectory: true)
        try write("manifest", at: "Package.swift", in: source)
        try write("main", at: "Sources/ZenCRON/main.swift", in: source)
        try write("test", at: "Tests/ZenCRONTests/HostTests.swift", in: source)
        try write("stale build", at: ".build/release/ZenCRON", in: source)
        try write("editor", at: ".swiftpm/state", in: source)
        try write("junk", at: ".DS_Store", in: source)

        try ZenCRONInstallation.syncPackage(from: source, to: copy)

        #expect(try files(in: copy) == [
            "Package.swift", "Sources/ZenCRON/main.swift", "Tests/ZenCRONTests/HostTests.swift"
        ])
        #expect(try read("Sources/ZenCRON/main.swift", in: copy) == "main")
    }

    @Test
    func theBuildDirectoryOfTheWorkingCopySurvivesAndSourceBuildStateStaysOut() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let copy = root.appendingPathComponent("copy", isDirectory: true)
        try write("manifest", at: "Package.swift", in: source)
        try write("source build", at: ".build/artifact", in: source)
        try write("incremental state", at: ".build/release/ZenCRON", in: copy)
        try write("old manifest", at: "Package.swift", in: copy)

        try ZenCRONInstallation.syncPackage(from: source, to: copy)

        #expect(try read(".build/release/ZenCRON", in: copy) == "incremental state")
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent(".build/artifact").path))
        #expect(try read("Package.swift", in: copy) == "manifest")
    }

    @Test
    func filesAndDirectoriesRemovedFromTheSourceDisappearFromTheCopy() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let copy = root.appendingPathComponent("copy", isDirectory: true)
        try write("manifest", at: "Package.swift", in: source)
        try write("kept", at: "Sources/ZenCRON/main.swift", in: source)
        try write("manifest", at: "Package.swift", in: copy)
        try write("kept", at: "Sources/ZenCRON/main.swift", in: copy)
        try write("gone", at: "Sources/ZenCRON/Removed.swift", in: copy)
        try write("gone", at: "Obsolete/File.swift", in: copy)
        try write("build", at: ".build/state", in: copy)

        try ZenCRONInstallation.syncPackage(from: source, to: copy)

        #expect(try files(in: copy) == ["Package.swift", "Sources/ZenCRON/main.swift"])
        #expect(try read(".build/state", in: copy) == "build")
    }

    @Test
    func unchangedFilesAreNotTouchedSoTheNextBuildStaysIncremental() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let copy = root.appendingPathComponent("copy", isDirectory: true)
        try write("same", at: "Sources/ZenCRON/Same.swift", in: source)
        try write("before", at: "Sources/ZenCRON/Changed.swift", in: source)
        try ZenCRONInstallation.syncPackage(from: source, to: copy)
        let longAgo = Date(timeIntervalSince1970: 1_000_000)
        for name in ["Same", "Changed"] {
            try FileManager.default.setAttributes(
                [.modificationDate: longAgo],
                ofItemAtPath: copy.appendingPathComponent("Sources/ZenCRON/\(name).swift").path
            )
        }
        try write("after", at: "Sources/ZenCRON/Changed.swift", in: source)

        try ZenCRONInstallation.syncPackage(from: source, to: copy)

        #expect(try modificationDate("Sources/ZenCRON/Same.swift", in: copy) == longAgo)
        #expect(try modificationDate("Sources/ZenCRON/Changed.swift", in: copy) != longAgo)
        #expect(try read("Sources/ZenCRON/Changed.swift", in: copy) == "after")
    }

    @Test
    func aFileBecomingADirectoryAndBackIsReplaced() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let copy = root.appendingPathComponent("copy", isDirectory: true)
        try write("a file", at: "Thing", in: copy)
        try write("a directory entry", at: "Other/Inside.swift", in: copy)
        try write("now a directory", at: "Thing/Inside.swift", in: source)
        try write("now a file", at: "Other", in: source)

        try ZenCRONInstallation.syncPackage(from: source, to: copy)

        #expect(try files(in: copy) == ["Other", "Thing/Inside.swift"])
        #expect(try read("Other", in: copy) == "now a file")
    }

    @Test
    func theSourceIsNeverModified() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let copy = root.appendingPathComponent("copy", isDirectory: true)
        try write("manifest", at: "Package.swift", in: source)
        try write("build", at: ".build/state", in: source)
        try write("extra", at: "Extra.swift", in: copy)

        try ZenCRONInstallation.syncPackage(from: source, to: copy)

        #expect(try files(in: source) == ["Package.swift"])
        #expect(try read(".build/state", in: source) == "build")
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCRON-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ contents: String, at relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func read(_ relativePath: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func modificationDate(_ relativePath: String, in root: URL) throws -> Date? {
        try FileManager.default
            .attributesOfItem(atPath: root.appendingPathComponent(relativePath).path)[.modificationDate] as? Date
    }

    /// Regular files under `root`, as sorted paths relative to it, skipping
    /// SwiftPM build state.
    private func files(in root: URL) throws -> [String] {
        var result: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        while let relative = enumerator?.nextObject() as? String {
            if relative.hasPrefix(".build") { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent(relative).path,
                isDirectory: &isDirectory
            ) else { continue }
            if !isDirectory.boolValue { result.append(relative) }
        }
        return result.sorted()
    }
}
