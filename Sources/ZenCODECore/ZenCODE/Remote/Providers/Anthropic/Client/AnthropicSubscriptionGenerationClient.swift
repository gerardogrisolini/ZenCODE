//
//  AnthropicSubscriptionGenerationClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation

public actor AnthropicSubscriptionGenerationClient: AgentRuntimeBackend {
    public struct AgentSession {
        public let id: String
        public let cwd: URL
        public var systemPrompt: String?
        public let cacheKey: String?
        public var allowedToolNames: Set<String>?
        public var thinkingSelection: AgentThinkingSelection?
        public var preserveThinking: Bool
        /// A preflight budget can be impossible even for a tiny history. The
        /// diagnostic is useful once per user turn, but a context-limit retry
        /// rebuilds the request and must not emit it again.
        var didReportUnsatisfiableBudget = false
        public var messages: [[String: Any]]
    }

    public static var isAvailable: Bool {
        AnthropicSubscriptionModel.isReady
    }

    static let apiBaseURL = URL(string: "https://api.anthropic.com/v1")!
    static let claudeCodeVersion = "2.1.201"
    static let claudeCodeBetaHeader = "claude-code-20250219"
    static let oauthBetaHeader = "oauth-2025-04-20"
    static let longContextBetaHeader = "context-1m-2025-08-07"
    static let contextManagementBetaHeader = "context-management-2025-06-27"
    static let effortBetaHeader = "effort-2025-11-24"
    static let promptCachingScopeBetaHeader = "prompt-caching-scope-2026-01-05"
    static let interleavedThinkingBetaHeader = "interleaved-thinking-2025-05-14"
    static let extendedCacheTTLHeader = "extended-cache-ttl-2025-04-11"
    static let minimumOutputTokensForThinking = 1_024

    public let configuration: AgentRuntimeConfiguration
    public let provider: AgentRemoteProvider
    /// Shared NIO HTTP/SSE transport for Anthropic message generation.
    public let transport: RemoteTransportCore
    let ownsTransport: Bool
    public let toolExecutor: DirectToolExecutor
    /// Session dictionaries contain non-Sendable JSON bridge values. Export
    /// only `AgentRuntimeSessionSnapshot` through `snapshotSession(id:)`.
    var sessions: [String: AgentSession] = [:]
    var sessionGenerations: [String: UInt64] = [:]
    /// Non-conversation tokens (tool catalogue, provider system blocks) and
    /// the provider's per-conversation inflation rate, measured on the last
    /// request of each session so compaction can reserve what it is unable to
    /// remove. Invalidated by every lifecycle change that can move either.
    var sessionRequestOverhead: [String: SubscriptionCompactionSupport.RequestOverhead] = [:]
    private var nextSessionGeneration: UInt64 = 0
    let messagesEndpointURLOverride: URL?

    public init(
        configuration: AgentRuntimeConfiguration,
        provider: AgentRemoteProvider,
        transport: RemoteTransportCore? = nil,
        /// A controlled final messages endpoint override for deterministic
        /// loopback tests and embedding boundaries.
        messagesEndpointURLOverride: URL? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        sharedChat: AgentSharedChat? = nil,
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil,
        subAgentContextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        self.configuration = configuration
        self.provider = provider
        let resolvedTransport = transport ?? RemoteTransportCore()
        self.transport = resolvedTransport
        ownsTransport = transport == nil
        self.messagesEndpointURLOverride = messagesEndpointURLOverride
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
                modelID: configuration.modelID ?? provider.modelID,
                isSubAgent: sharedChatSenderID != nil
            ),
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

    public func interruptBackgroundJobs() async -> Int {
        await toolExecutor.interruptBackgroundJobs()
    }

    public func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant] {
        await toolExecutor.sharedChatParticipants(rootSessionID: rootSessionID)
    }

    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        try await sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID,
            messageID: UUID()
        )
    }

    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String,
        messageID: UUID
    ) async throws -> AgentSharedChat.Delivery {
        try await toolExecutor.sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID,
            messageID: messageID
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

    struct SessionLease: Sendable {
        let id: String
        let generation: UInt64
    }

    func installSession(_ session: AgentSession, id: String) {
        nextSessionGeneration &+= 1
        sessionGenerations[id] = nextSessionGeneration
        sessions[id] = session
        sessionRequestOverhead.removeValue(forKey: id)
    }

    func invalidateSession(id: String) {
        nextSessionGeneration &+= 1
        sessionGenerations[id] = nextSessionGeneration
        sessions.removeValue(forKey: id)
        sessionRequestOverhead.removeValue(forKey: id)
    }

    func sessionLease(for id: String) -> SessionLease? {
        guard sessions[id] != nil, let generation = sessionGenerations[id] else {
            return nil
        }
        return SessionLease(id: id, generation: generation)
    }

    func currentSession(for lease: SessionLease) -> AgentSession? {
        guard sessionGenerations[lease.id] == lease.generation else {
            return nil
        }
        return sessions[lease.id]
    }

    @discardableResult
    func mutateSession(
        for lease: SessionLease,
        _ mutation: (inout AgentSession) -> Void
    ) -> Bool {
        guard sessionGenerations[lease.id] == lease.generation,
              var session = sessions[lease.id] else {
            return false
        }
        mutation(&session)
        sessions[lease.id] = session
        // A session mutation may append user, assistant, or tool wire content.
        // The cached request rate is content-dependent, so favour correctness
        // over attempting to infer which mutation leaves it unchanged. Static
        // provider overhead is measured again with the next wire payload.
        sessionRequestOverhead.removeValue(forKey: lease.id)
        return true
    }
}
