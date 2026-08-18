//
//  RemoteSSEEventStream.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation

/// A decoded server-sent event.
public struct RemoteSSEEvent: Sendable, Equatable {
    public let event: String?
    public let data: String
    public let id: String?
    public let retryMilliseconds: Int?

    public init(
        event: String?,
        data: String,
        id: String?,
        retryMilliseconds: Int?
    ) {
        self.event = event
        self.data = data
        self.id = id
        self.retryMilliseconds = retryMilliseconds
    }
}

/// The stream produced no data for the configured post-head idle timeout.
///
/// Mirrors the WebSocket path's per-receive idle timeout (`nil` disables it):
/// a stalled SSE body would otherwise park the NIO read forever, because the
/// request timeout only covers connect plus the response head. Thrown after
/// the stream's lifetime token has torn the channel down, so the generation
/// surfaces a clear error instead of hanging.
public struct RemoteSSEIdleTimeoutError: Error, Sendable, Equatable, LocalizedError {
    /// The configured idle budget in nanoseconds. Zero is never produced; the
    /// stream only throws this once the budget exceeded a strictly positive
    /// value.
    public let timeoutNanoseconds: UInt64

    init(timeoutNanoseconds: UInt64) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public var errorDescription: String? {
        let seconds = timeoutNanoseconds / 1_000_000_000
        return "SSE stream stalled: no data for \(seconds)s (idle timeout)"
    }
}

public enum RemoteSSEParsingError: Error, Sendable, Equatable, LocalizedError {
    case lineLimitExceeded(maximumBytes: Int)
    case eventLimitExceeded(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .lineLimitExceeded(let maximumBytes):
            return "SSE line exceeds the \(maximumBytes)-byte limit."
        case .eventLimitExceeded(let maximumBytes):
            return "SSE event exceeds the \(maximumBytes)-byte limit."
        }
    }
}

/// A unicast SSE sequence layered over `RemoteHTTPBody`.
public struct RemoteSSEEventStream: AsyncSequence, Sendable {
    public typealias Element = RemoteSSEEvent

    /// Post-head idle budget: no body bytes for this long aborts the stream.
    /// Every received chunk (including SSE heartbeat comments) resets it.
    ///
    /// Mirrors the WebSocket path's configuration mechanism: an optional
    /// nanosecond knob where `nil` disables the watchdog. The default is
    /// deliberately generous — thinking models can stay silent for minutes
    /// between legitimate events — and reuses the WS convention so both paths
    /// can be tuned through one code-level knob.
    public static let defaultIdleTimeoutNanoseconds: UInt64 = 300 * 1_000_000_000
    public static let defaultMaximumLineBytes = 1 * 1_024 * 1_024
    public static let defaultMaximumEventBytes = 8 * 1_024 * 1_024

    private let body: RemoteHTTPBody
    private let idleTimeoutNanoseconds: UInt64?
    private let maximumLineBytes: Int
    private let maximumEventBytes: Int

    /// Creates an SSE decoder over the unicast body. The idle watchdog is
    /// enabled by default with `defaultIdleTimeoutNanoseconds`; `nil` or a
    /// non-positive value disables it, mirroring the WebSocket path's
    /// optional timeout knob.
    public init(
        body: RemoteHTTPBody,
        idleTimeoutNanoseconds: UInt64? = defaultIdleTimeoutNanoseconds,
        maximumLineBytes: Int = defaultMaximumLineBytes,
        maximumEventBytes: Int = defaultMaximumEventBytes
    ) {
        self.body = body
        self.idleTimeoutNanoseconds = (idleTimeoutNanoseconds ?? 0) > 0
            ? idleTimeoutNanoseconds
            : nil
        self.maximumLineBytes = Swift.max(1, maximumLineBytes)
        self.maximumEventBytes = Swift.max(1, maximumEventBytes)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            body: body,
            idleTimeoutNanoseconds: idleTimeoutNanoseconds,
            maximumLineBytes: maximumLineBytes,
            maximumEventBytes: maximumEventBytes
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var bodyIterator: RemoteHTTPBody.AsyncIterator
        private let idleTimeoutNanoseconds: UInt64?
        private var lineBytes: [UInt8] = []
        private var pendingEvents: [RemoteSSEEvent] = []
        private var builder = EventBuilder()
        private var reachedEnd = false
        private var previousByteWasCR = false
        private let maximumLineBytes: Int
        private let maximumEventBytes: Int

        fileprivate init(
            body: RemoteHTTPBody,
            idleTimeoutNanoseconds: UInt64?,
            maximumLineBytes: Int,
            maximumEventBytes: Int
        ) {
            bodyIterator = body.makeAsyncIterator()
            self.idleTimeoutNanoseconds = idleTimeoutNanoseconds
            self.maximumLineBytes = maximumLineBytes
            self.maximumEventBytes = maximumEventBytes
        }

        public mutating func next() async throws -> RemoteSSEEvent? {
            if !pendingEvents.isEmpty {
                return pendingEvents.removeFirst()
            }
            guard !reachedEnd else {
                return nil
            }

            while let chunk = try await bodyIterator.next(
                idleTimeoutNanoseconds: idleTimeoutNanoseconds
            ) {
                try consume(chunk)
                if !pendingEvents.isEmpty {
                    return pendingEvents.removeFirst()
                }
            }

            reachedEnd = true
            if !lineBytes.isEmpty {
                try consumeLine(lineBytes)
                lineBytes.removeAll(keepingCapacity: false)
            }
            if let event = builder.finish() {
                builder = EventBuilder()
                return event
            }
            return nil
        }

        private mutating func consume(_ chunk: Data) throws {
            for byte in chunk {
                if previousByteWasCR {
                    previousByteWasCR = false
                    if byte == 0x0A { // CRLF was already consumed at CR.
                        continue
                    }
                }
                if byte == 0x0A || byte == 0x0D { // LF or CR
                    try consumeLine(lineBytes)
                    lineBytes.removeAll(keepingCapacity: true)
                    previousByteWasCR = byte == 0x0D
                } else {
                    guard lineBytes.count < maximumLineBytes else {
                        throw RemoteSSEParsingError.lineLimitExceeded(
                            maximumBytes: maximumLineBytes
                        )
                    }
                    lineBytes.append(byte)
                }
            }
        }

        private mutating func consumeLine(_ bytes: [UInt8]) throws {
            guard !bytes.isEmpty else {
                if let event = builder.finish() {
                    pendingEvents.append(event)
                }
                builder = EventBuilder()
                return
            }

            // Comments are intentionally ignored, including heartbeat lines.
            guard bytes.first != 0x3A else { // ':'
                return
            }
            let line = String(decoding: bytes, as: UTF8.self)
            let separator = line.firstIndex(of: ":")
            let field: String
            let rawValue: String
            if let separator {
                field = String(line[..<separator])
                var value = String(line[line.index(after: separator)...])
                if value.first == " " {
                    value.removeFirst()
                }
                rawValue = value
            } else {
                field = line
                rawValue = ""
            }

            switch field {
            case "event":
                builder.event = rawValue
            case "data":
                try builder.appendDataLine(
                    rawValue,
                    maximumEventBytes: maximumEventBytes
                )
            case "id":
                // Per the SSE spec, an id containing NUL is ignored.
                if !rawValue.utf8.contains(0) {
                    builder.id = rawValue
                }
            case "retry":
                builder.retryMilliseconds = Int(rawValue)
            default:
                break
            }
        }
    }

    private struct EventBuilder {
        var event: String?
        var dataLines: [String] = []
        var id: String?
        var retryMilliseconds: Int?
        var dataBytes = 0

        mutating func appendDataLine(
            _ line: String,
            maximumEventBytes: Int
        ) throws {
            let separatorBytes = dataLines.isEmpty ? 0 : 1
            let addedBytes = line.utf8.count + separatorBytes
            guard addedBytes <= maximumEventBytes - dataBytes else {
                throw RemoteSSEParsingError.eventLimitExceeded(
                    maximumBytes: maximumEventBytes
                )
            }
            dataLines.append(line)
            dataBytes += addedBytes
        }

        mutating func finish() -> RemoteSSEEvent? {
            guard !dataLines.isEmpty else {
                return nil
            }
            return RemoteSSEEvent(
                event: event,
                data: dataLines.joined(separator: "\n"),
                id: id,
                retryMilliseconds: retryMilliseconds
            )
        }
    }
}
