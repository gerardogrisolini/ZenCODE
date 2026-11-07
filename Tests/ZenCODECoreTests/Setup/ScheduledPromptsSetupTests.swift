//
//  ScheduledPromptsSetupTests.swift
//  ZenCODECoreTests
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// The "Scheduled prompts (ZenCRON)" setup section. The build and the process
/// execution are replaced by fakes: no test runs `swift build`, starts a real
/// ZenCRON or touches the real support directory.
@Suite("Scheduled prompts setup")
struct ScheduledPromptsSetupTests {
    private typealias Runner = ZenCODESetupRunner
    private typealias Status = ZenCODESetupRunner.ZenCRONSetupStatus
    private typealias Outcome = ZenCODESetupRunner.ZenCRONSetupOutcome

    // MARK: - Section metadata

    @Test(arguments: ["scheduled prompts", "scheduled", "cron", "zencron", "crontab"])
    func theSectionAnswersToItsAliases(alias: String) {
        #expect(SetupSection.scheduledPrompts.matches(alias))
    }

    // MARK: - Menu

    @Test
    func theDefaultStatusOnlyChecksTheFileSystem() throws {
        let support = try makeTemporaryDirectory()
        defer { remove(support) }

        #expect(Status.fileCheck(supportDirectory: support) == Status(
            path: ZenCRONInstallation.installedExecutableURL(supportDirectory: support).path,
            state: .notInstalled
        ))

        try install(bytes: "x", in: support)
        #expect(Status.fileCheck(supportDirectory: support).state == .installedUnchecked)
    }

    // MARK: - Status with a version

    @Test
    func loadReadsTheVersionOfAnInstalledHost() async throws {
        let support = try makeTemporaryDirectory()
        defer { remove(support) }
        try install(bytes: "version=ZenCRON 5", in: support)
        let reads = Recorder()

        let status = await Status.load(supportDirectory: support) { url in
            reads.record(url.path)
            return "ZenCRON 5"
        }

        #expect(status.state == .installed(version: "ZenCRON 5"))
        #expect(status.summary == "ZenCRON: ZenCRON 5 installed at \(status.path)")
        #expect(reads.values == [status.path])
    }

    // MARK: - Build and install

    @Test
    func aMissingCheckoutIsReportedWithoutBuilding() async throws {
        let fixture = try Fixture(checkout: .missing)
        defer { fixture.cleanUp() }

        let outcome = await fixture.run(.macOS)

        #expect(outcome == .sourceMissing(detail: "no ZenCODE source checkout was found"))
        #expect(
            outcome.message == "ZenCRON cannot be built: no ZenCODE source checkout was found. "
                + "Building it needs a ZenCODE source checkout and a Swift toolchain, as for the optional features."
        )
        #expect(fixture.recorder.builds.isEmpty)
        #expect(fixture.installedBytes == nil)
    }

    @Test
    func aFailedBuildReportsTheUsefulOutputAndInstallsNothing() async throws {
        let stderr = (1...60).map { "error line \($0)" }.joined(separator: "\n") + "\n"
        let fixture = try Fixture(build: .exits(1, stderr: stderr))
        defer { fixture.cleanUp() }

        let outcome = await fixture.run(.macOS)

        guard case let .buildFailed(summary, output) = outcome else {
            Issue.record("expected a build failure, got \(outcome)")
            return
        }
        #expect(summary == "swift build exited with status 1.")
        #expect(output.hasPrefix("error line 21\n"))
        #expect(output.hasSuffix("error line 60"))
        #expect(outcome.message == "ZenCRON could not be built: swift build exited with status 1.\n\(output)")
        #expect(fixture.installedBytes == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.binDirectory.path))
    }

    @Test
    func aFirstInstallationInstallsTheHost() async throws {
        let fixture = try Fixture(build: .succeeds(version: "ZenCRON 1", label: "first"))
        defer { fixture.cleanUp() }

        let outcome = await fixture.run(.macOS)

        #expect(outcome == .installed(path: fixture.installedPath, version: "ZenCRON 1"))
        #expect(outcome.message == "Installed ZenCRON 1 at \(fixture.installedPath).")
        #expect(fixture.installedLabel == "first")
        #expect(FileManager.default.isExecutableFile(atPath: fixture.installedPath))
        // The version of the installed host is not even asked: nothing was there.
        #expect(fixture.recorder.versionReads == [fixture.builtPath])
    }

    @Test
    func macOSKeepsTheInstalledHostOfTheSameVersion() async throws {
        let fixture = try Fixture(build: .succeeds(version: "ZenCRON 1", label: "rebuilt"))
        defer { fixture.cleanUp() }
        try fixture.install(label: "original", version: "ZenCRON 1")

        let outcome = await fixture.run(.macOS)

        #expect(outcome == .kept(path: fixture.installedPath, version: "ZenCRON 1"))
        #expect(
            outcome.message == "ZenCRON 1 is already installed at \(fixture.installedPath); "
                + "it was kept so that macOS keeps the privacy permissions of scheduled prompts."
        )
        // Untouched: the same bytes, not the rebuilt ones.
        #expect(fixture.installedLabel == "original")
        #expect(fixture.recorder.versionReads == [fixture.builtPath, fixture.installedPath])
    }

    @Test
    func macOSReplacesTheInstalledHostOfADifferentVersion() async throws {
        let fixture = try Fixture(build: .succeeds(version: "ZenCRON 2", label: "newer"))
        defer { fixture.cleanUp() }
        try fixture.install(label: "older", version: "ZenCRON 1")

        let outcome = await fixture.run(.macOS)

        #expect(outcome == .replaced(path: fixture.installedPath, version: "ZenCRON 2"))
        #expect(outcome.message == "Replaced ZenCRON at \(fixture.installedPath) with ZenCRON 2.")
        #expect(fixture.installedLabel == "newer")
    }

    @Test
    func linuxAlwaysReplacesTheInstalledHostEvenOfTheSameVersion() async throws {
        let fixture = try Fixture(build: .succeeds(version: "ZenCRON 1", label: "rebuilt"))
        defer { fixture.cleanUp() }
        try fixture.install(label: "original", version: "ZenCRON 1")

        let outcome = await fixture.run(.linux)

        #expect(outcome == .replaced(path: fixture.installedPath, version: "ZenCRON 1"))
        #expect(outcome.message == "Replaced ZenCRON at \(fixture.installedPath) with ZenCRON 1.")
        #expect(fixture.installedLabel == "rebuilt")
        // Linux does not compare versions, so the old host is never started.
        #expect(fixture.recorder.versionReads == [fixture.builtPath])
    }

    @Test
    func aFailedInstallationLeavesTheInstalledHostAndSaysSo() async throws {
        let fixture = try Fixture(build: .succeeds(version: "ZenCRON 2", label: "newer"))
        defer { fixture.cleanUp() }
        // A non-empty directory where the executable goes: it cannot be replaced.
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: fixture.installedPath).appendingPathComponent("inside"),
            withIntermediateDirectories: true
        )

        let outcome = await fixture.run(.linux)

        guard case let .installFailed(message) = outcome else {
            Issue.record("expected an installation failure, got \(outcome)")
            return
        }
        #expect(message.hasPrefix("Could not install ZenCRON at \(fixture.installedPath): "))
        #expect(outcome.message == message)
    }

    // MARK: - The section itself

    @Test
    func escLeavesTheSectionWithoutDoingAnything() async throws {
        let fixture = try Fixture(build: .succeeds(version: "ZenCRON 1", label: "first"))
        defer { fixture.cleanUp() }
        let output = Recorder()

        await Runner.configureScheduledPrompts(
            tools: fixture.tools(.macOS),
            supportDirectory: fixture.support,
            write: { output.record($0) },
            selectOne: { _, _, _ in nil }
        )

        #expect(fixture.recorder.builds.isEmpty)
        #expect(fixture.installedBytes == nil)
        #expect(output.values.joined().contains("ZenCRON: not installed (expected at \(fixture.installedPath))"))
    }

    @Test
    func choosingBuildShowsTheStatusTheProgressAndTheFinalMessage() async throws {
        let fixture = try Fixture(build: .succeeds(version: "ZenCRON 1", label: "first"))
        defer { fixture.cleanUp() }
        let output = Recorder()
        let menus = Recorder()

        await Runner.configureScheduledPrompts(
            tools: fixture.tools(.macOS),
            supportDirectory: fixture.support,
            write: { output.record($0) },
            selectOne: { title, items, selected in
                menus.record("\(title)|\(items.map(\.title).joined(separator: ","))|\(selected)")
                return .build
            }
        )

        let text = output.values.joined()
        #expect(menus.values == ["Scheduled prompts (ZenCRON)|Build and install ZenCRON,Back|build"])
        #expect(text.contains("Scheduled prompts (ZenCRON)"))
        #expect(text.contains("ZenCRON: not installed (expected at \(fixture.installedPath))"))
        #expect(text.contains("  • Resolving ZenCODE source checkout…\n"))
        #expect(text.hasSuffix("Installed ZenCRON 1 at \(fixture.installedPath).\n"))
        #expect(fixture.installedLabel == "first")
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCRON-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// An executable file where the section looks for ZenCRON.
    private func install(bytes: String, in support: URL) throws {
        let url = ZenCRONInstallation.installedExecutableURL(supportDirectory: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// Thread-safe list of recorded strings.
private final class Recorder: Sendable {
    private struct State {
        var values: [String] = []
        var builds: [String] = []
        var timeouts: [TimeInterval] = []
        var versionReads: [String] = []
        var progress: [String] = []
    }

    private let state = Mutex(State())

    func record(_ value: String) { state.withLock { $0.values.append(value) } }
    func recordBuild(_ path: String, timeout: TimeInterval) {
        state.withLock {
            $0.builds.append(path)
            $0.timeouts.append(timeout)
        }
    }
    func recordVersionRead(_ path: String) { state.withLock { $0.versionReads.append(path) } }
    func recordProgress(_ line: String) { state.withLock { $0.progress.append(line) } }

    var values: [String] { state.withLock { $0.values } }
    var builds: [String] { state.withLock { $0.builds } }
    var timeouts: [TimeInterval] { state.withLock { $0.timeouts } }
    var versionReads: [String] { state.withLock { $0.versionReads } }
    var progress: [String] { state.withLock { $0.progress } }
}

/// A checkout, a support directory and fake tools, all in one temporary
/// directory. The fake build writes a small file as the "executable":
///
///     binary <label>
///     version=<version>
///
/// and the fake version reader parses the `version=` line, so no process runs.
private struct Fixture {
    enum Checkout {
        case valid
        case withoutPackage
        case missing
    }

    enum Build: Sendable {
        case succeeds(version: String, label: String)
        case exits(Int32, stderr: String)
        case timesOut
        case throwsError(String)
        case succeedsWithoutExecutable
    }

    struct FakeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let root: URL
    let support: URL
    let checkoutURL: URL
    let checkout: Checkout
    let build: Build
    let recorder = Recorder()

    init(
        checkout: Checkout = .valid,
        build: Build = .succeeds(version: "ZenCRON 1", label: "build")
    ) throws {
        self.checkout = checkout
        self.build = build
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCRON-setup-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        checkoutURL = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkoutURL, withIntermediateDirectories: true)
        try Data("// root".utf8).write(to: checkoutURL.appendingPathComponent("Package.swift"))
        if checkout == .valid {
            try write("// zencron manifest", at: "Package.swift", in: sourcePackage)
            try write("print(1)", at: "Sources/ZenCRON/main.swift", in: sourcePackage)
            try write("// obsolete", at: "Sources/ZenCRON/Obsolete.swift", in: sourcePackage)
            try write("// tests", at: "Tests/ZenCRONTests/Tests.swift", in: sourcePackage)
            // Build state of the checkout itself must never reach the copy.
            try write("stale", at: ".build/stale", in: sourcePackage)
        }
    }

    var sourcePackage: URL {
        checkoutURL.appendingPathComponent(ZenCRONInstallation.packageRelativePath, isDirectory: true)
    }
    var workingCopy: URL { ZenCRONInstallation.workingCopyURL(supportDirectory: support) }
    var binDirectory: URL { ZenCRONInstallation.installedExecutableURL(supportDirectory: support).deletingLastPathComponent() }
    var installedPath: String { ZenCRONInstallation.installedExecutableURL(supportDirectory: support).path }
    var builtPath: String { ZenCRONInstallation.builtExecutableURL(packageDirectory: workingCopy).path }

    var installedBytes: String? {
        try? String(contentsOfFile: installedPath, encoding: .utf8)
    }

    /// The `<label>` of the installed fake executable.
    var installedLabel: String? {
        installedBytes?.components(separatedBy: "\n").first?.replacingOccurrences(of: "binary ", with: "")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// An executable already installed, as a previous run would have left it.
    func install(label: String, version: String) throws {
        let url = ZenCRONInstallation.installedExecutableURL(supportDirectory: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.contents(label: label, version: version).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func run(
        _ platform: ZenCRONInstallation.Platform,
        buildTimeout: TimeInterval = SwiftFeatureRuntime.defaultOptionalFeatureInstallTimeoutSeconds
    ) async -> ZenCODESetupRunner.ZenCRONSetupOutcome {
        let recorder = recorder
        return await ZenCODESetupRunner.buildAndInstallZenCRON(
            tools: tools(platform),
            supportDirectory: support,
            buildTimeout: buildTimeout,
            progress: { recorder.recordProgress($0) }
        )
    }

    func tools(_ platform: ZenCRONInstallation.Platform) -> ZenCODESetupRunner.ZenCRONSetupTools {
        let recorder = recorder
        let checkout = checkout
        let checkoutURL = checkoutURL
        let build = build
        return ZenCODESetupRunner.ZenCRONSetupTools(
            checkoutURL: {
                guard checkout != .missing else { throw FakeError(message: "no checkout") }
                return checkoutURL
            },
            build: { package, timeout, progress in
                recorder.recordBuild(package.path, timeout: timeout)
                progress("fake build output")
                switch build {
                case let .exits(status, stderr):
                    return ZenCODESetupRunner.ZenCRONBuildResult(
                        exitCode: status, timedOut: false, stdout: "", stderr: stderr
                    )
                case .timesOut:
                    return ZenCODESetupRunner.ZenCRONBuildResult(
                        exitCode: -1, timedOut: true, stdout: "", stderr: ""
                    )
                case let .throwsError(message):
                    throw FakeError(message: message)
                case .succeedsWithoutExecutable:
                    break
                case let .succeeds(version, label):
                    let built = ZenCRONInstallation.builtExecutableURL(packageDirectory: package)
                    try FileManager.default.createDirectory(
                        at: built.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data(Self.contents(label: label, version: version).utf8).write(to: built)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: built.path)
                }
                // One artefact per build, to see what survives from one to the next.
                let number = recorder.builds.count
                let buildDirectory = package.appendingPathComponent(".build", isDirectory: true)
                try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
                try Data().write(to: buildDirectory.appendingPathComponent("build-\(number)"))
                return ZenCODESetupRunner.ZenCRONBuildResult(exitCode: 0, timedOut: false, stdout: "", stderr: "")
            },
            readVersion: { url in
                recorder.recordVersionRead(url.path)
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let line = text.components(separatedBy: "\n").first { $0.hasPrefix("version=") }
                guard let version = line?.dropFirst("version=".count), version != "unreadable" else {
                    throw ZenCRONInstallation.VersionError.noOutput
                }
                return String(version)
            },
            platform: platform
        )
    }

    private static func contents(label: String, version: String) -> String {
        "binary \(label)\nversion=\(version)\n"
    }

    private func write(_ contents: String, at relativePath: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
}
