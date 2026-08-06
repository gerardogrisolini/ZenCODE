//
//  RemoteGenerationClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

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
    /// Historical session value retained for source compatibility. It does not
    /// participate in HTTP or SSE I/O.
    public let urlSession: RemoteProviderSession
    /// The shared HTTP/SSE engine. Its lifetime is owned by the composition
    /// root when an explicitly-owned instance is injected; the default borrows
    /// the process-wide NIO event-loop group.
    public let transport: RemoteTransportCore
    private let ownsTransport: Bool
    public let toolExecutor: DirectToolExecutor
    /// `AgentSession` contains JSON bridge values and must never cross the
    /// actor boundary. Public callers use `snapshotSession(id:)`, whose result
    /// is Sendable, rather than observing this mutable implementation detail.
    private var sessions: [String: AgentSession] = [:]
    /// A generation is a lease on a particular lifetime of a session ID. It is
    /// deliberately retained after removal so an operation suspended on an old
    /// session cannot recreate it when it resumes.
    private var sessionGenerations: [String: UInt64] = [:]
    private var nextSessionGeneration: UInt64 = 0
    public var didEmitLoadedModel = false
    let streamEndpointBaseURLOverride: URL?

    public init(
        configuration: AgentRuntimeConfiguration,
        provider: AgentRemoteProvider,
        apiKey: String?,
        /// Historical injection retained for source compatibility. HTTP/SSE
        /// generation is always performed by `transport`.
        urlSession: RemoteProviderSession? = nil,
        transport: RemoteTransportCore? = nil,
        /// A controlled endpoint base override for deterministic embeddings
        /// and loopback tests. Provider capability decisions continue to use
        /// `provider.baseURL`, so the request payload remains provider-accurate.
        streamEndpointBaseURLOverride: URL? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        sharedChat: AgentSharedChat? = nil,
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil,
        subAgentContextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        self.configuration = configuration
        self.provider = provider
        self.apiKey = apiKey?.nilIfBlank
        self.urlSession = urlSession
            ?? RemoteProviderSessionCompatibility.generationSession()
        let resolvedTransport = transport ?? RemoteTransportCore()
        self.transport = resolvedTransport
        ownsTransport = transport == nil
        self.streamEndpointBaseURLOverride = streamEndpointBaseURLOverride
        self.toolExecutor = DirectToolExecutor(
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime ?? SwiftFeatureRuntime(),
            preferredWorkspaceRootURL: configuration.workingDirectory,
            sharedChat: sharedChat,
            sharedChatSenderID: sharedChatSenderID,
            sharedChatRootSessionID: sharedChatRootSessionID,
            subAgentContextualBackendFactory: subAgentContextualBackendFactory
                ?? DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
    }

    public func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        await toolExecutor.installTaskOrchestrator(orchestrator)
    }

    public func closeSubAgent(id: String) async -> Bool {
        await toolExecutor.closeSubAgent(id: id)
    }

    public func interruptSubAgents(rootSessionID: String) async -> Int {
        await toolExecutor.interruptSubAgents(rootSessionID: rootSessionID)
    }

    public func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant] {
        await toolExecutor.sharedChatParticipants(rootSessionID: rootSessionID)
    }

    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        try await toolExecutor.sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID
        )
    }

    public func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        await toolExecutor.drainCoordinatorSharedChatMessages(rootSessionID: rootSessionID)
    }

    public func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        await toolExecutor.sharedChatTranscriptMessages(rootSessionID: rootSessionID)
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
        installSession(AgentSession(
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

    public func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String? = nil
    ) async {
        await toolExecutor.updateToolProviders(providers, sessionID: sessionID)
    }

    public func shutdown() async {
        sessions.removeAll()
        sessionGenerations.removeAll()
        await toolExecutor.shutdown()
        if ownsTransport {
            try? await transport.shutdown()
        }
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
            dynamicContext: splitMessages.dynamicContext,
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
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: configuration.configuredContextWindowLimit,
                maxOutputTokens: configuration.maxOutputTokens
            ),
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
        guard let lease = sessionLease(for: sessionID) else {
            throw RemoteGenerationClientError.missingSession
        }

        _ = try await preloadModel(onEvent: onEvent)
        guard currentSession(for: lease) != nil else {
            throw RemoteGenerationClientError.missingSession
        }

        var accumulatedText = ""
        var generationStats: [RemoteGenerationStats] = []
        var didRetryWithoutImages = false
        for round in 0..<configuration.maxToolRounds {
            // Re-read shared state at the start of each round so changes applied
            // by concurrent operations between rounds are not lost.
            guard let session = currentSession(for: lease) else {
                throw RemoteGenerationClientError.missingSession
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
                        guard mutateSession(for: lease, { session in
                            session.messages = Self.messagesStrippingImageContent(
                                from: session.messages
                            )
                        }) else {
                            throw RemoteGenerationClientError.missingSession
                        }
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
            if configuration.verboseLogging,
               let cacheDiagnostic = Self.cacheUsageDiagnostic(
                   provider: provider.displayTitle,
                   usage: streamResult.stats.usage
               ) {
                await onEvent(.diagnostic(cacheDiagnostic))
            }
            guard mutateSession(for: lease, { session in
                appendAssistantMessage(
                    streamResult: streamResult,
                    to: &session.messages
                )
            }) else {
                throw RemoteGenerationClientError.missingSession
            }
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
                return DirectAgentResponse(
                    text: accumulatedText,
                    stopReason: streamResult.stopReason,
                    modelID: provider.modelID
                )
            }

            for toolCall in streamResult.toolCalls {
                await onEvent(.toolCallStarted(toolCall))
                guard let activeSession = currentSession(for: lease) else {
                    throw RemoteGenerationClientError.missingSession
                }
                let result = await toolExecutor.execute(
                    sessionID: activeSession.id,
                    toolCall: toolCall,
                    workingDirectory: activeSession.cwd,
                    allowedToolNames: activeSession.allowedToolNames
                )
                await onEvent(.toolCallCompleted(toolCall, result))
                guard mutateSession(for: lease, { session in
                    session.messages.append(
                        Self.toolResultMessage(toolCall: toolCall, result: result)
                    )
                }) else {
                    throw RemoteGenerationClientError.missingSession
                }
            }

            if round == configuration.maxToolRounds - 1 {
                throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
            }
        }
        throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
    }

    private struct SessionLease: Sendable {
        let id: String
        let generation: UInt64
    }

    private func installSession(_ session: AgentSession, id: String) {
        nextSessionGeneration &+= 1
        sessionGenerations[id] = nextSessionGeneration
        sessions[id] = session
    }

    private func invalidateSession(id: String) {
        // Advance even when the value was already absent: this invalidates any
        // in-flight lease before asynchronous cleanup starts.
        nextSessionGeneration &+= 1
        sessionGenerations[id] = nextSessionGeneration
        sessions.removeValue(forKey: id)
    }

    private func sessionLease(for id: String) -> SessionLease? {
        guard sessions[id] != nil, let generation = sessionGenerations[id] else {
            return nil
        }
        return SessionLease(id: id, generation: generation)
    }

    private func currentSession(for lease: SessionLease) -> AgentSession? {
        guard sessionGenerations[lease.id] == lease.generation else {
            return nil
        }
        return sessions[lease.id]
    }

    @discardableResult
    private func mutateSession(
        for lease: SessionLease,
        _ mutation: (inout AgentSession) -> Void
    ) -> Bool {
        guard sessionGenerations[lease.id] == lease.generation,
              var session = sessions[lease.id] else {
            return false
        }
        mutation(&session)
        sessions[lease.id] = session
        return true
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
                .map { index, item in
                    runtimeImageAttachment(from: item, index: index)
                        ?? AgentRuntimeAttachment(
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
    ) -> (
        systemPrompt: String?,
        dynamicContext: String?,
        history: [AgentRuntimeMessage]
    ) {
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

        let separatedContext = AgentRuntimeDynamicContext.separating(
            from: agentRuntimeMessages(from: Array(remainingMessages))
        )
        return (systemPrompt, separatedContext.context, separatedContext.history)
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

        let protectedContext: [String: Any]? = conversationMessages.first.flatMap { message -> [String: Any]? in
            guard let role = stringValue(message["role"])?.lowercased(),
                  role == AgentRuntimeMessage.Role.user.rawValue,
                  let content = contentString(from: message["content"]),
                  AgentRuntimeDynamicContext.context(
                      from: AgentRuntimeMessage(role: .user, content: content)
                  ) != nil else {
                return nil
            }
            return message
        }
        if let protectedContext {
            compactedMessages.append(protectedContext)
        }
        let messagesEligibleForRecent = protectedContext == nil
            ? conversationMessages
            : conversationMessages.dropFirst()
        compactedMessages.append(
            contentsOf: messagesEligibleForRecent.suffix(compactionResult.keptRecentMessageCount)
        )
        return compactedMessages
    }
}
