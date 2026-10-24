//
//  CronJobRunner.swift
//  ZenCODE
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Outcome and protocol

/// What one immediate run of a crontab entry produced.
struct ZenCronRunOutcome: Sendable, Equatable {
    /// Exit status of the shell. A child killed by a signal reports the shell
    /// convention `128 + signal`, so it cannot be mistaken for a plain exit code.
    let exitStatus: Int32
    /// Retained prefix of the standard output (at most 1 MiB).
    let stdout: String
    /// Retained prefix of the standard error (at most 64 KiB).
    let stderr: String
    /// Wall-clock time from launch to the exit of the shell.
    let duration: Duration
    /// `true` when the run was cut short by cancellation (the child was
    /// sent SIGTERM, or its output was abandoned after being cancelled).
    let wasTerminated: Bool
}

/// Runs a crontab command immediately, the way cron would.
protocol CronJobRunning: Sendable {
    /// Executes `cronCommand` (the command field of a crontab line, still in
    /// cron syntax, so a `%` is already escaped when it must be literal).
    ///
    /// Task cancellation terminates the child and returns an outcome with
    /// `wasTerminated == true`. Throws only when the shell cannot be launched.
    func run(
        cronCommand: String,
        environment: [String: String],
        homeDirectory: URL
    ) async throws -> ZenCronRunOutcome
}

// MARK: - Cron command syntax

/// Cron's treatment of `%` in the command field.
enum ZenCronCommandSplit {
    /// Splits `cronCommand` into the shell command and the standard input:
    ///
    /// - `\%` is a literal `%`;
    /// - the first unescaped `%` ends the command, the rest is the standard input;
    /// - every further unescaped `%` in that rest is a newline (an escaped one
    ///   stays a literal `%`);
    /// - without an unescaped `%` the standard input is empty.
    ///
    /// A backslash not followed by `%` is kept untouched. No newline is added
    /// to the standard input beyond the ones produced by `%`.
    static func split(_ cronCommand: String) -> (shellCommand: String, stdin: String) {
        let scalars = Array(cronCommand.unicodeScalars)
        var command = String.UnicodeScalarView()
        var input = String.UnicodeScalarView()
        var inInput = false
        var position = 0
        while position < scalars.count {
            let scalar = scalars[position]
            if scalar == "\\", position + 1 < scalars.count, scalars[position + 1] == "%" {
                if inInput { input.append("%") } else { command.append("%") }
                position += 2
                continue
            }
            if scalar == "%" {
                if inInput { input.append("\n") } else { inInput = true }
            } else if inInput {
                input.append(scalar)
            } else {
                command.append(scalar)
            }
            position += 1
        }
        return (String(command), String(input))
    }
}

/// The environment cron gives to its jobs.
enum ZenCronEnvironment {
    /// Exactly `HOME`, `SHELL=/bin/sh` and `PATH`, plus `LOGNAME` and `USER`
    /// when `current` has them. `HOME` is always `home` (cron takes it from the
    /// password database, never from the caller's environment). `PATH` is cron's
    /// own default (`/usr/bin:/bin`) unless the caller passes the one the
    /// crontab sets for the job (see `ZenCrontabDocument.effectivePath`).
    ///
    /// Other variable assignments in the crontab (`SHELL=`, `HOME=`, a foreign
    /// `MAILTO=`, …) are not replicated: only the block's `PATH` is, because it
    /// is what finds `zen`.
    static func minimal(
        current: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = UserHomeDirectory.current(),
        path: String = "/usr/bin:/bin"
    ) -> [String: String] {
        var environment = [
            "HOME": home.path,
            "SHELL": "/bin/sh",
            "PATH": path
        ]
        for key in ["LOGNAME", "USER"] {
            if let value = current[key] {
                environment[key] = value
            }
        }
        return environment
    }
}

// MARK: - Report extraction

/// Reads the final answer out of the JSONL a scheduled `zen --jsonl` run prints
/// (see `Docs/jsonl.md`).
enum ZenCronRunReport {
    enum Result: Equatable {
        /// The last `message.completed` record.
        case completed(text: String)
        /// The last `error` record, when no message completed.
        case failed(category: String, message: String)
        /// No usable record: not JSONL, or a run that ended without a message.
        case noResult
    }

    /// A completed message wins over an error; among records of the same kind
    /// the last one wins. Lines that are not JSON objects (or lack the expected
    /// string fields) are ignored. Lines are split on `\n` only: other Unicode
    /// line separators may legitimately appear inside a JSON string.
    static func extract(stdout: String) -> Result {
        var completedText: String?
        var failure: (category: String, message: String)?
        for line in stdout.utf8.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            switch type {
            case "message.completed":
                if let text = object["text"] as? String {
                    completedText = text
                }
            case "error":
                if let category = object["category"] as? String,
                   let message = object["message"] as? String {
                    failure = (category, message)
                }
            default:
                break
            }
        }
        if let completedText { return .completed(text: completedText) }
        if let failure { return .failed(category: failure.category, message: failure.message) }
        return .noResult
    }
}

// MARK: - System runner

/// `CronJobRunning` backed by `/bin/sh -c`, launched with the given
/// environment (nothing is added) from the home directory.
struct SystemCronJobRunner: CronJobRunning {
    static let shellPath = "/bin/sh"
    /// Retained standard output; the pipe keeps being drained past the limit.
    static let stdoutLimit = 1 << 20
    /// Retained standard error.
    static let stderrLimit = 64 * 1024

    func run(
        cronCommand: String,
        environment: [String: String],
        homeDirectory: URL
    ) async throws -> ZenCronRunOutcome {
        let parts = ZenCronCommandSplit.split(cronCommand)
        let session = CronProcessSession()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.launch(
                    shellCommand: parts.shellCommand,
                    stdin: parts.stdin,
                    environment: environment,
                    homeDirectory: homeDirectory
                ) { continuation.resume(with: $0) }
            }
        } onCancel: {
            session.cancel()
        }
    }
}

/// One run: owns the `Process` and serialises launch, cancellation and exit
/// under a lock, so a cancellation that arrives before the launch, during the
/// run, while the output is drained or after the end is always safe (the
/// child is only signalled while running, the continuation is resumed once).
///
/// Every blocking wait (child exit, pipe drains, a stdin write into a full
/// pipe) happens on dedicated threads, never on the cooperative thread pool.
///
/// Signals go to the shell's whole process group when the shell leads one
/// (swift-corelibs-foundation spawns it with `POSIX_SPAWN_SETPGROUP`), so a
/// cancellation also stops the commands it forked. On Linux that is what lets
/// a cancelled run end promptly: Foundation notices the exit of the shell only
/// once every holder of a socket it hands to the child has closed it, and the
/// shell's descendants inherit that socket (a shell such as dash does not
/// `exec` the last command). Until then the shell stays an unreaped zombie and
/// the run stays `.running`, so the SIGKILL fallback still reaches the group.
/// Residual limit on Linux: a descendant that left the group (`setsid`, a
/// daemon) and keeps that socket open delays the return until it exits.
private final class CronProcessSession: @unchecked Sendable {
    private enum Phase {
        case idle, running, exited, draining, finished
    }

    /// Time a child gets to honour SIGTERM before it is killed.
    private static let killGrace: DispatchTimeInterval = .seconds(3)
    /// Time granted to the pipes to reach EOF after a cancellation: a grandchild
    /// that survived the shell may keep them open indefinitely.
    private static let drainGrace: DispatchTimeInterval = .seconds(2)

    private let lock = NSLock()
    private let process = Process()
    private let exitSignal = DispatchSemaphore(value: 0)
    private let drainSignal = DispatchSemaphore(value: 0)
    private var phase = Phase.idle
    private var cancelRequested = false
    private var terminateSent = false
    /// The shell leads its own process group, so signals target `-pid`.
    private var leadsProcessGroup = false
    private var drainedOutput: (stdout: Data, stderr: Data)?

    /// Runs the command on a dedicated thread and calls `completion` exactly once.
    func launch(
        shellCommand: String,
        stdin: String,
        environment: [String: String],
        homeDirectory: URL,
        completion: @escaping @Sendable (Result<ZenCronRunOutcome, any Error>) -> Void
    ) {
        let thread = Thread { [self] in
            completion(
                execute(
                    shellCommand: shellCommand,
                    stdin: stdin,
                    environment: environment,
                    homeDirectory: homeDirectory
                )
            )
        }
        thread.name = "ZenCODE.cron-run"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Terminates the child if it is running; otherwise only records the
    /// request, which the run honours at its next checkpoint.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelRequested = true
        switch phase {
        case .running:
            terminateSent = true
            signalChild(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [self] in
                killIfStillRunning()
            }
        case .draining:
            // Stop waiting for pipes that a surviving descendant holds open.
            drainSignal.signal()
        case .idle, .exited, .finished:
            break
        }
    }

    // MARK: Run

    private func execute(
        shellCommand: String,
        stdin: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> Result<ZenCronRunOutcome, any Error> {
        let clock = ContinuousClock()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: SystemCronJobRunner.shellPath)
        process.arguments = ["-c", shellCommand]
        process.environment = environment
        process.currentDirectoryURL = homeDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [self] _ in processDidExit() }

        let started = clock.now
        // Checking the cancellation flag and launching happen under the same
        // lock `cancel()` takes, so no request can slip in between.
        lock.lock()
        if cancelRequested {
            phase = .finished
            lock.unlock()
            process.terminationHandler = nil
            return .success(
                ZenCronRunOutcome(
                    exitStatus: 128 + SIGTERM,
                    stdout: "",
                    stderr: "",
                    duration: .zero,
                    wasTerminated: true
                )
            )
        }
        do {
            try process.run()
        } catch {
            phase = .finished
            lock.unlock()
            process.terminationHandler = nil
            return .failure(error)
        }
        // Recorded right after the launch: a negative pid is only ever used
        // when the shell itself leads the group named after it (a shell that
        // already exited reports no group and keeps the per-pid signal).
        let identifier = process.processIdentifier
        leadsProcessGroup = identifier > 0 && getpgid(identifier) == identifier
        phase = .running
        lock.unlock()

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        let outputDrain = SupportDirectoryArchive.BoundedPipeDrain(
            handle: outputHandle,
            limit: SystemCronJobRunner.stdoutLimit
        )
        let errorDrain = SupportDirectoryArchive.BoundedPipeDrain(
            handle: errorHandle,
            limit: SystemCronJobRunner.stderrLimit
        )

        // The drains already run, so a chatty child cannot stall this write.
        // A child that exits without reading its stdin is not an error: the
        // write fails with EPIPE (never SIGPIPE) and the exit status speaks.
        let writer = inputPipe.fileHandleForWriting
        SystemCrontabClient.suppressSIGPIPE(on: writer)
        if !stdin.isEmpty {
            try? writer.write(contentsOf: Data(stdin.utf8))
        }
        try? writer.close()

        exitSignal.wait()
        let ended = clock.now
        process.terminationHandler = nil

        lock.lock()
        phase = .draining
        let terminatedByUs = terminateSent
        let cancelledAlready = cancelRequested
        lock.unlock()

        // `finish()` blocks until EOF, so it runs on its own thread. Like cron,
        // a normal run waits for EOF however long it takes; once cancelled it
        // only waits a bounded time.
        let collector = Thread { [self] in
            let standardOutput = outputDrain.finish()
            let standardError = errorDrain.finish()
            lock.lock()
            drainedOutput = (standardOutput, standardError)
            lock.unlock()
            drainSignal.signal()
        }
        collector.name = "ZenCODE.cron-drain"
        collector.stackSize = 256 * 1024
        collector.start()
        if terminatedByUs || cancelledAlready {
            _ = drainSignal.wait(timeout: .now() + Self.drainGrace)
        } else {
            drainSignal.wait()
        }

        lock.lock()
        phase = .finished
        let drained = drainedOutput
        lock.unlock()

        if drained != nil {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        // Otherwise the drain threads still own the pipes and release them
        // when the surviving descendant lets go.

        let status: Int32 = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus
            : process.terminationStatus
        return .success(
            ZenCronRunOutcome(
                exitStatus: status,
                stdout: String(decoding: drained?.stdout ?? Data(), as: UTF8.self),
                stderr: String(decoding: drained?.stderr ?? Data(), as: UTF8.self),
                duration: ended - started,
                wasTerminated: terminatedByUs || drained == nil
            )
        )
    }

    private func processDidExit() {
        lock.lock()
        if phase == .running {
            phase = .exited
        }
        lock.unlock()
        exitSignal.signal()
    }

    /// Last resort for a child that ignored SIGTERM, or for descendants that
    /// ignored it while the shell itself died (an unreaped zombie on Linux).
    private func killIfStillRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .running else { return }
        signalChild(SIGKILL)
    }

    /// Sends `signal` to the shell's process group when it leads one,
    /// otherwise to the shell alone. Call with `lock` held while `.running`.
    private func signalChild(_ signal: Int32) {
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        _ = kill(leadsProcessGroup ? -identifier : identifier, signal)
    }
}
