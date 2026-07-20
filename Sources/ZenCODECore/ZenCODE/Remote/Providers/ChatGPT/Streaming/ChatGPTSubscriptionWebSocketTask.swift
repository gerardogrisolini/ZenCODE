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
    @unchecked Sendable
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
    }

    private let connector: @Sendable () async throws -> RemoteWebSocketConnection
    private let stateStorage = Mutex(State())
    private let connectionTaskStorage = Mutex<Task<Void, Never>?>(nil)
    /// Retains a connected driver long enough for `cancel` to close a socket
    /// that has already transitioned to `.completed` after an I/O failure.
    private let connectedDriverStorage = Mutex<ChatGPTSubscriptionNIOWebSocketDriver?>(nil)

    init(
        transport: RemoteTransportCore,
        request: RemoteWebSocketRequest
    ) {
        connector = {
            try await transport.connectWebSocket(request)
        }
    }

    init(
        connector: @escaping @Sendable () async throws -> RemoteWebSocketConnection
    ) {
        self.connector = connector
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
            state.lifecycle = .connecting
            return true
        }
        guard shouldStart else {
            return
        }

        let task = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let connection = try await connector()
                let driver = ChatGPTSubscriptionNIOWebSocketDriver(
                    connection: connection
                )
                await driver.start()
                install(driver)
            } catch is CancellationError {
                fail(CancellationError())
            } catch {
                fail(error)
            }
        }
        connectionTaskStorage.withLock { $0 = task }
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
        try Task.checkCancellation()
        let driver = try await readyDriver()
        do {
            try await driver.sendPing()
        } catch {
            recordTerminalFailure(error)
            throw error
        }
    }

    func cancel(with closeCode: UInt16?, reason: Data?) {
        let result = stateStorage.withLock {
            state -> (
                driver: ChatGPTSubscriptionNIOWebSocketDriver?,
                waiters: [CheckedContinuation<Void, Error>]
            ) in
            let driver: ChatGPTSubscriptionNIOWebSocketDriver?
            if case let .ready(value) = state.lifecycle {
                driver = value
            } else {
                driver = connectedDriverStorage.withLock { $0 }
            }
            if matchesTerminalCancellation(state.lifecycle) {
                return (driver, [])
            }
            state.lifecycle = .cancelled
            state.closeCode = closeCode
            let waiters = state.readinessWaiters
            state.readinessWaiters.removeAll()
            return (driver, waiters)
        }

        connectionTaskStorage.withLock { task in
            task?.cancel()
            task = nil
        }
        connectedDriverStorage.withLock { $0 = nil }
        for waiter in result.waiters {
            waiter.resume(throwing: CancellationError())
        }
        if let driver = result.driver {
            Task {
                await driver.close(code: closeCode, reason: reason)
            }
        }
    }

    private func readyDriver() async throws -> ChatGPTSubscriptionNIOWebSocketDriver {
        try await waitUntilReady()
        try Task.checkCancellation()
        return try stateStorage.withLock { state in
            guard case let .ready(driver) = state.lifecycle else {
                switch state.lifecycle {
                case let .failed(error):
                    throw error
                case .cancelled:
                    throw CancellationError()
                case .completed:
                    throw RemoteTransportError.closed
                case .suspended, .connecting:
                    throw RemoteTransportError.closed
                case .ready:
                    fatalError("Ready WebSocket task lost its driver")
                }
            }
            return driver
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
            let waiters = state.readinessWaiters
            state.readinessWaiters.removeAll()
            return (false, waiters)
        }
        connectionTaskStorage.withLock { $0 = nil }

        if result.shouldClose {
            Task {
                await driver.close(
                    code: ChatGPTSubscriptionWebSocketCloseCode.goingAway,
                    reason: nil
                )
            }
            return
        }
        connectedDriverStorage.withLock { $0 = driver }
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
            return waiters
        }
        connectionTaskStorage.withLock { $0 = nil }
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
            if state.closeCode == nil {
                state.closeCode = ChatGPTSubscriptionWebSocketCloseCode.abnormalClosure
            }
            return true
        }
        if didTransition {
            connectionTaskStorage.withLock { $0 = nil }
        }
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
/// Responses stream or consuming a JSON message.
private actor ChatGPTSubscriptionNIOWebSocketDriver {
    private let connection: RemoteWebSocketConnection
    private var receiveWaiter: CheckedContinuation<
        ChatGPTSubscriptionWebSocketMessage,
        Error
    >?
    private var queuedMessages: [ChatGPTSubscriptionWebSocketMessage] = []
    private var pingWaiters: [Data: CheckedContinuation<Void, Error>] = [:]
    private var observedPongs = Set<Data>()
    private var terminalError: Error?
    private var readerTask: Task<Void, Never>?
    private var fragmentedPayload: Data?
    private var fragmentedMessageIsText = false

    init(connection: RemoteWebSocketConnection) {
        self.connection = connection
    }

    func start() {
        guard readerTask == nil else {
            return
        }
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func send(_ message: ChatGPTSubscriptionWebSocketMessage) async throws {
        try throwIfTerminal()
        switch message {
        case let .text(value):
            try await connection.send(.text(value))
        case let .binary(data):
            try await connection.send(.binary(data))
        }
    }

    func receive() async throws -> ChatGPTSubscriptionWebSocketMessage {
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
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
                    continuation.resume(returning: queuedMessages.removeFirst())
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    receiveWaiter = continuation
                }
            }
        } onCancel: {
            Task {
                await cancel()
            }
        }
    }

    func sendPing() async throws {
        try throwIfTerminal()
        let payload = Self.makePingPayload()
        try await connection.send(.ping(payload))
        try await waitForPong(payload)
    }

    func close(code: UInt16?, reason: Data?) async {
        if terminalError == nil {
            finish(RemoteTransportError.closed)
        }
        let closeCode = code ?? ChatGPTSubscriptionWebSocketCloseCode.normalClosure
        let closeReason = reason.flatMap { String(data: $0, encoding: .utf8) }
        try? await connection.close(code: closeCode, reason: closeReason)
    }

    private func cancel() async {
        if terminalError == nil {
            finish(CancellationError())
        }
        try? await connection.close(
            code: ChatGPTSubscriptionWebSocketCloseCode.goingAway,
            reason: nil
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
            Task {
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
                guard let frame = try await connection.receive() else {
                    finish(RemoteTransportError.closed)
                    return
                }
                try receive(frame)
            } catch is CancellationError {
                finish(CancellationError())
                return
            } catch {
                finish(error)
                return
            }
        }
    }

    private func receive(_ frame: RemoteWebSocketFrame) throws {
        switch frame {
        case let .text(text, isFinal):
            guard fragmentedPayload == nil else {
                throw RemoteTransportError.protocolViolation(
                    "Received a new text frame before a fragmented message ended"
                )
            }
            if isFinal {
                deliver(.text(text))
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
                deliver(.binary(data))
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
                    deliver(.text(text))
                } else {
                    deliver(.binary(fragmentedPayload))
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

    private func deliver(_ message: ChatGPTSubscriptionWebSocketMessage) {
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            waiter.resume(returning: message)
        } else {
            queuedMessages.append(message)
        }
    }

    private func finish(_ error: Error) {
        guard terminalError == nil else {
            return
        }
        terminalError = error
        fragmentedPayload = nil
        readerTask?.cancel()
        readerTask = nil

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
}
