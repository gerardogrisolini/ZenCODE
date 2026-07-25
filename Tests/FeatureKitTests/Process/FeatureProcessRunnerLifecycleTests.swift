//
//  FeatureProcessRunnerLifecycleTests.swift
//  ZenCODE
//

import Foundation
import FeatureKit
import Testing

/// Lifecycle coverage for `FeatureProcessRunner`: timeout escalation against a
/// SIGTERM-ignoring child, cancellation, large stdin/stdout payloads, and the
/// line-limit truncation path. Each test bounds itself with a deadline so a
/// regression fails instead of hanging the suite.
@Suite(.timeLimit(.minutes(1)))
struct FeatureProcessRunnerLifecycleTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    @Test
    func timeoutEscalatesToKillWhenTheChildIgnoresSIGTERM() async throws {
        let result = try await FeatureProcessRunner.run(
            executableURL: Self.shell,
            arguments: ["-c", "trap '' TERM; sleep 30"],
            timeout: 0.3
        )

        #expect(result.timedOut)
        // The escalation must reap the child; a poisoned waiter used to return
        // here with the process still alive.
        #expect(result.exitCode != 0)
    }

    @Test
    func timeoutIsNotReportedWhenTheChildExitsFirst() async throws {
        let result = try await FeatureProcessRunner.run(
            executableURL: Self.shell,
            arguments: ["-c", "printf 'done'"],
            timeout: 30
        )

        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "done")
    }

    @Test
    func cancellationStopsAChildThatIgnoresSIGTERM() async throws {
        // The child announces readiness through a marker file once its SIGTERM
        // trap is installed, so cancellation happens deterministically after the
        // trap is in place instead of racing on a fixed sleep.
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode_feature_process_cancel_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let markerPath = marker.path

        let task = Task {
            try await FeatureProcessRunner.run(
                executableURL: Self.shell,
                arguments: ["-c", "trap '' TERM; touch \"\(markerPath)\"; sleep 30"]
            )
        }

        // Deterministic readiness: poll the marker until it appears, bounded so
        // a failure still terminates instead of hanging.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline,
              !FileManager.default.fileExists(atPath: markerPath) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled process run to throw.")
        } catch is CancellationError {
            // Expected: cancellation escalates to SIGKILL and returns promptly.
        } catch {
            Issue.record("Unexpected error for a cancelled process run: \(error)")
        }
    }

    @Test
    func largeStdinIsWrittenWhileStdoutIsDrained() async throws {
        // Far larger than a 64 KiB pipe buffer in both directions, so a
        // blocking writer or a serialized reader would deadlock.
        let line = String(repeating: "z", count: 512) + "\n"
        let payload = String(repeating: line, count: 2_000)

        let result = try await FeatureProcessRunner.run(
            executableURL: Self.shell,
            arguments: ["-c", "cat"],
            stdinData: Data(payload.utf8),
            timeout: 30
        )

        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(result.stdoutData.count == payload.utf8.count)
    }

    @Test(.timeLimit(.minutes(1)))
    func stdoutLineLimitEscalatesAndReapsSIGTERMIgnoringChildWithoutTimeout() async throws {
        let result = try await FeatureProcessRunner.run(
            executableURL: Self.shell,
            arguments: ["-c", "trap '' TERM; while :; do printf 'line\\n'; done"],
            stdoutLineLimit: 5
        )

        #expect(result.stdoutWasTruncated)
        // The child ignores the initial SIGTERM. Returning with a non-zero
        // status proves the supervisor reached SIGKILL and reaped it instead of
        // leaving a no-timeout run suspended after stdout truncation.
        #expect(result.exitCode != 0)
        #expect(!result.timedOut)
    }

    @Test
    func stderrIsCapturedAlongsideTheExitCode() async throws {
        let result = try await FeatureProcessRunner.run(
            executableURL: Self.shell,
            arguments: ["-c", "printf 'oops' 1>&2; exit 3"],
            timeout: 30
        )

        #expect(result.exitCode == 3)
        #expect(result.stderr == "oops")
        #expect(!result.timedOut)
    }

    @Test
    func writingToAChildThatNeverReadsStdinStillCompletes() async throws {
        // The child exits without consuming stdin: the writer must observe
        // EPIPE/back-pressure and return instead of blocking forever, and
        // SIGPIPE must not take ZenCODE down.
        let payload = Data(String(repeating: "q", count: 1_000_000).utf8)

        let result = try await FeatureProcessRunner.run(
            executableURL: Self.shell,
            arguments: ["-c", "exit 0"],
            stdinData: payload,
            timeout: 30
        )

        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
    }
}
