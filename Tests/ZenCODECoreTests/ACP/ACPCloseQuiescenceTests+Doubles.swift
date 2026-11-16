//
//  ACPCloseQuiescenceTests+Doubles.swift
//  ZenCODE
//
//  Test doubles of the `session/close` quiescence tests: the gate that pins a
//  turn at an exact point, and the backend double that ends the turn as
//  cancelled once the gate opens.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// Gate that reports arrival, so a test can pin the prompt inside generation
/// and only then race the close against it.
final class CloseQuiescenceGate: Sendable {
    private struct State {
        var isOpen = false
        var arrivals = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func arriveAndWait() async {
        let pendingArrivals = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.arrivals += 1
            let pending = state.arrivalWaiters
            state.arrivalWaiters.removeAll()
            return pending
        }
        for waiter in pendingArrivals {
            waiter.resume()
        }
        if state.withLock({ $0.isOpen }) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func waitUntilReached() async {
        if state.withLock({ $0.arrivals > 0 }) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.arrivals > 0 {
                    return true
                }
                state.arrivalWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let pending = state.waiters
            state.waiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - Backend double

/// Runtime backend whose `sendPrompt` can be pinned inside generation by a
/// gate. The turn emits its content *before* the gate — so in app mode it sits
/// in the ACP prompt update buffer until the final flush — and ends as
/// cancelled once the gate opens, mirroring a runtime that honours the
/// cancellation `session/close` and `session/cancel` mark the wrapper task with.
actor CloseQuiescenceBackend: AgentRuntimeBackend {
    private let promptGate: CloseQuiescenceGate
    private let bufferedChunk: String
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    init(promptGate: CloseQuiescenceGate, bufferedChunk: String) {
        self.promptGate = promptGate
        self.bufferedChunk = bufferedChunk
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard sessions[id] == nil else {
            return
        }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        await onEvent(.content(bufferedChunk))
        await promptGate.arriveAndWait()
        try Task.checkCancellation()
        return DirectAgentResponse(
            text: "done",
            stopReason: "end_turn",
            modelID: "test-model"
        )
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}
