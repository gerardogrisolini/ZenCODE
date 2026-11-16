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
