//
//  RemoteGenerationClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor RemoteGenerationClient: AgentRuntimeBackend {
    public struct AgentSession {
        public let id: String
        public let cwd: URL
        public var systemPrompt: String?
        public let cacheKey: String?
        public var allowedToolNames: Set<String>?
        public var thinkingSelection: AgentThinkingSelection?
        public var preserveThinking: Bool
        public var messages: [[String: Any]]
    }

    public let configuration: AgentRuntimeConfiguration
    public let provider: AgentRemoteProvider
    public let apiKey: String?
    public let urlSession: URLSession
    public let toolExecutor: DirectToolExecutor
    public var sessions: [String: AgentSession] = [:]
    public var didEmitLoadedModel = false

    public init(
        configuration: AgentRuntimeConfiguration,
        provider: AgentRemoteProvider,
        apiKey: String?,
        urlSession: URLSession? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime()
    ) {
        self.configuration = configuration
        self.provider = provider
        self.apiKey = apiKey?.nilIfBlank
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 900
            sessionConfiguration.timeoutIntervalForResource = 900
            self.urlSession = URLSession(configuration: sessionConfiguration)
        }
        self.toolExecutor = DirectToolExecutor(
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            preferredWorkspaceRootURL: configuration.workingDirectory,
            subAgentContextualBackendFactory: { context in
                try AgentCoreBackend.makeRemoteBackend(
                    configuration: configuration.applyingSubAgentBackendContext(context),
                    mcpRuntime: mcpRuntime,
                    fallbackProvider: provider,
                    fallbackAPIKey: apiKey,
                    urlSession: urlSession,
                    chatGPTConnectionScopeID: UUID().uuidString
                )
            }
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
            messages: Self.initialMessages(
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
        session.messages = Self.replacingSystemPrompt(
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

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedSubAgentToolExecutor(executor)
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
        try validateConfiguration()
        if !didEmitLoadedModel {
            didEmitLoadedModel = true
            await onEvent(.modelLoaded(provider.modelID))
        }
        return provider.modelID
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
        let splitMessages = Self.snapshotMessages(from: session.messages)
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

    public func compactSession(
        id: String,
        force: Bool
    ) async -> AgentRuntimeSessionCompactionResult? {
        guard var session = sessions[id] else {
            return nil
        }
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            Self.agentRuntimeMessages(from: session.messages),
            maxTokens: configuration.configuredContextWindowLimit,
            force: force
        )
        guard result.wasCompacted else {
            return nil
        }

        session.messages = Self.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        sessions[id] = session
        guard let snapshot = snapshotSession(id: id) else {
            return nil
        }
        return AgentRuntimeSessionCompactionResult(
            snapshot: snapshot,
            compactionResult: result
        )
    }

    public func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if sessions[sessionID] == nil {
            createSession(id: sessionID, cwd: configuration.workingDirectory.path)
        }
        guard var session = sessions[sessionID] else {
            throw RemoteGenerationClientError.missingSession
        }

        _ = try await preloadModel(onEvent: onEvent)
        session.messages.append(
            Self.remoteMessage(
                role: "user",
                content: prompt,
                attachments: attachments
            )
        )
        // Persist immediately so concurrent actor operations (compaction,
        // option updates) observe and build on the latest messages instead of
        // being silently overwritten by the local copy at the end of the loop.
        sessions[sessionID] = session

        var accumulatedText = ""
        var generationStats: [RemoteGenerationStats] = []
        var didRetryWithoutImages = false
        for round in 0..<configuration.maxToolRounds {
            // Re-read shared state at the start of each round so changes applied
            // by concurrent operations between rounds are not lost.
            if let latestSession = sessions[sessionID] {
                session = latestSession
            }
            let expectsPromptCache = Self.messagesExpectPromptCache(session.messages)
            let streamResult: RemoteStreamResult
            while true {
                do {
                    switch provider.chatEndpoint {
                    case .chatCompletions:
                        streamResult = try await streamChatCompletions(
                            messages: session.messages,
                            sessionID: session.id,
                            allowedToolNames: session.allowedToolNames,
                            preferredWorkspaceRootURL: session.cwd,
                            thinkingSelection: session.thinkingSelection,
                            onEvent: onEvent
                        )
                    case .responses:
                        streamResult = try await streamResponses(
                            messages: session.messages,
                            sessionID: session.id,
                            allowedToolNames: session.allowedToolNames,
                            preferredWorkspaceRootURL: session.cwd,
                            thinkingSelection: session.thinkingSelection,
                            onEvent: onEvent
                        )
                    }
                    break
                } catch {
                    if !didRetryWithoutImages,
                       Self.isImageContentRejectedError(error),
                       Self.messagesContainImageContent(session.messages) {
                        didRetryWithoutImages = true
                        session.messages = Self.messagesStrippingImageContent(
                            from: session.messages
                        )
                        sessions[sessionID] = session
                        await onEvent(.diagnostic(
                            "\(provider.displayTitle) does not support image input with the selected model. Retrying without attached images."
                        ))
                        continue
                    }
                    throw error
                }
            }

            accumulatedText.append(streamResult.text)
            generationStats.append(streamResult.stats)
            if let cacheWarning = Self.promptCacheWarning(
                provider: provider.displayTitle,
                usage: streamResult.stats.usage,
                expectsCacheRead: expectsPromptCache
            ) {
                await onEvent(.diagnostic(cacheWarning))
            }
            appendAssistantMessage(
                streamResult: streamResult,
                to: &session.messages
            )
            sessions[sessionID] = session
            if let metrics = Self.generationMetrics(
                generationStats,
                estimateMissingRates: Self.shouldEstimateStreamingRates(
                    baseURL: provider.baseURL
                )
            ) {
                await Self.publishGenerationMetrics(
                    metrics,
                    maxTokens: configuration.configuredContextWindowLimit,
                    modelID: provider.modelID,
                    onEvent: onEvent
                )
            }

            if streamResult.toolCalls.isEmpty {
                if !configuration.appMode,
                   let summary = Self.generationSummary(
                       generationStats,
                       estimateMissingRates: Self.shouldEstimateStreamingRates(
                           baseURL: provider.baseURL
                       )
                   ) {
                    await onEvent(.diagnostic(summary))
                }
                sessions[sessionID] = session
                return DirectAgentResponse(
                    text: accumulatedText,
                    stopReason: streamResult.stopReason,
                    modelID: provider.modelID
                )
            }

            for toolCall in streamResult.toolCalls {
                await onEvent(.toolCallStarted(toolCall))
                let result = await toolExecutor.execute(
                    sessionID: session.id,
                    toolCall: toolCall,
                    workingDirectory: session.cwd,
                    allowedToolNames: session.allowedToolNames
                )
                await onEvent(.toolCallCompleted(toolCall, result))
                session.messages.append([
                    "role": "tool",
                    "tool_call_id": toolCall.id,
                    "name": toolCall.name,
                    "content": result.modelOutput
                ])
                sessions[sessionID] = session
            }

            if round == configuration.maxToolRounds - 1 {
                sessions[sessionID] = session
                throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
            }
        }
        sessions[sessionID] = session

        throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
    }

    public static func agentRuntimeMessages(
        from messages: [[String: Any]]
    ) -> [AgentRuntimeMessage] {
        messages.map { message in
            let rawRole = (message["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let role = AgentRuntimeMessage.Role(rawValue: rawRole) ?? .user
            let content = contentString(from: message["content"]) ?? ""
            let imageAttachments = chatCompletionsImageContentItems(from: message["content"])
                .enumerated()
                .map { index, _ in
                    AgentRuntimeAttachment(
                        kind: .image,
                        originalFilename: "image-\(index + 1)"
                    )
                }
            return AgentRuntimeMessage(
                role: role,
                content: content,
                reasoningContent: reasoningContent(from: message),
                reasoningItemsJSON: stringValue(message["reasoning_items"])?.nilIfBlank,
                thinkingBlocksJSON: stringValue(message["thinking_blocks"])?.nilIfBlank,
                providerResponseID: stringValue(message["response_id"])?.nilIfBlank
                    ?? stringValue(message["provider_response_id"])?.nilIfBlank,
                attachments: imageAttachments,
                toolCalls: runtimeToolCalls(from: message),
                toolCallID: stringValue(message["tool_call_id"])?.nilIfBlank,
                toolName: stringValue(message["name"])?.nilIfBlank
            )
        }
    }

    public static func snapshotMessages(
        from messages: [[String: Any]]
    ) -> (systemPrompt: String?, history: [AgentRuntimeMessage]) {
        var remainingMessages = messages[...]
        let systemPrompt: String?
        if let firstRole = remainingMessages.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "system" {
            systemPrompt = contentString(from: remainingMessages.first?["content"])?.nilIfBlank
            remainingMessages = remainingMessages.dropFirst()
        } else {
            systemPrompt = nil
        }

        return (
            systemPrompt,
            agentRuntimeMessages(from: Array(remainingMessages))
        )
    }

    public static func runtimeToolCalls(
        from message: [String: Any]
    ) -> [AgentRuntimeToolCall] {
        guard let rawToolCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }

        return rawToolCalls.compactMap { rawToolCall in
            guard let function = rawToolCall["function"] as? [String: Any],
                  let name = stringValue(function["name"])?.nilIfBlank else {
                return nil
            }
            return AgentRuntimeToolCall(
                id: stringValue(rawToolCall["id"])?.nilIfBlank,
                name: name,
                argumentsJSON: toolArgumentsJSON(from: function["arguments"])
            )
        }
    }

    private static func reasoningContent(from message: [String: Any]) -> String? {
        responseReasoningText(from: message)
    }

    public static func toolArgumentsJSON(from value: Any?) -> String {
        if let string = stringValue(value)?.nilIfBlank {
            return string
        }
        if let value {
            return AgentJSONSupport.jsonString(from: value)
        }
        return "{}"
    }

    static func remoteMessages(
        compactionResult: AgentConversationCompactionResult,
        preservingRecentFrom messages: [[String: Any]]
    ) -> [[String: Any]] {
        let conversationMessages: ArraySlice<[String: Any]>
        if let firstRole = messages.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system" {
            conversationMessages = messages.dropFirst()
        } else {
            conversationMessages = messages[...]
        }

        var compactedMessages: [[String: Any]] = []
        if let compactedSystemPrompt = compactionResult.compactedSystemPrompt?.nilIfBlank {
            compactedMessages.append([
                "role": "system",
                "content": compactedSystemPrompt
            ])
        }

        compactedMessages.append(
            contentsOf: conversationMessages.suffix(compactionResult.keptRecentMessageCount)
        )
        return compactedMessages
    }
}
