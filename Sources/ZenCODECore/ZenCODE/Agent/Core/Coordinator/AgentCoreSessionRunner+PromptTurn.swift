//
//  AgentCoreSessionRunner+PromptTurn.swift
//  ZenCODE
//

import Foundation
import ToolCore


extension AgentCoreSessionRunner {
    public func sendPrompt(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        authorizeTool: AgentToolAuthorizationHandler? = nil,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
        toolProviders: [AgentToolProvider] = [],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        try await sessionTurnLease.withLease(sessionID: configuration.sessionID) { [self] in
            try await self.sendPromptUsingLease(
                configuration: configuration,
                prompt: prompt,
                attachments: attachments,
                authorizeTool: authorizeTool,
                onToolWillExecute: onToolWillExecute,
                borrowedSubAgentToolExecutor: borrowedSubAgentToolExecutor,
                toolProviders: toolProviders,
                onEvent: onEvent
            )
        }
    }

    private func sendPromptUsingLease(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        authorizeTool: AgentToolAuthorizationHandler? = nil,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
        toolProviders: [AgentToolProvider] = [],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let promptID = UUID()
        if let authorizationHandler = authorizeTool ?? defaultToolAuthorizationHandler {
            authorizationRouter.register(
                promptID: promptID,
                sessionID: configuration.sessionID,
                handler: authorizationHandler
            )
        }
        defer {
            authorizationRouter.clear(promptID: promptID)
        }

        let backend = try await ensureBackend(configuration: configuration)
        let generation = backendGeneration
        await backend.updateBorrowedSubAgentToolExecutor(
            borrowedSubAgentToolExecutor
        )
        try verifyBackendGeneration(generation)
        let ownedSkillProvider = promptSkillProvidersBySessionID[configuration.sessionID]?.asToolProvider()
        let nonSkillProviders = toolProviders.filter { provider in
            !provider.tools.contains { PromptSkillToolProvider.toolNames.contains($0.name) }
        }
        let effectiveToolProviders = (ownedSkillProvider.map { [$0] } ?? []) + nonSkillProviders
        await backend.updateToolProviders(
            effectiveToolProviders,
            sessionID: configuration.sessionID
        )
        try verifyBackendGeneration(generation)
        try await ensureSession(
            configuration: configuration,
            backend: backend,
            backendGeneration: generation
        )
        try verifyBackendGeneration(generation)
        // Capture the session incarnation only after the session exists: a later
        // close/reset/rebuild drops this generation and fences the turn's
        // snapshot cache and backend restore.
        let sessionGeneration = currentSessionGeneration(for: configuration.sessionID)
        let initialSnapshot = await backend.snapshotSession(id: configuration.sessionID)
            ?? AgentRuntimeSessionSnapshot(configuration: configuration)
        try verifyBackendGeneration(generation)
        let turnRecorder = AgentCorePromptTurnRecorder(
            initialSnapshot: initialSnapshot,
            prompt: prompt,
            attachments: attachments
        )
        // Every turn — operator, replayed, or synthetic — marks the room busy
        // for the Core auto-trigger, so a shared-chat message can never open a
        // second concurrent prompt behind a consumer's back. The prompt is
        // handed over as well: it is what binds a synthetic turn to the claim
        // it consumes, so no unrelated turn can release that claim when it ends.
        let chatCoordinator = sharedChatCoordinator()
        let chatTurn = await chatCoordinator.noteTurnStarted(
            roomID: configuration.sessionID,
            prompt: prompt
        )

        // Bounded and best-effort: this returns nil on timeout, failure, or an
        // empty graph, and the turn then proceeds with a request that is
        // byte-identical to one sent with memory switched off.
        let memoryBlock = await MemoryTurnCoordinator.shared.memoryBlock(
            sessionID: configuration.sessionID,
            workspaceRootURL: configuration.workingDirectory,
            prompt: prompt
        )

        do {
            let response = try await AgentToolAuthorizationContext.$turnID.withValue(promptID) {
                // Nested inside the existing turn-scoped binding, and around
                // the same call, so the block reaches request assembly through
                // the actor hop exactly the way `turnID` already reaches tool
                // executors. It is scoped to this one `sendPrompt`, so nothing
                // that outlives the turn can observe it.
                try await MemoryTurnContext.$currentTurnMemoryBlock.withValue(memoryBlock) {
                    try await backend.sendPrompt(
                        sessionID: configuration.sessionID,
                        prompt: prompt,
                        attachments: attachments,
                        onEvent: { event in
                            await turnRecorder.record(event)
                            if case let .toolCallStarted(toolCall) = event {
                                await onToolWillExecute?(toolCall)
                            }
                            await onEvent(event)
                        }
                    )
                }
            }
            try verifyBackendGeneration(generation)
            await finalizeTurn(
                outcome: .completed,
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder,
                sessionGeneration: sessionGeneration,
                backendGeneration: generation,
                onEvent: onEvent
            )
            await chatCoordinator.noteTurnEnded(chatTurn)
            return response
        } catch is CancellationError {
            await finalizeTurn(
                outcome: .cancelled,
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder,
                sessionGeneration: sessionGeneration,
                backendGeneration: generation,
                onEvent: onEvent
            )
            // A cancelled synthetic turn must still release the room, otherwise
            // later shared-chat messages would never start a turn again.
            await chatCoordinator.noteTurnEnded(chatTurn)
            throw CancellationError()
        } catch {
            await finalizeTurn(
                outcome: .failed(message: error.localizedDescription),
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder,
                sessionGeneration: sessionGeneration,
                backendGeneration: generation,
                onEvent: onEvent
            )
            await chatCoordinator.noteTurnEnded(chatTurn)
            throw error
        }
    }

    /// Shared turn-finalization: snapshot, restore, and turn-ended event.
    private func finalizeTurn(
        outcome: DirectAgentTurnOutcome,
        backend: AgentCoreBackend,
        configuration: AgentCoreSessionConfiguration,
        recorder: AgentCorePromptTurnRecorder,
        sessionGeneration: SessionGeneration?,
        backendGeneration: UInt64,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        guard isCurrentBackendGeneration(backendGeneration) else {
            return
        }
        let recovery = await recoveredSessionSnapshot(
            backend: backend,
            configuration: configuration,
            recorder: recorder,
            sessionGeneration: sessionGeneration
        )
        guard isCurrentBackendGeneration(backendGeneration) else {
            return
        }
        await restoreSessionIfNeeded(
            recovery,
            backend: backend,
            baseConfiguration: configuration,
            sessionGeneration: sessionGeneration
        )
        guard isCurrentBackendGeneration(backendGeneration) else {
            return
        }
        await onEvent(.sessionSnapshot(recovery.snapshot))
        await onEvent(.turnEnded(outcome))
    }

}
