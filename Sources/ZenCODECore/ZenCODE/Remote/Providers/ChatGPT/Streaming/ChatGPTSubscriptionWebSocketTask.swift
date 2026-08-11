//
//  ChatGPTSubscriptionWebSocketTask.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
import Synchronization

/// Message-level view used by the Responses client. The shared NIO substrate
/// still retains frame-level fidelity; this adapter reassembles fragmented data
/// messages because the Responses protocol exchanges JSON messages.
enum ChatGPTSubscriptionWebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// Lifecycle exposed to the pool for reuse decisions. It deliberately does not
/// mirror platform-native task states, so the same pool runs everywhere.
enum ChatGPTSubscriptionWebSocketTaskState: Sendable, Equatable {
    case suspended
    case running
    case canceling
    case completed
}

/// Minimal, cross-platform adapter boundary retained for deterministic pool and
/// retry tests. Production instances are `ChatGPTSubscriptionNIOWebSocketTask`.
protocol ChatGPTSubscriptionWebSocketTask: AnyObject, Sendable {
    var closeCode: UInt16? { get }
    var state: ChatGPTSubscriptionWebSocketTaskState { get }

    func resume()
    func send(_ message: ChatGPTSubscriptionWebSocketMessage) async throws
    func receive() async throws -> ChatGPTSubscriptionWebSocketMessage
    /// Sends an RFC 6455 ping and completes only after its matching pong.
    func sendPing() async throws
    /// Heartbeat variant whose in-flight control-frame write survives a pool
    /// handoff cancellation without closing the shared connection.
    func sendHeartbeatPing() async throws
    func cancel(with closeCode: UInt16?, reason: Data?)
}

enum ChatGPTSubscriptionWebSocketCloseCode {
    static let normalClosure: UInt16 = 1000
    static let goingAway: UInt16 = 1001
    static let abnormalClosure: UInt16 = 1006
}

/// SwiftNIO-backed adapter used by the ChatGPT Responses pool on every
/// supported platform. Connecting is started explicitly by `resume()`, making
/// acquisition synchronous while all I/O remains cancellation-aware async NIO.
final class ChatGPTSubscriptionNIOWebSocketTask:
    ChatGPTSubscriptionWebSocketTask,
    Sendable
{
    private enum Lifecycle {
        case suspended
        case connecting
        case ready(ChatGPTSubscriptionNIOWebSocketDriver)
        case failed(Error)
        case cancelled
        case completed
    }

    private struct State {
        var lifecycle: Lifecycle = .suspended
        var closeCode: UInt16?
        var readinessWaiters: [CheckedContinuation<Void, Error>] = []
        /// The task is adopted only while this state is `.connecting`.  Keeping
        /// it in this same critical section makes cancellation before adoption
        /// observable rather than a lost cancellation.
        var connectionTask: Task<Void, Never>?
        /// Retains a connected driver long enough for `cancel` to close a socket
        /// that has already transitioned to `.completed` after an I/O failure.
        var connectedDriver: ChatGPTSubscriptionNIOWebSocketDriver?
    }

    private let driverFactory: @Sendable () async throws -> ChatGPTSubscriptionNIOWebSocketDriver
    private let closeDriver: @Sendable (
        ChatGPTSubscriptionNIOWebSocketDriver,
        UInt16?,
        Data?
    ) -> Void
    /// Test-only seam deliberately invoked after `connecting` is published and
    /// before the task is adopted. It is never called while `stateStorage` is
    /// locked, so it may synchronously coordinate a deterministic interleaving.
    private let beforeTaskAdoption: @Sendable () -> Void
    private let stateStorage = Mutex(State())

    init(
        transport: RemoteTransportCore,
        request: RemoteWebSocketRequest
    ) {
        self.driverFactory = {
            let connection = try await transport.connectWebSocket(request)
            return ChatGPTSubscriptionNIOWebSocketDriver(connection: connection)
        }
        self.closeDriver = { driver, closeCode, reason in
            Task(name: "ChatGPT WebSocket cancellation") {
                await driver.close(code: closeCode, reason: reason)
            }
        }
        self.beforeTaskAdoption = {}
    }

    init(
        connector: @escaping @Sendable () async throws -> RemoteWebSocketConnection,
        beforeTaskAdoption: @escaping @Sendable () -> Void = {}
    ) {
        self.driverFactory = {
            let connection = try await connector()
            return ChatGPTSubscriptionNIOWebSocketDriver(connection: connection)
        }
        self.closeDriver = { driver, closeCode, reason in
            Task(name: "ChatGPT WebSocket cancellation") {
                await driver.close(code: closeCode, reason: reason)
            }
        }
        self.beforeTaskAdoption = beforeTaskAdoption
    }

    /// Internal driver injection keeps task lifecycle teardown deterministic in
    /// tests without opening a network connection.
    init(
        driverFactory: @escaping @Sendable () async throws -> ChatGPTSubscriptionNIOWebSocketDriver,
        closeDriver: @escaping @Sendable (
            ChatGPTSubscriptionNIOWebSocketDriver,
            UInt16?,
            Data?
        ) -> Void,
        beforeTaskAdoption: @escaping @Sendable () -> Void = {}
    ) {
        self.driverFactory = driverFactory
        self.closeDriver = closeDriver
        self.beforeTaskAdoption = beforeTaskAdoption
    }

    var closeCode: UInt16? {
        stateStorage.withLock(\.closeCode)
    }

    var state: ChatGPTSubscriptionWebSocketTaskState {
        stateStorage.withLock { state in
            switch state.lifecycle {
            case .suspended:
                return .suspended
            case .connecting, .ready:
                return .running
            case .cancelled:
                return .canceling
            case .failed, .completed:
                return .completed
            }
        }
    }

    func resume() {
        let shouldStart = stateStorage.withLock { state -> Bool in
            guard case .suspended = state.lifecycle else {
                return false
            }
            // This is the adoption ticket. `cancel` can invalidate it before
            // the Task exists; adoption below then cancels the just-created task.
            state.lifecycle = .connecting
            return true
        }
        guard shouldStart else {
            return
        }

        beforeTaskAdoption()
        let connectionTask = Task(name: "ChatGPT WebSocket connection") { [weak self] in
            guard let self else {
                return
            }
            do {
                let driver = try await driverFactory()
                await driver.start()
                install(driver)
            } catch is CancellationError {
                fail(CancellationError())
            } catch {
                fail(error)
            }
        }
        let shouldCancel = stateStorage.withLock { state -> Bool in
            guard case .connecting = state.lifecycle else {
                return true
            }
            state.connectionTask = connectionTask
            return false
        }
        if shouldCancel {
            // Cancellation won before task adoption. Do not publish a task into
            // a terminal state; cancel it outside the mutex.
            connectionTask.cancel()
        }
    }

    func send(_ message: ChatGPTSubscriptionWebSocketMessage) async throws {
        try Task.checkCancellation()
        let driver = try await readyDriver()
        do {
            try await driver.send(message)
        } catch {
            recordTerminalFailure(error)
            throw error
        }
    }

    func receive() async throws -> ChatGPTSubscriptionWebSocketMessage {
        try Task.checkCancellation()
        let driver = try await readyDriver()
        do {
            return try await driver.receive()
        } catch {
            recordTerminalFailure(error)
            throw error
        }
    }

    func sendPing() async throws {
        try await sendPing(preservingConnectionOnWriteCancellation: false)
    }

    func sendHeartbeatPing() async throws {
        try await sendPing(preservingConnectionOnWriteCancellation: true)
    }

    private func sendPing(
        preservingConnectionOnWriteCancellation: Bool
    ) async throws {
        try Task.checkCancellation()
        let driver = try await readyDriver()
        do {
            try await driver.sendPing(
                preservingConnectionOnWriteCancellation:
                    preservingConnectionOnWriteCancellation
            )
        } catch {
            recordTerminalFailure(error)
            throw error
        }
    }

    func cancel(with closeCode: UInt16?, reason: Data?) {
        let result = stateStorage.withLock {
            state -> (
                driver: ChatGPTSubscriptionNIOWebSocketDriver?,
                waiters: [CheckedContinuation<Void, Error>],
                task: Task<Void, Never>?
            ) in
            let driver: ChatGPTSubscriptionNIOWebSocketDriver?
            if case let .ready(value) = state.lifecycle {
                driver = value
            } else {
                driver = state.connectedDriver
            }
            // Consume the retained driver even when cancellation already won.
            // The local is closed below, outside the state mutex, exactly once.
            state.connectedDriver = nil
            if matchesTerminalCancellation(state.lifecycle) {
                return (driver, [], nil)
            }
            state.lifecycle = .cancelled
            state.closeCode = closeCode
            let waiters = state.readinessWaiters
            state.readinessWaiters.removeAll()
            let task = state.connectionTask
            state.connectionTask = nil
            return (driver, waiters, task)
        }

        result.task?.cancel()
        for waiter in result.waiters {
            waiter.resume(throwing: CancellationError())
        }
        if let driver = result.driver {
            closeDriver(driver, closeCode, reason)
        }
    }

    private func readyDriver() async throws -> ChatGPTSubscriptionNIOWebSocketDriver {
        try await waitUntilReady()
        try Task.checkCancellation()
        return try stateStorage.withLock { state in
            switch state.lifecycle {
            case let .ready(driver):
                return driver
            case let .failed(error):
                throw error
            case .cancelled:
                throw CancellationError()
            case .completed, .suspended, .connecting:
                throw RemoteTransportError.closed
            }
        }
    }

    private func waitUntilReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let result = stateStorage.withLock { state -> Result<Void, Error>? in
                    switch state.lifecycle {
                    case .ready:
                        return .success(())
                    case let .failed(error):
                        return .failure(error)
                    case .cancelled:
                        return .failure(CancellationError())
                    case .completed:
                        return .failure(RemoteTransportError.closed)
                    case .suspended, .connecting:
                        state.readinessWaiters.append(continuation)
                        return nil
                    }
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancel(
                with: ChatGPTSubscriptionWebSocketCloseCode.goingAway,
                reason: nil
            )
        }
    }

    private func install(_ driver: ChatGPTSubscriptionNIOWebSocketDriver) {
        let result = stateStorage.withLock {
            state -> (
                shouldClose: Bool,
                waiters: [CheckedContinuation<Void, Error>]
            ) in
            guard case .connecting = state.lifecycle else {
                return (true, [])
            }
            state.lifecycle = .ready(driver)
            state.connectionTask = nil
            state.connectedDriver = driver
            let waiters = state.readinessWaiters
            state.readinessWaiters.removeAll()
            return (false, waiters)
        }
        if result.shouldClose {
            Task(name: "ChatGPT WebSocket rejected connection") {
                await driver.close(
                    code: ChatGPTSubscriptionWebSocketCloseCode.goingAway,
                    reason: nil
                )
            }
            return
        }
        for waiter in result.waiters {
            waiter.resume()
        }
    }

    private func fail(_ error: Error) {
        let result = stateStorage.withLock {
            state -> [CheckedContinuation<Void, Error>] in
            guard !matchesTerminalCancellation(state.lifecycle) else {
                return []
            }
            if error is CancellationError {
                state.lifecycle = .cancelled
            } else {
                state.lifecycle = .failed(error)
                if state.closeCode == nil {
                    state.closeCode = ChatGPTSubscriptionWebSocketCloseCode.abnormalClosure
                }
            }
            let waiters = state.readinessWaiters
            state.readinessWaiters.removeAll()
            state.connectionTask = nil
            return waiters
        }
        for waiter in result {
            waiter.resume(throwing: error)
        }
    }

    private func recordTerminalFailure(_ error: Error) {
        guard !(error is CancellationError) else {
            return
        }
        let didTransition = stateStorage.withLock { state -> Bool in
            guard case .ready = state.lifecycle else {
                return false
            }
            state.lifecycle = .completed
            state.connectionTask = nil
            if state.closeCode == nil {
                state.closeCode = ChatGPTSubscriptionWebSocketCloseCode.abnormalClosure
            }
            return true
        }
        _ = didTransition
    }

    private func matchesTerminalCancellation(_ lifecycle: Lifecycle) -> Bool {
        switch lifecycle {
        case .cancelled, .completed, .failed:
            return true
        case .suspended, .connecting, .ready:
            return false
        }
    }
}

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
