//
//  ChatShellSnapshotTests+Doubles.swift
//  ZenCODE
//
//  The scripted runtime backend, the saved-sessions read gate, and the
//  snapshot recorder that the chat shell snapshot tests run a host with.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// A runtime backend whose turns stream one content event and answer, and
/// that keeps a snapshot of each session, so a session can be saved.
actor ShellTestBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

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
            modelID: "test-model",
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
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let answer = "Answer to: \(prompt)"
        await onEvent(.content(answer))
        if let snapshot = sessions[sessionID] {
            sessions[sessionID] = AgentRuntimeSessionSnapshot(
                sessionID: snapshot.sessionID,
                modelID: snapshot.modelID,
                workingDirectoryPath: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt,
                cacheKey: snapshot.cacheKey,
                history: snapshot.history + [
                    AgentRuntimeMessage(role: .user, content: prompt),
                    AgentRuntimeMessage(role: .assistant, content: answer),
                ],
                allowedToolNames: snapshot.allowedToolNames,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            )
        }
        return DirectAgentResponse(text: answer, stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

/// Holds each read of the saved sessions the shell makes until the test
/// answers it, so that the test orders the reads.
@ChatSessionActor
final class SavedSessionsReadGate {
    private var waiting: [Int: CheckedContinuation<[ChatSavedSessionSummary]?, Never>] = [:]
    private(set) var readCount = 0

    /// The reader the host calls (``ChatSessionHost/shellSavedSessionsReader``).
    nonisolated var reader: @Sendable (URL) async -> [ChatSavedSessionSummary]? {
        { [self] _ in await read() }
    }

    private func read() async -> [ChatSavedSessionSummary]? {
        let index = readCount
        readCount += 1
        return await withCheckedContinuation { waiting[index] = $0 }
    }

    /// Answers the read `index`, counted from 0 in the order the reads
    /// started, with saved sessions named `names`.
    func answer(_ index: Int, with names: [String]) {
        waiting.removeValue(forKey: index)?.resume(returning: names.map { name in
            ChatSavedSessionSummary(
                name: name, modelID: nil, messageCount: 0, contextUsedTokens: nil,
                savedAt: Date(timeIntervalSince1970: 1_000)
            )
        })
    }
}

/// Every shell snapshot one stream delivered, in order.
@ChatSessionActor
final class ShellRecorder {
    private(set) var snapshots: [ChatShellSnapshot] = []
    private var consumer: Task<Void, Never>?

    init(_ host: ChatSessionHost) {
        let stream = host.shellSnapshots()
        consumer = Task { @ChatSessionActor [weak self] in
            for await snapshot in stream {
                self?.snapshots.append(snapshot)
            }
        }
    }

    func stop() {
        consumer?.cancel()
    }
}
