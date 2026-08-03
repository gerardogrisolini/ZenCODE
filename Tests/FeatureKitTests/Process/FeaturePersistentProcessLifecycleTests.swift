//
//  FeaturePersistentProcessLifecycleTests.swift
//  ZenCODE
//

import FeatureKit
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FeaturePersistentProcessLifecycleTests {
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
