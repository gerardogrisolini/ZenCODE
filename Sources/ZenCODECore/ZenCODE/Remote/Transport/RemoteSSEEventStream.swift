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

    private let body: RemoteHTTPBody
    private let idleTimeoutNanoseconds: UInt64?

    /// Creates an SSE decoder over the unicast body. The idle watchdog is
    /// enabled by default with `defaultIdleTimeoutNanoseconds`; `nil` or a
    /// non-positive value disables it, mirroring the WebSocket path's
    /// optional timeout knob.
    public init(
        body: RemoteHTTPBody,
        idleTimeoutNanoseconds: UInt64? = defaultIdleTimeoutNanoseconds
    ) {
        self.body = body
        self.idleTimeoutNanoseconds = (idleTimeoutNanoseconds ?? 0) > 0
            ? idleTimeoutNanoseconds
            : nil
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            body: body,
            idleTimeoutNanoseconds: idleTimeoutNanoseconds
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var bodyIterator: RemoteHTTPBody.AsyncIterator
        private let idleTimeoutNanoseconds: UInt64?
        private var lineBytes: [UInt8] = []
        private var pendingEvents: [RemoteSSEEvent] = []
        private var builder = EventBuilder()
        private var reachedEnd = false

        fileprivate init(
            body: RemoteHTTPBody,
            idleTimeoutNanoseconds: UInt64?
        ) {
            bodyIterator = body.makeAsyncIterator()
            self.idleTimeoutNanoseconds = idleTimeoutNanoseconds
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
                consume(chunk)
                if !pendingEvents.isEmpty {
                    return pendingEvents.removeFirst()
                }
            }

            reachedEnd = true
            if !lineBytes.isEmpty {
                consumeLine(lineBytes)
                lineBytes.removeAll(keepingCapacity: false)
            }
            if let event = builder.finish() {
                builder = EventBuilder()
                return event
            }
            return nil
        }

        private mutating func consume(_ chunk: Data) {
            for byte in chunk {
                if byte == 0x0A { // LF
                    if lineBytes.last == 0x0D { // CRLF
                        lineBytes.removeLast()
                    }
                    consumeLine(lineBytes)
                    lineBytes.removeAll(keepingCapacity: true)
                } else {
                    lineBytes.append(byte)
                }
            }
        }

        private mutating func consumeLine(_ bytes: [UInt8]) {
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
                builder.dataLines.append(rawValue)
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
