//
//  AgentCoreBackend.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor AgentCoreBackend {
    private struct SessionSeed {
        let cwd: String
        var systemPrompt: String?
        var history: [AgentRuntimeMessage]
        let cacheKey: String?
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
    }

    private let configuration: AgentRuntimeConfiguration
    private let mcpRuntime: DirectMCPToolRuntime
    private var activeBackend: (any AgentRuntimeBackend)?
    /// Single-flight guard for resolving and hydrating the runtime backend.
    /// Actor reentrancy allows another caller into `resolveBackend` whenever
    /// installation awaits an actor-backed runtime; all callers must join the
    /// same preparation instead of invoking the factory again.
    private var backendPreparation: Task<any AgentRuntimeBackend, Error>?
    /// Fences an in-flight backend installation when shutdown releases the
    /// runtime while one of its asynchronous setup calls is suspended.
    private var backendGeneration: UInt64 = 0
    // AgentCoreSessionRunner owns application/session persistence snapshots.
    // AgentCoreBackend owns only transient seed state used to hydrate its active runtime backend.
    private var sessions: [String: SessionSeed] = [:]
    private var taskOrchestrator: SessionTaskOrchestrator?
    private var borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?
    private var toolProvidersBySessionID: [String: [AgentToolProvider]] = [:]
    private let backendFactory: AgentRuntimeBackendFactory?

    public init(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) {
        self.configuration = configuration
        self.mcpRuntime = mcpRuntime
        self.backendFactory = backendFactory
    }

    public static func makeRemoteBackend(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime,
        fallbackProvider: AgentRemoteProvider? = nil,
        fallbackAPIKey: String? = nil,
        urlSession: URLSession? = nil,
        chatGPTConnectionScopeID: String? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil
    ) throws -> any AgentRuntimeBackend {
        try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: mcpRuntime,
            fallbackProvider: fallbackProvider,
            fallbackAPIKey: fallbackAPIKey,
            urlSession: urlSession,
            chatGPTConnectionScopeID: chatGPTConnectionScopeID,
            swiftFeatureRuntime: swiftFeatureRuntime
        )
    }

    public func createSession(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) async {
        let allowedToolNames = normalizedAllowedToolNames(allowedToolNames)
        let seed = SessionSeed(
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
        sessions[id] = seed
        if let backend = activeBackend {
            await backend.createSession(
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
                history: result.snapshot.history,
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
        sessions.removeValue(forKey: id)
        if let backend = activeBackend {
            await backend.closeSession(id: id)
        }
    }

    public func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) async {
        guard var seed = sessions[id] else {
            return
        }
        let allowedToolNames = normalizedAllowedToolNames(allowedToolNames)
        seed.systemPrompt = systemPrompt
        seed.allowedToolNames = allowedToolNames
        seed.thinkingSelection = thinkingSelection
        seed.preserveThinking = preserveThinking
        sessions[id] = seed

        if let backend = activeBackend {
            await backend.updateSessionOptions(
                id: id,
                systemPrompt: systemPrompt,
                allowedToolNames: allowedToolNames,
                thinkingSelection: thinkingSelection,
                preserveThinking: preserveThinking
            )
        }
    }

    public func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        taskOrchestrator = orchestrator
        await applyTaskOrchestrator(to: activeBackend)
    }

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        borrowedSubAgentToolExecutor = executor
        await applyBorrowedSubAgentToolExecutor(to: activeBackend)
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
        sessions.removeValue(forKey: id)
        toolProvidersBySessionID.removeValue(forKey: id)
        if let backend = activeBackend {
            await backend.closeSession(id: id)
        }
    }

    public func shutdown() async {
        backendGeneration &+= 1
        backendPreparation?.cancel()
        backendPreparation = nil
        sessions.removeAll()
        toolProvidersBySessionID.removeAll()
        let backend = activeBackend
        activeBackend = nil
        if let backend {
            await backend.shutdown()
        }
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        let backend = try await resolveBackend(onEvent: onEvent)
        return try await backend.preloadModel(onEvent: onEvent)
    }

    public func activeToolDescriptors() async -> [DirectToolDescriptor] {
        await activeToolDescriptors(sessionID: nil)
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

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        if let backend = activeBackend {
            return await backend.subAgentSnapshots()
        }
        return []
    }

    public func snapshotSession(id sessionID: String) async -> AgentRuntimeSessionSnapshot? {
        if let snapshot = await activeBackend?.snapshotSession(id: sessionID) {
            return snapshot
        }
        guard let seed = sessions[sessionID] else {
            return nil
        }
        return seedSnapshot(id: sessionID, seed: seed)
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

    private func resolveBackend(
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
            let backend = try backendFactory(configuration, mcpRuntime)
            do {
                try await installResolvedBackend(backend, generation: generation)
                return backend
            } catch {
                await backend.shutdown()
                throw error
            }
        }

        let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: configuration.modelID
        )
        let backend = try Self.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: mcpRuntime
        )
        if !configuration.appMode,
           let provider = selection?.remoteProvider {
            await onEvent(.status("Using remote provider \(provider.displayTitle)."))
            try verifyBackendGeneration(generation)
        }

        do {
            try await installResolvedBackend(backend, generation: generation)
            return backend
        } catch {
            await backend.shutdown()
            throw error
        }
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
        await applyToolProviders(to: backend)
        try verifyBackendGeneration(generation)
        for (sessionID, seed) in sessions {
            await backend.createSession(
                id: sessionID,
                cwd: seed.cwd,
                systemPrompt: seed.systemPrompt,
                history: seed.history,
                cacheKey: seed.cacheKey,
                allowedToolNames: seed.allowedToolNames,
                thinkingSelection: seed.thinkingSelection,
                preserveThinking: seed.preserveThinking
            )
            try verifyBackendGeneration(generation)
        }
        activeBackend = backend
    }

    private func verifyBackendGeneration(_ generation: UInt64) throws {
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
            history: seed.history,
            cacheKey: seed.cacheKey,
            allowedToolNames: seed.allowedToolNames,
            thinkingSelection: seed.thinkingSelection,
            preserveThinking: seed.preserveThinking
        )
    }

    private func normalizedAllowedToolNames(
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
            history: snapshot.history,
            cacheKey: snapshot.cacheKey,
            allowedToolNames: normalizedAllowedToolNames(snapshot.allowedToolNames),
            thinkingSelection: snapshot.thinkingSelection,
            preserveThinking: snapshot.preserveThinking
        )
    }
}

enum AgentCoreBackendError: LocalizedError {
    case missingRemoteProvider
    case missingRemoteAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .missingRemoteProvider:
            return "The selected remote provider is no longer configured in ZenCODE."
        case let .missingRemoteAPIKey(providerName):
            return "No API key is stored for \(providerName). Configure it in ZenCODE settings or pass --bearer-token."
        }
    }
}
