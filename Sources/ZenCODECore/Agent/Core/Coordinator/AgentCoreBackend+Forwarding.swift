//
//  AgentCoreBackend+Forwarding.swift
//  ZenCODE
//
//  Requests that resolve or forward to the active runtime backend: prompts,
//  model preload, sub-agents, shared chat, background jobs, and engine
//  checkpoints.
//

import Foundation
import ToolCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AgentCoreBackend {
    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        let backend = try await resolveBackend(onEvent: onEvent)
        return try await backend.preloadModel(onEvent: onEvent)
    }

    public func activeToolDescriptors(
        sessionID: String?
    ) async -> [DirectToolDescriptor] {
        if let backend = activeBackend {
            return await backend.activeToolDescriptors(sessionID: sessionID)
        }
        return []
    }

    public func closeSubAgent(id: String) async -> Bool {
        guard let activeBackend else { return false }
        return await activeBackend.closeSubAgent(id: id)
    }

    public func interruptSubAgents(rootSessionID: String) async -> Int {
        guard let activeBackend else { return 0 }
        return await activeBackend.interruptSubAgents(rootSessionID: rootSessionID)
    }

    public func interruptBackgroundJobs() async -> Int {
        guard let activeBackend else { return 0 }
        return await activeBackend.interruptBackgroundJobs()
    }

    /// Forwards to the active backend; `.notApplicable` while none is resolved
    /// (saving never builds a backend nor opens a model).
    public func saveEngineCheckpoint(
        sessionID: String,
        to url: URL
    ) async throws -> AgentEngineCheckpointSaveOutcome {
        guard let activeBackend else { return .notApplicable }
        return try await activeBackend.saveEngineCheckpoint(sessionID: sessionID, to: url)
    }

    /// Forwards to the active backend; `.notApplicable` while none is resolved.
    public func restoreEngineCheckpoint(
        sessionID: String,
        from url: URL,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async -> AgentEngineCheckpointRestoreOutcome {
        guard let activeBackend else { return .notApplicable }
        return await activeBackend.restoreEngineCheckpoint(sessionID: sessionID, from: url, onEvent: onEvent)
    }

    /// Forwards to the active backend; rejects while none is resolved (a DS4
    /// control never builds a backend nor opens a model).
    public func ds4Control(
        _ command: AgentDS4ControlCommand,
        sessionID: String
    ) async throws -> AgentDS4ControlResult {
        guard let activeBackend else { throw AgentDS4ControlError.noActiveBackend }
        return try await activeBackend.ds4Control(command, sessionID: sessionID)
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        if let backend = activeBackend {
            return await backend.subAgentSnapshots()
        }
        return []
    }

    public func sharedChatParticipants(
        rootSessionID: String
    ) async -> [AgentSharedChat.Participant] {
        guard let activeBackend else { return [] }
        return await activeBackend.sharedChatParticipants(rootSessionID: rootSessionID)
    }

    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String,
        messageID: UUID = UUID()
    ) async throws -> AgentSharedChat.Delivery {
        guard let activeBackend else {
            throw AgentSharedChat.Error.unavailable
        }
        return try await activeBackend.sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID,
            messageID: messageID
        )
    }

    public func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        guard let activeBackend else { return [] }
        return await activeBackend.drainCoordinatorSharedChatMessages(
            rootSessionID: rootSessionID
        )
    }

    public func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        guard let activeBackend else { return [] }
        return await activeBackend.sharedChatTranscriptMessages(
            rootSessionID: rootSessionID
        )
    }

    public func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment] = [],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let backend = try await resolveBackend(onEvent: onEvent)
        if sessions[sessionID] == nil {
            sessions[sessionID] = SessionSeed(
                cwd: configuration.workingDirectory.path,
                systemPrompt: nil,
                dynamicContext: nil,
                history: [],
                cacheKey: nil,
                allowedToolNames: normalizedAllowedToolNames(nil),
                thinkingSelection: nil,
                preserveThinking: false
            )
        }
        try await ensureSessionExists(sessionID: sessionID, backend: backend)

        return try await backend.sendPrompt(
            sessionID: sessionID,
            prompt: prompt,
            attachments: attachments,
            onEvent: onEvent
        )
    }

    private func ensureSessionExists(
        sessionID: String,
        backend: any AgentRuntimeBackend
    ) async throws {
        guard let seed = sessions[sessionID] else {
            return
        }
        await backend.createSessionIfNeeded(
            id: sessionID,
            cwd: seed.cwd,
            systemPrompt: seed.systemPrompt,
            history: runtimeHistory(for: seed),
            cacheKey: seed.cacheKey,
            allowedToolNames: seed.allowedToolNames,
            thinkingSelection: seed.thinkingSelection,
            preserveThinking: seed.preserveThinking
        )
    }
}

extension AgentCoreBackend {
    func existingSubAgentSnapshotEvents(rootSessionID: String) async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>? {
        guard let activeBackend else { return nil }
        return await activeBackend.subAgentSnapshotEvents(rootSessionID: rootSessionID)
    }

    public func subAgentSnapshotEvents(rootSessionID: String) async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]> {
        guard let activeBackend else { return AsyncStream { $0.finish() } }
        return await activeBackend.subAgentSnapshotEvents(rootSessionID: rootSessionID)
    }

    /// Forwards to the active backend; `nil` while none is resolved (a
    /// transcript read never builds a backend).
    public func subAgentTranscript(
        agentID: String,
        rootSessionID: String
    ) async -> ChatSubAgentTranscript? {
        guard let activeBackend else { return nil }
        return await activeBackend.subAgentTranscript(agentID: agentID, rootSessionID: rootSessionID)
    }
}
