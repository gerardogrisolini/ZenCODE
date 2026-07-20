//
//  ChatGPTSubscriptionGenerationClient+Lifecycle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
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
        let messages = RemoteGenerationClient.initialMessages(
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            allowedToolNames: allowedToolNames
        )
        sessions[id] = AgentSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            messages: messages,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking,
            continuation: Self.restoredContinuation(from: messages),
            chatGPTSessionID: nil
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
        let oldSystemPrompt = session.systemPrompt
        let oldAllowedToolNames = session.allowedToolNames
        session.systemPrompt = systemPrompt

        session.messages = RemoteGenerationClient.replacingSystemPrompt(
            in: session.messages,
            cwd: session.cwd,
            systemPrompt: systemPrompt,
            allowedToolNames: allowedToolNames
        )
        session.allowedToolNames = allowedToolNames
        session.thinkingSelection = thinkingSelection
        session.preserveThinking = preserveThinking
        if oldSystemPrompt != systemPrompt || oldAllowedToolNames != allowedToolNames {
            if let chatGPTSessionID = session.chatGPTSessionID {
                webSocketPool.closeSession(sessionID: chatGPTSessionID)
            }
            session.continuation = nil
            session.chatGPTSessionID = nil
        }

        sessions[id] = session
    }

    public func closeSession(id: String) async {
        let session = sessions.removeValue(forKey: id)
        if let chatGPTSessionID = session?.chatGPTSessionID {
            webSocketPool.closeSession(sessionID: chatGPTSessionID)
        }
    }

    public func shutdown() async {
        let sessionIDs = sessions.values.compactMap(\.chatGPTSessionID)
        sessions.removeAll()
        if ownsWebSocketPool {
            await webSocketPool.shutdown()
        } else {
            for sessionID in sessionIDs {
                webSocketPool.closeSession(sessionID: sessionID)
            }
        }
        await toolExecutor.shutdown()
    }

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedSubAgentToolExecutor(executor)
    }

    public func updateToolProviders(_ providers: [AgentToolProvider]) async {
        await toolExecutor.updateToolProviders(providers)
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        _ = try await CodexAgentModel.loadValidCredentials()
        let modelLLMID = modelLLMID()
        await onEvent(.modelLoaded(CodexAgentModel.selectionTitle(forLLMID: modelLLMID)))
        return modelLLMID
    }

    public func activeToolDescriptors() async -> [DirectToolDescriptor] {
        guard let session = sessions.values.first else {
            return await toolExecutor.descriptors(allowedToolNames: [])
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: URL(fileURLWithPath: session.cwd)
        )
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
    }

    public func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard let session = sessions[id] else {
            return nil
        }
        let splitMessages = RemoteGenerationClient.snapshotMessages(
            from: session.messages
        )
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: configuration.modelID,
            workingDirectoryPath: session.cwd,
            systemPrompt: splitMessages.systemPrompt ?? session.systemPrompt,
            cacheKey: session.cacheKey,
            history: splitMessages.history,
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            preserveThinking: session.preserveThinking
        )
    }

    static func restoredContinuation(
        from messages: [[String: Any]]
    ) -> ChatGPTSubscriptionContinuationState? {
        let payload = ChatGPTSubscriptionRequestBuilder.chatGPTResponsesInputPayload(
            from: messages
        )
        let instructions = payload.instructions?.nilIfBlank ?? ""

        for index in messages.indices.reversed() {
            let message = messages[index]
            let role = (message["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard role == "assistant",
                  let responseID = RemoteGenerationClient.stringValue(message["response_id"])?.nilIfBlank
                    ?? RemoteGenerationClient.stringValue(message["provider_response_id"])?.nilIfBlank else {
                continue
            }

            return ChatGPTSubscriptionContinuationState(
                responseID: responseID,
                messageCount: index + 1,
                instructions: instructions,
                allowsFreshTransport: true
            )
        }

        return nil
    }
}
