//
//  CrontabClient.swift
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

/// Absolute paths of the system tools `/cron` depends on, located without
/// consulting `PATH` (deterministic even when it is empty or attacker-controlled).
///
/// `nil` means the tool is not installed or not executable; callers decide
/// whether that is fatal (`crontab`) or only worth a warning (`sendmail`).
public struct ZenCronToolchain: Sendable, Equatable {
    /// Absolute path of the `crontab` executable, if any.
    public let crontabPath: String?
    /// Absolute path of the `sendmail` executable (needed by cron to deliver
    /// job output by mail), if any.
    public let sendmailPath: String?

    public init(crontabPath: String?, sendmailPath: String?) {
        self.crontabPath = crontabPath
        self.sendmailPath = sendmailPath
    }

    /// Probes only the fixed locations below, in order, and keeps the first
    /// executable one for each tool (same criterion as the tar lookup in
    /// `SupportDirectoryArchive`).
    public static func locate(fileManager: FileManager = .default) -> ZenCronToolchain {
        ZenCronToolchain(
            crontabPath: firstExecutable(
                in: crontabCandidates,
                fileManager: fileManager
            ),
            sendmailPath: firstExecutable(
                in: sendmailCandidates,
                fileManager: fileManager
            )
        )
    }

    static let crontabCandidates = ["/usr/bin/crontab", "/bin/crontab"]
    static let sendmailCandidates = ["/usr/sbin/sendmail", "/usr/lib/sendmail"]

    private static func firstExecutable(
        in candidates: [String],
        fileManager: FileManager
    ) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

/// Reads and replaces the current user's whole crontab text.
protocol CrontabClient: Sendable {
    /// Returns the current crontab text, or `""` when the user has none.
    func readCrontab() throws -> String
    /// Replaces the user's crontab with `text`; empty text removes it.
    func writeCrontab(_ text: String) throws
}

/// `CrontabClient` backed by the system `crontab` binary, launched directly
/// through `Process` (never through a shell).
struct SystemCrontabClient: CrontabClient {
    /// Substring `crontab` prints on stderr when the user has no crontab yet;
    /// that is an empty crontab, not a failure.
    static let noCrontabMarker = "no crontab for"

    /// Retained stderr prefix, enough for any `crontab` diagnostic.
    private static let stderrLimit = 4 * 1024

    /// Set only by tests so a stand-in executable replaces the real binary.
    private let crontabPathOverride: String?

    /// Uses the system `crontab`, located again at every call.
    init() {
        crontabPathOverride = nil
    }

    /// Uses the executable at `crontabPath` instead of the system `crontab`.
    init(crontabPath: String) {
        crontabPathOverride = crontabPath
    }

    func readCrontab() throws -> String {
        let output = try run(["-l"], standardInput: nil)
        var standardOutput = ""
        if output.status == 0 {
            // Never decode lossily: a rewrite would silently corrupt the
            // user's own (non-UTF-8) entries with replacement characters.
            guard let decoded = String(data: output.standardOutput, encoding: .utf8) else {
                throw ZenCrontabError.commandFailed(
                    status: 0,
                    detail: "the existing crontab is not valid UTF-8, so it cannot be rewritten safely. "
                        + "Convert it to UTF-8 with `crontab -e`, then retry."
                )
            }
            standardOutput = decoded
        }
        return try Self.classifyRead(
            status: output.status,
            stdout: standardOutput,
            stderr: output.standardError
        )
    }

    func writeCrontab(_ text: String) throws {
        if text.isEmpty {
            let output = try run(["-r"], standardInput: nil)
            try Self.classifyRemoval(
                status: output.status,
                stderr: output.standardError
            )
            return
        }
        let output = try run(["-"], standardInput: Data(text.utf8))
        guard output.status == 0 else {
            throw ZenCrontabError.commandFailed(
                status: output.status,
                detail: output.standardError
            )
        }
        if let inputError = output.inputError {
            // Exit 0 does not prove crontab consumed the whole text.
            throw ZenCrontabError.commandFailed(
                status: 0,
                detail: "the new crontab could not be sent to crontab (\(inputError.localizedDescription)); "
                    + "the previous crontab was left unchanged or may be incomplete, check it with `crontab -l`"
            )
        }
    }

    /// Maps the outcome of `crontab -l`: success returns stdout, "no crontab
    /// for <user>" is an empty crontab, anything else is a failure.
    static func classifyRead(
        status: Int32,
        stdout: String,
        stderr: String
    ) throws -> String {
        if status == 0 { return stdout }
        if stderr.contains(noCrontabMarker) { return "" }
        throw ZenCrontabError.commandFailed(
            status: status,
            detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Maps the outcome of `crontab -r`: removing a crontab that does not
    /// exist is already the requested state.
    static func classifyRemoval(status: Int32, stderr: String) throws {
        if status == 0 || stderr.contains(noCrontabMarker) { return }
        throw ZenCrontabError.commandFailed(
            status: status,
            detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Process plumbing

private extension SystemCrontabClient {
    struct ProcessOutput {
        let status: Int32
        /// Complete stdout (a crontab must never be truncated).
        let standardOutput: Data
        /// Trimmed prefix of stderr.
        let standardError: String
        /// Failure to deliver `standardInput` to the child, if any.
        let inputError: (any Error)?
    }

    func resolveExecutable() throws -> URL {
        let fileManager = FileManager.default
        let path: String?
        if let crontabPathOverride {
            path = fileManager.isExecutableFile(atPath: crontabPathOverride)
                ? crontabPathOverride
                : nil
        } else {
            path = ZenCronToolchain.locate(fileManager: fileManager).crontabPath
        }
        guard let path else { throw ZenCrontabError.crontabUnavailable }
        return URL(fileURLWithPath: path)
    }

    /// Runs `crontab` with `arguments`. stdout and stderr are drained on
    /// dedicated threads while stdin is fed, so no pipe can stall the child;
    /// stdin is closed before waiting for exit so `crontab -` sees EOF.
    func run(_ arguments: [String], standardInput: Data?) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = try resolveExecutable()
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let inputPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }

        do {
            try process.run()
        } catch {
            throw ZenCrontabError.crontabUnavailable
        }

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        // `Int.max` keeps the whole crontab: truncating it would make the
        // next read-modify-write drop the user's entries.
        let outputDrain = SupportDirectoryArchive.BoundedPipeDrain(
            handle: outputHandle,
            limit: Int.max
        )
        let errorDrain = SupportDirectoryArchive.BoundedPipeDrain(
            handle: errorHandle,
            limit: Self.stderrLimit
        )

        var inputError: (any Error)?
        if let inputPipe, let standardInput {
            let writer = inputPipe.fileHandleForWriting
            Self.suppressSIGPIPE(on: writer)
            do {
                try writer.write(contentsOf: standardInput)
            } catch {
                // The child exited early (e.g. crontab refused the user);
                // its exit status explains why and is reported by the caller.
                inputError = error
            }
            try? writer.close()
        }

        process.waitUntilExit()
        let standardOutput = outputDrain.finish()
        let standardError = errorDrain.finish()
        try? outputHandle.close()
        try? errorHandle.close()

        return ProcessOutput(
            status: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: String(decoding: standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            inputError: inputError
        )
    }
}

// Not part of the file-private plumbing above: `SystemCronJobRunner` reuses it
// to feed a child's stdin safely.
extension SystemCrontabClient {
    /// Makes a write to a pipe whose reader already exited fail with `EPIPE`
    /// instead of raising SIGPIPE, whose default action would kill ZenCODE.
    static func suppressSIGPIPE(on handle: FileHandle) {
        #if canImport(Darwin)
        // Per-descriptor: no process-wide side effect.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        #elseif canImport(Glibc) || canImport(Musl)
        // No per-descriptor switch exists here; same process-wide disposition
        // FeatureKit installs before spawning feature processes.
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
    }
}
