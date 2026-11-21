//
//  AgentCoreSessionRunner+SessionLifecycle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension AgentCoreSessionRunner {
    public func activeToolDescriptors(
        sessionID: String
    ) async -> [DirectToolDescriptor] {
        guard let backend else {
            return []
        }
        return await backend.activeToolDescriptors(sessionID: sessionID)
    }

    public func snapshotSession(id sessionID: String) async -> AgentRuntimeSessionSnapshot? {
        if let snapshot = await backend?.snapshotSession(id: sessionID) {
            if let lastKnownSnapshot = lastKnownSessionSnapshots[sessionID],
               lastKnownSnapshot.isLikelyNewerThan(snapshot) {
                return lastKnownSnapshot
            }
            return snapshot
        }
        if let snapshot = lastKnownSessionSnapshots[sessionID] {
            return snapshot
        }
        guard let configuration = sessions[sessionID] else {
            return nil
        }
        return AgentRuntimeSessionSnapshot(
            sessionID: configuration.sessionID,
            modelID: configuration.modelID,
            workingDirectoryPath: configuration.workingDirectoryPath,
            systemPrompt: configuration.systemPrompt,
            dynamicContext: configuration.dynamicContext,
            cacheKey: configuration.cacheKey,
            history: configuration.history,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    @discardableResult
    public func replaceSessionHistory(
        id sessionID: String,
        history: [AgentRuntimeMessage],
        expectedSessionGeneration: SessionGeneration
    ) async -> Bool {
        do {
            return try await sessionMutationLease.withLease(
                sessionID: sessionID
            ) { [self] in
                await replaceSessionHistoryUsingMutationLease(
                    id: sessionID,
                    history: history,
                    expectedSessionGeneration: expectedSessionGeneration
                )
            }
        } catch {
            return false
        }
    }

    private func replaceSessionHistoryUsingMutationLease(
        id sessionID: String,
        history: [AgentRuntimeMessage],
        expectedSessionGeneration: SessionGeneration
    ) async -> Bool {
        guard isCurrentSessionGeneration(
            expectedSessionGeneration,
            for: sessionID
        ) else {
            return false
        }
        guard let baseConfiguration = sessions[sessionID] else {
            return false
        }
        let generation = backendGeneration
        let currentSnapshot = await backend?.snapshotSession(id: sessionID)
            ?? lastKnownSessionSnapshots[sessionID]
            ?? AgentRuntimeSessionSnapshot(configuration: baseConfiguration)
        guard isCurrentBackendGeneration(generation),
              isCurrentSessionGeneration(
                  expectedSessionGeneration,
                  for: sessionID
              ) else {
            return false
        }
        let replacement = currentSnapshot.replacingHistory(history)
        let replacementConfiguration = baseConfiguration.replacingRuntimeState(
            with: replacement
        )

        if let backend {
            await backend.clearSession(id: sessionID)
            guard isCurrentBackendGeneration(generation),
                  isCurrentSessionGeneration(
                      expectedSessionGeneration,
                      for: sessionID
                  ) else {
                return false
            }
            await backend.createSession(
                id: replacement.sessionID,
                cwd: replacement.workingDirectoryPath,
                systemPrompt: replacement.systemPrompt,
                dynamicContext: replacement.dynamicContext,
                history: replacement.history,
                cacheKey: replacement.cacheKey,
                allowedToolNames: replacement.allowedToolNames,
                thinkingSelection: replacement.thinkingSelection,
                preserveThinking: replacement.preserveThinking
            )
            guard isCurrentBackendGeneration(generation),
                  isCurrentSessionGeneration(
                      expectedSessionGeneration,
                      for: sessionID
                  ) else {
                return false
            }
        }
        sessions[sessionID] = replacementConfiguration
        lastKnownSessionSnapshots[sessionID] = replacement
        return true
    }


    public func compactSession(
        id sessionID: String,
        force: Bool = true,
        maxTokensOverride: Int? = nil
    ) async throws -> AgentRuntimeSessionCompactionResult? {
        let generation = backendGeneration
        let result: AgentRuntimeSessionCompactionResult?
        if let backendResult = await backend?.compactSession(
            id: sessionID,
            force: force,
            maxTokensOverride: maxTokensOverride
        ) {
            try verifyBackendGeneration(generation)
            result = backendResult
        } else {
            result = compactStoredSession(
                id: sessionID,
                force: force,
                maxTokensOverride: maxTokensOverride
            )
        }
        guard let result else {
            return nil
        }

        try verifyBackendGeneration(generation)
        cacheCompactedSessionSnapshot(result.snapshot)
        return result
    }

    /// Shared session-restore entry point used by persisted TUI and ACP
    /// sessions to recreate their runtime state from the saved configuration.
    public func restoreSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        try await createSession(configuration: configuration)
    }


    public func cancelPrompt(sessionID: String) async {
        // Terminating background jobs is bounded: it only queues signals and
        // returns without waiting for job exits.
        _ = await interruptBackgroundJobs()
        _ = await interruptSubAgents(rootSessionID: sessionID)
    }

    /// Rebuilds transient model/session state while preserving the authoritative
    /// task graph for the same session identity.
    public func rebuildSession(id sessionID: String) async {
        memoryLearningPermits[sessionID] = memoryLearningPermits[sessionID]?.renewed()
        invalidateSessionGeneration(for: sessionID, preservingLearningBudget: true)
        sessions.removeValue(forKey: sessionID)
        lastKnownSessionSnapshots.removeValue(forKey: sessionID)
        promptSkillProvidersBySessionID.removeValue(forKey: sessionID)
        authorizationRouter.discard(sessionID: sessionID)
        // The rebuilt session keeps its identity but starts a new conversation,
        // so it must not inherit paused recall from the history being dropped.
        await MemoryTurnCoordinator.shared.discard(sessionID: sessionID)
        // The transient bus lives inside the backend tree: release an
        // unresolved synthetic batch so it is re-offered instead of lost, while
        // keeping live observers attached across the rebuild. The room stays
        // fenced until the clear below has run, so no poll woken in between can
        // drain the retiring bus into the rebuilt session.
        let chatReset = await sharedChatCoordinatorStorage?.beginReset(roomID: sessionID)
        await backend?.clearSession(id: sessionID)
        if let chatReset {
            await sharedChatCoordinatorStorage?.endReset(chatReset)
        }
        // A rebuilt session is a fresh conversation: readable mention aliases
        // start clean so they are never inherited from the dropped roster.
        await sharedChatMentionCatalogStorage?.reset()
    }

    /// Discards a logical session, including its persisted task graph.
    public func resetSession(id sessionID: String? = nil) async {
        do {
            try await resetSessionThrowing(id: sessionID)
        } catch {
            ZenLogger.error(
                .viewModelRuntime,
                "agent core session runner could not discard task graph: \(error.localizedDescription)"
            )
        }
    }

    /// Throwing counterpart to ``resetSession(id:)`` for callers that need to
    /// surface a checkpoint-deletion failure instead of treating teardown as
    /// best-effort. The original non-throwing API remains available.
    public func resetSessionThrowing(id sessionID: String? = nil) async throws {
        if sessionID == nil {
            memoryLearningPermits.values.forEach { $0.invalidate() }
            memoryLearningPermits.removeAll()
        }
        if let sessionID {
            memoryLearningPermits.removeValue(forKey: sessionID)?.invalidate()
            _ = await interruptSubAgents(rootSessionID: sessionID)
            await rebuildSession(id: sessionID)
            // The conversation ends: so do the features its Builder
            // sub-agents exposed (after the interruption, before the throwing
            // discard).
            await revokeFeatureExposures(sessionID: sessionID)
            try await taskOrchestrator.discardSession(id: sessionID)
            return
        }

        authorizationRouter.discardAll()
        promptSkillProvidersBySessionID.removeAll()
        snapshotStore.discardAll()

        let taskSessionIDs = await taskOrchestrator.registeredSessionIDs()
        let sessionIDs = Array(
            Set(sessions.keys)
                .union(lastKnownSessionSnapshots.keys)
                .union(taskSessionIDs)
        )
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        // Every conversation of this runner ends; before the loop, so a
        // failing discard cannot skip it.
        await revokeKnownFeatureExposures(including: sessionIDs)
        for sessionID in sessionIDs {
            _ = await interruptSubAgents(rootSessionID: sessionID)
            await MemoryTurnCoordinator.shared.discard(sessionID: sessionID)
            // Same ordering as `rebuildSession`: the room is fenced across the
            // backend clear, never merely before it.
            let chatReset = await sharedChatCoordinatorStorage?.beginReset(roomID: sessionID)
            await backend?.clearSession(id: sessionID)
            if let chatReset {
                await sharedChatCoordinatorStorage?.endReset(chatReset)
            }
            try await taskOrchestrator.discardSession(id: sessionID)
        }
    }

    public func closeSession(id sessionID: String) async {
        do {
            try await closeSessionThrowing(id: sessionID)
        } catch {
            ZenLogger.error(
                .viewModelRuntime,
                "agent core session runner lifecycle persistence failed: \(error.localizedDescription)"
            )
        }
    }

    /// Throwing counterpart to ``closeSession(id:)`` for callers that need to
    /// observe persistence failures after the applicable teardown completes.
    public func closeSessionThrowing(id sessionID: String) async throws {
        // Drop the incarnation before any suspension so a prompt that is still
        // winding down cannot cache or restore this session afterwards.
        invalidateSessionGeneration(for: sessionID)
        sessions.removeValue(forKey: sessionID)
        lastKnownSessionSnapshots.removeValue(forKey: sessionID)
        authorizationRouter.discard(sessionID: sessionID)
        _ = await interruptSubAgents(rootSessionID: sessionID)
        // The conversation ends: so do the features its Builder sub-agents
        // exposed, before the throwing flushes below.
        await revokeFeatureExposures(sessionID: sessionID)
        // A recreated session reuses the id, so its recall health belongs to
        // the incarnation that owned the conversation. Drop it before the
        // throwing checkpoint flush so a failed close cannot strand a pause.
        await MemoryTurnCoordinator.shared.discard(sessionID: sessionID)
        // Durability barrier for memory: before any teardown, flush the
        // automatic-recall maintenance that deliberately stayed in memory below
        // its checkpoint threshold. Best effort across every open store; the first failure is
        // rethrown so a persistence error surfaces before the session is gone.
        var memoryFlushError: (any Error)?
        do {
            try await memoryGraphStoreRegistry.flushAll()
        } catch {
            memoryFlushError = error
        }
        try await taskOrchestrator.flush(sessionID: sessionID)
        promptSkillProvidersBySessionID.removeValue(forKey: sessionID)
        // Terminate coordination for this room so a suspended observer resumes
        // instead of waiting forever on a closed session.
        await sharedChatCoordinatorStorage?.stop(roomID: sessionID)
        await backend?.closeSession(id: sessionID)
        // Re-drop after the suspensions above: a prompt finalization that raced
        // this close may have re-inserted state before its generation check.
        sessions.removeValue(forKey: sessionID)
        lastKnownSessionSnapshots.removeValue(forKey: sessionID)
        if let memoryFlushError { throw memoryFlushError }
    }

    public func shutdown() async {
        memoryLearningPermits.values.forEach { $0.invalidate() }
        memoryLearningPermits.removeAll()
        // Latch before the first suspension: an `ensureBackend` caller that is
        // already parked in the single-flight preparation observes this and
        // gives up, instead of looping and building a fresh backend for a
        // runtime that is being torn down. An ordinary backend reset (model or
        // agent switch) deliberately does *not* latch it, so those callers keep
        // their retry-and-rebuild behaviour.
        backendManager.latchShutdown()
        await shutdownBackendKeepingExternalTools()
        // Terminal teardown: no exposure of this runner's sessions survives
        // it. An ordinary backend reset (model or agent switch) keeps them; an
        // agent switch revokes them when the session is created again with
        // the new profile.
        await revokeKnownFeatureExposures()
        // Process exit: the engine is freed unless a DS4 session is still live
        // (another runner of this process uses the model). Never waits.
        _ = await ds4EngineRegistry.closeIfIdle()
        await mcpRuntime.shutdown()
    }

    /// Shuts down the model backend and all session state while keeping the
    /// connected external MCP servers alive. Use this for backend resets such as model or
    /// agent switching, where tearing down MCP connections would force the
    /// user to grant external-tool consents again.
    public func shutdownBackendKeepingExternalTools() async {
        do {
            try await shutdownBackendKeepingExternalToolsThrowing()
        } catch {
            ZenLogger.error(
                .viewModelRuntime,
                "agent core session runner lifecycle persistence failed: \(error.localizedDescription)"
            )
        }
    }

    /// Throwing counterpart to ``shutdownBackendKeepingExternalTools()``. It
    /// retains the compatibility wrapper, completes the established teardown
    /// after a memory-flush failure, then makes that failure observable.
    public func shutdownBackendKeepingExternalToolsThrowing() async throws {
        memoryLearningPermits.values.forEach { $0.invalidate() }
        memoryLearningPermits.removeAll()
        authorizationRouter.discardAll()
        // Fence in-flight backend creation and session work before suspending.
        let backendToShutdown = backendManager.invalidateBackend()
        snapshotStore.discardAll()
        // Durability barrier for memory: flushing here — before the teardown
        // below clears the stores that own the pending maintenance — makes the
        // accumulated in-memory state durable.
        var memoryFlushError: (any Error)?
        do {
            try await memoryGraphStoreRegistry.flushAll()
        } catch {
            memoryFlushError = error
        }
        try await taskOrchestrator.flush()
        // Terminate every task-graph event observer so suspended `events(...)`
        // consumers resume instead of waiting forever after shutdown.
        await taskOrchestrator.finishEventStreams()
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        promptSkillProvidersBySessionID.removeAll()
        // The runtime tree that produced the transient transcript is gone, so
        // finish every observer and drop the parked batches with it.
        await sharedChatCoordinatorStorage?.stopAll()
        await sharedChatMentionCatalogStorage?.reset()
        await backendToShutdown?.shutdown()
        if let memoryFlushError { throw memoryFlushError }
    }

    func ensureSession(
        configuration: AgentCoreSessionConfiguration,
        backend: AgentCoreBackend,
        backendGeneration: UInt64
    ) async throws {
        if let existing = sessions[configuration.sessionID] {
            if existing.matchesSessionIdentity(configuration) {
                if await !backend.hasSession(id: configuration.sessionID) {
                    await createBackendSession(backend, configuration: existing)
                    try verifyBackendGeneration(backendGeneration)
                }
                return
            }
            if existing.matchesSessionIdentityIgnoringThinking(configuration) {
                if await !backend.hasSession(id: configuration.sessionID) {
                    await createBackendSession(backend, configuration: existing)
                    try verifyBackendGeneration(backendGeneration)
                }
                try await updateSessionOptions(configuration: configuration)
                return
            }
        }
        try await createSession(configuration: configuration)
    }

    /// Returns the runner-owned backend, creating it at most once even when
    /// several prompts, preloads, or session updates race: concurrent callers
    /// join the in-flight creation instead of starting a second one.
    func ensureBackend(
        configuration: AgentCoreSessionConfiguration
    ) async throws -> AgentCoreBackend {
        // Snapshot the shutdown epoch on entry. A `reset` (model or agent
        // switch) is a legitimate reason to loop and rebuild; a `shutdown` is
        // not, so a caller that was suspended across one must fail instead of
        // resurrecting a backend behind the closed runtime.
        let entryShutdownGeneration = shutdownGeneration

        func ensureNotShutDownSinceEntry() throws {
            guard shutdownGeneration == entryShutdownGeneration else {
                throw BackendInvalidatedError()
            }
        }

        while true {
            try ensureNotShutDownSinceEntry()
            if let preparation = backendPreparation {
                // Single-flight: wait for the in-flight creation, then
                // re-evaluate because a reset may have happened meanwhile.
                _ = try? await preparation.value
                if backendPreparation == preparation {
                    backendPreparation = nil
                }
                try ensureNotShutDownSinceEntry()
                continue
            }

            if let activeRuntimeConfiguration,
               !activeRuntimeConfiguration.matchesRuntime(configuration) {
                await resetBackend()
                try ensureNotShutDownSinceEntry()
                continue
            }

            if let backend {
                return backend
            }

            let generation = backendGeneration
            let preparation = Task(name: "Agent backend preparation") { [weak self] () throws -> AgentCoreBackend in
                guard let self else {
                    throw BackendInvalidatedError()
                }
                return try await self.makeBackend(
                    configuration: configuration,
                    generation: generation
                )
            }
            backendPreparation = preparation
            do {
                let backend = try await preparation.value
                if backendPreparation == preparation {
                    backendPreparation = nil
                }
                try ensureNotShutDownSinceEntry()
                return backend
            } catch {
                if backendPreparation == preparation {
                    backendPreparation = nil
                }
                // A shutdown fences this caller for good; only a reset earns a
                // retry against the current generation.
                try ensureNotShutDownSinceEntry()
                if error is BackendInvalidatedError {
                    continue
                }
                throw error
            }
        }
    }

    private func makeBackend(
        configuration: AgentCoreSessionConfiguration,
        generation: UInt64
    ) async throws -> AgentCoreBackend {
        let runtimeConfiguration = configuration.runtimeConfiguration
            .withToolAuthorizationHandler { request in
                await self.authorizeTool(request)
            }
        let backend = AgentCoreBackend(
            configuration: runtimeConfiguration,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
            backendFactory: backendFactory,
            ds4EngineRegistry: ds4EngineRegistry
        )
        await backend.installTaskOrchestrator(taskOrchestrator)
        await backend.updateSubAgentToolEventHandler(
            subAgentToolEventHandler
        )
        guard isCurrentBackendGeneration(generation) else {
            // Reset or shutdown ran while this backend was being prepared:
            // discard the orphan instead of installing stale state.
            await backend.shutdown()
            throw BackendInvalidatedError()
        }
        self.backend = backend
        activeRuntimeConfiguration = configuration
        ZenLogger.debug(
            .viewModelRuntime,
            "agent core session runner initialized model=\(configuration.modelID ?? "default") workingDirectory=\(configuration.workingDirectoryPath)."
        )
        return backend
    }

    private func resetBackend() async {
        // Rotate fences, retaining the logical-session budget for subsequent turns.
        memoryLearningPermits = memoryLearningPermits.mapValues { $0.renewed() }
        let backendToShutdown = backendManager.invalidateBackend()
        // A runtime mismatch (for example another ACP session selecting a
        // different model or cwd) replaces the single backend, not the logical
        // sessions owned by this runner. Their configurations and snapshots are
        // the source used to rehydrate each session when its runtime becomes
        // active again, so dropping the whole store here loses unrelated
        // session history on every A -> B -> A hand-off. Full shutdown and
        // logical reset still discard the store in their dedicated paths.
        await backendToShutdown?.shutdown()
    }

    func verifyBackendGeneration(_ generation: UInt64) throws {
        try backendManager.verify(generation: generation)
    }

    func isCurrentBackendGeneration(_ generation: UInt64) -> Bool {
        backendManager.isCurrent(generation: generation)
    }

    @discardableResult
    func beginSessionGeneration(for sessionID: String) -> SessionGeneration {
        guard let configuration = sessions[sessionID] else {
            preconditionFailure("A session generation requires its configuration")
        }
        return snapshotStore.begin(configuration)
    }

    public func currentSessionGeneration(for sessionID: String) -> SessionGeneration? {
        snapshotStore.currentGeneration(for: sessionID)
    }

    private func invalidateSessionGeneration(for sessionID: String, preservingLearningBudget: Bool = false) {
        if !preservingLearningBudget {
            memoryLearningPermits.removeValue(forKey: sessionID)?.invalidate()
        }
        snapshotStore.discard(sessionID)
    }

    /// `true` while the captured incarnation is still the live one. A closed,
    /// rebuilt, reset, or shut-down session never matches again.
    func isCurrentSessionGeneration(
        _ generation: SessionGeneration?,
        for sessionID: String
    ) -> Bool {
        snapshotStore.isCurrent(generation, sessionID: sessionID)
    }

}
