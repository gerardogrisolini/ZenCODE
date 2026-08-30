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

public enum FeatureProcessRunner {
    /// Hard per-pipe retention bound for one-shot child processes. A line-count
    /// guard alone is insufficient: minified JSON, base64 output, and stderr can
    /// grow for hours without ever producing a stdout newline.
    public static let defaultMaximumOutputBytesPerStream = 16 * 1_024 * 1_024

    public static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeout: TimeInterval? = nil,
        stdoutLineLimit: Int? = nil,
        maximumOutputBytesPerStream: Int = defaultMaximumOutputBytesPerStream
    ) async throws -> FeatureProcessResult {
        #if os(macOS) || os(Linux)
        try Task.checkCancellation()
        FeatureProcessDescriptors.ignoreSIGPIPEOnce()

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
        } else {
            // Feature processes must not inherit the controlling terminal;
            // otherwise they compete with ZenCODE for the operator's keystrokes.
            process.standardInput = FileHandle.nullDevice
        }

        let exitObserver = FeatureProcessExitSignal()
        let exitMonitor = FeatureProcessExitMonitor { exitCode in
            exitObserver.finish(exitCode: exitCode)
        }
        exitMonitor.install(on: process)

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }
        exitMonitor.startMonitoring(processID: process.processIdentifier)

        // Every parent-owned pipe end is switched to non-blocking mode. A
        // blocking `read`/`write` here would park a cooperative executor thread
        // (the runner is used concurrently by several feature tools) and could
        // never observe cancellation; the polling loops below yield with
        // `Task.sleep` instead, which is cancellation-aware and thread-free.
        FeatureProcessDescriptors.makeNonBlocking(stdoutPipe.fileHandleForReading)
        FeatureProcessDescriptors.makeNonBlocking(stderrPipe.fileHandleForReading)
        if let stdinPipe {
            FeatureProcessDescriptors.makeNonBlocking(stdinPipe.fileHandleForWriting)
        }

        // One-shot signal bridging the output readers and the exit supervisor.
        // When a reader exceeds its line or byte budget it requests termination
        // here; the supervisor treats that as a first-class escalation trigger on
        // the same footing as timeout/cancellation, so a child that ignores SIGTERM
        // is still guaranteed to reach SIGKILL and be reaped.
        let terminationRequest = FeatureProcessTerminationSignal()
        let outputByteLimit = max(1, maximumOutputBytesPerStream)

        // Drain stdout/stderr while writing stdin. Starting all three streams as
        // structured `async let` children guarantees the pipes are drained
        // concurrently with the stdin write, so a payload larger than the OS pipe
        // buffer cannot deadlock the run, and cancellation propagates to every
        // stream together with the exit supervisor below.
        async let stdoutOutcome = drainPipe(
            stdoutPipe.fileHandleForReading,
            exitObserver: exitObserver,
            lineLimit: stdoutLineLimit,
            byteLimit: outputByteLimit,
            terminationRequest: terminationRequest
        )
        async let stderrOutcome = drainPipe(
            stderrPipe.fileHandleForReading,
            exitObserver: exitObserver,
            lineLimit: nil,
            byteLimit: outputByteLimit,
            terminationRequest: terminationRequest
        )
        async let stdinOutcome = writeStdin(
            stdinPipe,
            data: stdinData,
            exitObserver: exitObserver
        )

        let timedOut = await superviseProcessExit(
            process,
            exitObserver: exitObserver,
            timeout: timeout,
            terminationRequest: terminationRequest
        )

        process.terminationHandler = nil

        let stdoutResult = await stdoutOutcome
        let stderrResult = await stderrOutcome
        // Awaited (not fire-and-forget) so the write completes and the pipe is
        // closed before we report a result. The outcome is captured rather than
        // swallowed by `try?`; we intentionally do not throw here to preserve the
        // runner's contract of returning whatever output the process produced.
        _ = await stdinOutcome

        try Task.checkCancellation()

        return FeatureProcessResult(
            exitCode: exitObserver.exitCode ?? -1,
            stdoutData: stdoutResult.0,
            stderrData: stderrResult.0,
            timedOut: timedOut,
            stdoutWasTruncated: stdoutResult.1,
            stderrWasTruncated: stderrResult.1
        )
        #else
        _ = executableURL
        _ = arguments
        _ = workingDirectory
        _ = environment
        _ = stdinData
        _ = timeout
        _ = stdoutLineLimit
        _ = maximumOutputBytesPerStream
        throw FeatureProcessRunnerError.unsupportedPlatform
        #endif
    }

    #if os(macOS) || os(Linux)
    /// Reads a child pipe to EOF without ever blocking a cooperative executor
    /// thread. The loop also stops once the child has exited and the pipe is
    /// drained: a descendant that inherited the write end can keep it open
    /// forever, and waiting for that unrelated process would hang the runner
    /// long after its child (and any timeout escalation) is gone.
    private static func drainPipe(
        _ handle: FileHandle,
        exitObserver: FeatureProcessExitSignal,
        lineLimit: Int?,
        byteLimit: Int,
        terminationRequest: FeatureProcessTerminationSignal
    ) async -> (Data, Bool) {
        let descriptor = handle.fileDescriptor
        var output = Data()
        var scratch = [UInt8](repeating: 0, count: 65_536)
        var observedLineCount = 0
        var wasTruncated = false

        while true {
            let bytesRead = scratch.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return read(descriptor, base, rawBuffer.count)
            }

            if bytesRead > 0 {
                let retainedByteCount = min(bytesRead, max(0, byteLimit - output.count))
                if retainedByteCount > 0 {
                    output.append(contentsOf: scratch[0 ..< retainedByteCount])
                }
                guard retainedByteCount == bytesRead else {
                    wasTruncated = true
                    // Stop reading before the `Data` can exceed its hard bound;
                    // the supervisor drains lifecycle ownership by terminating
                    // and reaping the producer.
                    terminationRequest.resolve(.outputByteLimit)
                    break
                }
                if let lineLimit, lineLimit > 0 {
                    for index in 0 ..< bytesRead where scratch[index] == UInt8(ascii: "\n") {
                        observedLineCount += 1
                    }
                    if observedLineCount >= lineLimit {
                        wasTruncated = true
                        // Hand off to the supervisor instead of signalling the
                        // child directly. The supervisor escalates through
                        // SIGTERM -> grace -> SIGKILL, guaranteeing termination
                        // even when the child ignores SIGTERM, while the outcome
                        // keeps timedOut == false because this is a truncation,
                        // not a timeout.
                        terminationRequest.resolve(.stdoutLineLimit)
                        break
                    }
                }
                continue
            }

            if bytesRead == 0 {
                break
            }

            let capturedErrno = errno
            if capturedErrno == EINTR {
                continue
            }

            if capturedErrno == EAGAIN || capturedErrno == EWOULDBLOCK {
                // Bytes written by the child are already queued in the pipe
                // before it exits, so an empty pipe after the owned exit was
                // observed means drained. A descendant may otherwise keep the
                // inherited write end open indefinitely.
                if exitObserver.hasExited {
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000)
                } catch {
                    break
                }
                continue
            }

            // Unreadable descriptor: report whatever the process produced.
            break
        }

        return (output, wasTruncated)
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
    /// so it is drained concurrently with the stdout/stderr readers, and uses the
    /// non-blocking descriptor so a child that stops reading cannot wedge the
    /// executor: back-pressure becomes an async sleep, and a dead child yields
    /// `EPIPE` instead of an unbounded block.
    private static func writeStdin(
        _ pipe: Pipe?,
        data: Data?,
        exitObserver: FeatureProcessExitSignal
    ) async -> StdinWriteOutcome {
        guard let data, let pipe else { return .nothingToWrite }
        let writer = pipe.fileHandleForWriting
        let descriptor = writer.fileDescriptor

        var totalWritten = 0
        var outcome = StdinWriteOutcome.written

        while totalWritten < data.count {
            let written = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return write(
                    descriptor,
                    base.advanced(by: totalWritten),
                    rawBuffer.count - totalWritten
                )
            }

            if written > 0 {
                totalWritten += written
                continue
            }

            let capturedErrno = errno
            if written == -1, capturedErrno == EINTR {
                continue
            }

            if written == -1, capturedErrno == EAGAIN || capturedErrno == EWOULDBLOCK {
                if exitObserver.hasExited {
                    outcome = .failed
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000)
                } catch {
                    outcome = .failed
                    break
                }
                continue
            }

            outcome = .failed
            break
        }

        try? writer.close()
        return outcome
    }

    /// Supervises process termination, applying the same `SIGTERM -> grace ->
    /// SIGKILL` escalation to an optional timeout, cooperative cancellation, and
    /// an output-limit truncation request. The natural-exit waiter is cancellation-
    /// aware, so any trigger can always tear it down and reach the SIGKILL
    /// fallback: a process that ignores SIGTERM can no longer hang the runner.
    /// A line-limit truncation escalates like the others but is reported as
    /// `timedOut == false` because the run was truncated, not timed out.
    private static func superviseProcessExit(
        _ process: Process,
        exitObserver: FeatureProcessExitSignal,
        timeout: TimeInterval?,
        terminationRequest: FeatureProcessTerminationSignal
    ) async -> Bool {
        let outcome = await withTaskGroup(of: FeatureProcessExitOutcome.self) { group -> FeatureProcessExitOutcome in
            // Natural exit waiter. `exitObserver.wait()` resumes on process exit
            // OR on cancellation, so this child never stays suspended once the
            // group is asked to stop.
            group.addTask(name: "Feature process natural exit") {
                await exitObserver.wait()
                return .exited
            }

            // Escalation trigger: fires when the timeout elapses (if any) or the
            // task is cancelled, whichever happens first.
            group.addTask(name: "Feature process timeout") {
                await FeatureProcessTerminationEscalator.waitForTimeoutOrCancellation(timeout)
                return .timeoutOrCancellation
            }

            // Output-limit trigger: a reader exceeded either its stdout line
            // budget or its per-pipe byte budget. This fires without an external
            // timeout and still escalates for a child that ignores SIGTERM.
            group.addTask(name: "Feature process output truncation") {
                await terminationRequest.wait()
                return .outputTruncated
            }

            // As soon as one condition fires, stop waiting and tear the other
            // children down. The exit waiter is cancellation-aware, so cancelAll()
            // always unblocks it instead of leaving a continuation suspended.
            let result = await group.next() ?? .timeoutOrCancellation
            group.cancelAll()
            return result
        }

        // Preserve the race winner even if process exit becomes observable just
        // afterward. Once the deadline waiter wins, timedOut must not be cleared
        // by a subsequent hasExited read.
        let timedOut = outcome == .timeoutOrCancellation

        // If the process already terminated, no escalation is needed. Otherwise
        // the trigger (timeout, cancellation, or line limit) won and we must
        // escalate to reach a guaranteed kill, even for a process that ignores
        // SIGTERM.
        guard exitObserver.hasExited else {
            // Shared, bounded TERM -> grace -> KILL -> reap escalation.
            await FeatureProcessTerminationEscalator.escalate(
                process,
                exitSignal: exitObserver
            )
            // A line-limit truncation triggers escalation so the run always
            // returns, but it is not a timeout: preserve timedOut == false.
            return timedOut
        }
        return timedOut
    }
    #endif
}

#if os(macOS) || os(Linux)
/// Which supervised condition ended the run first.
private enum FeatureProcessExitOutcome: Sendable {
    case exited
    case timeoutOrCancellation
    case outputTruncated
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
