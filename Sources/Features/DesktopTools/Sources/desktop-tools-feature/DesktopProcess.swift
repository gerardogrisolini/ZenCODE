import FeatureKit
import Foundation

/// Desktop-owned limits atop the shared pipe-draining, cancellable child runner.
enum DesktopProcess {
    static func run(executableURL: URL, arguments: [String], timeout: TimeInterval = 30,
                    maximumOutputBytes: Int = 1_048_576) async throws -> FeatureProcessResult {
        guard timeout.isFinite, timeout > 0 else {
            throw DesktopControlError.processFailed("The child process deadline has expired.")
        }
        let result = try await FeatureProcessRunner.run(
            executableURL: executableURL, arguments: arguments, timeout: timeout,
            maximumOutputBytesPerStream: maximumOutputBytes
        )
        try validate(result)
        return result
    }

    static func validate(_ result: FeatureProcessResult) throws {
        guard !result.timedOut else {
            throw DesktopControlError.processFailed("The desktop child process exceeded its deadline.")
        }
        guard !result.stdoutWasTruncated, !result.stderrWasTruncated else {
            throw DesktopControlError.processFailed("The desktop child process exceeded its output limit.")
        }
    }
}
