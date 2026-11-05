//
//  ZenCODETelegramProcess.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 05/11/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization

// MARK: - Log

/// The log of `zen --telegram`: one line per event on standard error, each
/// `<timestamp> <text>`, the timestamp being the local time in ISO 8601 to
/// the second with its offset
/// (`2026-11-05T10:00:00+01:00 Telegram remote control is active.`).
///
/// A text of several lines becomes one log line for each line that is not
/// blank, each with its own timestamp; blank lines are dropped. The mode logs
/// its startup, the notices of the Telegram channel, its errors, and its
/// stop; never a prompt or a response.
struct ZenCODETelegramLog: Sendable {
    /// Receives the formatted lines of one event, each ending with a newline.
    typealias Sink = @Sendable (String) -> Void

    private let sink: Sink
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date

    init(
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        sink: @escaping Sink
    ) {
        self.sink = sink
        self.timeZone = timeZone
        self.now = now
    }

    /// The log of the process: the preserved standard error
    /// (``AgentOutput/standardError``), written with `write(2)` and never
    /// fatal (see ``ZenCODETelegramOutput/write(_:to:)``).
    static let standardError = ZenCODETelegramLog { lines in
        ZenCODETelegramOutput.write(lines, to: AgentOutput.standardError.fileDescriptor)
    }

    /// Logs `text`, one timestamped line for each line that is not blank.
    func log(_ text: String) {
        let lines = Self.formattedLines(text, date: now(), timeZone: timeZone)
        guard !lines.isEmpty else { return }
        sink(lines)
    }

    /// `text` as log lines at `date`: every line that is not blank, prefixed
    /// by the timestamp and a space and ended by a newline; empty when every
    /// line is blank.
    static func formattedLines(_ text: String, date: Date, timeZone: TimeZone) -> String {
        let stamp = timestamp(for: date, in: timeZone)
        var output = ""
        for line in text.split(whereSeparator: \.isNewline)
        where line.contains(where: { !$0.isWhitespace }) {
            output += "\(stamp) \(line)\n"
        }
        return output
    }

    /// `date` in `timeZone` as ISO 8601 to the second, with the offset in
    /// hours and minutes (`+00:00` rather than `Z` for UTC).
    static func timestamp(for date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let offsetSeconds = timeZone.secondsFromGMT(for: date)
        let offsetMinutes = abs(offsetSeconds) / 60
        let sign = offsetSeconds < 0 ? "-" : "+"
        return "\(padded(components.year, width: 4))-\(padded(components.month))-\(padded(components.day))"
            + "T\(padded(components.hour)):\(padded(components.minute)):\(padded(components.second))"
            + "\(sign)\(padded(offsetMinutes / 60)):\(padded(offsetMinutes % 60))"
    }

    private static func padded(_ value: Int?, width: Int = 2) -> String {
        let digits = String(value ?? 0)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

// MARK: - Output

/// The writes of `zen --telegram` on the descriptors the process keeps.
///
/// After the ssh session that started the process ends, standard error may be
/// a pty that answers `EIO` or a pipe whose reader is gone (`EPIPE`).
/// `FileHandle.write(_:)`, which `FileHandle.writeString(_:)` ends in, is
/// fatal on such an error (an Objective-C exception on macOS, a `try!` on
/// Linux), so the mode writes with `write(2)` and ignores every error, and
/// SIGPIPE is suppressed on those descriptors
/// (``ZenCODETelegramProcess/installSafeOutput(log:)``).
enum ZenCODETelegramOutput {
    /// Serializes the writes, so the lines of two events never interleave.
    private static let lock = Mutex(())

    /// Writes `text` to `fileDescriptor` whole, retrying on `EINTR` and after
    /// a partial write, and gives up silently on any other error.
    static func write(_ text: String, to fileDescriptor: Int32) {
        let bytes = Array(text.utf8)
        lock.withLock { _ in
            writeAll(bytes, to: fileDescriptor)
        }
    }

    private static func writeAll(_ bytes: [UInt8], to fileDescriptor: Int32) {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let written = Darwin.write(fileDescriptor, base + offset, buffer.count - offset)
                #else
                let written = Glibc.write(fileDescriptor, base + offset, buffer.count - offset)
                #endif
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// The process-wide writer of ``TerminalOutputSynchronization`` in this
    /// mode: what is written to the preserved standard error goes to `log`,
    /// a timestamped line per line; what is written to the preserved standard
    /// output (nothing, in this mode) is written with `write(2)` as it is,
    /// never fatal and never moved to standard error. Every other handle
    /// keeps the ordinary write.
    static func writer(
        standardErrorDescriptor: Int32,
        standardOutputDescriptor: Int32,
        log: ZenCODETelegramLog
    ) -> TerminalOutputSynchronization.Writer {
        { string, fileHandle in
            switch fileHandle.fileDescriptor {
            case standardErrorDescriptor:
                log.log(string)
                return true
            case standardOutputDescriptor:
                write(string, to: standardOutputDescriptor)
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Process

/// What `zen --telegram` changes in its process before the session starts.
enum ZenCODETelegramProcess {
    /// Detaches the process from the terminal it was started from: SIGHUP is
    /// ignored, so closing the ssh session does not end it, and standard
    /// input reads `/dev/null`, so nothing can wait on the terminal.
    static func detachFromTerminal() {
        _ = signal(SIGHUP, SIG_IGN)
        let nullDescriptor = open("/dev/null", O_RDONLY)
        guard nullDescriptor >= 0 else { return }
        _ = dup2(nullDescriptor, STDIN_FILENO)
        if nullDescriptor != STDIN_FILENO {
            close(nullDescriptor)
        }
    }

    /// Makes every write of the process to its preserved standard error and
    /// output safe (see ``ZenCODETelegramOutput``): SIGPIPE is suppressed on
    /// them (per descriptor on macOS, for the process on Linux), and the
    /// process-wide writer of ``TerminalOutputSynchronization`` is installed,
    /// so `AgentOutput.standardError.writeString(_:)` from any subsystem (the
    /// consent authorizer's diagnostic, for one) becomes timestamped log lines.
    /// The memory diagnostics, which write to standard error without
    /// `writeString`, are routed to the log as well.
    ///
    /// The writer is global to the process and stays installed until it
    /// exits: only the `--telegram` path installs it, so no other mode
    /// changes.
    static func installSafeOutput(log: ZenCODETelegramLog) {
        SystemCrontabClient.suppressSIGPIPE(on: AgentOutput.standardError)
        SystemCrontabClient.suppressSIGPIPE(on: AgentOutput.standardOutput)
        TerminalOutputSynchronization.installWriter(
            ZenCODETelegramOutput.writer(
                standardErrorDescriptor: AgentOutput.standardError.fileDescriptor,
                standardOutputDescriptor: AgentOutput.standardOutput.fileDescriptor,
                log: log
            )
        )
        MemorySemanticFallbackDiagnostics.installVisibleErrorSink { line in
            log.log(line)
        }
    }
}

// MARK: - Signals

/// A signal that stops `zen --telegram`.
enum ZenCODETelegramStopSignal: Sendable, Equatable {
    case interrupt
    case terminate

    /// The name the log gives it: `Stopping (SIGTERM).`
    var name: String {
        switch self {
        case .interrupt: "SIGINT"
        case .terminate: "SIGTERM"
        }
    }
}

/// What the process does with each stop signal it receives: the first one
/// stops the session, every later one forces the exit at once.
final class ZenCODETelegramStopSignalLatch: Sendable {
    enum Action: Sendable, Equatable {
        /// Stop the session cleanly.
        case stop(ZenCODETelegramStopSignal)
        /// A stop is already running: exit now, with status 1.
        case forceExit
    }

    private let received = Mutex(false)

    func receive(_ signal: ZenCODETelegramStopSignal) -> Action {
        received.withLock { received in
            defer { received = true }
            return received ? .forceExit : .stop(signal)
        }
    }
}

#if canImport(Darwin)
private typealias ZenCODETelegramSignalDisposition = sig_t
#else
private typealias ZenCODETelegramSignalDisposition = __sighandler_t
#endif

/// The SIGINT and SIGTERM handling of `zen --telegram`, with the schema of
/// `TerminalSignalRestoration` (the disposition set to `SIG_IGN`, the signal
/// read by a `DispatchSourceSignal`) on a queue and sources of its own, so it
/// never touches that type's registrations. SIGTERM is always handled; a
/// SIGINT the parent left ignored (as a non-interactive shell does for its
/// background commands) stays ignored, as the Unix convention wants. SIGHUP
/// is not handled: it is ignored
/// (``ZenCODETelegramProcess/detachFromTerminal()``).
///
/// The first signal is yielded to ``stopSignals``; a later one, while the stop
/// runs, logs `Forced stop.` and calls `forceExit`. The sources live as long
/// as the monitor, which the process keeps until it exits.
final class ZenCODETelegramSignalMonitor: @unchecked Sendable {
    /// One signal the monitor handles.
    struct HandledSignal: Sendable {
        let signalNumber: Int32
        let stopSignal: ZenCODETelegramStopSignal
        /// Whether a `SIG_IGN` inherited from the parent is kept, with no
        /// source: the signal then never reaches the monitor.
        let keepsInheritedIgnore: Bool
    }

    /// SIGTERM, always handled, and SIGINT, unless the parent ignored it.
    static let processSignals = [
        HandledSignal(signalNumber: SIGTERM, stopSignal: .terminate, keepsInheritedIgnore: false),
        HandledSignal(signalNumber: SIGINT, stopSignal: .interrupt, keepsInheritedIgnore: true),
    ]

    // Immutable after `init`; the sources are only retained.
    let stopSignals: AsyncStream<ZenCODETelegramStopSignal>
    private let sources: [any DispatchSourceSignal]

    private static let queue = DispatchQueue(label: "zencode.telegram.signals")

    private init(stopSignals: AsyncStream<ZenCODETelegramStopSignal>, sources: [any DispatchSourceSignal]) {
        self.stopSignals = stopSignals
        self.sources = sources
    }

    /// Installs the handling of `signals` (the process's SIGTERM and SIGINT;
    /// a test passes signals of its own) for the rest of the process.
    static func start(
        log: ZenCODETelegramLog,
        signals: [HandledSignal] = processSignals,
        forceExit: @escaping @Sendable () -> Void
    ) -> ZenCODETelegramSignalMonitor {
        let (stopSignals, continuation) = AsyncStream.makeStream(of: ZenCODETelegramStopSignal.self)
        let latch = ZenCODETelegramStopSignalLatch()
        var sources: [any DispatchSourceSignal] = []
        for handled in signals {
            let previous = signal(handled.signalNumber, SIG_IGN)
            if dispositionValue(previous) == dispositionValue(SIG_ERR) { continue }
            if handled.keepsInheritedIgnore, dispositionValue(previous) == dispositionValue(SIG_IGN) {
                // Ignored by the parent: it stays ignored, with no source.
                continue
            }
            let stopSignal = handled.stopSignal
            let source = DispatchSource.makeSignalSource(signal: handled.signalNumber, queue: queue)
            source.setEventHandler {
                switch latch.receive(stopSignal) {
                case let .stop(signal):
                    continuation.yield(signal)
                case .forceExit:
                    log.log("Forced stop.")
                    forceExit()
                }
            }
            source.resume()
            sources.append(source)
        }
        return ZenCODETelegramSignalMonitor(stopSignals: stopSignals, sources: sources)
    }

    private static func dispositionValue(_ disposition: ZenCODETelegramSignalDisposition?) -> Int {
        unsafeBitCast(disposition, to: Int.self)
    }
}
