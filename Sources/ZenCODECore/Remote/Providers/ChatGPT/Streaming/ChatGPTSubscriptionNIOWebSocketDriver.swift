//
//  ChatGPTSubscriptionNIOWebSocketDriver.swift
//  ZenCODE
//
//  The single-reader frame dispatcher behind the ChatGPT Subscription NIO
//  WebSocket task: bounded application queue, pong waiters and fragmented
//  message reassembly.
//

import Foundation
import Synchronization

/// A single-reader frame dispatcher. It keeps application receives and pong
/// waiters independent, preventing a heartbeat/readiness ping from racing the
/// Responses stream or consuming a JSON message. Application buffering remains
/// bounded, but capacity is awaited only before an application message is
/// queued: a full application queue must not prevent the next control frame
/// from being received and handled.
actor ChatGPTSubscriptionNIOWebSocketDriver {
    static let defaultMaximumQueuedApplicationMessages = 64

    private let receiveFrame: @Sendable () async throws -> RemoteWebSocketFrame?
    private let sendFrame: @Sendable (RemoteWebSocketFrame) async throws -> Void
    private let closeConnection: @Sendable (UInt16, String?) async throws -> Void
    private let onFrameDelivered: @Sendable (RemoteWebSocketFrame) async -> Void
    private let maximumQueuedApplicationMessages: Int
    private var receiveWaiter: CheckedContinuation<
        ChatGPTSubscriptionWebSocketMessage,
        Error
    >?
    private var queuedMessages: [ChatGPTSubscriptionWebSocketMessage] = []
    private var queueSpaceWaiter: CheckedContinuation<Void, Error>?
    private var pingWaiters: [Data: CheckedContinuation<Void, Error>] = [:]
    private var observedPongs = Set<Data>()
    private var terminalError: Error?
    private var readerTask: Task<Void, Never>?
    private var fragmentedPayload: Data?
    private var fragmentedMessageIsText = false

    init(connection: RemoteWebSocketConnection) {
        receiveFrame = {
            try await connection.receive()
        }
        sendFrame = { frame in
            try await connection.send(frame)
        }
        closeConnection = { code, reason in
            try await connection.close(code: code, reason: reason)
        }
        onFrameDelivered = { _ in }
        maximumQueuedApplicationMessages = Self.defaultMaximumQueuedApplicationMessages
    }

    /// Internal injection points keep dispatcher back-pressure and teardown
    /// tests deterministic without opening a network connection.
    init(
        maximumQueuedApplicationMessages: Int,
        receiveFrame: @escaping @Sendable () async throws -> RemoteWebSocketFrame?,
        sendFrame: @escaping @Sendable (RemoteWebSocketFrame) async throws -> Void,
        closeConnection: @escaping @Sendable (UInt16, String?) async throws -> Void,
        onFrameDelivered: @escaping @Sendable (RemoteWebSocketFrame) async -> Void = { _ in }
    ) {
        self.maximumQueuedApplicationMessages = max(
            maximumQueuedApplicationMessages,
            1
        )
        self.receiveFrame = receiveFrame
        self.sendFrame = sendFrame
        self.closeConnection = closeConnection
        self.onFrameDelivered = onFrameDelivered
    }

    func start() {
        guard readerTask == nil else {
            return
        }
        readerTask = Task(name: "ChatGPT WebSocket background task") { [weak self] in
            await self?.readLoop()
        }
    }

    func send(_ message: ChatGPTSubscriptionWebSocketMessage) async throws {
        try throwIfTerminal()
        switch message {
        case let .text(value):
            try await sendFrame(.text(value))
        case let .binary(data):
            try await sendFrame(.binary(data))
        }
    }

    func receive() async throws -> ChatGPTSubscriptionWebSocketMessage {
        if !queuedMessages.isEmpty {
            let message = queuedMessages.removeFirst()
            resumeQueueSpaceWaiterIfNeeded()
            return message
        }
        try throwIfTerminal()
        guard receiveWaiter == nil else {
            throw RemoteTransportError.concurrentWebSocketReceive
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<
                    ChatGPTSubscriptionWebSocketMessage,
                    Error
                >) in
                if !queuedMessages.isEmpty {
                    let message = queuedMessages.removeFirst()
                    resumeQueueSpaceWaiterIfNeeded()
                    continuation.resume(returning: message)
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    receiveWaiter = continuation
                }
            }
        } onCancel: {
            Task(name: "ChatGPT WebSocket background task") {
                await cancel()
            }
        }
    }

    func sendPing(
        preservingConnectionOnWriteCancellation: Bool = false
    ) async throws {
        try throwIfTerminal()
        let payload = Self.makePingPayload()

        if preservingConnectionOnWriteCancellation {
            // The pool cancels an idle heartbeat when leasing its socket. If
            // cancellation reaches RemoteWebSocketConnection.send while this
            // frame is in flight, its low-level cancellation handler closes the
            // channel. Let only the already-started control-frame write finish
            // in a child that does not inherit cancellation, then stop before
            // waiting for the pong. Readiness pings deliberately use the normal
            // cancellable path so their timeout can still force-close a stall.
            let sendFrame = self.sendFrame
            let writeTask = Task(name: "ChatGPT WebSocket background task") {
                try await sendFrame(.ping(payload))
            }
            try await writeTask.value
            try Task.checkCancellation()
        } else {
            try await sendFrame(.ping(payload))
        }
        try await waitForPong(payload)
    }

    func close(code: UInt16?, reason: Data?) async {
        finish(
            RemoteTransportError.closed,
            discardingQueuedMessages: true
        )
        let closeCode = code ?? ChatGPTSubscriptionWebSocketCloseCode.normalClosure
        let closeReason = reason.flatMap { String(data: $0, encoding: .utf8) }
        try? await closeConnection(closeCode, closeReason)
    }

    private func cancel() async {
        finish(CancellationError(), discardingQueuedMessages: true)
        try? await closeConnection(
            ChatGPTSubscriptionWebSocketCloseCode.goingAway,
            nil
        )
    }

    private func waitForPong(_ payload: Data) async throws {
        if observedPongs.remove(payload) != nil {
            return
        }
        try throwIfTerminal()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if observedPongs.remove(payload) != nil {
                    continuation.resume()
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    pingWaiters[payload] = continuation
                }
            }
        } onCancel: {
            Task(name: "ChatGPT WebSocket background task") {
                await cancelPing(payload)
            }
        }
    }

    private func cancelPing(_ payload: Data) {
        guard let waiter = pingWaiters.removeValue(forKey: payload) else {
            return
        }
        waiter.resume(throwing: CancellationError())
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                guard let frame = try await receiveFrame() else {
                    finish(RemoteTransportError.closed)
                    return
                }
                try await receive(frame)
                await onFrameDelivered(frame)
            } catch is CancellationError {
                finish(CancellationError())
                return
            } catch {
                finish(error)
                return
            }
        }
    }

    private func receive(_ frame: RemoteWebSocketFrame) async throws {
        switch frame {
        case let .text(text, isFinal):
            guard fragmentedPayload == nil else {
                throw RemoteTransportError.protocolViolation(
                    "Received a new text frame before a fragmented message ended"
                )
            }
            if isFinal {
                try await deliver(.text(text))
            } else {
                fragmentedPayload = Data(text.utf8)
                fragmentedMessageIsText = true
            }
        case let .binary(data, isFinal):
            guard fragmentedPayload == nil else {
                throw RemoteTransportError.protocolViolation(
                    "Received a new binary frame before a fragmented message ended"
                )
            }
            if isFinal {
                try await deliver(.binary(data))
            } else {
                fragmentedPayload = data
                fragmentedMessageIsText = false
            }
        case let .continuation(data, isFinal):
            guard var fragmentedPayload else {
                throw RemoteTransportError.protocolViolation(
                    "Received a continuation frame without a fragmented message"
                )
            }
            fragmentedPayload.append(data)
            if isFinal {
                self.fragmentedPayload = nil
                if fragmentedMessageIsText {
                    guard let text = String(data: fragmentedPayload, encoding: .utf8) else {
                        throw RemoteTransportError.protocolViolation(
                            "Fragmented WebSocket text message was not valid UTF-8"
                        )
                    }
                    try await deliver(.text(text))
                } else {
                    try await deliver(.binary(fragmentedPayload))
                }
            } else {
                self.fragmentedPayload = fragmentedPayload
            }
        case .ping:
            // RemoteWebSocketConnection already sends the matching pong.
            break
        case let .pong(payload):
            if let waiter = pingWaiters.removeValue(forKey: payload) {
                waiter.resume()
            } else {
                observedPongs.insert(payload)
            }
        case .close:
            finish(RemoteTransportError.closed)
        }
    }

    private func deliver(_ message: ChatGPTSubscriptionWebSocketMessage) async throws {
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            waiter.resume(returning: message)
            return
        }

        // A frame is received before capacity is awaited, so control frames do
        // not get stuck behind a full application queue. Recheck after every
        // suspension so a future dispatcher change cannot turn an invariant
        // violation into a silently dropped application message. A consumer
        // can also register while this await is suspended; satisfy it directly
        // rather than queueing a message it is already waiting for.
        try await waitForQueueSpace()
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            waiter.resume(returning: message)
            return
        }
        queuedMessages.append(message)
    }

    private func waitForQueueSpace() async throws {
        while queuedMessages.count >= maximumQueuedApplicationMessages {
            try throwIfTerminal()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else if queuedMessages.count < maximumQueuedApplicationMessages {
                    continuation.resume()
                } else if queueSpaceWaiter != nil {
                    continuation.resume(
                        throwing: RemoteTransportError.protocolViolation(
                            "WebSocket dispatcher registered more than one queue-space waiter"
                        )
                    )
                } else {
                    // `readLoop` is the sole reader, so there can be only one
                    // capacity waiter. Treat any future invariant violation as
                    // a recoverable transport error rather than terminating the
                    // whole process from a networking task.
                    queueSpaceWaiter = continuation
                }
            }
        }
        try throwIfTerminal()
    }

    private func resumeQueueSpaceWaiterIfNeeded() {
        guard queuedMessages.count < maximumQueuedApplicationMessages,
              let queueSpaceWaiter else {
            return
        }
        self.queueSpaceWaiter = nil
        queueSpaceWaiter.resume()
    }

    private func finish(
        _ error: Error,
        discardingQueuedMessages: Bool = false
    ) {
        guard terminalError == nil else {
            if discardingQueuedMessages {
                queuedMessages.removeAll(keepingCapacity: false)
            }
            return
        }
        terminalError = error
        fragmentedPayload = nil
        if discardingQueuedMessages {
            queuedMessages.removeAll(keepingCapacity: false)
        }
        readerTask?.cancel()
        readerTask = nil

        let queueSpaceWaiter = self.queueSpaceWaiter
        self.queueSpaceWaiter = nil
        queueSpaceWaiter?.resume(throwing: error)

        let receiveWaiter = self.receiveWaiter
        self.receiveWaiter = nil
        receiveWaiter?.resume(throwing: error)

        let pingWaiters = self.pingWaiters.values
        self.pingWaiters.removeAll()
        observedPongs.removeAll()
        for waiter in pingWaiters {
            waiter.resume(throwing: error)
        }
    }

    private func throwIfTerminal() throws {
        if let terminalError {
            throw terminalError
        }
    }

    private static func makePingPayload() -> Data {
        // A unique payload correlates a pong to its readiness/heartbeat ping.
        Data(UUID().uuidString.utf8)
    }

    /// Visible to deterministic module tests only; production consumers never
    /// need to observe dispatcher internals.
    var bufferedApplicationMessageCount: Int {
        queuedMessages.count
    }
}
