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

    @Test
    func constantsNameTheExecutableAndThePackage() {
        #expect(ZenCRONInstallation.executableName == "ZenCRON")
        #expect(ZenCRONInstallation.packageRelativePath == "Sources/ZenCRON")
        #expect(ZenCRONInstallation.versionArgument == "--zencron-version")
    }

    @Test(arguments: [
        ("/Users/me/.zencode", "/Users/me/.zencode/bin/ZenCRON"),
        ("/custom/support dir", "/custom/support dir/bin/ZenCRON")
    ])
    func theInstalledExecutableLivesInTheBinDirectoryOfTheGivenSupportDirectory(
        support: String,
        expected: String
    ) {
        // The directory is what `ZENCODE_SUPPORT_DIRECTORY` names when set,
        // and `~/.zencode` otherwise: the helper only appends `bin/ZenCRON`.
        let url = ZenCRONInstallation.installedExecutableURL(
            supportDirectory: URL(fileURLWithPath: support, isDirectory: true)
        )
        #expect(url.path == expected)
    }

    @Test
    func theDefaultSupportDirectoryIsTheStandardOne() throws {
        let support = try makeTemporaryDirectory()
        defer { remove(support) }

        AppStorageDirectory.withSupportDirectoryURL(support) {
            #expect(
                ZenCRONInstallation.installedExecutableURL().path
                    == support.standardizedFileURL.appendingPathComponent("bin/ZenCRON").path
            )
            #expect(
                ZenCRONInstallation.workingCopyURL().path
                    == support.standardizedFileURL.appendingPathComponent("zencron/package").path
            )
        }
        #expect(
            ZenCRONInstallation.installedExecutableURL()
                == ZenCRONInstallation.installedExecutableURL(supportDirectory: ZenFileService.supportDirectoryURL())
        )
    }

    @Test
    func theBuiltExecutableIsInTheReleaseBuildDirectoryOfThePackage() {
        let package = URL(fileURLWithPath: "/work/package", isDirectory: true)
        #expect(
            ZenCRONInstallation.builtExecutableURL(packageDirectory: package).path
                == "/work/package/.build/release/ZenCRON"
        )
    }

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

    @Test
    func versionErrorsReadAsTheReasonInsideDoesNotStart() {
        #expect(ZenCRONInstallation.VersionError.notExecutable.localizedDescription == "it is not executable")
        #expect(
            ZenCRONInstallation.VersionError.exitStatus(2, stderr: " dyld: missing\n").localizedDescription
                == "it exited with status 2: dyld: missing"
        )
        #expect(
            ZenCRONInstallation.VersionError.exitStatus(2, stderr: "").localizedDescription
                == "it exited with status 2"
        )
        #expect(
            ZenCRONInstallation.VersionError.timedOut(seconds: 10).localizedDescription
                == "it did not answer --zencron-version within 10 seconds"
        )
        #expect(ZenCRONInstallation.VersionError.noOutput.localizedDescription == "it printed no version")
        #expect(
            ZenCRONInstallation.VersionError.unexpectedOutput("hello").localizedDescription
                == "it printed 'hello' instead of 'ZenCRON <number>'"
        )
    }

    // MARK: - Version of a real executable

    @Test
    func versionRunsTheExecutableWithTheVersionArgument() async throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }
        // Fails unless the only argument is `--zencron-version`; `cat` returns
        // at once only when standard input is /dev/null.
        let executable = try makeScript(
            """
            [ "$#" = 1 ] && [ "$1" = "--zencron-version" ] || exit 9
            cat > /dev/null
            printf 'ZenCRON 3\\n'
            """,
            in: directory
        )

        #expect(try await ZenCRONInstallation.version(ofExecutableAt: executable, timeout: 20) == "ZenCRON 3")
    }

    @Test
    func versionFailsWhenTheExitStatusIsNotZero() async throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }
        let executable = try makeScript(
            "printf 'ZenCRON 1\\n'; printf 'boom\\n' >&2; exit 2",
            in: directory
        )

        await #expect(throws: ZenCRONInstallation.VersionError.exitStatus(2, stderr: "boom\n")) {
            try await ZenCRONInstallation.version(ofExecutableAt: executable, timeout: 20)
        }
    }

    @Test(arguments: [
        ("printf 'hello\\n'", ZenCRONInstallation.VersionError.unexpectedOutput("hello")),
        ("printf 'ZenCRON 1\\nZenCRON 1\\n'", .multipleLines),
        ("exit 0", .noOutput)
    ])
    func versionFailsWhenTheOutputIsNotASingleVersionLine(
        script: String,
        expected: ZenCRONInstallation.VersionError
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }
        let executable = try makeScript(script, in: directory)

        await #expect(throws: expected) {
            try await ZenCRONInstallation.version(ofExecutableAt: executable, timeout: 20)
        }
    }

    @Test
    func versionTimesOutOnAnExecutableThatDoesNotAnswer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }
        let executable = try makeScript("exec sleep 30", in: directory)

        await #expect(throws: ZenCRONInstallation.VersionError.timedOut(seconds: 1)) {
            try await ZenCRONInstallation.version(ofExecutableAt: executable, timeout: 0.5)
        }
    }

    @Test
    func versionFailsWhenTheExecutableCannotBeLaunched() async throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        do {
            _ = try await ZenCRONInstallation.version(
                ofExecutableAt: directory.appendingPathComponent("missing"),
                timeout: 20
            )
            Issue.record("expected the missing executable to fail")
        } catch let error as ZenCRONInstallation.VersionError {
            guard case .launchFailed = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(error.localizedDescription.hasPrefix("it could not be launched: "))
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

    @Test
    func checkedInstalledExecutableRefusesAFileThatIsNotExecutable() async throws {
        let support = try makeTemporaryDirectory()
        defer { remove(support) }
        let url = try installScript("printf 'ZenCRON 1\\n'", in: support)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        await #expect(
            throws: ZenCrontabError.zenCRONDoesNotStart(path: url.path, reason: "it is not executable")
        ) {
            try await ZenCRONInstallation.checkedInstalledExecutable(supportDirectory: support, timeout: 20)
        }
    }

    @Test
    func checkedInstalledExecutableRefusesAHostThatDoesNotReportItsVersion() async throws {
        let support = try makeTemporaryDirectory()
        defer { remove(support) }
        let url = try installScript("exit 1", in: support)

        await #expect(
            throws: ZenCrontabError.zenCRONDoesNotStart(path: url.path, reason: "it exited with status 1")
        ) {
            try await ZenCRONInstallation.checkedInstalledExecutable(supportDirectory: support, timeout: 20)
        }
    }

    // MARK: - Replacement policy

    @Test
    func macOSKeepsTheInstalledHostOfTheSameVersion() {
        #expect(
            ZenCRONInstallation.decision(
                installedVersion: "ZenCRON 1", builtVersion: "ZenCRON 1", platform: .macOS
            ) == .keep
        )
    }

    @Test(arguments: [
        ("ZenCRON 1", "ZenCRON 2"),
        ("ZenCRON 2", "ZenCRON 1"),
        ("ZenCRON 1", "ZenCRON 10")
    ])
    func macOSReplacesTheInstalledHostOfADifferentVersion(installed: String, built: String) {
        #expect(
            ZenCRONInstallation.decision(installedVersion: installed, builtVersion: built, platform: .macOS)
                == .install
        )
    }

    @Test
    func macOSInstallsWhenThereIsNoReadableInstalledVersion() {
        #expect(
            ZenCRONInstallation.decision(installedVersion: nil, builtVersion: "ZenCRON 1", platform: .macOS)
                == .install
        )
    }

    @Test(arguments: [
        ("ZenCRON 1", "ZenCRON 1"),
        ("ZenCRON 1", "ZenCRON 2"),
        (nil, "ZenCRON 1")
    ] as [(String?, String)])
    func linuxAlwaysReplacesTheInstalledHost(installed: String?, built: String) {
        #expect(
            ZenCRONInstallation.decision(installedVersion: installed, builtVersion: built, platform: .linux)
                == .install
        )
    }

    @Test
    func theCurrentPlatformIsTheOneTheCodeRunsOn() {
        #if os(macOS)
        #expect(ZenCRONInstallation.Platform.current == .macOS)
        #else
        #expect(ZenCRONInstallation.Platform.current == .linux)
        #endif
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
    func installLeavesNoTemporaryFileInTheBinDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let built = try writeFile("one", named: "built", in: root)

        let target = try ZenCRONInstallation.install(builtExecutable: built, supportDirectory: root)

        let entries = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        #expect(entries == ["ZenCRON"])
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
    func installKeepsTheModeOfAnExistingBinDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let built = try writeFile("x", named: "built", in: root)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        try ZenCRONInstallation.install(builtExecutable: built, supportDirectory: root)

        #expect(try permissions(of: bin) == 0o700)
    }

    @Test
    func installCopiesTheFileASymbolicLinkPointsTo() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let real = try writeFile("real bytes", named: "arm64-release-ZenCRON", in: root)
        let link = root.appendingPathComponent("ZenCRON-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let target = try ZenCRONInstallation.install(builtExecutable: link, supportDirectory: root)

        let type = try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(try String(contentsOf: target, encoding: .utf8) == "real bytes")
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

    @Test
    func aTargetThatCannotBeReplacedReportsItsPathAndCleansUp() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let built = try writeFile("x", named: "built", in: root)
        // A non-empty directory where the executable should be: rename fails.
        let target = ZenCRONInstallation.installedExecutableURL(supportDirectory: root)
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("inside"),
            withIntermediateDirectories: true
        )

        do {
            try ZenCRONInstallation.install(builtExecutable: built, supportDirectory: root)
            Issue.record("expected the installation to fail")
        } catch let error as ZenCRONInstallation.InstallError {
            guard case let .failed(path, reason) = error else { return }
            #expect(path == target.path)
            #expect(!reason.isEmpty)
            #expect(error.localizedDescription.hasPrefix("Could not install ZenCRON at \(target.path): "))
        }
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
