//
//  ChatGPTSubscriptionGenerationClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif

public actor ChatGPTSubscriptionGenerationClient: AgentRuntimeBackend {
    public static var isAvailable: Bool {
        CodexAgentModel.isReady
    }

    struct AgentSession {
        let id: String
        let cwd: String
        var systemPrompt: String?
        let cacheKey: String?
        var messages: [[String: Any]]
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
        var continuation: ChatGPTSubscriptionContinuationState?
        var chatGPTSessionID: String?
    }

    struct RequestConfiguration {
        let modelID: String?
        let workingDirectory: String
        let systemPrompt: String
        let sessionKey: String
        let connectionScopeID: String?
        let history: [AgentRuntimeMessage]
        let allowedToolNames: Set<String>?
        let thinkingSelection: AgentThinkingSelection?
        let appMode: Bool
    }

    struct SessionIdentity: Codable, Hashable, Sendable {
        let sessionKey: String
        let modelID: String
        let workingDirectory: String
        let systemPrompt: String
        let toolSelection: String?
        let appMode: Bool
        let connectionScopeID: String?

        init(configuration: RequestConfiguration) {
            let key = configuration.sessionKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model = CodexAgentModel.selectionID(
                forModelID: CodexAgentModel.modelID(fromLLMID: configuration.modelID)
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)

            sessionKey = key.isEmpty ? "default" : key
            modelID = model.isEmpty ? CodexAgentModel.defaultLLMID : model
            workingDirectory = configuration.workingDirectory
            systemPrompt = configuration.systemPrompt
            toolSelection = Self.toolSelectionSignature(
                configuration.allowedToolNames
            )
            appMode = configuration.appMode
            connectionScopeID = configuration.connectionScopeID?.nilIfBlank
        }

        init?(storageKey: String) {
            guard let data = Data(base64Encoded: storageKey),
                  let value = try? JSONDecoder().decode(Self.self, from: data) else {
                return nil
            }
            self = value
        }

        var storageKey: String {
            guard let data = try? JSONEncoder().encode(self) else {
                return [
                    sessionKey,
                    modelID,
                    workingDirectory,
                    systemPrompt,
                    toolSelection ?? "tools:any",
                    appMode ? "app" : "cli",
                    connectionScopeID ?? "connection:default"
                ].joined(separator: "\u{1f}")
            }
            return data.base64EncodedString()
        }

        private static func toolSelectionSignature(_ allowedToolNames: Set<String>?) -> String? {
            guard let allowedToolNames else {
                return nil
            }

            let names = allowedToolNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            guard !names.isEmpty else {
                return "tools:none"
            }
            return "tools:\(names.joined(separator: "\u{1e}"))"
        }
        }

    // Keep the existing storage key so installed sessions retain their warm
    // prompt-cache identity after this state is separated from transport IDs.
    static let promptCacheKeyStoreUserDefaultsKey =
        "ChatGPTSubscriptionGenerationClient.sessionIDsByIdentity.v1"
    static let compactionReserveTokenCount = 20_000

    let configuration: AgentRuntimeConfiguration
    /// Historical session value retained for source compatibility. It does not
    /// select or execute the WebSocket transport.
    let urlSession: RemoteProviderSession
    let toolExecutor: DirectToolExecutor
    let webSocketPool: ChatGPTSubscriptionWebSocketPool
    let ownsWebSocketPool: Bool
    let connectionScopeID: String?
    var sessions: [String: AgentSession] = [:]
    var sessionGenerations: [String: UInt64] = [:]
    var nextSessionGeneration: UInt64 = 0
    var promptCacheKeysByIdentity = ChatGPTSubscriptionGenerationClient.loadStoredPromptCacheKeys()

    public init(
        configuration: AgentRuntimeConfiguration,
        /// Historical injection retained while Responses streaming uses only
        /// the shared NIO transport selected by its WebSocket pool.
        urlSession: RemoteProviderSession? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        webSocketPool: ChatGPTSubscriptionWebSocketPool? = nil,
        connectionScopeID: String? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        subAgentContextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
            ?? RemoteProviderSessionCompatibility.generationSession()
        self.webSocketPool = webSocketPool ?? ChatGPTSubscriptionWebSocketPool()
        ownsWebSocketPool = webSocketPool == nil
        self.connectionScopeID = connectionScopeID?.nilIfBlank
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

    struct SessionLease: Sendable {
        let id: String
        let generation: UInt64
    }

    func installSession(_ session: AgentSession, id: String) {
        nextSessionGeneration &+= 1
        sessionGenerations[id] = nextSessionGeneration
        sessions[id] = session
    }

    func invalidateSession(id: String) -> AgentSession? {
        nextSessionGeneration &+= 1
        sessionGenerations[id] = nextSessionGeneration
        return sessions.removeValue(forKey: id)
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
        return true
    }
}
