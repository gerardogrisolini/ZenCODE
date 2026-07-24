//
//  RemoteWebSocketConnection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
@preconcurrency import NIOCore
import NIOWebSocket

/// Nil-safe holder for a single parked WebSocket receive continuation, so a
/// caller cancellation and the read loop can both try to resume it without
/// ever resuming a `CheckedContinuation` twice.
private final class RemoteWebSocketReadHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RemoteWebSocketFrame?, any Error>?

    init(_ continuation: CheckedContinuation<RemoteWebSocketFrame?, any Error>) {
        self.continuation = continuation
    }

    func resume(returning frame: RemoteWebSocketFrame?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: frame)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

/// Actor-isolated WebSocket connection returned by `RemoteTransportCore`.
///
/// This is a thin public handle. All NIO state, queues, waiters and frame
/// handling live in the internal `RemoteWebSocketDriver` actor, and this handle
/// retains the driver together with a `RemoteTransportLifetimeToken`. Releasing
/// the last reference to the connection closes the channel and tears down the
/// scoped run-task, so a caller that stops using an upgraded connection can no
/// longer leak the driver actor the run-task retains.
///
/// All access to NIO's inbound stream and outbound writer remains inside the
/// `executeThenClose` scope that owns the channel. Public operations are queued
/// by the driver and serviced by two scoped loops: one drains write requests,
/// the other drains read requests. Keeping the loops independent is required
/// for correctness: a caller must be able to send a frame while another caller
/// is already parked on `receive()`, otherwise a request/response protocol over
/// an idle connection deadlocks. Delegating to the reentrant driver actor
/// preserves that property.
public actor RemoteWebSocketConnection {
    let driver: RemoteWebSocketDriver
    private let lifetime: RemoteTransportLifetimeToken

    init(
        driver: RemoteWebSocketDriver,
        lifetime: RemoteTransportLifetimeToken
    ) {
        self.driver = driver
        self.lifetime = lifetime
    }

    /// Sends one WebSocket frame. Client frames are always masked as required
    /// by RFC 6455, including control frames.
    public func send(_ frame: RemoteWebSocketFrame) async throws {
        try await driver.send(frame)
    }

    /// Receives one frame, or `nil` after a clean peer/channel closure.
    public func receive() async throws -> RemoteWebSocketFrame? {
        try await driver.receive()
    }

    /// Sends a close control frame and closes the underlying transport channel.
    /// Callers that require the peer close acknowledgement can use `send(.close)`
    /// followed by `receive()` instead.
    public func close(
        code: UInt16 = 1000,
        reason: String? = nil
    ) async throws {
        try await driver.close(code: code, reason: reason)
    }
}

/// Internal driver actor for an upgraded WebSocket connection.
///
/// It owns the queues, waiters, the read/write loops, the frame codec and the
/// channel lease. The scoped run-task captures this actor (strongly) and a weak
/// reference back to the lifetime token; the public handle captures the token.
/// `abandon()`, invoked from the token when the last handle is released, wakes
/// both loop waiters so the run-task can complete and release this actor even
/// when the caller dropped the connection without closing it.
actor RemoteWebSocketDriver {
    private enum WriteRequest {
        case send(RemoteWebSocketFrame, CheckedContinuation<Void, any Error>)
        case close(UInt16, String?, CheckedContinuation<Void, any Error>)
    }

    private typealias ReadRequest = RemoteWebSocketReadHolder

    private let allocator: ByteBufferAllocator
    private let lease: RemoteChannelLease
    private var pendingWrites: [WriteRequest] = []
    private var pendingReads: [ReadRequest] = []
    private var writeWaiter: CheckedContinuation<WriteRequest?, Never>?
    private var readWaiter: CheckedContinuation<ReadRequest?, Never>?
    private var isReceiving = false
    private var activeRead: ReadRequest?
    private var didSendClose = false
    private var isClosed = false

    init(allocator: ByteBufferAllocator, lease: RemoteChannelLease) {
        self.allocator = allocator
        self.lease = lease
    }

    deinit {
        lease.close()
    }

    /// Sends one WebSocket frame. Client frames are always masked as required
    /// by RFC 6455, including control frames.
    func send(_ frame: RemoteWebSocketFrame) async throws {
        guard !isClosed else {
            throw RemoteTransportError.closed
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueWrite(.send(frame, continuation))
            }
        } onCancel: {
            lease.close()
        }
    }

    /// Receives one frame, or `nil` after a clean peer/channel closure.
    func receive() async throws -> RemoteWebSocketFrame? {
        guard !isClosed else {
            return nil
        }
        guard !isReceiving else {
            throw RemoteTransportError.concurrentWebSocketReceive
        }
        isReceiving = true
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let holder = RemoteWebSocketReadHolder(continuation)
                    activeRead = holder
                    enqueueRead(holder)
                }
            } onCancel: {
                // Resume the parked receive directly so the caller observes
                // cancellation rather than a clean EOF, then close the channel.
                // The actor hop guarantees `activeRead` is set before this runs.
                lease.close()
                Task { await self.cancelActiveReceive() }
            }
        } catch {
            isReceiving = false
            throw remoteTransportMappedError(error)
        }
    }

    /// Sends a close control frame and closes the underlying transport channel.
    func close(
        code: UInt16 = 1000,
        reason: String? = nil
    ) async throws {
        guard !isClosed else {
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueWrite(.close(code, reason, continuation))
            }
        } onCancel: {
            lease.close()
        }
    }

    /// Runs inside `NIOAsyncChannel.executeThenClose`. The read and write
    /// loops run as sibling child tasks so a queued send is written even while
    /// a receive is awaiting the next inbound frame. Both loops terminate
    /// through `finish`, which resumes their queue waiters with `nil`.
    func run(
        inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.serviceWrites(outbound: outbound)
            }
            group.addTask {
                try await self.serviceReads(
                    inbound: inbound,
                    outbound: outbound
                )
            }
            defer { group.cancelAll() }
            try await group.waitForAll()
        }
    }

    private func serviceWrites(
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    ) async throws {
        do {
            while let request = await nextWriteRequest() {
                switch request {
                case let .send(frame, continuation):
                    do {
                        try await outbound.write(
                            try Self.makeRawFrame(frame, allocator: allocator)
                        )
                        if case .close = frame {
                            didSendClose = true
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                        throw error
                    }

                case let .close(code, reason, continuation):
                    do {
                        try await outbound.write(
                            try Self.makeRawFrame(
                                .close(code: code, reason: reason),
                                allocator: allocator
                            )
                        )
                        didSendClose = true
                        continuation.resume()
                        finish()
                    } catch {
                        continuation.resume(throwing: error)
                        throw error
                    }
                }
            }
        } catch {
            finish(throwing: error)
            throw error
        }
    }

    /// Keeping the iterator as a local value avoids sending a non-Sendable
    /// iterator across actor tasks.
    private func serviceReads(
        inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    ) async throws {
        var iterator = inbound.makeAsyncIterator()
        do {
            while let holder = await nextReadRequest() {
                do {
                    guard let rawFrame = try await iterator.next() else {
                        isReceiving = false
                        finish()
                        holder.resume(returning: nil)
                        continue
                    }
                    let frame = try await Self.decode(
                        rawFrame,
                        outbound: outbound,
                        allocator: allocator,
                        didSendClose: didSendClose
                    )
                    isReceiving = false
                    holder.resume(returning: frame)
                    if case .close = frame {
                        finish()
                    }
                } catch {
                    isReceiving = false
                    holder.resume(throwing: error)
                    throw error
                }
            }
        } catch {
            finish(throwing: error)
            throw error
        }
    }

    func fail(_ error: any Error) {
        finish(throwing: error)
    }

    /// Tears the driver down on behalf of the lifetime token when the last
    /// public handle is released. It reuses the normal terminal path so both
    /// loop waiters are resumed, which lets `executeThenClose` complete and the
    /// driver be released. Idempotent. Reached only through actual handle
    /// release, never through a channel-closure observation.
    func abandon() {
        finish(throwing: RemoteTransportError.closed)
    }

    /// Resumes a parked receive with cancellation. Called from the receive
    /// cancellation handler through an actor hop; by then `activeRead` is set.
    func cancelActiveReceive() {
        guard let activeRead else {
            return
        }
        self.activeRead = nil
        activeRead.resume(throwing: CancellationError())
    }

    private func enqueueWrite(_ request: WriteRequest) {
        guard !isClosed else {
            switch request {
            case let .send(_, continuation), let .close(_, _, continuation):
                continuation.resume(throwing: RemoteTransportError.closed)
            }
            return
        }
        if let writeWaiter {
            self.writeWaiter = nil
            writeWaiter.resume(returning: request)
        } else {
            pendingWrites.append(request)
        }
    }

    private func enqueueRead(_ holder: ReadRequest) {
        guard !isClosed else {
            isReceiving = false
            holder.resume(returning: nil)
            return
        }
        if let readWaiter {
            self.readWaiter = nil
            readWaiter.resume(returning: holder)
        } else {
            pendingReads.append(holder)
        }
    }

    private func nextWriteRequest() async -> WriteRequest? {
        guard !isClosed else {
            return nil
        }
        if !pendingWrites.isEmpty {
            return pendingWrites.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            writeWaiter = continuation
        }
    }

    private func nextReadRequest() async -> ReadRequest? {
        guard !isClosed else {
            return nil
        }
        if !pendingReads.isEmpty {
            return pendingReads.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            readWaiter = continuation
        }
    }

    private func finish(throwing error: (any Error)? = nil) {
        guard !isClosed else {
            return
        }
        isClosed = true
        lease.close()

        let terminalError = error ?? RemoteTransportError.closed
        for request in pendingWrites {
            switch request {
            case let .send(_, continuation), let .close(_, _, continuation):
                continuation.resume(throwing: terminalError)
            }
        }
        pendingWrites.removeAll()
        for holder in pendingReads {
            isReceiving = false
            if error == nil {
                holder.resume(returning: nil)
            } else {
                holder.resume(throwing: terminalError)
            }
        }
        pendingReads.removeAll()
        if let activeRead {
            self.activeRead = nil
            if error == nil {
                activeRead.resume(returning: nil)
            } else {
                activeRead.resume(throwing: terminalError)
            }
        }
        if let writeWaiter {
            self.writeWaiter = nil
            writeWaiter.resume(returning: nil)
        }
        if let readWaiter {
            self.readWaiter = nil
            readWaiter.resume(returning: nil)
        }
    }

    private static func decode(
        _ rawFrame: WebSocketFrame,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        allocator: ByteBufferAllocator,
        didSendClose: Bool
    ) async throws -> RemoteWebSocketFrame {
        var buffer = rawFrame.data
        if let maskKey = rawFrame.maskKey {
            buffer.webSocketUnmask(maskKey)
        }
        let payload = Data(buffer.readableBytesView)

        switch rawFrame.opcode {
        case .text:
            guard let text = String(data: payload, encoding: .utf8) else {
                throw RemoteTransportError.protocolViolation(
                    "WebSocket text frame was not valid UTF-8"
                )
            }
            return .text(text, final: rawFrame.fin)
        case .binary:
            return .binary(payload, final: rawFrame.fin)
        case .continuation:
            return .continuation(payload, final: rawFrame.fin)
        case .ping:
            guard payload.count <= 125 else {
                throw RemoteTransportError.protocolViolation(
                    "WebSocket ping payload exceeded 125 bytes"
                )
            }
            // RFC 6455 requires a prompt pong with the same payload. Do not hide
            // the ping from callers: heartbeat/pooling code may still observe it.
            try await outbound.write(
                try makeRawFrame(.pong(payload), allocator: allocator)
            )
            return .ping(payload)
        case .pong:
            return .pong(payload)
        case .connectionClose:
            let close = parseClose(payload)
            // A close response is required unless this client already sent one.
            if !didSendClose {
                try? await outbound.write(
                    try makeRawFrame(
                        .close(code: close.code ?? 1000, reason: close.reason),
                        allocator: allocator
                    )
                )
            }
            return .close(code: close.code, reason: close.reason)
        default:
            throw RemoteTransportError.protocolViolation(
                "WebSocket used an unknown opcode"
            )
        }
    }

    private static func makeRawFrame(
        _ frame: RemoteWebSocketFrame,
        allocator: ByteBufferAllocator
    ) throws -> WebSocketFrame {
        let opcode: WebSocketOpcode
        let final: Bool
        var payload = Data()

        switch frame {
        case let .text(value, isFinal):
            opcode = .text
            final = isFinal
            payload = Data(value.utf8)
        case let .binary(value, isFinal):
            opcode = .binary
            final = isFinal
            payload = value
        case let .continuation(value, isFinal):
            opcode = .continuation
            final = isFinal
            payload = value
        case let .ping(value):
            guard value.count <= 125 else {
                throw RemoteTransportError.protocolViolation(
                    "WebSocket ping payload exceeded 125 bytes"
                )
            }
            opcode = .ping
            final = true
            payload = value
        case let .pong(value):
            guard value.count <= 125 else {
                throw RemoteTransportError.protocolViolation(
                    "WebSocket pong payload exceeded 125 bytes"
                )
            }
            opcode = .pong
            final = true
            payload = value
        case let .close(code, reason):
            opcode = .connectionClose
            final = true
            if let code {
                payload.append(UInt8((code >> 8) & 0xFF))
                payload.append(UInt8(code & 0xFF))
            }
            if let reason {
                payload.append(contentsOf: reason.utf8)
            }
            guard payload.count <= 125 else {
                throw RemoteTransportError.protocolViolation(
                    "WebSocket close payload exceeded 125 bytes"
                )
            }
        }

        var buffer = allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        return WebSocketFrame(
            fin: final,
            opcode: opcode,
            maskKey: .random(),
            data: buffer
        )
    }

    private static func parseClose(_ payload: Data) -> (
        code: UInt16?,
        reason: String?
    ) {
        guard payload.count >= 2 else {
            return (nil, nil)
        }
        let code = (UInt16(payload[payload.startIndex]) << 8)
            | UInt16(payload[payload.index(after: payload.startIndex)])
        let reasonBytes = payload.dropFirst(2)
        let reason = reasonBytes.isEmpty
            ? nil
            : String(data: reasonBytes, encoding: .utf8)
        return (code, reason)
    }
}
