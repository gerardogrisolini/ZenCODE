//
//  AsyncProcessRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public struct AsyncProcessResult: Sendable {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data
    public let timedOut: Bool
    public let stdoutWasTruncated: Bool

    public var stdout: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    public var stderr: String {
        String(decoding: stderrData, as: UTF8.self)
    }
}

public enum AsyncProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeout: TimeInterval? = nil,
        stdoutLineLimit: Int? = nil
    ) async throws -> AsyncProcessResult {
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

        let exitObserver = AsyncProcessExitObserver()
        process.terminationHandler = { _ in
            Task {
                await exitObserver.finish()
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }

        // Drain stdout/stderr concurrently with the stdin write. The readers
        // are started before feeding stdin so a child that fills its output
        // pipe and then waits for input cannot deadlock against the parent
        // filling stdin (a classic bidirectional pipe deadlock).
        let stdoutReader = Task.detached { () -> (Data, Bool) in
            readStdout(
                from: stdoutPipe,
                process: process,
                lineLimit: stdoutLineLimit
            )
        }
        let stderrReader = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        if let stdinData,
           let stdinPipe {
            let writer = stdinPipe.fileHandleForWriting
            try? writer.write(contentsOf: stdinData)
            try? writer.close()
        }

        // The exit wait is cancellation-aware: both the timeout and
        // cancellation outcomes traverse the same escalation
        // (terminate -> grace period -> SIGKILL), so a process that ignores
        // SIGTERM can never leave the exit continuation suspended.
        let timedOut = await waitForProcessExit(
            process,
            exitObserver: exitObserver,
            timeout: timeout
        )

        process.terminationHandler = nil
        let stdoutResult = await stdoutReader.value
        let stderrData = await stderrReader.value

        try Task.checkCancellation()

        return AsyncProcessResult(
            exitCode: process.terminationStatus,
            stdoutData: stdoutResult.0,
            stderrData: stderrData,
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
        throw AsyncProcessRunnerError.unsupportedPlatform
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

    private static func waitForProcessExit(
        _ process: Process,
        exitObserver: AsyncProcessExitObserver,
        timeout: TimeInterval?
    ) async -> Bool {
        await withTaskGroup(of: ExitOutcome.self) { group in
            // Natural exit: resumed by the process termination handler.
            group.addTask {
                await exitObserver.wait()
                return .exited
            }

            // Timeout deadline (optional).
            if let timeout, timeout > 0 {
                group.addTask {
                    let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    // If the process exited while we slept, this is not a
                    // timeout; treat it as a natural exit to avoid escalation.
                    if await exitObserver.hasFinished {
                        return .exited
                    }
                    return .timedOut
                }
            }

            // Cooperative cancellation. Structured cancellation propagates into
            // this child task, so its continuation is resumed (exactly once) as
            // soon as the surrounding run is cancelled.
            group.addTask {
                await waitUntilCancelled()
                return .cancelled
            }

            let outcome = await group.next() ?? .exited
            group.cancelAll()

            // Timeout and cancellation share the same escalation path so SIGKILL
            // is always reachable even when SIGTERM is ignored.
            if outcome != .exited {
                await escalateTermination(process: process, exitObserver: exitObserver)
            }
            return outcome == .timedOut
        }
    }

    /// Graceful-to-forced termination shared by the timeout and cancellation
    /// paths: SIGTERM, then a grace period, then SIGKILL. Idempotent — it is a
    /// no-op once the process has already exited, and every signal is guarded by
    /// `process.isRunning`, so a concurrent timeout/cancellation overlap cannot
    /// escalate twice. Forcing SIGKILL (rather than relying on SIGTERM alone)
    /// guarantees the exit observer's continuation is always resumed exactly once.
    private static func escalateTermination(
        process: Process,
        exitObserver: AsyncProcessExitObserver
    ) async {
        guard await !exitObserver.hasFinished else {
            return
        }
        if process.isRunning {
            process.terminate()
        }

        // Grace period: give the SIGTERM a chance to be honored.
        if await waitForExitAfterTermination(exitObserver: exitObserver) {
            return
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        await exitObserver.wait()
    }

    private static func waitForExitAfterTermination(
        exitObserver: AsyncProcessExitObserver
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
            return exited
        }
    }

    /// Suspends the current task until it is cancelled (returning immediately if
    /// already cancelled). Gives the exit-wait task group a cancellation signal
    /// to race against natural completion, so a cancelled run is never stuck
    /// behind a process that ignores SIGTERM. The continuation is resumed exactly
    /// once through `CancellationResumeBox`.
    private static func waitUntilCancelled() async {
        let box = CancellationResumeBox()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.store(continuation)
            }
        } onCancel: {
            box.resume()
        }
    }
    #endif
}

#if os(macOS) || os(Linux)
/// Outcome of racing the natural process exit against timeout and cancellation
/// inside `AsyncProcessRunner.waitForProcessExit`.
private enum ExitOutcome: Sendable {
    case exited
    case timedOut
    case cancelled
}

/// Holds the cancellation continuation for `AsyncProcessRunner.waitUntilCancelled`
/// and resumes it exactly once, whether cancellation arrives before or after the
/// continuation is installed. Mirrors the module's `Mutex`-based exactly-once
/// resume guards.
private final class CancellationResumeBox: Sendable {
    private let state = Mutex<CheckedContinuation<Void, Never>?>(nil)

    func store(_ continuation: CheckedContinuation<Void, Never>) {
        let alreadyCancelled = state.withLock { stored -> Bool in
            if Task.isCancelled {
                return true
            }
            stored = continuation
            return false
        }
        if alreadyCancelled {
            continuation.resume()
        }
    }

    func resume() {
        let pending = state.withLock { stored -> CheckedContinuation<Void, Never>? in
            let continuation = stored
            stored = nil
            return continuation
        }
        pending?.resume()
    }
}

private actor AsyncProcessExitObserver {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var hasFinished = false

    func wait() async {
        guard !hasFinished else {
            return
        }

        await withCheckedContinuation { continuation in
            if hasFinished {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func finish() {
        guard !hasFinished else {
            return
        }

        hasFinished = true
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
#endif

public enum AsyncProcessRunnerError: LocalizedError, Sendable {
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Local process execution is unavailable on this platform."
        }
    }
}
