//
//  RemoteHTTPBody.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
@preconcurrency import NIOCore
import NIOHTTP1

/// A unicast incremental HTTP response body.
///
/// Calling `next()` drives a bounded read from the underlying NIO channel. A
/// second iterator is rejected rather than duplicating or buffering a remote
/// stream. Cancelling a suspended `next()` closes the connection immediately.
public struct RemoteHTTPBody: AsyncSequence, Sendable {
    public typealias Element = Data

    let storage: RemoteHTTPBodyStorage

    init(storage: RemoteHTTPBodyStorage) {
        self.storage = storage
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage)
    }

    /// Creates an SSE decoder over this same unicast body. Do not also iterate
    /// the body bytes directly after creating this sequence.
    public func sseEvents() -> RemoteSSEEventStream {
        RemoteSSEEventStream(body: self)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let storage: RemoteHTTPBodyStorage
        private let identifier = UUID()
        private var isFinished = false

        fileprivate init(storage: RemoteHTTPBodyStorage) {
            self.storage = storage
        }

        public mutating func next() async throws -> Data? {
            guard !isFinished else {
                return nil
            }
            do {
                let chunk = try await storage.nextChunk(for: identifier)
                if chunk == nil {
                    isFinished = true
                }
                return chunk
            } catch {
                isFinished = true
                throw error
            }
        }
    }
}

actor RemoteHTTPBodyStorage {
    private var iterator: NIOAsyncChannelInboundStream<
        HTTPClientResponsePart
    >.AsyncIterator
    private let lease: RemoteChannelLease
    private var returnedHead = false
    private var bodyConsumerID: UUID?
    private var isReading = false
    private var isFinished = false

    init(
        inbound: NIOAsyncChannelInboundStream<HTTPClientResponsePart>,
        lease: RemoteChannelLease
    ) {
        iterator = inbound.makeAsyncIterator()
        self.lease = lease
    }

    deinit {
        lease.close()
    }

    func receiveHead() async throws -> HTTPResponseHead {
        try await withTaskCancellationHandler {
            guard !returnedHead else {
                throw RemoteTransportError.protocolViolation(
                    "HTTP response head requested more than once"
                )
            }
            while let part = try await nextPart() {
                switch part {
                case let .head(head):
                    returnedHead = true
                    return head
                case .body, .end:
                    finish()
                    throw RemoteTransportError.protocolViolation(
                        "HTTP body arrived before its response head"
                    )
                }
            }
            finish()
            throw RemoteTransportError.closed
        } onCancel: {
            lease.close()
        }
    }

    func nextChunk(for identifier: UUID) async throws -> Data? {
        return try await withTaskCancellationHandler(operation: { () async throws -> Data? in
            guard returnedHead else {
                throw RemoteTransportError.protocolViolation(
                    "HTTP body was read before the response head"
                )
            }
            guard !isFinished else {
                return nil
            }
            if let bodyConsumerID, bodyConsumerID != identifier {
                throw RemoteTransportError.bodyAlreadyConsumed
            }
            bodyConsumerID = identifier

            do {
                while let part = try await nextPart() {
                    switch part {
                    case .head:
                        finish()
                        throw RemoteTransportError.protocolViolation(
                            "HTTP response emitted more than one response head"
                        )
                    case let .body(buffer):
                        return Data(buffer.readableBytesView)
                    case .end:
                        finish()
                        return nil
                    }
                }
                finish()
                return nil
            } catch {
                finish()
                throw remoteTransportMappedError(error)
            }
        }, onCancel: {
            lease.close()
        })
    }

    /// `NIOAsyncChannel` exposes a non-Sendable iterator. This actor keeps the
    /// iterator isolated and rejects overlapping calls while it is suspended,
    /// preserving the underlying unicast/backpressure contract.
    private func nextPart() async throws -> HTTPClientResponsePart? {
        guard !isReading else {
            throw RemoteTransportError.concurrentBodyRead
        }
        isReading = true
        var localIterator = iterator
        do {
            let part = try await localIterator.next()
            iterator = localIterator
            isReading = false
            return part
        } catch {
            iterator = localIterator
            isReading = false
            throw error
        }
    }

    private func finish() {
        guard !isFinished else {
            return
        }
        isFinished = true
        lease.close()
    }
}
