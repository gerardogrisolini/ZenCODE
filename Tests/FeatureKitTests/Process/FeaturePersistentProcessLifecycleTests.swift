//
//  FeaturePersistentProcessLifecycleTests.swift
//  ZenCODE
//

import FeatureKit
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FeaturePersistentProcessLifecycleTests {
    /// Echo fixture: answers every framed request with the same response id.
    private static func makeFixture() throws -> (root: URL, executable: URL) {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "feature-persistent-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let executableURL = rootURL.appendingPathComponent("fixture-feature")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"\\]*\\)".*/\\1/p')
          printf '{"id":"%s","responseData":"b2s="}\n' "$request_id"
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return (rootURL, executableURL)
    }

    @Test
    func repeatedShutdownIsIdempotentAndTerminatesTheChild() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let session = FeaturePersistentProcess(
            executableURL: fixture.executable,
            workingDirectory: fixture.root
        )
        let response = try await session.response(
            to: FeaturePersistentRequest(operation: .listTools),
            timeout: 10
        )
        #expect(response == Data("ok".utf8))
        let processID = await session.processIdentifier
        try #require(processID != nil)

        await session.shutdown()
        // Repeated teardown must return promptly instead of hanging or trapping.
        await session.shutdown()
        await session.shutdown()

        #expect(await session.processIdentifier == nil)

        // Any later request on a closed session fails deterministically rather
        // than silently starting a new child.
        await #expect(throws: FeaturePersistentProcessError.self) {
            _ = try await session.response(
                to: FeaturePersistentRequest(operation: .listTools),
                timeout: 5
            )
        }
    }

    @Test
    func shutdownWithoutAStartedProcessSucceeds() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let session = FeaturePersistentProcess(
            executableURL: fixture.executable,
            workingDirectory: fixture.root
        )
        await session.shutdown()
        await session.shutdown()
        #expect(await session.processIdentifier == nil)
    }

    @Test
    func startupFailureIsReportedAsATransportError() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-feature-\(UUID().uuidString)")
        let session = FeaturePersistentProcess(executableURL: missing)

        await #expect(throws: (any Error).self) {
            _ = try await session.response(
                to: FeaturePersistentRequest(operation: .listTools),
                timeout: 5
            )
        }
        // Teardown after a failed start must still be idempotent.
        await session.shutdown()
        #expect(await session.processIdentifier == nil)
    }

    @Test
    func releasingClientClosesPersistentProcessWithoutExplicitShutdown() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "feature-persistent-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("fixture-feature")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"\\]*\\)".*/\\1/p')
          printf '{"id":"%s","responseData":"b2s="}\n' "$request_id"
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        var process: FeaturePersistentProcess? = FeaturePersistentProcess(
            executableURL: executableURL,
            workingDirectory: rootURL
        )
        let response = try await process?.response(
            to: FeaturePersistentRequest(operation: .listTools),
            timeout: 10
        )
        #expect(response == Data("ok".utf8))

        let weakProcess = WeakPersistentProcess(process)
        process = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while weakProcess.value != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let released = weakProcess.value == nil
        if let leakedProcess = weakProcess.value {
            await leakedProcess.shutdown()
        }
        #expect(released)
    }
}

private final class WeakPersistentProcess: @unchecked Sendable {
    weak var value: FeaturePersistentProcess?

    init(_ value: FeaturePersistentProcess?) {
        self.value = value
    }
}
