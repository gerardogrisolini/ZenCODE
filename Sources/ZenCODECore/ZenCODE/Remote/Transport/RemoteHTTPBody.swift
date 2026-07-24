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
///
/// This handle and its `AsyncIterator` retain a shared `RemoteTransportLifetimeToken`.
/// The token is the sole owner of the connection's lifetime: releasing the last
/// copy (body, response, SSE sequence or iterator) closes the channel and tears
/// down the scoped run-task, so a consumer that stops draining the stream can
/// never leak the driver actor that the run-task retains.
public struct RemoteHTTPBody: AsyncSequence, Sendable {
    public typealias Element = Data

    let storage: RemoteHTTPBodyStorage
    let lifetime: RemoteTransportLifetimeToken

    init(storage: RemoteHTTPBodyStorage, lifetime: RemoteTransportLifetimeToken) {
        self.storage = storage
        self.lifetime = lifetime
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage, lifetime: lifetime)
    }

    /// Creates an SSE decoder over this same unicast body. Do not also iterate
    /// the body bytes directly after creating this sequence.
    public func sseEvents() -> RemoteSSEEventStream {
        RemoteSSEEventStream(body: self)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let storage: RemoteHTTPBodyStorage
        private let lifetime: RemoteTransportLifetimeToken
        private let identifier = UUID()
        private var isFinished = false

        fileprivate init(
            storage: RemoteHTTPBodyStorage,
            lifetime: RemoteTransportLifetimeToken
        ) {
            self.storage = storage
            self.lifetime = lifetime
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

/// The response metadata is deliberately Sendable because it crosses from the
/// scoped NIO channel task back to the transport caller.
struct RemoteHTTPResponseHead: Sendable {
    let status: Int
    let headers: [RemoteHTTPHeader]
}

/// Allows cancellation and the scoped channel task to race to complete a read
/// without ever resuming its checked continuation twice.
private final class RemoteHTTPReadContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

actor RemoteHTTPBodyStorage {
    private enum ReadRequest {
        case head(RemoteHTTPReadContinuation<RemoteHTTPResponseHead>)
        case chunk(RemoteHTTPReadContinuation<Data?>)
    }

    private let lease: RemoteChannelLease
    private var pendingRequests: [ReadRequest] = []
    private var requestWaiter: CheckedContinuation<ReadRequest?, Never>?
    private var returnedHead = false
    private var bodyConsumerID: UUID?
    private var isReading = false
    private var isFinished = false
    private var activeHead: RemoteHTTPReadContinuation<RemoteHTTPResponseHead>?
    private var activeChunk: RemoteHTTPReadContinuation<Data?>?

    init(lease: RemoteChannelLease) {
        self.lease = lease
    }

    deinit {
        lease.close()
    }

    func receiveHead() async throws -> RemoteHTTPResponseHead {
        try await withTaskCancellationHandler {
            guard !returnedHead else {
                throw RemoteTransportError.protocolViolation(
                    "HTTP response head requested more than once"
                )
            }
            guard !isFinished else {
                throw RemoteTransportError.closed
            }
            return try await withCheckedThrowingContinuation { continuation in
                let read = RemoteHTTPReadContinuation(continuation)
                activeHead = read
                enqueue(.head(read))
            }
        } onCancel: {
            lease.close()
        }
    }

    func nextChunk(for identifier: UUID) async throws -> Data? {
        try await withTaskCancellationHandler(operation: {
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
            guard !isReading else {
                throw RemoteTransportError.concurrentBodyRead
            }
            bodyConsumerID = identifier
            isReading = true

            do {
                let chunk: Data? = try await withCheckedThrowingContinuation {
                    continuation in
                    let read = RemoteHTTPReadContinuation(continuation)
                    activeChunk = read
                    enqueue(.chunk(read))
                }
                isReading = false
                activeChunk = nil
                return chunk
            } catch {
                isReading = false
                activeChunk = nil
                throw remoteTransportMappedError(error)
            }
        }, onCancel: {
            lease.close()
            Task { await self.cancelActiveRead() }
        })
    }

    /// Runs inside `NIOAsyncChannel.executeThenClose`. The NIO iterator remains
    /// a task-local value for its entire lifetime, while callers request exactly
    /// one body chunk at a time through this actor.
    nonisolated func run(
        inbound: NIOAsyncChannelInboundStream<HTTPClientResponsePart>
    ) async throws {
        var iterator = inbound.makeAsyncIterator()
        do {
            while let request = await self.nextRequest() {
                switch request {
                case let .head(continuation):
                    var receivedHead = false
                    while let part = try await iterator.next() {
                        switch part {
                        case let .head(head):
                            receivedHead = true
                            await self.completeHead(
                                RemoteHTTPResponseHead(
                                    status: Int(head.status.code),
                                    headers: head.headers.map {
                                        RemoteHTTPHeader(name: $0.name, value: $0.value)
                                    }
                                ),
                                continuation: continuation
                            )
                            break
                        case .body, .end:
                            let error = RemoteTransportError.protocolViolation(
                                "HTTP body arrived before its response head"
                            )
                            continuation.resume(throwing: error)
                            throw error
                        }
                        if receivedHead {
                            break
                        }
                    }
                    guard receivedHead else {
                        let error = RemoteTransportError.closed
                        continuation.resume(throwing: error)
                        throw error
                    }
                case let .chunk(continuation):
                    var returnedChunk = false
                    while let part = try await iterator.next() {
                        switch part {
                        case .head:
                            let error = RemoteTransportError.protocolViolation(
                                "HTTP response emitted more than one response head"
                            )
                            continuation.resume(throwing: error)
                            throw error
                        case let .body(buffer):
                            continuation.resume(
                                returning: Data(buffer.readableBytesView)
                            )
                            returnedChunk = true
                        case .end:
                            await self.finish()
                            continuation.resume(returning: nil)
                            returnedChunk = true
                        }
                        if returnedChunk {
                            break
                        }
                    }
                    if !returnedChunk {
                        await self.finish()
                        continuation.resume(returning: nil)
                    }
                }
            }
        } catch {
            await self.finish(throwing: error)
            throw error
        }
    }

    func fail(_ error: any Error) {
        finish(throwing: error)
    }

    /// Tears the driver down on behalf of the lifetime token when the last
    /// public handle is released while a consumer is no longer draining the
    /// stream. It reuses the normal terminal path so the run-task parked in
    /// `nextRequest()` is resumed, which lets `executeThenClose` complete and
    /// the driver be released. Idempotent.
    ///
    /// This is reached only through actual handle release, never through a
    /// channel-closure observation, so it cannot mask a Content-Length
    /// truncation error (the NIO iterator remains the sole framing authority
    /// while a consumer holds the handle).
    func abandon() {
        finish(throwing: RemoteTransportError.closed)
    }

    private func cancelActiveRead() {
        activeChunk?.resume(throwing: CancellationError())
    }

    private func completeHead(
        _ head: RemoteHTTPResponseHead,
        continuation: RemoteHTTPReadContinuation<RemoteHTTPResponseHead>
    ) {
        returnedHead = true
        if activeHead === continuation {
            activeHead = nil
        }
        continuation.resume(returning: head)
    }

    private func enqueue(_ request: ReadRequest) {
        if let requestWaiter {
            self.requestWaiter = nil
            requestWaiter.resume(returning: request)
        } else {
            pendingRequests.append(request)
        }
    }

    private func nextRequest() async -> ReadRequest? {
        guard !isFinished else {
            return nil
        }
        if !pendingRequests.isEmpty {
            return pendingRequests.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            requestWaiter = continuation
        }
    }

    private func finish(throwing error: (any Error)? = nil) {
        guard !isFinished else {
            return
        }
        isFinished = true
        lease.close()

        // Wake the producer parked in `nextRequest()` so `run()` returns and the
        // `NIOAsyncChannel.executeThenClose` closure can complete. Without this,
        // a channel close while the body producer is waiting for its next read
        // request leaves `run()` suspended forever, so `executeThenClose` never
        // finishes and the caller hangs.
        if let requestWaiter {
            self.requestWaiter = nil
            requestWaiter.resume(returning: nil)
        }

        let terminalError = error ?? RemoteTransportError.closed
        activeHead?.resume(throwing: terminalError)
        activeHead = nil
        if let activeChunk {
            if error == nil {
                activeChunk.resume(returning: nil)
            } else {
                activeChunk.resume(throwing: terminalError)
            }
            self.activeChunk = nil
        }
        for request in pendingRequests {
            switch request {
            case let .head(continuation):
                continuation.resume(throwing: terminalError)
            case let .chunk(continuation):
                if error == nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(throwing: terminalError)
                }
            }
        }
        pendingRequests.removeAll()
    }

    private func finish() {
        finish(throwing: nil)
    }
}
