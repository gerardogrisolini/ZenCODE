//
//  StdioLineReader.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization

public final class StdioLineReader: Sendable {
    /// Outcome of a single `read(2)` attempt on the input descriptor.
    private enum ReadOutcome {
        /// Bytes were appended to the buffer.
        case bytesRead
        /// The read was interrupted or would block; poll again.
        case retry
        /// EOF or an unrecoverable read error; the descriptor is finished.
        case endOfInput
    }

    /// `POLLHUP | POLLERR | POLLNVAL`: the peer closed the pipe, the descriptor
    /// errored, or it is not open. `poll` reports these in `revents` even when
    /// they were not requested in `events`, and it returns immediately every
    /// time, so ignoring them burns a full CPU core in a tight loop.
    private static let terminalPollEvents = Int16(POLLHUP | POLLERR | POLLNVAL)
    private static let pollTimeoutMilliseconds: Int32 = 200

    private let fileDescriptor: Int32
    private let buffer = Mutex<[UInt8]>([])
    /// Latches once the descriptor reports EOF/HUP/ERR so later `readLine`
    /// calls drain the remainder and stop instead of polling a dead fd.
    private let didReachEndOfInput = Mutex<Bool>(false)
    /// Number of times a read or drain has waited in `poll`.
    ///
    /// Makes "this reader is blocked waiting for input" observable instead of
    /// merely assumed: a caller (in practice a test asserting cancellation
    /// behaviour) can order itself against an in-flight read rather than
    /// sleeping and hoping the loop was entered.
    private let pollWaits = Mutex<UInt64>(0)

    public init() {
        self.fileDescriptor = STDIN_FILENO
    }

    /// Test seam: read from an arbitrary descriptor (for example a pipe) so
    /// EOF/HUP/ERR handling can be exercised deterministically.
    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// `true` once the input descriptor reported EOF, HUP, or an error.
    var hasReachedEndOfInput: Bool {
        didReachEndOfInput.withLock { $0 }
    }

    /// How many times this reader has entered a `poll` wait.
    var pollWaitCount: UInt64 {
        pollWaits.withLock { $0 }
    }

    public func readLine() -> String? {
        readLineInternal(shouldCancel: nil)
    }

    /// Cancellation-aware variant used by the off-actor bridges.
    ///
    /// `readLine()` alone observes only `Task.isCancelled`, which is always
    /// `false` on the dedicated dispatch queue used by ``TerminalBlockingRead``.
    /// A read bridged off the cooperative pool would therefore never see a
    /// cancellation and would hold stdin until a line happened to arrive. The
    /// caller supplies the bridge's token so the poll loop unwinds at its next
    /// timeout boundary and the awaiting side can resume.
    func readLine(shouldCancel: @escaping @Sendable () -> Bool) -> String? {
        readLineInternal(shouldCancel: shouldCancel)
    }

    private func readLineInternal(
        shouldCancel: (@Sendable () -> Bool)?
    ) -> String? {
        // Cancellation can arrive either as task cancellation (detached reader
        // in the ACP launcher) or through the bridge token (off-actor TUI
        // reads). Both must end the poll loop.
        func isCancelled() -> Bool {
            Task.isCancelled || shouldCancel?() == true
        }

        while true {
            // Cooperative cancellation: StdioLineReader is driven by a detached
            // task in the ACP launcher whose `onTermination` cancels this task.
            // `availableData` blocks indefinitely and would never observe that
            // cancellation, so poll with a short timeout instead and stop as
            // soon as the read is cancelled.
            if isCancelled() {
                return nil
            }
            if let line = takeBufferedLine() {
                return line
            }
            if hasReachedEndOfInput {
                return takeBufferedRemainder()
            }

            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            pollWaits.withLock { $0 &+= 1 }
            let pollResult = poll(&descriptor, 1, Self.pollTimeoutMilliseconds)
            if isCancelled() {
                return nil
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return finishInput()
            }
            if pollResult == 0 {
                // Timed out with no events: re-check cancellation and poll again.
                continue
            }

            let revents = descriptor.revents
            if (revents & Int16(POLLIN)) != 0 {
                switch readAvailableBytes() {
                case .bytesRead:
                    continue
                case .endOfInput:
                    return finishInput()
                case .retry:
                    // POLLIN without readable bytes only happens on a hung-up or
                    // broken descriptor; treating it as retryable would spin.
                    if (revents & Self.terminalPollEvents) != 0 {
                        return finishInput()
                    }
                    continue
                }
            }
            if (revents & Self.terminalPollEvents) != 0 {
                return finishInput()
            }
            // Any other reported event (e.g. POLLPRI) carries no readable data;
            // keep polling with the timeout rather than busy-looping.
        }
    }

    public func drainBufferedLines(waitMilliseconds: Int32 = 0) -> [String] {
        drainBufferedLines(waitMilliseconds: waitMilliseconds, shouldCancel: nil)
    }

    /// Cancellation-aware drain used by the off-actor paste path.
    ///
    /// The drain keeps reading while a producer keeps feeding the descriptor, so
    /// without a cancellation signal a continuously written pipe never ends the
    /// loop. Since ``TerminalBlockingRead`` now resumes its caller only after the
    /// body returns, such a drain would hold the whole teardown, not just this
    /// read. The token is therefore polled on every iteration. If the token
    /// fires, the buffered data is discarded instead of extracted: a continuous
    /// producer may have filled the buffer faster than the cancellation could
    /// land, and converting that backlog into lines the caller will throw away
    /// would defeat the prompt return the cancellation promised.
    func drainBufferedLines(
        waitMilliseconds: Int32,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> [String] {
        if waitMilliseconds > 0 {
            drainPendingInput(
                waitMilliseconds: waitMilliseconds,
                shouldCancel: shouldCancel
            )
        }

        // A continuous producer can pile megabytes into the buffer while the
        // drain polls; once the drain was cancelled, extracting those lines is
        // wasted work whose result the caller discards anyway. Dropping the
        // buffer here keeps the return path as prompt as the cancellation
        // latency already paid, instead of paying for an extraction whose
        // output is thrown away.
        if Task.isCancelled || shouldCancel?() == true {
            buffer.withLock { $0.removeAll() }
            return []
        }

        return buffer.withLock { buffer in
            var lines: [String] = []
            var sliceStart = buffer.startIndex
            for index in buffer.indices {
                if buffer[index] == 0x0a {
                    lines.append(Self.string(fromLineBytes: Array(buffer[sliceStart..<index])))
                    sliceStart = buffer.index(after: index)
                }
            }
            if sliceStart < buffer.endIndex {
                lines.append(Self.string(fromLineBytes: Array(buffer[sliceStart..<buffer.endIndex])))
            }
            buffer.removeAll()
            return lines
        }
    }

    private func finishInput() -> String? {
        didReachEndOfInput.withLock { $0 = true }
        return takeBufferedRemainder()
    }

    private func readAvailableBytes() -> ReadOutcome {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
            read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        if readCount > 0 {
            let chunk = Array(bytes.prefix(readCount))
            buffer.withLock { buffer in
                buffer.append(contentsOf: chunk)
            }
            return .bytesRead
        }
        if readCount == 0 {
            return .endOfInput
        }
        // A signal or a spurious wake-up is recoverable; anything else means the
        // descriptor is unusable and must not be polled again.
        if errno == EINTR || errno == EAGAIN {
            return .retry
        }
        return .endOfInput
    }

    private func takeBufferedLine() -> String? {
        buffer.withLock { buffer in
            guard let newlineIndex = buffer.firstIndex(of: 0x0a) else {
                return nil
            }
            let lineBytes = Array(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            return Self.string(fromLineBytes: lineBytes)
        }
    }

    private func takeBufferedRemainder() -> String? {
        buffer.withLock { buffer in
            guard !buffer.isEmpty else {
                return nil
            }
            let lineBytes = buffer
            buffer.removeAll()
            return Self.string(fromLineBytes: lineBytes)
        }
    }

    private func drainPendingInput(
        waitMilliseconds: Int32,
        shouldCancel: (@Sendable () -> Bool)?
    ) {
        func isCancelled() -> Bool {
            Task.isCancelled || shouldCancel?() == true
        }

        var timeout = waitMilliseconds
        while true {
            // A producer that keeps writing keeps `poll` ready forever, so the
            // "no more data" exit is not reachable under load. Cancellation is
            // the only other way out and must be checked before every wait as
            // well as after it: the token can be set while this thread sits in
            // `poll`, and the awaiting side stays suspended until this returns.
            if isCancelled() {
                return
            }

            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            pollWaits.withLock { $0 &+= 1 }
            let pollResult = poll(&descriptor, 1, timeout)
            if isCancelled() {
                return
            }
            guard pollResult > 0 else {
                if pollResult < 0, errno != EINTR {
                    didReachEndOfInput.withLock { $0 = true }
                }
                return
            }
            guard (descriptor.revents & Int16(POLLIN)) != 0 else {
                if (descriptor.revents & Self.terminalPollEvents) != 0 {
                    didReachEndOfInput.withLock { $0 = true }
                }
                return
            }

            switch readAvailableBytes() {
            case .bytesRead:
                timeout = 25
            case .endOfInput:
                didReachEndOfInput.withLock { $0 = true }
                return
            case .retry:
                return
            }
        }
    }

    private static func string(fromLineBytes bytes: [UInt8]) -> String {
        String(decoding: trimmedCarriageReturn(from: bytes), as: UTF8.self)
    }

    private static func trimmedCarriageReturn(from bytes: [UInt8]) -> [UInt8] {
        guard bytes.last == 0x0d else {
            return bytes
        }
        return Array(bytes.dropLast())
    }
}
