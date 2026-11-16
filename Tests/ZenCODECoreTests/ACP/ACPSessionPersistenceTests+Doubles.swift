//
//  ACPSessionPersistenceTests+Doubles.swift
//  ZenCODE
//
//  Test doubles shared by the ACP session persistence tests: a wire that
//  records every JSON-RPC message, a gate that holds a turn, and a scripted
//  runtime backend.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Doubles

/// Every JSON-RPC message a bridge wrote, in order.
final class ACPPersistenceWire: Sendable {
    struct Chunk: Equatable, Sendable {
        let kind: String
        let text: String
    }

    private let storage = Mutex<[JSONValue]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                storage.withLock { $0.append(value) }
            }
        }
    }

    var count: Int {
        storage.withLock { $0.count }
    }

    func message(at index: Int) -> [String: JSONValue]? {
        storage.withLock { index < $0.count ? $0[index].objectValue : nil }
    }

    func index(ofResponse id: Int) -> Int? {
        storage.withLock { messages in
            messages.firstIndex { message in
                let object = message.objectValue
                return object?["id"] == .number(Double(id)) && object?["method"] == nil
            }
        }
    }

    /// The `result` of the response to request `id`, if it succeeded.
    func result(id: Int) -> [String: JSONValue]? {
        index(ofResponse: id).flatMap { message(at: $0) }?["result"]?.objectValue
    }

    /// The `error` of the response to request `id`, if it failed.
    func error(id: Int) -> [String: JSONValue]? {
        index(ofResponse: id).flatMap { message(at: $0) }?["error"]?.objectValue
    }

    func sessionID(ofResponse id: Int) -> String? {
        result(id: id)?["sessionId"]?.acpStringValue
    }

    func stopReason(id: Int) -> String? {
        result(id: id)?["stopReason"]?.acpStringValue
    }

    /// The user and agent message chunks written before message `index`.
    func chunks(before index: Int) -> [Chunk] {
        storage.withLock { Array($0.prefix(index)) }.compactMap { message in
            guard let object = message.objectValue,
                  object["method"]?.acpStringValue == "session/update",
                  let update = object["params"]?.objectValue?["update"]?.objectValue,
                  let kind = update["sessionUpdate"]?.acpStringValue,
                  kind == "user_message_chunk" || kind == "agent_message_chunk",
                  let text = update["content"]?.objectValue?["text"]?.acpStringValue else {
                return nil
            }
            return Chunk(kind: kind, text: text)
        }
    }
}

/// Holds a prompt inside the backend until the test opens it, and tells the
/// test when the prompt got there.
final class ACPPersistenceGate: Sendable {
    private struct State {
        var isOpen = false
        var isReached = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func arriveAndWait() async {
        let reachedWaiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isReached = true
            defer { state.reachedWaiters.removeAll() }
            return state.reachedWaiters
        }
        for waiter in reachedWaiters { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                guard !state.isOpen else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                guard !state.isReached else { return true }
                state.reachedWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A backend that keeps every session's history as a model does: a prompt
/// adds itself and its reply. It records the history each prompt arrived
/// with. One instance is one process's backend. The prompt `gatedPrompt`
/// waits at `gate` before it answers.
actor ACPPersistenceBackend: AgentRuntimeBackend {
    struct Observation: Sendable {
        let prompt: String
        let history: [AgentRuntimeMessage]
    }

    private let gate: ACPPersistenceGate?
    private let gatedPrompt: String?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var observations: [Observation] = []

    init(gate: ACPPersistenceGate? = nil, gatedPrompt: String? = nil) {
        self.gate = gate
        self.gatedPrompt = gatedPrompt
    }

    nonisolated var factory: AgentRuntimeBackendFactory {
        { [self] _, _ in self }
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
        guard sessions[id] == nil else { return }
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
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard let snapshot = sessions[id] else { return }
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: snapshot.workingDirectoryPath,
            systemPrompt: systemPrompt,
            cacheKey: snapshot.cacheKey,
            history: snapshot.history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "persistence-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        observations.append(Observation(prompt: prompt, history: sessions[sessionID]?.history ?? []))
        if let gate, prompt == gatedPrompt {
            await gate.arriveAndWait()
        }
        let reply = "reply to: \(prompt)"
        if let snapshot = sessions[sessionID] {
            sessions[sessionID] = snapshot.replacingHistory(snapshot.history + [
                AgentRuntimeMessage(role: .user, content: prompt),
                AgentRuntimeMessage(role: .assistant, content: reply),
            ])
        }
        await onEvent(.content(reply))
        return DirectAgentResponse(text: reply, stopReason: "end_turn", modelID: "persistence-model")
    }
}
