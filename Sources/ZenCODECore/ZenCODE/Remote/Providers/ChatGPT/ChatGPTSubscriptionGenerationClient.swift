//
//  ChatGPTSubscriptionGenerationClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
#if os(macOS)
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
                    appMode ? "app" : "cli"
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

    static let sessionStoreUserDefaultsKey =
        "ChatGPTSubscriptionGenerationClient.sessionIDsByIdentity.v1"
    static let compactionReserveTokenCount = 20_000

    let configuration: AgentRuntimeConfiguration
    let urlSession: URLSession
    let toolExecutor: DirectToolExecutor
    let webSocketPool: ChatGPTSubscriptionWebSocketPool
    let usesWebSocketTransport: Bool
    var sessions: [String: AgentSession] = [:]
    var sessionIDsByIdentity = ChatGPTSubscriptionGenerationClient.loadStoredSessionIDs()

    public init(
        configuration: AgentRuntimeConfiguration,
        urlSession: URLSession? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        webSocketPool: ChatGPTSubscriptionWebSocketPool = ChatGPTSubscriptionWebSocketPool(),
        usesWebSocketTransport: Bool = true
    ) {
        self.configuration = configuration
        self.webSocketPool = webSocketPool
        self.usesWebSocketTransport = usesWebSocketTransport
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
                let fallbackProvider = AgentRemoteProvider(
                    id: AgentRemoteProvider.chatGPTSubscriptionProviderID,
                    name: CodexAgentModel.displayTitle,
                    baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL,
                    modelID: configuration.modelID ?? CodexAgentModel.defaultLLMID
                )
                return try AgentCoreBackend.makeRemoteBackend(
                    configuration: configuration.applyingSubAgentBackendContext(context),
                    mcpRuntime: mcpRuntime,
                    fallbackProvider: fallbackProvider,
                    urlSession: urlSession,
                    chatGPTUsesWebSocketTransport: usesWebSocketTransport
                )
            }
        )
    }
}

#endif
