//
//  FeatureProcessResult.swift
//  ZenCODE
//

import Foundation

public struct FeatureProcessResult: Sendable {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data
    public let timedOut: Bool
    public let stdoutWasTruncated: Bool
    public let stderrWasTruncated: Bool

    public init(
        exitCode: Int32,
        stdoutData: Data,
        stderrData: Data,
        timedOut: Bool,
        stdoutWasTruncated: Bool,
        stderrWasTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.timedOut = timedOut
        self.stdoutWasTruncated = stdoutWasTruncated
        self.stderrWasTruncated = stderrWasTruncated
    }

    public var stdout: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    public var stderr: String {
        String(decoding: stderrData, as: UTF8.self)
    }

    /// Canonical textual rendering of a finished process: an `exit_code` line,
    /// an optional `timed_out` marker, and non-empty `stdout`/`stderr` sections,
    /// falling back to `<no output>` when only the exit code is present. Shared
    /// so Git, local-exec, and other feature tools present process results
    /// identically instead of each re-deriving this format.
    public var renderedProcessOutput: String {
        let renderedStdout = stdoutWasTruncated
            ? "[stdout exceeded its safety limit; output was truncated and the producer was stopped if still running.]\n" + stdout
            : stdout
        let renderedStderr = stderrWasTruncated
            ? "[stderr exceeded its safety limit; output was truncated and the producer was stopped if still running.]\n" + stderr
            : stderr
        return FeatureProcessOutputRenderer.render(
            exitCode: exitCode,
            stdout: renderedStdout,
            stderr: renderedStderr,
            timedOut: timedOut
        )
    }
}
