//
//  AnthropicSubscriptionGenerationClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor AnthropicSubscriptionGenerationClient: AgentRuntimeBackend {
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
    public let urlSession: URLSession
    public let toolExecutor: DirectToolExecutor
    public var sessions: [String: AgentSession] = [:]

    public init(
        configuration: AgentRuntimeConfiguration,
        provider: AgentRemoteProvider,
        urlSession: URLSession? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        subAgentContextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        self.configuration = configuration
        self.provider = provider
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
            swiftFeatureRuntime: swiftFeatureRuntime ?? SwiftFeatureRuntime(),
            preferredWorkspaceRootURL: configuration.workingDirectory,
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
}
#endif
