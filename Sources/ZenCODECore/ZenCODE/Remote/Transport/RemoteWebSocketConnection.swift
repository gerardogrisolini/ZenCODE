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
/// The actor owns the unicast inbound iterator and serializes receives. Writes
/// use NIO's async writer, which waits for socket writability. Incoming pings
/// remain observable and receive an RFC 6455 pong automatically.
public actor RemoteWebSocketConnection {
    private var iterator: NIOAsyncChannelInboundStream<
        WebSocketFrame
    >.AsyncIterator
    private let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    private let allocator: ByteBufferAllocator
    private let lease: RemoteChannelLease
    private var isReceiving = false
    private var didSendClose = false
    private var isClosed = false

    init(
        inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
        allocator: ByteBufferAllocator,
        lease: RemoteChannelLease
    ) {
        iterator = inbound.makeAsyncIterator()
        self.outbound = outbound
        self.allocator = allocator
        self.lease = lease
    }

    deinit {
        lease.close()
    }

    /// Sends one WebSocket frame. Client frames are always masked as required
    /// by RFC 6455, including control frames.
    public func send(_ frame: RemoteWebSocketFrame) async throws {
        try await withTaskCancellationHandler {
            guard !isClosed else {
                throw RemoteTransportError.closed
            }
            let rawFrame = try makeRawFrame(frame)
            do {
                try await outbound.write(rawFrame)
                if case .close = frame {
                    didSendClose = true
                }
            } catch {
                lease.close()
                throw remoteTransportMappedError(error)
            }
        } onCancel: {
            lease.close()
        }
    }

    /// Receives one frame, or `nil` after a clean peer/channel closure.
    public func receive() async throws -> RemoteWebSocketFrame? {
        try await withTaskCancellationHandler {
            guard !isClosed else {
                return nil
            }
            do {
                guard let rawFrame = try await nextRawFrame() else {
                    isClosed = true
                    lease.close()
                    return nil
                }
                let frame = try await decode(rawFrame)
                if case .close = frame {
                    isClosed = true
                    lease.close()
                }
                return frame
            } catch {
                lease.close()
                throw remoteTransportMappedError(error)
            }
        } onCancel: {
            lease.close()
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
        do {
            try await outbound.write(
                try makeRawFrame(.close(code: code, reason: reason))
            )
        } catch {
            lease.close()
            throw remoteTransportMappedError(error)
        }
        didSendClose = true
        isClosed = true
        lease.close()
    }

    private func nextRawFrame() async throws -> WebSocketFrame? {
        guard !isReceiving else {
            throw RemoteTransportError.concurrentWebSocketReceive
        }
        isReceiving = true
        var localIterator = iterator
        do {
            let frame = try await localIterator.next()
            iterator = localIterator
            isReceiving = false
            return frame
        } catch {
            iterator = localIterator
            isReceiving = false
            throw error
        }
    }

    private func decode(
        _ rawFrame: WebSocketFrame
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
            try await outbound.write(try makeRawFrame(.pong(payload)))
            return .ping(payload)
        case .pong:
            return .pong(payload)
        case .connectionClose:
            let close = parseClose(payload)
            // A close response is required unless this client already sent one.
            if !didSendClose {
                try? await outbound.write(
                    try makeRawFrame(
                        .close(code: close.code ?? 1000, reason: close.reason)
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

    private func makeRawFrame(
        _ frame: RemoteWebSocketFrame
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

    private func parseClose(_ payload: Data) -> (
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
