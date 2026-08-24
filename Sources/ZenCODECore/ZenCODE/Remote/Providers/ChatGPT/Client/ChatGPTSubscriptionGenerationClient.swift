//
//  ChatGPTSubscriptionGenerationClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization
import ToolCore
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
        private struct PersistenceRepresentation: Encodable {
            let sessionKey: String
            let modelID: String
            let workingDirectory: String
            let systemPrompt: String
            let toolSelection: String?
            let appMode: Bool
            let connectionScopeID: String?

            init(identity: SessionIdentity) {
                sessionKey = identity.sessionKey.precomposedStringWithCanonicalMapping
                modelID = identity.modelID.precomposedStringWithCanonicalMapping
                workingDirectory = identity.workingDirectory
                    .precomposedStringWithCanonicalMapping
                systemPrompt = identity.systemPrompt.precomposedStringWithCanonicalMapping
                toolSelection = identity.toolSelection?
                    .precomposedStringWithCanonicalMapping
                appMode = identity.appMode
                connectionScopeID = identity.connectionScopeID?
                    .precomposedStringWithCanonicalMapping
            }
        }

        private static let promptCachePersistenceKeyPrefix = "sha256:"

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
            workingDirectory = ""
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
            guard let data = canonicalData else {
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

        /// Compact, privacy-preserving key used only for persistence.
        ///
        /// `storageKey` remains the reversible compatibility representation of
        /// the identity, but it embeds the full system prompt and can be tens of
        /// kilobytes long. Persisting hundreds of those keys in `UserDefaults`
        /// crosses macOS's 4 MiB preference limit. Hashing a canonical
        /// fixed-field encoding preserves the exact cache identity while keeping
        /// every on-disk key a fixed size and avoiding prompt text in the
        /// preferences plist.
        var promptCachePersistenceKey: String {
            return Self.promptCachePersistenceKeyPrefix
            + promptCacheIdentityData.sha256Hex()
        }

        static func isPromptCachePersistenceKey(_ value: String) -> Bool {
            guard value.hasPrefix(promptCachePersistenceKeyPrefix) else {
                return false
            }
            let digestBytes = value.dropFirst(promptCachePersistenceKeyPrefix.count).utf8
            return digestBytes.count == 64 && digestBytes.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
        }

        /// Stable binary encoding for the persisted digest. Length prefixes and
        /// optional-value markers avoid delimiter ambiguity, while NFC brings
        /// canonically equivalent Swift strings to identical bytes.
        private var promptCacheIdentityData: Data {
            let representation = PersistenceRepresentation(identity: self)
            var data = Data("ZenCODE.prompt-cache-identity.v3".utf8)
            Self.append(representation.sessionKey, to: &data)
            Self.append(representation.modelID, to: &data)
            Self.append(representation.workingDirectory, to: &data)
            Self.append(representation.systemPrompt, to: &data)
            Self.append(representation.toolSelection, to: &data)
            data.append(representation.appMode ? 1 : 0)
            Self.append(representation.connectionScopeID, to: &data)
            return data
        }

        private static func append(_ value: String, to data: inout Data) {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }

        private static func append(_ value: String?, to data: inout Data) {
            guard let value else {
                data.append(0)
                return
            }
            data.append(1)
            append(value, to: &data)
        }

        private var canonicalData: Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(PersistenceRepresentation(identity: self))
        }

        private static func toolSelectionSignature(_ allowedToolNames: Set<String>?) -> String? {
            guard let allowedToolNames else {
                return nil
            }

            let names = Set(allowedToolNames.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            })
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
    static let maximumStoredPromptCacheKeyCount = 256
    static let maximumStoredPromptCacheValueByteCount = 256
    static let promptCachePersistenceLock = Mutex<Void>(())
    static let compactionReserveTokenCount = 20_000

    let configuration: AgentRuntimeConfiguration
    let toolExecutor: DirectToolExecutor
    let webSocketPool: ChatGPTSubscriptionWebSocketPool
    let ownsWebSocketPool: Bool
    let connectionScopeID: String?
    /// Delegated backends receive a connection scope from the sub-agent factory.
    /// They stay on HTTP/SSE so parallel, reusable agents cannot accumulate an
    /// uncoordinated set of long-lived Responses WebSockets. The unscoped root
    /// backend remains WebSocket-preferred.
    var usesDelegatedHTTPStreamingTransport: Bool {
        connectionScopeID != nil
    }
    var sessions: [String: AgentSession] = [:]
    var sessionGenerations: [String: UInt64] = [:]
    var nextSessionGeneration: UInt64 = 0
    var promptCacheKeysByIdentity: [SessionIdentity: String] = [:]
    var storedPromptCacheKeysByIdentity =
        ChatGPTSubscriptionGenerationClient.loadStoredPromptCacheKeys()

    public init(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        webSocketPool: ChatGPTSubscriptionWebSocketPool? = nil,
        connectionScopeID: String? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        sharedChat: AgentSharedChat? = nil,
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil,
        subAgentContextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        self.configuration = configuration
        self.webSocketPool = webSocketPool ?? ChatGPTSubscriptionWebSocketPool()
        ownsWebSocketPool = webSocketPool == nil
        self.connectionScopeID = connectionScopeID?.nilIfBlank
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
                modelID: configuration.modelID,
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

    struct SessionLease: Sendable {
        let id: String
        let generation: UInt64
    }

    /// Fences transport fallback state to one installed incarnation of a
    /// logical session. Reusing the same public session ID after close/recreate
    /// cannot inherit a late fallback activation from the previous request.
    static func httpFallbackScopeID(
        sessionID: String,
        generation: UInt64
    ) -> String {
        "\(sessionID)\u{1f}\(generation)"
    }

    static func httpFallbackScopeID(for lease: SessionLease) -> String {
        httpFallbackScopeID(
            sessionID: lease.id,
            generation: lease.generation
        )
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
