//
//  SystemLogEmitter.swift
//  ZenCODE
//

import Foundation
#if canImport(OSLog)
import OSLog
import Synchronization
#endif

/// Severity of a system-log record, mapped onto the platform's system logger.
enum SystemLogSeverity: Sendable, Equatable {
    case debug
    case info
    case notice
    case warning
    case error

    /// syslog priority component passed to `logger(1)` on Linux/WSL. The
    /// facility is fixed to `user`: entries belong to the invoking user's
    /// session, not to a daemon.
    var syslogPriority: String {
        switch self {
        case .debug:
            return "user.debug"
        case .info:
            return "user.info"
        case .notice:
            return "user.notice"
        case .warning:
            return "user.warning"
        case .error:
            return "user.err"
        }
    }
}

/// One pre-rendered, public, already-redacted system-log record.
///
/// The message must already be redacted and bounded by the producer: this
/// emitter owns routing and severity only, never redaction. `category` becomes
/// the platform log category so entries stay identifiable and filterable.
struct SystemLogRecord: Sendable, Equatable {
    let category: String
    let severity: SystemLogSeverity
    let message: String
}

/// Shared backend that emits records through the platform system logger.
///
/// Apple platforms use Swift's ``Logger`` and Unified Logging directly under
/// the `com.zencode.zen` subsystem. The open-source toolchain does not ship
/// `OSLog`, so Linux/WSL bridges to the operating system's `logger(1)` command,
/// which still targets syslog or the systemd journal instead of any
/// application-owned file.
///
/// Emission is best-effort and synchronous: every failure path (missing binary,
/// spawn error, nonzero exit) is isolated so observational logging can never
/// alter tool behavior. No fallback to stderr, files, or stdout exists. The
/// emitter never appends timestamps or process metadata; the system logger
/// supplies them. On Linux the child's standard input, output, and error are
/// all bound to `FileHandle.nullDevice`, so a `logger(1)` diagnostic or usage
/// error can never leak into the ACP/chat stdout stream or the visible stderr
/// channel.
enum SystemLogEmitter {
    /// Unified Logging subsystem shared by every ZenCODE record.
    static let subsystem = "com.zencode.zen"

    /// syslog tag used by the `logger(1)` bridge on Linux/WSL.
    static let linuxTag = "zen"

    /// Absolute `logger(1)` candidates probed on Linux/WSL, without a shell.
    private static let loggerCommandCandidates = [
        "/usr/bin/logger",
        "/bin/logger"
    ]

    #if canImport(OSLog)
    private static let loggers = Mutex<[String: Logger]>([:])

    private static func logger(category: String) -> Logger {
        loggers.withLock { loggers in
            if let cached = loggers[category] {
                return cached
            }
            let created = Logger(subsystem: subsystem, category: category)
            loggers[category] = created
            return created
        }
    }
    #endif

    /// Arguments handed to `logger(1)` for one record.
    ///
    /// Built on every platform (not only Linux/WSL) so the tag, syslog
    /// priority, and the `--` end-of-options guard can be verified by tests
    /// without ever spawning the real binary or writing to the system log.
    static func loggerCommandArguments(for record: SystemLogRecord) -> [String] {
        [
            "-t", linuxTag,
            "-p", record.severity.syslogPriority,
            "--", record.message
        ]
    }

    /// Builds the configured, **not started** `logger(1)` child process.
    ///
    /// Cross-platform for the same reason as ``loggerCommandArguments(for:)``:
    /// the argument vector and the null stdio wiring are observable contracts
    /// and must be testable without side effects.
    static func makeLoggerProcess(
        executable: String,
        record: SystemLogRecord
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = loggerCommandArguments(for: record)
        // Detach every stream from the parent: `logger(1)` must never write a
        // usage or diagnostic line onto the ACP/chat stdout stream or stderr,
        // and must never inherit or consume the parent's stdin.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// First executable `logger(1)` candidate, probed without a shell.
    /// `isExecutableFile` is a seam so tests can drive resolution
    /// deterministically on any host.
    static func resolveLoggerExecutable(
        isExecutableFile: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) -> String? {
        loggerCommandCandidates.first(where: isExecutableFile)
    }

    /// Emits one record. The message must be redacted, bounded, and safe to
    /// publish as `privacy: .public` before it reaches this API.
    static func emit(_ record: SystemLogRecord) {
        #if canImport(OSLog)
        // The record is pre-redacted by contract; OSLog must publish it as-is
        // so `log show`/Console display the full diagnostic text.
        switch record.severity {
        case .debug:
            logger(category: record.category).debug("\(record.message, privacy: .public)")
        case .info:
            logger(category: record.category).info("\(record.message, privacy: .public)")
        case .notice:
            logger(category: record.category).notice("\(record.message, privacy: .public)")
        case .warning:
            logger(category: record.category).warning("\(record.message, privacy: .public)")
        case .error:
            logger(category: record.category).error("\(record.message, privacy: .public)")
        }
        #else
        emitThroughSystemLoggerCommand(record)
        #endif
    }

    #if !canImport(OSLog)
    /// Bridges one record to the operating system's `logger(1)` command.
    ///
    /// The message is passed as a single `--`-terminated argument without any
    /// shell, and the child's stdio is fully bound to the null device. A
    /// missing binary, a spawn failure, or a nonzero exit status is silently
    /// isolated: system logging is observational and must never alter tool
    /// behavior, and there is deliberately no stderr/file fallback.
    private static func emitThroughSystemLoggerCommand(
        _ record: SystemLogRecord
    ) {
        guard let executable = resolveLoggerExecutable() else {
            return
        }
        let process = makeLoggerProcess(executable: executable, record: record)
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Isolated by contract: never surface or propagate.
        }
    }
    #endif
}
