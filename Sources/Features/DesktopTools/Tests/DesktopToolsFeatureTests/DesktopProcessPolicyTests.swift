import FeatureKit
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopProcessPolicyTests {
    @Test(arguments: [true, false])
    func zeroLaunchTimeoutObservesOnceWithBoundedChildAndNeverSleeps(_ initiallyReady: Bool) async throws {
        var observations = 0
        var childTimeouts: [TimeInterval] = []
        var sleeps: [TimeInterval] = []
        let ready = try await DesktopProbePolicy.waitForLaunch(
            timeout: 0,
            observe: { timeout in
                observations += 1
                childTimeouts.append(timeout)
                // A retry would incorrectly turn the not-ready case into success.
                return initiallyReady || observations > 1
            },
            sleep: { sleeps.append($0) }
        )
        #expect(ready == initiallyReady)
        #expect(observations == 1)
        #expect(childTimeouts == [2])
        #expect(sleeps.isEmpty)
    }

    @Test
    func zeroLaunchTimeoutPropagatesFreshProbeFailureWithoutRetry() async {
        var observations = 0
        var sleeps = 0
        await #expect(throws: DesktopControlError.self) {
            _ = try await DesktopProbePolicy.waitForLaunch(
                timeout: 0,
                observe: { timeout in
                    observations += 1
                    #expect(timeout == 2)
                    throw DesktopControlError.processFailed("Injected one-shot probe failure")
                },
                sleep: { _ in sleeps += 1 }
            )
        }
        #expect(observations == 1)
        #expect(sleeps == 0)
    }

    @Test
    func positiveLaunchTimeoutUsesRemainingBudgetRatherThanZeroTimeoutAllowance() async throws {
        var childTimeouts: [TimeInterval] = []
        var sleeps = 0
        let ready = try await DesktopProbePolicy.waitForLaunch(
            timeout: 1,
            observe: { timeout in
                childTimeouts.append(timeout)
                return true
            },
            sleep: { _ in sleeps += 1 }
        )
        #expect(ready)
        #expect(childTimeouts.count == 1)
        #expect(childTimeouts.allSatisfy { $0 > 0 && $0 <= 1 })
        #expect(sleeps == 0)
    }

    @Test
    func validDeadlineRunsHarmlessChildThroughSharedRunner() async throws {
        let result = try await DesktopProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["desktop-runner-smoke\\n"], timeout: 2,
            maximumOutputBytes: 1_024
        )
        #expect(result.exitCode == 0)
        #expect(result.stdoutData == Data("desktop-runner-smoke\n".utf8))
        #expect(result.stderrData.isEmpty)
        #expect(!result.timedOut)
        #expect(!result.stdoutWasTruncated)
        #expect(!result.stderrWasTruncated)
    }

    @Test
    func retryBackoffIsBoundedAndReducesFreshProbeCount() {
        let delays = (0..<8).map { DesktopProbePolicy.retryDelay(attempt: $0, remaining: 10) }
        #expect(delays == [0.1, 0.2, 0.4, 0.5, 0.5, 0.5, 0.5, 0.5])
        // Simulate instantaneous one-shot snapshots: this is the maximum count,
        // since real child startup/exit also consumes the same outer deadline.
        var remaining = 2.0
        var attempts = 0
        while DesktopProbePolicy.childTimeout(remaining: remaining) != nil {
            remaining -= DesktopProbePolicy.retryDelay(attempt: attempts, remaining: remaining)
            attempts += 1
        }
        #expect(attempts == 6)
        #expect(attempts < 40) // previous 50ms polling over two seconds
    }

    @Test
    func retryAndChildDeadlinesAreClippedToRemainingBudget() {
        #expect(DesktopProbePolicy.retryDelay(attempt: 30, remaining: 0.03) == 0.03)
        #expect(DesktopProbePolicy.childTimeout(remaining: 30) == 2)
        #expect(DesktopProbePolicy.childTimeout(remaining: 0.03) == 0.03)
        #expect(DesktopProbePolicy.retryDelay(attempt: Int.max, remaining: 2) == 0.5)
        #expect(DesktopProbePolicy.retryDelay(attempt: -1, remaining: 2) == 0.1)
    }

    @Test(arguments: [0.0, -1, Double.nan, Double.infinity])
    func expiredOrInvalidBudgetCannotStartAnotherProbe(_ remaining: Double) {
        #expect(DesktopProbePolicy.childTimeout(remaining: remaining) == nil)
        #expect(DesktopProbePolicy.retryDelay(attempt: 0, remaining: remaining) == 0)
    }

    @Test
    func timeoutAndEitherTruncatedPipeFailClosed() {
        for flags in [(true, false, false), (false, true, false), (false, false, true)] {
            let result = FeatureProcessResult(
                exitCode: 0, stdoutData: Data("{}".utf8), stderrData: Data(),
                timedOut: flags.0, stdoutWasTruncated: flags.1, stderrWasTruncated: flags.2
            )
            #expect(throws: DesktopControlError.self) { try DesktopProcess.validate(result) }
        }
    }

    @Test
    func completeNonzeroResultRemainsAvailableForCallerDiagnostics() throws {
        let result = FeatureProcessResult(
            exitCode: 7, stdoutData: Data(), stderrData: Data("failure detail".utf8),
            timedOut: false, stdoutWasTruncated: false
        )
        try DesktopProcess.validate(result)
        #expect(result.exitCode == 7)
        #expect(result.stderr == "failure detail")
    }

    @Test(arguments: [0.0, -1, Double.nan, Double.infinity])
    func invalidDeadlineIsRejectedBeforeAnyChildLaunch(_ timeout: Double) async {
        await #expect(throws: DesktopControlError.self) {
            _ = try await DesktopProcess.run(
                executableURL: URL(fileURLWithPath: "/never-launch-this-test-path"),
                arguments: [], timeout: timeout
            )
        }
    }
}
