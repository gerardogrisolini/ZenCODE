//
//  ZenCRONInstallationTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

/// `ZenCRONInstallation`: locations, version parsing, the replacement policy and
/// the atomic installation. Every executable is a throw-away script in a UUID
/// named temporary directory; the real support directory is never used.
@Suite("ZenCRON installation")
struct ZenCRONInstallationTests {
    // MARK: - Locations

    // MARK: - Version parsing

    @Test(arguments: [
        ("ZenCRON 1\n", "ZenCRON 1"),
        ("ZenCRON 1", "ZenCRON 1"),
        ("ZenCRON 12\n", "ZenCRON 12"),
        ("ZenCRON 7\r\n", "ZenCRON 7")
    ])
    func parseVersionAcceptsASingleVersionLine(output: String, expected: String) throws {
        #expect(try ZenCRONInstallation.parseVersion(output) == expected)
    }

    @Test(arguments: [
        ("", ZenCRONInstallation.VersionError.noOutput),
        ("\n", .noOutput),
        ("ZenCRON 1\nZenCRON 2\n", .multipleLines),
        ("ZenCRON 1\n\n", .multipleLines),
        ("ZenCRON 1\r\nZenCRON 2\r\n", .multipleLines),
        ("ZenCRON 1\r", .multipleLines),
        ("banner\nZenCRON 1\n", .multipleLines),
        ("hello\n", .unexpectedOutput("hello")),
        ("zencron 1\n", .unexpectedOutput("zencron 1")),
        ("ZenCRON\n", .unexpectedOutput("ZenCRON")),
        ("ZenCRON \n", .unexpectedOutput("ZenCRON ")),
        ("ZenCRON x\n", .unexpectedOutput("ZenCRON x")),
        ("ZenCRON 1.2\n", .unexpectedOutput("ZenCRON 1.2")),
        ("ZenCRON  1\n", .unexpectedOutput("ZenCRON  1")),
        (" ZenCRON 1\n", .unexpectedOutput(" ZenCRON 1")),
        ("ZenCRON 1 \n", .unexpectedOutput("ZenCRON 1 ")),
        ("zen 1\n", .unexpectedOutput("zen 1"))
    ])
    func parseVersionRejectsAnythingElse(output: String, expected: ZenCRONInstallation.VersionError) {
        #expect(throws: expected) {
            try ZenCRONInstallation.parseVersion(output)
        }
    }

    @Test
    func interpretVersionResultReportsEveryFailedOutcome() throws {
        #expect(
            try ZenCRONInstallation.interpretVersionResult(
                exitCode: 0, timedOut: false, stdout: "ZenCRON 1\n", stderr: ""
            ) == "ZenCRON 1"
        )
        #expect(throws: ZenCRONInstallation.VersionError.exitStatus(3, stderr: "boom")) {
            try ZenCRONInstallation.interpretVersionResult(
                exitCode: 3, timedOut: false, stdout: "ZenCRON 1\n", stderr: "boom"
            )
        }
        #expect(throws: ZenCRONInstallation.VersionError.timedOut(seconds: 10)) {
            try ZenCRONInstallation.interpretVersionResult(
                exitCode: -1, timedOut: true, stdout: "", stderr: ""
            )
        }
        #expect(throws: ZenCRONInstallation.VersionError.timedOut(seconds: 2)) {
            try ZenCRONInstallation.interpretVersionResult(
                exitCode: -1, timedOut: true, stdout: "", stderr: "", timeout: 1.5
            )
        }
        #expect(throws: ZenCRONInstallation.VersionError.noOutput) {
            try ZenCRONInstallation.interpretVersionResult(
                exitCode: 0, timedOut: false, stdout: "", stderr: ""
            )
        }
    }

    // MARK: - Version of a real executable

    @Test
    func versionTimesOutOnAnExecutableThatDoesNotAnswer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }
        let executable = try makeScript("exec sleep 30", in: directory)

        await #expect(throws: ZenCRONInstallation.VersionError.timedOut(seconds: 1)) {
            try await ZenCRONInstallation.version(ofExecutableAt: executable, timeout: 0.5)
        }
    }

    // MARK: - The installed executable, as /cron add needs it

    @Test
    func checkedInstalledExecutableReturnsPathAndVersionOfAWorkingHost() async throws {
        let support = try makeTemporaryDirectory()
        defer { remove(support) }
        try installScript("printf 'ZenCRON 4\\n'", in: support)

        let installed = try await ZenCRONInstallation.checkedInstalledExecutable(
            supportDirectory: support,
            timeout: 20
        )

        #expect(
            installed == ZenCRONInstallation.InstalledExecutable(
                path: ZenCRONInstallation.installedExecutableURL(supportDirectory: support).path,
                version: "ZenCRON 4"
            )
        )
    }

    @Test
    func checkedInstalledExecutableRefusesAMissingHost() async throws {
        let support = try makeTemporaryDirectory()
        defer { remove(support) }
        let path = ZenCRONInstallation.installedExecutableURL(supportDirectory: support).path

        await #expect(throws: ZenCrontabError.zenCRONNotInstalled(path: path)) {
            try await ZenCRONInstallation.checkedInstalledExecutable(supportDirectory: support, timeout: 20)
        }
    }

    // MARK: - Replacement policy

    /// macOS keeps the installed host of the same version and replaces any other
    /// (or an unreadable one); Linux always replaces it.
    @Test(arguments: [
        ("ZenCRON 1", "ZenCRON 1", ZenCRONInstallation.Platform.macOS, ZenCRONInstallation.Decision.keep),
        ("ZenCRON 1", "ZenCRON 2", .macOS, .install),
        ("ZenCRON 2", "ZenCRON 1", .macOS, .install),
        ("ZenCRON 1", "ZenCRON 10", .macOS, .install),
        (nil, "ZenCRON 1", .macOS, .install),
        ("ZenCRON 1", "ZenCRON 1", .linux, .install),
        ("ZenCRON 1", "ZenCRON 2", .linux, .install),
        (nil, "ZenCRON 1", .linux, .install)
    ] as [(String?, String, ZenCRONInstallation.Platform, ZenCRONInstallation.Decision)])
    func macOSReplacesTheInstalledHostOfADifferentVersion(
        installed: String?,
        built: String,
        platform: ZenCRONInstallation.Platform,
        expected: ZenCRONInstallation.Decision
    ) {
        #expect(
            ZenCRONInstallation.decision(installedVersion: installed, builtVersion: built, platform: platform)
                == expected
        )
    }

    // MARK: - Atomic installation

    @Test
    func installCreatesTheBinDirectoryAndCopiesTheBytesUnchanged() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let bytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let built = root.appendingPathComponent("built")
        try bytes.write(to: built)
        // Whatever the mode of the build product, the installed file is 0755.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: built.path)

        let target = try ZenCRONInstallation.install(builtExecutable: built, supportDirectory: support)

        #expect(target == ZenCRONInstallation.installedExecutableURL(supportDirectory: support))
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try permissions(of: target) == 0o755)
        #expect(try permissions(of: target.deletingLastPathComponent()) == 0o755)
        #expect(FileManager.default.isExecutableFile(atPath: target.path))
        // The build product is left alone.
        #expect(try Data(contentsOf: built) == bytes)
        #expect(try permissions(of: built) == 0o600)
    }

    @Test
    func installReplacesTheTargetWithoutWritingIntoTheOldFile() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let built = try writeFile("new build", named: "built", in: root)
        let target = ZenCRONInstallation.installedExecutableURL(supportDirectory: root)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old build".utf8).write(to: target)
        // A process that already has the old file open (a running ZenCRON, a
        // cron job starting) keeps reading the old bytes: the target is
        // replaced by a rename, never rewritten in place.
        let oldHandle = try FileHandle(forReadingFrom: target)
        defer { try? oldHandle.close() }

        try ZenCRONInstallation.install(builtExecutable: built, supportDirectory: root)

        #expect(try String(contentsOf: target, encoding: .utf8) == "new build")
        #expect(try oldHandle.readToEnd() == Data("old build".utf8))
        #expect(try permissions(of: target) == 0o755)
        let entries = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        #expect(entries == ["ZenCRON"])
    }

    @Test
    func aFailedInstallLeavesTheInstalledHostAndNoTemporaryFile() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let target = ZenCRONInstallation.installedExecutableURL(supportDirectory: root)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("installed".utf8).write(to: target)

        #expect(throws: ZenCRONInstallation.InstallError.self) {
            try ZenCRONInstallation.install(
                builtExecutable: root.appendingPathComponent("does-not-exist"),
                supportDirectory: root
            )
        }

        #expect(try String(contentsOf: target, encoding: .utf8) == "installed")
        let entries = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        #expect(entries == ["ZenCRON"])
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCRON-installation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeFile(_ contents: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// An executable `/bin/sh` script with the given body.
    @discardableResult
    private func makeScript(_ body: String, named name: String = "ZenCRON", in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A script installed where `/cron add` looks for ZenCRON.
    @discardableResult
    private func installScript(_ body: String, in support: URL) throws -> URL {
        let bin = ZenCRONInstallation.installedExecutableURL(supportDirectory: support).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        return try makeScript(body, in: bin)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
