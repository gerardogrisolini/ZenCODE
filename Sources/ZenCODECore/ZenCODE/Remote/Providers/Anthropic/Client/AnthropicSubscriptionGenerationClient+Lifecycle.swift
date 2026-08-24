//
//  AnthropicSubscriptionGenerationClient+Lifecycle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation

extension AnthropicSubscriptionGenerationClient {
    public func createSession(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        let cwdURL = URL(fileURLWithPath: cwd).standardizedFileURL
        installSession(AgentSession(
            id: id,
            cwd: cwdURL,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking,
            messages: RemoteGenerationClient.initialMessages(
                cwd: cwdURL.path,
                systemPrompt: systemPrompt,
                history: history,
                allowedToolNames: allowedToolNames
            )), id: id)
    }

    public func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
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

    public func closeSession(id: String) async {
        invalidateSession(id: id)
        await toolExecutor.removeToolProviders(sessionID: id)
    }

    public func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard var session = sessions[id] else {
            return
        }
        session.messages = RemoteGenerationClient.replacingSystemPrompt(
            in: session.messages,
            cwd: session.cwd.path,
            systemPrompt: systemPrompt,
            allowedToolNames: allowedToolNames
        )
        session.systemPrompt = systemPrompt
        session.allowedToolNames = allowedToolNames
        session.thinkingSelection = thinkingSelection
        session.preserveThinking = preserveThinking
        sessions[id] = session
        // The system prompt and the allowed tool set are exactly what the
        // cached overhead measured; keeping it would reserve tokens this
        // session no longer spends and over-compact the conversation.
        invalidateRequestOverhead(sessionID: id)
    }

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedSubAgentToolExecutor(executor)
        // Borrowed sub-agent tools change the catalogue of every session.
        invalidateRequestOverhead(sessionID: nil)
    }

    public func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) async {
        await toolExecutor.updateSharedChatMessageAvailableHandler(handler)
    }

    public func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String? = nil
    ) async {
        await toolExecutor.updateToolProviders(providers, sessionID: sessionID)
        // A different tool catalogue means a different static overhead; a
        // global update invalidates every session's measurement.
        invalidateRequestOverhead(sessionID: sessionID)
    }

    public func shutdown() async {
        sessions.removeAll()
        sessionGenerations.removeAll()
        invalidateRequestOverhead(sessionID: nil)
        await toolExecutor.shutdown()
        if ownsTransport {
            try? await transport.shutdown()
        }
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        _ = try await AnthropicSubscriptionAuthService.loadValidCredentials()
        let modelLLMID = modelLLMID()
        await onEvent(.modelLoaded(AnthropicSubscriptionModel.selectionTitle(forLLMID: modelLLMID)))
        return modelLLMID
    }

    public func activeToolDescriptors() async -> [DirectToolDescriptor] {
        await activeToolDescriptors(sessionID: nil)
    }

    public func activeToolDescriptors(
        sessionID: String?
    ) async -> [DirectToolDescriptor] {
        let session = if let sessionID {
            sessions[sessionID]
        } else {
            sessions.values.first
        }
        guard let session else {
            return []
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd,
            sessionID: session.id
        )
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
    }

    public func updateSubAgentToolEventHandler(
        _ handler: DirectSubAgentToolEventHandler?
    ) async {
        await toolExecutor.updateSubAgentToolEventHandler(handler)
    }

    public func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard let session = sessions[id] else {
            return nil
        }
        let splitMessages = RemoteGenerationClient.snapshotMessages(from: session.messages)
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: configuration.modelID ?? provider.modelID,
            workingDirectoryPath: session.cwd.path,
            systemPrompt: splitMessages.systemPrompt ?? session.systemPrompt,
            dynamicContext: splitMessages.dynamicContext,
            cacheKey: session.cacheKey,
            history: splitMessages.history,
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            preserveThinking: session.preserveThinking
        )
    }
}
