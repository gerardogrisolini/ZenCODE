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
        ignoreSIGPIPEOnce()

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

        // Every parent-owned pipe end is switched to non-blocking mode. A
        // blocking `read`/`write` here would park a cooperative executor thread
        // (the runner is used concurrently by several feature tools) and could
        // never observe cancellation; the polling loops below yield with
        // `Task.sleep` instead, which is cancellation-aware and thread-free.
        makeNonBlocking(stdoutPipe.fileHandleForReading)
        makeNonBlocking(stderrPipe.fileHandleForReading)
        if let stdinPipe {
            makeNonBlocking(stdinPipe.fileHandleForWriting)
        }

        // One-shot signal bridging the output readers and the exit supervisor.
        // When a reader exceeds its line budget it requests termination here; the
        // supervisor treats that as a first-class escalation trigger on the same
        // footing as timeout/cancellation, so a child that ignores SIGTERM is
        // still guaranteed to reach SIGKILL and be reaped.
        let terminationRequest = FeatureProcessTerminationRequest()

        // Drain stdout/stderr while writing stdin. Starting all three streams as
        // structured `async let` children guarantees the pipes are drained
        // concurrently with the stdin write, so a payload larger than the OS pipe
        // buffer cannot deadlock the run, and cancellation propagates to every
        // stream together with the exit supervisor below.
        async let stdoutOutcome = drainPipe(
            stdoutPipe.fileHandleForReading,
            process: process,
            exitObserver: exitObserver,
            lineLimit: stdoutLineLimit,
            terminationRequest: terminationRequest
        )
        async let stderrOutcome = drainPipe(
            stderrPipe.fileHandleForReading,
            process: process,
            exitObserver: exitObserver,
            lineLimit: nil,
            terminationRequest: terminationRequest
        )
        async let stdinOutcome = writeStdin(
            stdinPipe,
            data: stdinData,
            process: process,
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
        let stderr = await stderrOutcome.0
        // Awaited (not fire-and-forget) so the write completes and the pipe is
        // closed before we report a result. The outcome is captured rather than
        // swallowed by `try?`; we intentionally do not throw here to preserve the
        // runner's contract of returning whatever output the process produced.
        _ = await stdinOutcome

        try Task.checkCancellation()

        return FeatureProcessResult(
            exitCode: exitCode(of: process, exitObserver: exitObserver),
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
    /// `Process.terminationStatus` traps when the child has not been reaped yet.
    /// Every escalation path waits for the real exit, so this is only a guard
    /// against pathological states (e.g. a child that outlived SIGKILL because
    /// it is a zombie held by another reaper) reporting a bogus status.
    private static func exitCode(
        of process: Process,
        exitObserver: FeatureProcessExitObserver
    ) -> Int32 {
        guard exitObserver.hasFinished || !process.isRunning else {
            return -1
        }
        return process.terminationStatus
    }

    /// Writing to a pipe whose reader already exited raises SIGPIPE, whose
    /// default disposition kills ZenCODE itself. Ignore it once so the write
    /// path observes `EPIPE` as an ordinary error instead.
    private static let sigpipeIgnored = Mutex(false)

    private static func ignoreSIGPIPEOnce() {
        let shouldInstall = sigpipeIgnored.withLock { installed -> Bool in
            guard !installed else { return false }
            installed = true
            return true
        }
        if shouldInstall {
            signal(SIGPIPE, SIG_IGN)
        }
    }

    /// Best-effort switch to `O_NONBLOCK`. A failure only degrades to the
    /// previous blocking behaviour, so it must not fail the run.
    private static func makeNonBlocking(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        let currentFlags = fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK)
    }

    /// Reads a child pipe to EOF without ever blocking a cooperative executor
    /// thread. The loop also stops once the child has exited and the pipe is
    /// drained: a descendant that inherited the write end can keep it open
    /// forever, and waiting for that unrelated process would hang the runner
    /// long after its child (and any timeout escalation) is gone.
    private static func drainPipe(
        _ handle: FileHandle,
        process: Process,
        exitObserver: FeatureProcessExitObserver,
        lineLimit: Int?,
        terminationRequest: FeatureProcessTerminationRequest
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
                output.append(contentsOf: scratch[0 ..< bytesRead])
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
                        terminationRequest.request()
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
                // before it exits, so an empty pipe after exit means drained.
                if exitObserver.hasFinished || !process.isRunning {
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
        process: Process,
        exitObserver: FeatureProcessExitObserver
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
                if exitObserver.hasFinished || !process.isRunning {
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
    /// a line-limit truncation request. The natural-exit waiter is cancellation-
    /// aware, so any trigger can always tear it down and reach the SIGKILL
    /// fallback: a process that ignores SIGTERM can no longer hang the runner.
    /// A line-limit truncation escalates like the others but is reported as
    /// `timedOut == false` because the run was truncated, not timed out.
    private static func superviseProcessExit(
        _ process: Process,
        exitObserver: FeatureProcessExitObserver,
        timeout: TimeInterval?,
        terminationRequest: FeatureProcessTerminationRequest
    ) async -> Bool {
        let outcome = await withTaskGroup(of: FeatureProcessExitOutcome.self) { group -> FeatureProcessExitOutcome in
            // Natural exit waiter. `exitObserver.wait()` resumes on process exit
            // OR on cancellation, so this child never stays suspended once the
            // group is asked to stop.
            group.addTask {
                await exitObserver.wait()
                return .exited
            }

            // Escalation trigger: fires when the timeout elapses (if any) or the
            // task is cancelled, whichever happens first.
            group.addTask {
                await waitForTimeoutOrCancellation(timeout)
                return .timeoutOrCancellation
            }

            // Line-limit trigger: an output reader that exceeded its line budget
            // requested termination. This fires without an external timeout and
            // must still escalate to SIGKILL for a child that ignores SIGTERM.
            group.addTask {
                await terminationRequest.wait()
                return .stdoutTruncated
            }

            // As soon as one condition fires, stop waiting and tear the other
            // children down. The exit waiter is cancellation-aware, so cancelAll()
            // always unblocks it instead of leaving a continuation suspended.
            let result = await group.next() ?? .timeoutOrCancellation
            group.cancelAll()
            return result
        }

        // If the process already terminated, no escalation is needed. Otherwise
        // the trigger (timeout, cancellation, or line limit) won and we must
        // escalate to reach a guaranteed kill, even for a process that ignores
        // SIGTERM.
        guard exitObserver.hasFinished else {
            _ = await escalateTermination(process, exitObserver: exitObserver)
            // A line-limit truncation triggers escalation so the run always
            // returns, but it is not a timeout: preserve timedOut == false.
            return outcome == .timeoutOrCancellation
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
        // The kill is imminent and unblockable, so this final reap deliberately
        // ignores cancellation: returning here while the child is still alive
        // would leave an unreaped process and an invalid `terminationStatus`.
        await exitObserver.waitIgnoringCancellation()
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
private enum FeatureProcessExitOutcome: Sendable {
    case exited
    case timeoutOrCancellation
    case stdoutTruncated
}

/// Cancellation-aware one-shot signal used to request process termination from
/// an output reader. A cancelled wait only resolves its own continuation, so a
/// later line-limit request is never lost while the process supervisor races the
/// other exit conditions.
private final class FeatureProcessTerminationRequest: Sendable {
    private struct State: Sendable {
        var hasBeenRequested = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var cancelledWaiters: Set<UUID> = []
    }

    private let state = Mutex(State())

    func request() {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.hasBeenRequested else { return [] }
            state.hasBeenRequested = true
            let pending = Array(state.waiters.values)
            state.waiters.removeAll()
            state.cancelledWaiters.removeAll()
            return pending
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        if state.withLock({ $0.hasBeenRequested }) { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                register(continuation, id: waiterID)
            }
        } onCancel: {
            cancelWaiter(waiterID)
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>, id: UUID) {
        let resumeImmediately = state.withLock { state -> Bool in
            if state.hasBeenRequested {
                return true
            }
            if state.cancelledWaiters.remove(id) != nil {
                return true
            }
            state.waiters[id] = continuation
            return false
        }
        if resumeImmediately {
            continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let pending = state.waiters.removeValue(forKey: id) else {
                state.cancelledWaiters.insert(id)
                return nil
            }
            return pending
        }
        continuation?.resume()
    }
}

/// Cancellation-aware exit signal for a spawned process.
///
/// Every `wait()` registers its own continuation, so cancelling one waiter
/// resolves only that waiter: the observer itself is never "poisoned" and later
/// waits (the SIGTERM grace window and the post-SIGKILL reap) still block until
/// the process really exits. Continuations are resumed exactly once under a
/// `Mutex`, including when cancellation is observed before registration.
private final class FeatureProcessExitObserver: Sendable {
    private struct State: Sendable {
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var cancelledWaiters: Set<UUID> = []
        var hasFinished = false
    }
    private let state = Mutex(State())

    /// Suspends until the process exits or the calling task is cancelled.
    func wait() async {
        if state.withLock({ $0.hasFinished }) { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                register(continuation, id: waiterID)
            }
        } onCancel: {
            cancelWaiter(waiterID)
        }
    }

    /// Suspends until the process exits, ignoring cancellation of the caller.
    func waitIgnoringCancellation() async {
        if state.withLock({ $0.hasFinished }) { return }

        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            register(continuation, id: waiterID)
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>, id: UUID) {
        let resumeImmediately = state.withLock { state -> Bool in
            if state.hasFinished {
                return true
            }
            // Cancellation can be observed before the continuation exists; the
            // recorded ticket makes the late registration resume right away
            // instead of leaking a suspended waiter.
            if state.cancelledWaiters.remove(id) != nil {
                return true
            }
            state.waiters[id] = continuation
            return false
        }
        if resumeImmediately {
            continuation.resume()
        }
    }

    /// Resolves a single cancelled waiter. Other waiters and the observer's
    /// ability to report a later real exit are untouched.
    private func cancelWaiter(_ id: UUID) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let pending = state.waiters.removeValue(forKey: id) else {
                state.cancelledWaiters.insert(id)
                return nil
            }
            return pending
        }
        continuation?.resume()
    }

    /// Marks the process finished and resumes every waiter. Idempotent, and each
    /// continuation is resumed exactly once.
    func finish() {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.hasFinished = true
            let pending = Array(state.waiters.values)
            state.waiters.removeAll()
            state.cancelledWaiters.removeAll()
            return pending
        }
        for continuation in continuations {
            continuation.resume()
        }
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
