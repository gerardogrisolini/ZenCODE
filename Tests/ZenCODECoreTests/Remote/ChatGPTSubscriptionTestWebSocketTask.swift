//
//  ChatGPTSubscriptionTestWebSocketTask.swift
//  ZenCODE
//
//  Deterministic ChatGPT Subscription WebSocket task double shared by the
//  ChatGPT WebSocket tests.
//

import Foundation
import Synchronization
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

/// Deterministic adapter double shared by all ChatGPT WebSocket tests. It has
/// no Foundation/WebKit/Network dependency, so exactly the same tests compile
/// on macOS and Linux.
final class ChatGPTSubscriptionTestWebSocketTask:
    ChatGPTSubscriptionWebSocketTask,
    @unchecked Sendable
{
    private struct State {
        var taskState: ChatGPTSubscriptionWebSocketTaskState = .suspended
        var closeCode: UInt16?
        var sendOutcomes: [Result<Void, Error>]
        var receiveOutcomes: [
            Result<ChatGPTSubscriptionWebSocketMessage, Error>
        ]
        var pingOutcomes: [Result<Void, Error>]
        var receiveWaiter: CheckedContinuation<
            ChatGPTSubscriptionWebSocketMessage,
            Error
        >?
        var sendWaiter: CheckedContinuation<Void, Never>?
        var sentMessages: [ChatGPTSubscriptionWebSocketMessage] = []
        var cancelCount = 0
        var resumeCount = 0
    }

    private let stateStorage: Mutex<State>

    init(
        sendOutcomes: [Result<Void, Error>] = [],
        receiveOutcomes: [Result<ChatGPTSubscriptionWebSocketMessage, Error>] = [],
        pingOutcomes: [Result<Void, Error>] = []
    ) {
        stateStorage = Mutex(
            State(
                sendOutcomes: sendOutcomes,
                receiveOutcomes: receiveOutcomes,
                pingOutcomes: pingOutcomes
            )
        )
    }

    var closeCode: UInt16? {
        stateStorage.withLock(\.closeCode)
    }

    var state: ChatGPTSubscriptionWebSocketTaskState {
        stateStorage.withLock(\.taskState)
    }

    var sentMessages: [ChatGPTSubscriptionWebSocketMessage] {
        stateStorage.withLock(\.sentMessages)
    }

    var cancelCount: Int {
        stateStorage.withLock(\.cancelCount)
    }

    func resume() {
        stateStorage.withLock { state in
            state.resumeCount += 1
            guard state.taskState == .suspended else {
                return
            }
            state.taskState = .running
        }
    }

    func send(_ message: ChatGPTSubscriptionWebSocketMessage) async throws {
        let outcome = stateStorage.withLock { state -> (
            Result<Void, Error>,
            CheckedContinuation<Void, Never>?
        ) in
            state.sentMessages.append(message)
            let result = state.sendOutcomes.isEmpty
                ? Result<Void, Error>.success(())
                : state.sendOutcomes.removeFirst()
            let waiter = state.sendWaiter
            state.sendWaiter = nil
            return (result, waiter)
        }
        outcome.1?.resume()
        try outcome.0.get()
    }

    func receive() async throws -> ChatGPTSubscriptionWebSocketMessage {
        if let result = stateStorage.withLock({ state in
            state.receiveOutcomes.isEmpty ? nil : state.receiveOutcomes.removeFirst()
        }) {
            return try result.get()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<
                    ChatGPTSubscriptionWebSocketMessage,
                    Error
                >) in
                let result = stateStorage.withLock {
                    state -> Result<ChatGPTSubscriptionWebSocketMessage, Error>? in
                    if !state.receiveOutcomes.isEmpty {
                        return state.receiveOutcomes.removeFirst()
                    }
                    if state.taskState == .canceling || state.taskState == .completed {
                        return .failure(CancellationError())
                    }
                    state.receiveWaiter = continuation
                    return nil
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

    func sendPing() async throws {
        let result = stateStorage.withLock { state -> Result<Void, Error> in
            guard !state.pingOutcomes.isEmpty else {
                return .success(())
            }
            return state.pingOutcomes.removeFirst()
        }
        try result.get()
    }

    func sendHeartbeatPing() async throws {
        try await sendPing()
    }

    func cancel(with closeCode: UInt16?, reason _: Data?) {
        let waiter = stateStorage.withLock {
            state -> CheckedContinuation<ChatGPTSubscriptionWebSocketMessage, Error>? in
            state.cancelCount += 1
            state.closeCode = closeCode
            state.taskState = .canceling
            let waiter = state.receiveWaiter
            state.receiveWaiter = nil
            return waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    func waitForSend() async {
        if !stateStorage.withLock(\.sentMessages).isEmpty {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResume = stateStorage.withLock { state -> Bool in
                if !state.sentMessages.isEmpty {
                    return true
                }
                state.sendWaiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}
