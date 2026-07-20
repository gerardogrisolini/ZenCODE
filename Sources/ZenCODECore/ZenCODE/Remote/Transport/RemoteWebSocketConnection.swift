//
//  RemoteWebSocketConnection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
@preconcurrency import NIOCore
import NIOWebSocket

/// Actor-isolated WebSocket connection returned by `RemoteTransportCore`.
///
/// All access to NIO's inbound stream and outbound writer remains inside the
/// `executeThenClose` scope that owns the channel. Public operations are queued
/// by this actor and serviced serially by that scoped task.
public actor RemoteWebSocketConnection {
    private enum Request {
        case send(RemoteWebSocketFrame, CheckedContinuation<Void, any Error>)
        case receive(CheckedContinuation<RemoteWebSocketFrame?, any Error>)
        case close(UInt16, String?, CheckedContinuation<Void, any Error>)
    }

    private let allocator: ByteBufferAllocator
    private let lease: RemoteChannelLease
    private var pendingRequests: [Request] = []
    private var requestWaiter: CheckedContinuation<Request, Never>?
    private var isReceiving = false
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
    public func send(_ frame: RemoteWebSocketFrame) async throws {
        guard !isClosed else {
            throw RemoteTransportError.closed
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(.send(frame, continuation))
            }
        } onCancel: {
            lease.close()
        }
    }

    /// Receives one frame, or `nil` after a clean peer/channel closure.
    public func receive() async throws -> RemoteWebSocketFrame? {
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
                    enqueue(.receive(continuation))
                }
            } onCancel: {
                lease.close()
            }
        } catch {
            isReceiving = false
            throw remoteTransportMappedError(error)
        }
    }

    /// Sends a close control frame and closes the underlying transport channel.
    /// Callers that require the peer close acknowledgement can use `send(.close)`
    /// followed by `receive()` instead.
    public func close(
        code: UInt16 = 1000,
        reason: String? = nil
    ) async throws {
        guard !isClosed else {
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(.close(code, reason, continuation))
            }
        } onCancel: {
            lease.close()
        }
    }

    /// Runs inside `NIOAsyncChannel.executeThenClose`. Keeping the iterator as
    /// a local value avoids sending a non-Sendable iterator across actor tasks.
    func run(
        inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    ) async throws {
        var iterator = inbound.makeAsyncIterator()
        do {
            while let request = await nextRequest() {
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

                case let .receive(continuation):
                    do {
                        guard let rawFrame = try await iterator.next() else {
                            isReceiving = false
                            finish()
                            continuation.resume(returning: nil)
                            continue
                        }
                        let frame = try await Self.decode(
                            rawFrame,
                            outbound: outbound,
                            allocator: allocator,
                            didSendClose: didSendClose
                        )
                        isReceiving = false
                        continuation.resume(returning: frame)
                        if case .close = frame {
                            finish()
                        }
                    } catch {
                        isReceiving = false
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

    func fail(_ error: any Error) {
        finish(throwing: error)
    }

    private func enqueue(_ request: Request) {
        if let requestWaiter {
            self.requestWaiter = nil
            requestWaiter.resume(returning: request)
        } else {
            pendingRequests.append(request)
        }
    }

    private func nextRequest() async -> Request? {
        guard !isClosed else {
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
        guard !isClosed else {
            return
        }
        isClosed = true
        lease.close()

        let terminalError = error ?? RemoteTransportError.closed
        for request in pendingRequests {
            switch request {
            case let .send(_, continuation), let .close(_, _, continuation):
                continuation.resume(throwing: terminalError)
            case let .receive(continuation):
                isReceiving = false
                if error == nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(throwing: terminalError)
                }
            }
        }
        pendingRequests.removeAll()
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
