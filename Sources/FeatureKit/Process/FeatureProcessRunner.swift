//
//  FeatureProcessRunner.swift
//  ZenCODE
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Synchronization

public enum FeatureProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeout: TimeInterval? = nil,
        stdoutLineLimit: Int? = nil
    ) async throws -> FeatureProcessResult {
        #if os(macOS) || os(Linux)
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = stdinData.map { _ in Pipe() }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        let exitObserver = FeatureProcessExitObserver()
        process.terminationHandler = { _ in
            exitObserver.finish()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }

        // Drain stdout/stderr while writing stdin. Starting all three streams as
        // structured `async let` children guarantees the pipes are drained
        // concurrently with the stdin write, so a payload larger than the OS pipe
        // buffer cannot deadlock the run, and cancellation propagates to every
        // stream together with the exit supervisor below.
        async let stdoutOutcome = readStdout(
            from: stdoutPipe,
            process: process,
            lineLimit: stdoutLineLimit
        )
        async let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        async let stdinOutcome = writeStdin(stdinPipe, data: stdinData)

        let timedOut = await superviseProcessExit(
            process,
            exitObserver: exitObserver,
            timeout: timeout
        )

        process.terminationHandler = nil

        let stdoutResult = await stdoutOutcome
        let stderr = await stderrData
        // Awaited (not fire-and-forget) so the write completes and the pipe is
        // closed before we report a result. The outcome is captured rather than
        // swallowed by `try?`; we intentionally do not throw here to preserve the
        // runner's contract of returning whatever output the process produced.
        _ = await stdinOutcome

        try Task.checkCancellation()

        return FeatureProcessResult(
            exitCode: process.terminationStatus,
            stdoutData: stdoutResult.0,
            stderrData: stderr,
            timedOut: timedOut,
            stdoutWasTruncated: stdoutResult.1
        )
        #else
        _ = executableURL
        _ = arguments
        _ = workingDirectory
        _ = environment
        _ = stdinData
        _ = timeout
        _ = stdoutLineLimit
        throw FeatureProcessRunnerError.unsupportedPlatform
        #endif
    }

    #if os(macOS) || os(Linux)
    private static func readStdout(
        from pipe: Pipe,
        process: Process,
        lineLimit: Int?
    ) -> (Data, Bool) {
        guard let lineLimit, lineLimit > 0 else {
            return (pipe.fileHandleForReading.readDataToEndOfFile(), false)
        }

        var stdoutData = Data()
        var observedLineCount = 0
        var wasTruncated = false

        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                break
            }

            stdoutData.append(chunk)
            observedLineCount += chunk.reduce(into: 0) { partialResult, byte in
                if byte == UInt8(ascii: "\n") {
                    partialResult += 1
                }
            }

            if observedLineCount >= lineLimit {
                wasTruncated = true
                if process.isRunning {
                    process.terminate()
                }
                break
            }
        }

        return (stdoutData, wasTruncated)
    }

    /// Outcome of an attempted stdin write, so the previously fire-and-forget
    /// writer no longer silently drops write/close failures. The payload-free
    /// `.failed` keeps the type `Sendable` (`any Error` itself is not Sendable).
    private enum StdinWriteOutcome: Sendable {
        case nothingToWrite
        case written
        case failed
    }

    /// Writes `data` to the child's stdin and closes the write end, surfacing the
    /// outcome instead of discarding it. Runs as a structured `async let` child
    /// so it is drained concurrently with the stdout/stderr readers.
    private static func writeStdin(
        _ pipe: Pipe?,
        data: Data?
    ) -> StdinWriteOutcome {
        guard let data, let pipe else { return .nothingToWrite }
        let writer = pipe.fileHandleForWriting
        do {
            try writer.write(contentsOf: data)
            try writer.close()
            return .written
        } catch {
            try? writer.close()
            return .failed
        }
    }

    /// Supervises process termination, applying the same `SIGTERM -> grace ->
    /// SIGKILL` escalation to both an optional timeout and cooperative
    /// cancellation. The natural-exit waiter is cancellation-aware, so a timeout
    /// or a parent cancellation can always tear it down and reach the SIGKILL
    /// fallback: a process that ignores SIGTERM can no longer hang the runner.
    private static func superviseProcessExit(
        _ process: Process,
        exitObserver: FeatureProcessExitObserver,
        timeout: TimeInterval?
    ) async -> Bool {
        await withTaskGroup(of: Void.self) { group in
            // Natural exit waiter. `exitObserver.wait()` resumes on process exit
            // OR on cancellation, so this child never stays suspended once the
            // group is asked to stop.
            group.addTask {
                await exitObserver.wait()
            }

            // Escalation trigger: fires when the timeout elapses (if any) or the
            // task is cancelled, whichever happens first.
            group.addTask {
                await waitForTimeoutOrCancellation(timeout)
            }

            // As soon as one condition fires, stop waiting and tear the other
            // child down. The exit waiter is cancellation-aware, so cancelAll()
            // always unblocks it instead of leaving a continuation suspended.
            _ = await group.next()
            group.cancelAll()
        }

        // If the process already terminated, no escalation is needed. Otherwise
        // the trigger (timeout or cancellation) won and we must escalate to reach
        // a guaranteed kill, even for a process that ignores SIGTERM.
        guard exitObserver.hasFinished else {
            return await escalateTermination(process, exitObserver: exitObserver)
        }
        return false
    }

    /// Suspends until `timeout` elapses or the task is cancelled. With no timeout
    /// it suspends until cancellation only: `Task.sleep` is cancellation-aware
    /// and returns by throwing, which `try?` turns into a normal return.
    private static func waitForTimeoutOrCancellation(_ timeout: TimeInterval?) async {
        let nanoseconds: UInt64
        if let timeout, timeout > 0 {
            nanoseconds = UInt64(timeout * 1_000_000_000)
        } else {
            nanoseconds = UInt64.max
        }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    /// `SIGTERM -> grace -> SIGKILL`. Returns `true` to signal that escalation
    /// occurred (reported as a timeout-equivalent outcome).
    private static func escalateTermination(
        _ process: Process,
        exitObserver: FeatureProcessExitObserver
    ) async -> Bool {
        if process.isRunning {
            process.terminate()
        }

        if await waitForExitAfterTermination(exitObserver: exitObserver) {
            return true
        }

        kill(process.processIdentifier, SIGKILL)
        await exitObserver.wait()
        return true
    }

    private static func waitForExitAfterTermination(
        exitObserver: FeatureProcessExitObserver
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exitObserver.wait()
                return true
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }

            let exited = await group.next() ?? false
            group.cancelAll()
            // `wait()` now also resumes on cancellation. Only consider the grace
            // period satisfied when the process genuinely exited; a cancellation
            // that broke the wait must fall through to the SIGKILL fallback.
            return exited && exitObserver.hasFinished
        }
    }
    #endif
}

#if os(macOS) || os(Linux)
/// Cancellation-aware single-shot exit signal for a spawned process.
///
/// `wait()` suspends until either the process terminates (`finish()`) or the
/// awaiting task is cancelled. In both cases the underlying continuation is
/// resumed exactly once, guarded by a `Mutex`, so a process that ignores SIGTERM
/// cannot leave a waiter suspended forever.
private final class FeatureProcessExitObserver: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var hasFinished = false
        var hasCancelled = false
    }
    private let state = Mutex(State())

    func wait() async {
        if state.withLock({ $0.hasFinished }) { return }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.register(continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeImmediately = state.withLock { state -> Bool in
            if state.hasFinished || state.hasCancelled {
                return true
            }
            if state.continuation != nil {
                // A single process has a single exit waiter; resume a late
                // duplicate defensively rather than leaking its continuation.
                return true
            }
            state.continuation = continuation
            return false
        }
        if resumeImmediately {
            continuation.resume()
        }
    }

    /// Marks the waiter cancelled and resumes it. Idempotent and exactly-once.
    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.hasCancelled = true
            let pending = state.continuation
            state.continuation = nil
            return pending
        }
        continuation?.resume()
    }

    /// Marks the process finished and resumes the waiter. Idempotent and exactly-once.
    func finish() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.hasFinished = true
            let pending = state.continuation
            state.continuation = nil
            return pending
        }
        continuation?.resume()
    }

    var hasFinished: Bool {
        state.withLock { $0.hasFinished }
    }
}
#endif

public enum FeatureProcessRunnerError: LocalizedError, Sendable {
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Local process execution is unavailable on this platform."
        }
    }
}
