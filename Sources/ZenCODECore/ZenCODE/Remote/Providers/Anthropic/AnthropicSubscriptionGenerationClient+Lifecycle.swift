//
//  AnthropicSubscriptionGenerationClient+Lifecycle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//
#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        sessions[id] = AgentSession(
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
            )
        )
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
        sessions.removeValue(forKey: id)
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
    }

    public func updateBorrowedOrchestrationToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedOrchestrationToolExecutor(executor)
    }

    public func updateToolProviders(_ providers: [AgentToolProvider]) async {
        await toolExecutor.updateToolProviders(providers)
    }

    public func shutdown() async {
        sessions.removeAll()
        await toolExecutor.shutdown()
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
        guard let session = sessions.values.first else {
            return await toolExecutor.descriptors(allowedToolNames: [])
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
        )
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
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
            cacheKey: session.cacheKey,
            history: splitMessages.history,
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            preserveThinking: session.preserveThinking
        )
    }
}

#endif
