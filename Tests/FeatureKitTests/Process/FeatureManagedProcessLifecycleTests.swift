//
//  FeatureManagedProcessLifecycleTests.swift
//  ZenCODE
//

import FeatureKit
import Foundation
import Testing

#if os(macOS) || os(Linux)
#if os(Linux)
import Glibc
#endif

/// Focused lifecycle coverage for the generic resident process owner. Fixtures
/// are ordinary executable files so the API's direct argv path is exercised
/// without having FeatureManagedProcess construct or invoke a shell.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FeatureManagedProcessLifecycleTests {
    // Repeated short-lived launches exercise the race between an empty pipe
    // read, the child's final writes, and publication of its natural exit.
    @Test(arguments: 0 ..< 64)
    func directArgvLaunchesAndPublishesNaturalExitAndOutput(_ iteration: Int) async throws {
        let fixture = try Self.makeFixture(
            name: "argv-\(iteration)",
            body: "#!/bin/sh\nprintf '%s' \"$1\"\nprintf 'diagnostic' 1>&2\nexit 7\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let process = FeatureManagedProcess(
            executableURL: fixture.executable,
            arguments: ["value with spaces"]
        )
        try await process.start()
        let exit = await process.waitUntilExit()

        #expect(exit.exitCode == 7)
        #expect(exit.stdout == "value with spaces")
        #expect(exit.stderr == "diagnostic")
        #expect(!exit.wasTerminated)
        #expect(exit.wasStarted)
        #expect(await process.processIdentifier == nil)
        #expect(!(await process.isRunning))
    }

    @Test
    func missingProcessSurfacesLaunchFailureAndLeavesLifecycleReusableForInspection() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-managed-missing-\(UUID().uuidString)")
        let process = FeatureManagedProcess(executableURL: missing)

        await #expect(throws: (any Error).self) {
            try await process.start()
        }
        #expect(!(await process.hasStarted))
        #expect(!(await process.isRunning))
        #expect(await process.processIdentifier == nil)
        #expect((await process.waitUntilExit()).wasStarted == false)
        await process.stop()
    }

    @Test
    func boundedReadersRetainAtMostTheConfiguredTailAndStopAProducerIgnoringTerm() async throws {
        let fixture = try Self.makeFixture(
            name: "output",
            body: "#!/bin/sh\ntouch \"$1\"\ntrap '' TERM\nwhile :; do printf '%4096s' x; printf '%4096s' e 1>&2; done\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let process = FeatureManagedProcess(
            executableURL: fixture.executable,
            arguments: [fixture.root.appendingPathComponent("started").path],
            maximumOutputBytesPerStream: 4 * 1_024,
            terminationGracePeriod: 0.05
        )
        try await process.start()
        try await Self.waitForFile(fixture.root.appendingPathComponent("started"))
        try await Task.sleep(for: .milliseconds(100))
        let partial = await process.output()
        #expect(await process.isRunning)
        #expect(partial.stdoutData.count > 0)
        #expect(partial.stderrData.count > 0)
        await process.stop()
        let exit = await process.waitUntilExit()

        #expect(exit.stdoutData.count <= 4 * 1_024)
        #expect(exit.stderrData.count <= 4 * 1_024)
        #expect(exit.stdoutWasTruncated)
        #expect(exit.stderrWasTruncated)
        #expect(exit.wasTerminated)
        #expect(exit.exitCode != 0)
        #expect(!(await process.isRunning))
    }

    @Test
    func cancellingExitWaitStopsAResidentChild() async throws {
        let fixture = try Self.makeFixture(
            name: "cancel",
            body: "#!/bin/sh\ntouch \"$1\"\ntrap '' TERM\nprintf ready\nsleep 30\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let process = FeatureManagedProcess(
            executableURL: fixture.executable,
            arguments: [fixture.root.appendingPathComponent("started").path],
            terminationGracePeriod: 0.05
        )
        try await process.start()
        try await Self.waitForFile(fixture.root.appendingPathComponent("started"))
        let waiter = Task {
            await process.waitUntilExit()
        }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        let exit = await waiter.value

        #expect(exit.wasStarted)
        #expect(exit.wasTerminated)
        #expect(!(await process.isRunning))
    }

    @Test
    func releasingTheOwnerDoesNotRetainReaderTasksOrResidentProcess() async throws {
        let fixture = try Self.makeFixture(
            name: "abandoned",
            body: "#!/bin/sh\ntouch \"$1\"\nsleep 30\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let startedMarker = fixture.root.appendingPathComponent("started")

        var process: FeatureManagedProcess? = FeatureManagedProcess(
            executableURL: fixture.executable,
            arguments: [startedMarker.path],
            terminationGracePeriod: 0.05
        )
        try await process?.start()
        try await Self.waitForFile(startedMarker)
        let weakProcess = WeakManagedProcess(process)
        process = nil

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while weakProcess.value != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakProcess.value == nil)
    }

    private static func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: url.path))
    }

    private static func makeFixture(
        name: String,
        body: String
    ) throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-managed-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fixture")
        try body.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return (root, executable)
    }
}

private final class WeakManagedProcess: @unchecked Sendable {
    weak var value: FeatureManagedProcess?

    init(_ value: FeatureManagedProcess?) {
        self.value = value
    }
}
#endif
