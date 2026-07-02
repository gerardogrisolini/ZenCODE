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
    static let claudeCodeVersion = "2.1.75"
    static let claudeCodeBetaHeader = "claude-code-20250219"
    static let oauthBetaHeader = "oauth-2025-04-20"
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
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime()
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
            outputLimit: 24_000,
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            preferredWorkspaceRootURL: configuration.workingDirectory,
            subAgentContextualBackendFactory: { context in
                try AgentCoreBackend.makeRemoteBackend(
                    configuration: configuration.applyingSubAgentBackendContext(context),
                    mcpRuntime: mcpRuntime,
                    fallbackProvider: provider,
                    urlSession: urlSession
                )
            }
        )
    }
}
#endif
