//
//  ChatGPTSubscriptionGenerationClient+Lifecycle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore
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
        if let existingSession = sessions[id],
           let generation = sessionGenerations[id] {
            webSocketPool.closeHTTPFallbackScope(
                scopeID: Self.httpFallbackScopeID(
                    sessionID: id,
                    generation: generation
                )
            )
            if let transportSessionID = existingSession.chatGPTSessionID {
                webSocketPool.closeSession(sessionID: transportSessionID)
            }
        }
        let messages = RemoteGenerationClient.initialMessages(
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            allowedToolNames: allowedToolNames
        )
        installSession(AgentSession(
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
        ), id: id)
        if usesDelegatedHTTPStreamingTransport,
           let generation = sessionGenerations[id] {
            // `connectionScopeID` is assigned only to delegated backends by the
            // remote sub-agent factory. Prime their generation-qualified scope
            // onto HTTP before any request can open a WebSocket. Reusing the
            // existing fallback scope also preserves cancellation and recreate
            // fencing for opening and active HTTP streams.
            webSocketPool.activateHTTPFallback(
                scopeID: Self.httpFallbackScopeID(
                    sessionID: id,
                    generation: generation
                )
            )
        }
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
        let fallbackScopeID = sessions[id] != nil
            ? sessionGenerations[id].map {
                Self.httpFallbackScopeID(sessionID: id, generation: $0)
            }
            : nil
        let session = invalidateSession(id: id)
        if let fallbackScopeID {
            webSocketPool.closeHTTPFallbackScope(scopeID: fallbackScopeID)
        }
        if let chatGPTSessionID = session?.chatGPTSessionID {
            webSocketPool.closeSession(sessionID: chatGPTSessionID)
        }
        // Fence and cancel transport work before the first suspension. Otherwise
        // the in-flight prompt can observe fallback removal and acquire a late
        // WebSocket while this actor awaits cross-actor provider cleanup.
        await toolExecutor.removeToolProviders(sessionID: id)
    }

    public func shutdown() async {
        let activeSessions = sessions.values.compactMap { session in
            sessionGenerations[session.id].map {
                (
                    Self.httpFallbackScopeID(
                        sessionID: session.id,
                        generation: $0
                    ),
                    session.chatGPTSessionID
                )
            }
        }
        sessions.removeAll()
        sessionGenerations.removeAll()
        if ownsWebSocketPool {
            await webSocketPool.shutdown()
        } else {
            for (scopeID, transportSessionID) in activeSessions {
                webSocketPool.closeHTTPFallbackScope(scopeID: scopeID)
                if let transportSessionID {
                    webSocketPool.closeSession(sessionID: transportSessionID)
                }
            }
        }
        await toolExecutor.shutdown()
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        _ = try await CodexAgentModel.loadValidCredentials()
        let modelLLMID = modelLLMID()
        await onEvent(.modelLoaded(CodexAgentModel.selectionTitle(forLLMID: modelLLMID)))
        return modelLLMID
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
            preferredWorkspaceRootURL: URL(fileURLWithPath: session.cwd),
            sessionID: session.id
        )
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
            dynamicContext: splitMessages.dynamicContext,
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
