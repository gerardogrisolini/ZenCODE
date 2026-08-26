//
//  AgentCoreSessionRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization
import ToolCore

public actor AgentCoreSessionRunner {
    public static var isAvailable: Bool {
        true
    }

    /// Thrown internally when a backend creation is fenced out by a concurrent
    /// reset or shutdown, so `ensureBackend` retries instead of installing a
    /// backend that no longer belongs to the current runtime generation.
    typealias BackendInvalidatedError = AgentCoreBackendManager.InvalidatedError

    /// Identifies one incarnation of a session. Every `createSession` starts a
    /// new generation and every close/reset drops it, so work that started
    /// before the change cannot cache or restore state afterwards.
    typealias SessionGeneration = AgentCoreSessionSnapshotStore.Generation

    var backendManager = AgentCoreBackendManager()
    var backend: AgentCoreBackend? {
        get { backendManager.backend }
        set { backendManager.backend = newValue }
    }
    /// Single-flight guard: concurrent `ensureBackend` callers join this task
    /// instead of each building their own `AgentCoreBackend`.
    var backendPreparation: Task<AgentCoreBackend, Error>? {
        get { backendManager.preparation }
        set { backendManager.preparation = newValue }
    }
    /// Bumped by every reset/shutdown so an in-flight backend creation that
    /// started earlier is discarded instead of overwriting newer state.
    var backendGeneration: UInt64 { backendManager.generation }
    /// Bumped only by shutdown (never by an ordinary backend reset). Work that
    /// entered before a shutdown compares against it and gives up instead of
    /// building a fresh backend for a runtime nobody is driving anymore.
    var shutdownGeneration: UInt64 { backendManager.shutdownGeneration }
    var activeRuntimeConfiguration: AgentCoreSessionConfiguration? {
        get { backendManager.activeConfiguration }
        set { backendManager.activeConfiguration = newValue }
    }
    var snapshotStore = AgentCoreSessionSnapshotStore()
    var sessions: [String: AgentCoreSessionConfiguration] {
        get { snapshotStore.configurations }
        set { snapshotStore.configurations = newValue }
    }
    var lastKnownSessionSnapshots: [String: AgentRuntimeSessionSnapshot] {
        get { snapshotStore.snapshots }
        set { snapshotStore.snapshots = newValue }
    }
    /// Session-scoped, mutable prompt-skill providers. Owned here so changing
    /// the skill selection updates only this snapshot and never the system
    /// prompt, allowlist, cache key, or remote session identity.
    var promptSkillProvidersBySessionID: [String: PromptSkillSessionProvider] = [:]
    var promptTaskRegistry = AgentCorePromptTaskRegistry()
    /// Serializes complete prompt turns per session without coupling unrelated
    /// sessions. It is deliberately outside backend state so a turn remains
    /// ordered across backend creation, recovery, and finalisation.
    let sessionTurnLease: AgentSessionTurnLease
    /// Serializes session creation/recreation with history replacement for the
    /// same logical id. Close remains deliberately preemptive: it invalidates the
    /// generation while a suspended mutation unwinds, and a replacement checks
    /// that generation before every commit.
    let sessionMutationLease = AgentSessionTurnLease()
    /// Core-side owner of coordinator-mailbox monitoring, batching and the
    /// single-flight auto-trigger decision. Built lazily so its message source
    /// can capture this runner weakly and never form a reference cycle.
    var sharedChatCoordinatorStorage: AgentSharedChatCoordinator?
    /// Actor-isolated catalogue of readable `@mention` handles. Built lazily and
    /// reset alongside the shared-chat coordinator so aliases are never recycled
    /// within a session but start clean on a new one.
    var sharedChatMentionCatalogStorage: SharedChatMentionCatalog?
    /// Presentation-only tool lifecycle sink retained across backend rebuilds so
    /// delegated work that outlives its spawning turn keeps the same renderer.
    var subAgentToolEventHandler: DirectSubAgentToolEventHandler?
    var authorizationRouter = AgentCoreAuthorizationRouter()
    /// Session-scoped copy of the same handler, kept alive across turns.
    ///
    /// Delegated sub-agents keep executing tools after the turn that spawned
    /// them has returned, so their consent cannot hang off a turn-scoped entry.
    /// Keying by session (not by turn) also preserves per-origin routing: a
    /// session driven from Telegram keeps asking its own operator there. Only
    /// reset/shutdown clears this map; the per-prompt `defer` must not.
    let defaultToolAuthorizationHandler: AgentToolAuthorizationHandler?
    let mcpRuntime: DirectMCPToolRuntime
    public let taskOrchestrator: SessionTaskOrchestrator
    let backendFactory: AgentRuntimeBackendFactory?

    struct LifecycleResourceCounts: Equatable {
        let promptSkillProviders: Int
        let authorizationSessions: Int
    }

    func lifecycleResourceCounts() -> LifecycleResourceCounts {
        LifecycleResourceCounts(
            promptSkillProviders: promptSkillProvidersBySessionID.count,
            authorizationSessions: authorizationRouter.retainedSessionCount
        )
    }

    public init(
        defaultToolAuthorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = nil,
        taskOrchestrator: SessionTaskOrchestrator? = nil,
        taskGraphStore: SessionTaskGraphStore? = SessionTaskGraphStore()
    ) {
        self.init(
            defaultToolAuthorizationHandler: defaultToolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            backendFactory: backendFactory,
            taskOrchestrator: taskOrchestrator,
            taskGraphStore: taskGraphStore,
            sessionTurnLease: AgentSessionTurnLease()
        )
    }

    init(
        defaultToolAuthorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = nil,
        taskOrchestrator: SessionTaskOrchestrator? = nil,
        taskGraphStore: SessionTaskGraphStore? = SessionTaskGraphStore(),
        sessionTurnLease: AgentSessionTurnLease
    ) {
        self.defaultToolAuthorizationHandler = defaultToolAuthorizationHandler
        self.mcpRuntime = mcpRuntime
        self.backendFactory = backendFactory
        self.taskOrchestrator = taskOrchestrator
            ?? SessionTaskOrchestrator(store: taskGraphStore)
        self.sessionTurnLease = sessionTurnLease
    }

    func localExecAccessMode() -> AgentLocalExecAccessMode {
        authorizationRouter.localExecAccessMode
    }

    @discardableResult
    func toggleLocalExecAccessMode() -> AgentLocalExecAccessMode {
        authorizationRouter.toggleLocalExecAccessMode()
    }

    func resetLocalExecAccessMode() {
        authorizationRouter.resetLocalExecAccessMode()
    }

    func createBackendSession(
        _ backend: AgentCoreBackend,
        configuration: AgentCoreSessionConfiguration
    ) async {
        await backend.createSession(
            id: configuration.sessionID,
            cwd: configuration.workingDirectoryPath,
            systemPrompt: configuration.systemPrompt,
            dynamicContext: configuration.dynamicContext,
            history: configuration.history,
            cacheKey: configuration.cacheKey,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    public func createSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        try await sessionMutationLease.withLease(
            sessionID: configuration.sessionID
        ) { [self] in
            try await createSessionUsingMutationLease(configuration: configuration)
        }
    }

    private func createSessionUsingMutationLease(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        try await taskOrchestrator.registerSession(
            id: configuration.sessionID,
            workingDirectory: URL(fileURLWithPath: configuration.workingDirectoryPath)
        )
        _ = ensurePromptSkillProvider(sessionID: configuration.sessionID)
        let backend = try await ensureBackend(configuration: configuration)
        let generation = backendGeneration
        await createBackendSession(backend, configuration: configuration)
        try verifyBackendGeneration(generation)
        sessions[configuration.sessionID] = configuration
        beginSessionGeneration(for: configuration.sessionID)
        ZenLogger.debug(
            .viewModelRuntime,
            "agent core session runner created session id=\(configuration.sessionID) history=\(configuration.history.count) tools=\(configuration.allowedToolNames?.count ?? 0)."
        )
    }

    public func updateSessionOptions(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        let backend = try await ensureBackend(configuration: configuration)
        let generation = backendGeneration
        await backend.updateSessionOptions(
            id: configuration.sessionID,
            systemPrompt: configuration.systemPrompt,
            dynamicContext: configuration.dynamicContext,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
        try verifyBackendGeneration(generation)
        sessions[configuration.sessionID] = configuration
    }

    /// Updates only the session-scoped prompt-skill selection. This mutates the
    /// provider snapshot in place and never changes the system prompt,
    /// allowlist, cache key, history, or remote session identity, so the
    /// KV-cache prefix and any remote continuation stay valid across selection
    /// changes.
    public func updatePromptSkillSelection(
        _ skills: [PromptSkill],
        sessionID: String
    ) async {
        let provider = ensurePromptSkillProvider(sessionID: sessionID)
        await provider.update(skills)
    }

    private func ensurePromptSkillProvider(sessionID: String) -> PromptSkillSessionProvider {
        if let existing = promptSkillProvidersBySessionID[sessionID] {
            return existing
        }
        let provider = PromptSkillSessionProvider()
        promptSkillProvidersBySessionID[sessionID] = provider
        return provider
    }

    public func preloadModel(
        configuration: AgentCoreSessionConfiguration,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        let backend = try await ensureBackend(configuration: configuration)
        let generation = backendGeneration
        let modelID = try await backend.preloadModel(onEvent: onEvent)
        try verifyBackendGeneration(generation)
        return modelID
    }

    public func preloadModel(
        configuration: AgentCoreSessionConfiguration
    ) -> AsyncThrowingStream<DirectAgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DirectAgentEvent, Error>.makeStream()
        let task = Task(name: "Agent model preload", priority: .userInitiated) {
            #if os(macOS)
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "Agent model load"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }
            #endif
            do {
                _ = try await preloadModel(configuration: configuration) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                ZenLogger.error(
                    .viewModelRuntime,
                    "agent core session runner preload failed: \(error.localizedDescription)"
                )
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

}
