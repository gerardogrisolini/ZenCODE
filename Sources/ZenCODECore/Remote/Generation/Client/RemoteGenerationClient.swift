//
//  RemoteGenerationClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public actor RemoteGenerationClient: LeasedSessionRuntimeBackend {
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
    /// Ordered capability declaration from the persisted model manifest.
    public let thinkingOptions: [AgentThinkingSelection]
    /// The shared HTTP/SSE engine. Its lifetime is owned by the composition
    /// root when an explicitly-owned instance is injected; the default borrows
    /// the process-wide NIO event-loop group.
    public let transport: RemoteTransportCore
    private let ownsTransport: Bool
    public let toolExecutor: DirectToolExecutor
    /// `AgentSession` contains JSON bridge values and must never cross the
    /// actor boundary. Public callers use `snapshotSession(id:)`, whose result
    /// is Sendable, rather than observing this mutable implementation detail.
    var sessions: [String: AgentSession] = [:]
    /// A generation is a lease on a particular lifetime of a session ID. It is
    /// deliberately retained after removal so an operation suspended on an old
    /// session cannot recreate it when it resumes.
    private(set) var sessionGenerations: [String: UInt64] = [:]
    private var nextSessionGeneration: UInt64 = 0
    public var didEmitLoadedModel = false
    /// Endpoint base override used only by deterministic loopback tests.
    /// The provider's persisted base URL remains the capability/payload source;
    /// this value only changes where the HTTP request is sent.
    public let streamEndpointBaseURLOverride: URL?
    /// In-process DS4 engine used instead of HTTP when the selected model has
    /// a DS4 runtime (`RemoteGenerationClient+DS4Engine.swift`).
    let ds4Generation: DS4LocalGeneration?
    /// Per-client bookkeeping of the DS4 path.
    var ds4State = DS4ClientState()

    public init(
        configuration: AgentRuntimeConfiguration,
        provider: AgentRemoteProvider,
        apiKey: String?,
        thinkingOptions: [AgentThinkingSelection]? = nil,
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
        self.init(
            configuration: configuration,
            provider: provider,
            apiKey: apiKey,
            thinkingOptions: thinkingOptions,
            transport: transport,
            streamEndpointBaseURLOverride: streamEndpointBaseURLOverride,
            ds4Generation: nil,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
            sharedChat: sharedChat,
            sharedChatSenderID: sharedChatSenderID,
            sharedChatRootSessionID: sharedChatRootSessionID,
            subAgentContextualBackendFactory: subAgentContextualBackendFactory
        )
    }

    /// Designated initializer; `ds4Generation` routes generation through the
    /// in-process DS4 engine.
    init(
        configuration: AgentRuntimeConfiguration,
        provider: AgentRemoteProvider,
        apiKey: String?,
        thinkingOptions: [AgentThinkingSelection]? = nil,
        transport: RemoteTransportCore? = nil,
        streamEndpointBaseURLOverride: URL? = nil,
        ds4Generation: DS4LocalGeneration?,
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
        self.thinkingOptions = thinkingOptions ?? []
        let resolvedTransport = transport ?? RemoteTransportCore()
        self.transport = resolvedTransport
        ownsTransport = transport == nil
        self.streamEndpointBaseURLOverride = streamEndpointBaseURLOverride
        self.ds4Generation = ds4Generation
        self.toolExecutor = DirectToolExecutor(
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime ?? SwiftFeatureRuntime(),
            preferredWorkspaceRootURL: configuration.workingDirectory,
            sharedChat: sharedChat,
            sharedChatSenderID: sharedChatSenderID,
            sharedChatRootSessionID: sharedChatRootSessionID,
            toolExecutionContext: ToolExecutionContext(
                agentID: configuration.agentID,
                agentName: configuration.agentName,
                profileID: configuration.profileID,
                profileName: configuration.profileName,
                profileRole: configuration.profileRole,
                modelID: configuration.modelID ?? provider.modelID,
                isSubAgent: sharedChatSenderID != nil,
                delegatingSessionID: configuration.delegatingSessionID,
                inheritsFeatureExposures: configuration.inheritsFeatureExposures
            ),
            subAgentContextualBackendFactory: subAgentContextualBackendFactory
                ?? DirectSubAgentRuntime.unavailableContextualBackendFactory
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

    public func closeSession(id: String) async {
        invalidateSession(id: id)
        await toolExecutor.removeToolProviders(sessionID: id)
        await releaseDS4EngineSession(id: id)
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

    public func shutdown() async {
        sessions.removeAll()
        sessionGenerations.removeAll()
        await releaseDS4EngineSessions()
        await toolExecutor.shutdown()
        if ownsTransport {
            try? await transport.shutdown()
        }
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        try validateConfiguration()
        if let ds4Generation {
            return try await preloadDS4Engine(ds4Generation, onEvent: onEvent)
        }
        if !didEmitLoadedModel {
            didEmitLoadedModel = true
            await onEvent(.modelLoaded(provider.modelID))
        }
        return provider.modelID
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
        await compactSession(id: id, force: force, exactTokenCount: nil)
    }

    /// Compacts the session. `exactTokenCount` is the exact size of the
    /// prompt the model would read for these messages (the DS4 path counts it
    /// with the engine tokenizer); when given, the budget converts between
    /// the shared estimator and real tokens with their ratio, so the compacted
    /// history targets the real context window. `nil` keeps the estimator-only
    /// budget used by every other provider.
    public func compactSession(
        id: String,
        force: Bool,
        exactTokenCount: Int?
    ) async -> AgentRuntimeSessionCompactionResult? {
        guard var session = sessions[id] else {
            return nil
        }
        let runtimeMessages = Self.agentRuntimeMessages(from: session.messages)
        var inflationFactor = 1.0
        if let exactTokenCount, exactTokenCount > 0 {
            let estimated = AgentConversationCompactionSupport.estimatedTokenCount(for: runtimeMessages)
            if estimated > 0 {
                inflationFactor = Double(exactTokenCount) / Double(estimated)
            }
        }
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            runtimeMessages,
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: configuration.configuredContextWindowLimit,
                maxOutputTokens: configuration.maxOutputTokens,
                conversationInflationFactor: inflationFactor
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
        // The compacted context forgot the `/ds4 hints` instructions and its tail
        // may still hold an old on/off note: the next boundary states it again.
        ds4State.hintsBySessionID[id]?.contextCompacted()
        guard let snapshot = snapshotSession(id: id) else {
            return nil
        }
        return AgentRuntimeSessionCompactionResult(
            snapshot: snapshot,
            compactionResult: result
        )
    }

    private func installSession(_ session: AgentSession, id: String) {
        nextSessionGeneration &+= 1
        sessionGenerations[id] = nextSessionGeneration
        sessions[id] = session
        // A replaced transcript may hold hints notes of an earlier context.
        ds4State.hintsBySessionID[id]?.contextCompacted()
    }

    private func invalidateSession(id: String) {
        // Advance even when the value was already absent: this invalidates any
        // in-flight lease before asynchronous cleanup starts.
        nextSessionGeneration &+= 1
        sessionGenerations[id] = nextSessionGeneration
        sessions.removeValue(forKey: id)
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
                anthropicContentBlocksJSON: stringValue(message["anthropic_content_blocks"])?.nilIfBlank,
                providerResponseID: stringValue(message["response_id"])?.nilIfBlank
                    ?? stringValue(message["provider_response_id"])?.nilIfBlank,
                attachments: imageAttachments,
                toolCalls: runtimeToolCalls(from: message),
                toolCallID: stringValue(message["tool_call_id"])?.nilIfBlank,
                toolName: stringValue(message["name"])?.nilIfBlank,
                toolResultIsError: message["is_error"] as? Bool,
                turnAddition: message[turnAdditionKey] as? String
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

extension RemoteGenerationClient.AgentSession: LeasedRuntimeSession {
    var workingDirectoryURL: URL { cwd }
}
