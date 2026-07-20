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

/// A unicast SSE sequence layered over `RemoteHTTPBody`.
public struct RemoteSSEEventStream: AsyncSequence, Sendable {
    public typealias Element = RemoteSSEEvent

    private let body: RemoteHTTPBody

    init(body: RemoteHTTPBody) {
        self.body = body
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(body: body)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var bodyIterator: RemoteHTTPBody.AsyncIterator
        private var lineBytes: [UInt8] = []
        private var pendingEvents: [RemoteSSEEvent] = []
        private var builder = EventBuilder()
        private var reachedEnd = false

        fileprivate init(body: RemoteHTTPBody) {
            bodyIterator = body.makeAsyncIterator()
        }

        public mutating func next() async throws -> RemoteSSEEvent? {
            if !pendingEvents.isEmpty {
                return pendingEvents.removeFirst()
            }
            guard !reachedEnd else {
                return nil
            }

            while let chunk = try await bodyIterator.next() {
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
