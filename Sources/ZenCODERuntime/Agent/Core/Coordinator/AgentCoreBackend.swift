//
//  AgentCoreBackend.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor AgentCoreBackend {
    struct SessionSeed {
        let cwd: String
        var systemPrompt: String?
        var dynamicContext: String?
        var history: [AgentRuntimeMessage]
        let cacheKey: String?
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
    }

    let configuration: AgentRuntimeConfiguration
    private let mcpRuntime: DirectMCPToolRuntime
    private let swiftFeatureRuntime: SwiftFeatureRuntime
    var activeBackend: (any AgentRuntimeBackend)?
    /// Single-flight guard for resolving and hydrating the runtime backend.
    /// Actor reentrancy allows another caller into `resolveBackend` whenever
    /// installation awaits an actor-backed runtime; all callers must join the
    /// same preparation instead of invoking the factory again.
    private var backendPreparation: Task<any AgentRuntimeBackend, Error>?
    /// Fences an in-flight backend installation when shutdown releases the
    /// runtime while one of its asynchronous setup calls is suspended.
    var backendGeneration: UInt64 = 0
    // AgentCoreSessionRunner owns application/session persistence snapshots.
    // AgentCoreBackend owns only transient seed state used to hydrate its active runtime backend.
    var memoryProposalSessions: [String: String] = [:]
    var sessions: [String: SessionSeed] = [:]
    private var taskOrchestrator: SessionTaskOrchestrator?
    private var borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?
    private var sharedChatMessageAvailableHandler: (@Sendable (String) -> Void)?
    private var subAgentToolEventHandler: DirectSubAgentToolEventHandler?
    private var toolProvidersBySessionID: [String: [AgentToolProvider]] = [:]
    /// The coordinator's response-language section per root session, read by
    /// delegated agents when they are created. It is kept beside the seeds
    /// (which snapshots and compaction rebuild) and never sent per turn.
    private var responseLanguageSectionsBySessionID: [String: String] = [:]
    private let backendFactory: AgentRuntimeBackendFactory?
    /// Owner of the in-process DS4 engine. A non-DS4 root backend that replaces
    /// a DS4 one closes it when no DS4 session is live. Injectable for tests.
    let ds4EngineRegistry: DS4EngineRegistry

    init(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = nil,
        ds4EngineRegistry: DS4EngineRegistry = .shared
    ) {
        self.configuration = configuration
        self.mcpRuntime = mcpRuntime
        self.swiftFeatureRuntime = swiftFeatureRuntime
        self.backendFactory = backendFactory
        self.ds4EngineRegistry = ds4EngineRegistry
    }

    public func createSession(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        dynamicContext: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false,
        responseLanguageSection: String? = nil
    ) async {
        let allowedToolNames = normalizedAllowedToolNames(allowedToolNames)
        let separatedContext = AgentRuntimeDynamicContext.separating(from: history)
        let seed = SessionSeed(
            cwd: cwd,
            systemPrompt: systemPrompt,
            dynamicContext: dynamicContext ?? separatedContext.context,
            history: separatedContext.history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
        sessions[id] = seed
        responseLanguageSectionsBySessionID[id] = responseLanguageSection?.nilIfBlank
        if let backend = activeBackend {
            await backend.createSession(
                id: id,
                cwd: cwd,
                systemPrompt: systemPrompt,
                history: runtimeHistory(for: seed),
                cacheKey: cacheKey,
                allowedToolNames: allowedToolNames,
                thinkingSelection: thinkingSelection,
                preserveThinking: preserveThinking
            )
        }
    }

    /// Whether this backend incarnation already owns the session seed.
    /// Runner-level configuration can outlive a backend replacement, so callers
    /// use this to distinguish a live backend session from a snapshot that still
    /// needs to be rehydrated into the new backend.
    func hasSession(id: String) -> Bool {
        sessions[id] != nil
    }

    public func compactSession(
        id sessionID: String,
        force: Bool = true,
        maxTokensOverride: Int? = nil
    ) async -> AgentRuntimeSessionCompactionResult? {
        let maxTokens = maxTokensOverride ?? configuration.configuredContextWindowLimit
        if let activeBackend {
            if let result = await activeBackend.compactSession(id: sessionID, force: force) {
                updateSessionSeed(from: result.snapshot)
                return result
            }
            guard let snapshot = await activeBackend.snapshotSession(id: sessionID),
                  let result = compactSnapshot(
                    snapshot,
                    maxTokens: maxTokens,
                    force: force
                  ) else {
                return nil
            }
            updateSessionSeed(from: result.snapshot)
            await activeBackend.createSession(
                id: result.snapshot.sessionID,
                cwd: result.snapshot.workingDirectoryPath,
                systemPrompt: result.snapshot.systemPrompt,
                history: AgentRuntimeDynamicContext.inserting(
                    result.snapshot.dynamicContext,
                    into: result.snapshot.history
                ),
                cacheKey: result.snapshot.cacheKey,
                allowedToolNames: result.snapshot.allowedToolNames,
                thinkingSelection: result.snapshot.thinkingSelection,
                preserveThinking: result.snapshot.preserveThinking
            )
            return result
        }

        guard let seed = sessions[sessionID],
              let result = compactSnapshot(
                seedSnapshot(id: sessionID, seed: seed),
                maxTokens: maxTokens,
                force: force
              ) else {
            return nil
        }

        updateSessionSeed(from: result.snapshot)
        return result
    }

    public func closeSession(id: String) async {
        // Same teardown as clearSession: also forgets tool providers so rebuilt backends don't reapply them.
        await clearSession(id: id)
    }

    public func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        dynamicContext: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool,
        responseLanguageSection: String? = nil
    ) async {
        guard var seed = sessions[id] else {
            return
        }
        responseLanguageSectionsBySessionID[id] = responseLanguageSection?.nilIfBlank
        let allowedToolNames = normalizedAllowedToolNames(allowedToolNames)
        seed.systemPrompt = systemPrompt
        let dynamicContextChanged = seed.dynamicContext != dynamicContext?.nilIfBlank
        seed.dynamicContext = dynamicContext?.nilIfBlank
        seed.allowedToolNames = allowedToolNames
        seed.thinkingSelection = thinkingSelection
        seed.preserveThinking = preserveThinking
        sessions[id] = seed

        if let backend = activeBackend {
            if dynamicContextChanged {
                await backend.createSession(
                    id: id,
                    cwd: seed.cwd,
                    systemPrompt: seed.systemPrompt,
                    history: runtimeHistory(for: seed),
                    cacheKey: seed.cacheKey,
                    allowedToolNames: seed.allowedToolNames,
                    thinkingSelection: seed.thinkingSelection,
                    preserveThinking: seed.preserveThinking
                )
            } else {
                await backend.updateSessionOptions(
                    id: id,
                    systemPrompt: systemPrompt,
                    allowedToolNames: allowedToolNames,
                    thinkingSelection: thinkingSelection,
                    preserveThinking: preserveThinking
                )
            }
        }
    }

    public func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        if let existing = taskOrchestrator {
            // Exclusive ownership: the orchestrator is set exactly once per
            // backend lifetime and must not be silently replaced — doing so
            // would lose checkpointed task-graph state and break the
            // session-restore invariant that SessionTaskOrchestrator is the
            // sole mutable task-graph owner.
            guard existing === orchestrator else {
                preconditionFailure(
                    "Attempted to replace the existing SessionTaskOrchestrator — the task graph has a sole owner."
                )
            }
            return
        }
        taskOrchestrator = orchestrator
        await applyTaskOrchestrator(to: activeBackend)
    }

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        borrowedSubAgentToolExecutor = executor
        await applyBorrowedSubAgentToolExecutor(to: activeBackend)
    }

    public func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) async {
        sharedChatMessageAvailableHandler = handler
        await applySharedChatMessageAvailableHandler(to: activeBackend)
    }

    public func updateSubAgentToolEventHandler(
        _ handler: DirectSubAgentToolEventHandler?
    ) async {
        subAgentToolEventHandler = handler
        await applySubAgentToolEventHandler(to: activeBackend)
    }

    public func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String
    ) async {
        toolProvidersBySessionID[sessionID] = providers
        if let backend = activeBackend {
            await backend.updateToolProviders(providers, sessionID: sessionID)
        }
    }

    public func clearSession(id: String) async {
        await closeMemoryProposal(parentID: id)
        sessions.removeValue(forKey: id)
        toolProvidersBySessionID.removeValue(forKey: id)
        responseLanguageSectionsBySessionID.removeValue(forKey: id)
        if let backend = activeBackend {
            await backend.closeSession(id: id)
        }
    }

    public func shutdown() async {
        backendGeneration &+= 1
        backendPreparation?.cancel()
        backendPreparation = nil
        sessions.removeAll()
        memoryProposalSessions.removeAll()
        toolProvidersBySessionID.removeAll()
        responseLanguageSectionsBySessionID.removeAll()
        let backend = activeBackend
        activeBackend = nil
        if let backend {
            await backend.shutdown()
        }
    }

    public func snapshotSession(id sessionID: String) async -> AgentRuntimeSessionSnapshot? {
        if let snapshot = await activeBackend?.snapshotSession(id: sessionID) {
            // Keep the seed in sync with provider-owned turns so replacing
            // dynamic context never recreates a session from stale history.
            updateSessionSeed(from: snapshot)
            return snapshot
        }
        guard let seed = sessions[sessionID] else {
            return nil
        }
        return seedSnapshot(id: sessionID, seed: seed)
    }

    func resolveBackend(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> any AgentRuntimeBackend {
        if let activeBackend {
            return activeBackend
        }
        if let backendPreparation {
            return try await backendPreparation.value
        }

        let generation = backendGeneration
        let preparation = Task(
            name: "Agent runtime backend preparation"
        ) { [weak self] () throws -> any AgentRuntimeBackend in
            guard let self else {
                throw CancellationError()
            }
            return try await self.prepareBackend(
                onEvent: onEvent,
                generation: generation
            )
        }
        backendPreparation = preparation

        do {
            let backend = try await preparation.value
            if backendPreparation == preparation {
                backendPreparation = nil
            }
            return backend
        } catch {
            if backendPreparation == preparation {
                backendPreparation = nil
            }
            throw error
        }
    }

    private func prepareBackend(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void,
        generation: UInt64
    ) async throws -> any AgentRuntimeBackend {
        if let backendFactory {
            // The factory keeps its two-parameter signature, so the session's
            // feature runtime travels in the configuration: a backend rebuilt
            // for a model or agent change reuses it instead of restarting the
            // feature processes (and asking Xcode for consent again).
            let backend = try backendFactory(
                configuration.withSwiftFeatureRuntime(swiftFeatureRuntime),
                mcpRuntime
            )
            do {
                try await installResolvedBackend(backend, generation: generation)
                await closeDS4EngineIfNonDS4Backend(backend)
                return backend
            } catch {
                await backend.shutdown()
                throw error
            }
        }

        // Compatibility fallback for embedders and older call sites. The `zen`
        // composition root always injects its production backend factory.
        let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: configuration.modelID
        )
        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime
        )
        if !configuration.appMode,
           let provider = selection?.remoteProvider {
            await onEvent(.status("Using remote provider \(provider.displayTitle)."))
            try verifyBackendGeneration(generation)
        }

        do {
            try await installResolvedBackend(backend, generation: generation)
            await closeDS4EngineIfNonDS4Backend(backend)
            return backend
        } catch {
            await backend.shutdown()
            throw error
        }
    }

    /// Frees the in-process DS4 engine when the root backend that was just
    /// installed does not use it (a remote provider or a subscription client),
    /// so its memory is released. A DS4 client keeps the engine: its model is
    /// the one in use. The engine stays open while a DS4 session is live, and
    /// the close never waits for a generation lease.
    private func closeDS4EngineIfNonDS4Backend(_ backend: any AgentRuntimeBackend) async {
        guard (backend as? RemoteGenerationClient)?.ds4Generation == nil else {
            return
        }
        _ = await ds4EngineRegistry.closeIfIdle()
    }

    /// Hydrates a backend completely before making it observable through
    /// `activeBackend`. Publishing earlier lets another caller use a runtime
    /// without its task orchestrator, borrowed executor, providers, or sessions.
    private func installResolvedBackend(
        _ backend: any AgentRuntimeBackend,
        generation: UInt64
    ) async throws {
        await applyTaskOrchestrator(to: backend)
        try verifyBackendGeneration(generation)
        await applyBorrowedSubAgentToolExecutor(to: backend)
        try verifyBackendGeneration(generation)
        await applySharedChatMessageAvailableHandler(to: backend)
        try verifyBackendGeneration(generation)
        await applySubAgentToolEventHandler(to: backend)
        try verifyBackendGeneration(generation)
        await backend.updateSubAgentResponseLanguageSectionProvider(
            subAgentResponseLanguageSectionProvider()
        )
        try verifyBackendGeneration(generation)
        await applyToolProviders(to: backend)
        try verifyBackendGeneration(generation)
        for (sessionID, seed) in sessions {
            await backend.createSession(
                id: sessionID,
                cwd: seed.cwd,
                systemPrompt: seed.systemPrompt,
                history: runtimeHistory(for: seed),
                cacheKey: seed.cacheKey,
                allowedToolNames: seed.allowedToolNames,
                thinkingSelection: seed.thinkingSelection,
                preserveThinking: seed.preserveThinking
            )
            try verifyBackendGeneration(generation)
        }
        activeBackend = backend
    }

    func verifyBackendGeneration(_ generation: UInt64) throws {
        guard generation == backendGeneration else {
            throw CancellationError()
        }
    }

    private func applyTaskOrchestrator(
        to backend: (any AgentRuntimeBackend)?
    ) async {
        if let backend, let taskOrchestrator {
            await backend.installTaskOrchestrator(taskOrchestrator)
        }
    }

    private func applyBorrowedSubAgentToolExecutor(
        to backend: (any AgentRuntimeBackend)?
    ) async {
        if let backend {
            await backend.updateBorrowedSubAgentToolExecutor(
                borrowedSubAgentToolExecutor
            )
        }
    }

    private func applySharedChatMessageAvailableHandler(
        to backend: (any AgentRuntimeBackend)?
    ) async {
        if let backend {
            await backend.updateSharedChatMessageAvailableHandler(
                sharedChatMessageAvailableHandler
            )
        }
    }

    private func applySubAgentToolEventHandler(
        to backend: (any AgentRuntimeBackend)?
    ) async {
        if let backend {
            await backend.updateSubAgentToolEventHandler(
                subAgentToolEventHandler
            )
        }
    }

    /// The live source of the response-language section installed once on
    /// every backend incarnation: delegated agents read the root session's
    /// current section when they are created, so no per-turn update and no
    /// language-change check is needed.
    private func subAgentResponseLanguageSectionProvider() -> DirectSubAgentResponseLanguageSectionProvider {
        { [weak self] rootSessionID in
            await self?.responseLanguageSection(forSessionID: rootSessionID)
        }
    }

    func responseLanguageSection(forSessionID sessionID: String) -> String? {
        responseLanguageSectionsBySessionID[sessionID]
    }

    private func applyToolProviders(
        to backend: (any AgentRuntimeBackend)?
    ) async {
        guard let backend else {
            return
        }
        for (sessionID, providers) in toolProvidersBySessionID {
            await backend.updateToolProviders(providers, sessionID: sessionID)
        }
    }

    func normalizedAllowedToolNames(
        _ allowedToolNames: Set<String>?
    ) -> Set<String>? {
        guard configuration.appMode else {
            return allowedToolNames
        }
        return allowedToolNames ?? []
    }

    private func seedSnapshot(
        id sessionID: String,
        seed: SessionSeed
    ) -> AgentRuntimeSessionSnapshot {
        AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            modelID: configuration.modelID,
            workingDirectoryPath: seed.cwd,
            systemPrompt: seed.systemPrompt,
            dynamicContext: seed.dynamicContext,
            cacheKey: seed.cacheKey,
            history: seed.history,
            allowedToolNames: seed.allowedToolNames,
            thinkingSelection: seed.thinkingSelection,
            preserveThinking: seed.preserveThinking
        )
    }

    private func compactSnapshot(
        _ snapshot: AgentRuntimeSessionSnapshot,
        maxTokens: Int?,
        force: Bool
    ) -> AgentRuntimeSessionCompactionResult? {
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            snapshot.compactionInputMessages,
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: maxTokens,
                maxOutputTokens: configuration.maxOutputTokens
            ),
            force: force
        )
        guard result.wasCompacted else {
            return nil
        }

        return AgentRuntimeSessionCompactionResult(
            snapshot: snapshot.applyingCompaction(result),
            compactionResult: result
        )
    }

    private func updateSessionSeed(from snapshot: AgentRuntimeSessionSnapshot) {
        sessions[snapshot.sessionID] = SessionSeed(
            cwd: snapshot.workingDirectoryPath,
            systemPrompt: snapshot.systemPrompt,
            dynamicContext: snapshot.dynamicContext,
            history: snapshot.history,
            cacheKey: snapshot.cacheKey,
            allowedToolNames: normalizedAllowedToolNames(snapshot.allowedToolNames),
            thinkingSelection: snapshot.thinkingSelection,
            preserveThinking: snapshot.preserveThinking
        )
    }

    func runtimeHistory(for seed: SessionSeed) -> [AgentRuntimeMessage] {
        AgentRuntimeDynamicContext.inserting(seed.dynamicContext, into: seed.history)
    }
}

// MARK: - Isolated, same-backend conservative memory proposal
extension AgentCoreBackend {
    private func closeMemoryProposal(parentID: String) async {
        guard let id = memoryProposalSessions.removeValue(forKey: parentID) else { return }
        await activeBackend?.closeSession(id: id)
    }
}
