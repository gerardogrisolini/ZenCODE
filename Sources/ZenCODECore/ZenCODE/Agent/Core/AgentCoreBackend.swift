//
//  AgentCoreBackend.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public actor AgentCoreBackend {
    private struct SessionSeed {
        let cwd: String
        var systemPrompt: String?
        let history: [AgentRuntimeMessage]
        let cacheKey: String?
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
    }

    private let configuration: AgentRuntimeConfiguration
    private let mcpRuntime: DirectMCPToolRuntime
    private var activeBackend: (any AgentRuntimeBackend)?
    private var sessions: [String: SessionSeed] = [:]
    private var borrowedOrchestrationToolExecutor: AgentBorrowedToolExecutor?
    private var toolProviders: [AgentToolProvider] = []
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
        force: Bool = true
    ) async -> AgentRuntimeSessionCompactionResult? {
        if let activeBackend {
            if let result = await activeBackend.compactSession(id: sessionID, force: force) {
                updateSessionSeed(from: result.snapshot)
                return result
            }
            guard let snapshot = await activeBackend.snapshotSession(id: sessionID),
                  let result = compactSnapshot(
                    snapshot,
                    maxTokens: configuration.configuredContextWindowLimit,
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
                maxTokens: configuration.configuredContextWindowLimit,
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

    public func updateBorrowedOrchestrationToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        borrowedOrchestrationToolExecutor = executor
        await applyBorrowedOrchestrationToolExecutor(to: activeBackend)
    }

    public func updateToolProviders(
        _ providers: [AgentToolProvider]
    ) async {
        toolProviders = providers
        await applyToolProviders(to: activeBackend)
    }

    public func clearSession(id: String) async {
        sessions.removeValue(forKey: id)
        if let backend = activeBackend {
            await backend.closeSession(id: id)
        }
    }

    public func shutdown() async {
        sessions.removeAll()
        if let backend = activeBackend {
            await backend.shutdown()
        }
        activeBackend = nil
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        let backend = try await resolveBackend(onEvent: onEvent)
        return try await backend.preloadModel(onEvent: onEvent)
    }

    public func activeToolDescriptors() async -> [DirectToolDescriptor] {
        if let backend = activeBackend {
            return await backend.activeToolDescriptors()
        }
        return []
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

    public func saveSessionRuntimeCache(id sessionID: String) async {
        guard let backend = activeBackend else {
            return
        }
        await backend.saveSessionRuntimeCache(id: sessionID)
    }

            public func restoreSessionRuntimeCache(id sessionID: String) async {
        // Resolve the backend lazily: restoring the KV cache happens before
        // the first prompt (e.g. right after session/new, session/load or
        // session/resume), so the underlying backend may not exist yet.
        // resolveBackend seeds the backend with the known sessions.
        let backend: any AgentRuntimeBackend
        do {
            backend = try await resolveBackend(onEvent: { _ in })
        } catch {
            return
        }
        await backend.restoreSessionRuntimeCache(id: sessionID)
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

        if let backendFactory {
            let backend = try backendFactory(configuration, mcpRuntime)
            activeBackend = backend
            await applyBorrowedOrchestrationToolExecutor(to: backend)
            await applyToolProviders(to: backend)
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
            }
            return backend
        }

        let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: configuration.modelID
        )
        if let modelID = configuration.modelID,
           AgentSettingsStore.isRemoteLLMIDSyntax(modelID),
           selection == nil {
            throw AgentCoreBackendError.missingRemoteProvider
        }

        let backend: any AgentRuntimeBackend
        switch selection?.providerKind {
        case .remoteAPI:
            guard let provider = selection?.remoteProvider else {
                throw AgentCoreBackendError.missingRemoteProvider
            }
            let apiKey = selection?.apiKey ?? configuration.bearerToken
            if provider.requiresAPIKey, apiKey?.nilIfBlank == nil {
                throw AgentCoreBackendError.missingRemoteAPIKey(provider.displayTitle)
            }

                                                            let resolvedConfiguration = configuration
                .withModelID(selection?.modelID)
                .withModelSettings(
                    configuredContextWindowLimit: selection?.configuredContextWindowLimit,
                    generationParameterOverrides: selection?.generationParameterOverrides
                )
            let remoteBackend: any AgentRuntimeBackend
            if provider.isChatGPTSubscriptionProvider {
#if os(macOS)
                remoteBackend = ChatGPTSubscriptionGenerationClient(
                    configuration: resolvedConfiguration,
                    mcpRuntime: mcpRuntime
                )
#else
                throw AgentCoreBackendError.missingRemoteProvider
#endif
            } else if provider.isAnthropicSubscriptionProvider {
#if os(macOS)
                remoteBackend = AnthropicSubscriptionGenerationClient(
                    configuration: resolvedConfiguration,
                    provider: provider,
                    mcpRuntime: mcpRuntime
                )
#else
                throw AgentCoreBackendError.missingRemoteProvider
#endif
            } else {
                remoteBackend = RemoteGenerationClient(
                    configuration: resolvedConfiguration,
                    provider: provider,
                    apiKey: apiKey,
                    mcpRuntime: mcpRuntime
                )
            }
            backend = remoteBackend
            if !configuration.appMode {
                await onEvent(.status("Using remote provider \(provider.displayTitle)."))
            }

        case .none:
            throw AgentCoreBackendError.missingRemoteProvider
        }

        activeBackend = backend
        await applyBorrowedOrchestrationToolExecutor(to: backend)
        await applyToolProviders(to: backend)
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
        }
        return backend
    }

    private func applyBorrowedOrchestrationToolExecutor(
        to backend: (any AgentRuntimeBackend)?
    ) async {
        if let backend {
            await backend.updateBorrowedOrchestrationToolExecutor(
                borrowedOrchestrationToolExecutor
            )
        }
    }

    private func applyToolProviders(
        to backend: (any AgentRuntimeBackend)?
    ) async {
        if let backend {
            await backend.updateToolProviders(toolProviders)
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
            maxTokens: maxTokens,
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

private enum AgentCoreBackendError: LocalizedError {
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
