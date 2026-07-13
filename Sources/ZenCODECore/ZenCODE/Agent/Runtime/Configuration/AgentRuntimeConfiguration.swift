//
//  AgentRuntimeConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum AgentLocalExecAccessMode: CaseIterable, Equatable, Sendable {
    case standard
    case fullAccess

    public var next: AgentLocalExecAccessMode {
        switch self {
        case .standard: return .fullAccess
        case .fullAccess: return .standard
        }
    }

    public var label: String {
        switch self {
        case .standard: return "default"
        case .fullAccess: return "full access"
        }
    }
}

public struct AgentToolAuthorizationRequest: Sendable {
    public let sessionID: String?
    public let toolCallID: String
    public let toolName: String
    public let title: String
    public let kind: String
    public let command: String
    public let workingDirectory: String
}

public typealias AgentToolAuthorizationHandler = @Sendable (AgentToolAuthorizationRequest) async -> Bool

public struct AgentToolCall: Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(
        id: String,
        name: String,
        argumentsJSON: String
    ) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public typealias AgentBorrowedToolCall = AgentToolCall
public typealias AgentToolExecutor = @Sendable (AgentToolCall) async throws -> String
public typealias AgentBorrowedToolExecutor = AgentToolExecutor
public typealias AgentRuntimeBackendFactory = @Sendable (
    AgentRuntimeConfiguration,
    DirectMCPToolRuntime
) throws -> any AgentRuntimeBackend

public struct AgentToolProvider: Sendable {
    public let tools: [ToolDescriptor]
    public let executor: AgentToolExecutor

    public init(
        tools: [ToolDescriptor],
        executor: @escaping AgentToolExecutor
    ) {
        self.tools = ToolDescriptor.canonicalized(tools)
        self.executor = executor
    }
}

public struct AgentRuntimeAttachment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case image
        case video
    }

    public let kind: Kind
    public let fileURL: URL?
    public let data: Data?
    public let contentType: String?
    public let originalFilename: String

    public init(
        kind: Kind,
        fileURL: URL? = nil,
        data: Data? = nil,
        contentType: String? = nil,
        originalFilename: String
    ) {
        self.kind = kind
        self.fileURL = fileURL
        self.data = data
        self.contentType = contentType?.nilIfBlank
        self.originalFilename = originalFilename.nilIfBlank ?? "attachment"
    }
}

public struct AgentRuntimeToolCall: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String
    public let argumentsJSON: String

    public init(
        id: String?,
        name: String,
        argumentsJSON: String
    ) {
        self.id = id?.nilIfBlank
        self.name = name.nilIfBlank ?? "tool"
        self.argumentsJSON = argumentsJSON.nilIfBlank ?? "{}"
    }
}

public struct AgentRuntimeMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String
    public let reasoningContent: String?
    public let reasoningItemsJSON: String?
    public let thinkingBlocksJSON: String?
    public let providerResponseID: String?
    public let attachments: [AgentRuntimeAttachment]
    public let toolCalls: [AgentRuntimeToolCall]
    public let toolCallID: String?
    public let toolName: String?

    public init(
        role: Role,
        content: String,
        reasoningContent: String? = nil,
        reasoningItemsJSON: String? = nil,
        thinkingBlocksJSON: String? = nil,
        providerResponseID: String? = nil,
        attachments: [AgentRuntimeAttachment] = [],
        toolCalls: [AgentRuntimeToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent?.nilIfBlank
        self.reasoningItemsJSON = reasoningItemsJSON?.nilIfBlank
        self.thinkingBlocksJSON = thinkingBlocksJSON?.nilIfBlank
        self.providerResponseID = providerResponseID?.nilIfBlank
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID?.nilIfBlank
        self.toolName = toolName?.nilIfBlank
    }
}

public struct AgentRuntimeSessionSnapshot: Sendable {
    public let sessionID: String
    public let modelID: String?
    public let workingDirectoryPath: String
    public let systemPrompt: String?
    public let cacheKey: String?
    public let history: [AgentRuntimeMessage]
    public let allowedToolNames: Set<String>?
    public let thinkingSelection: AgentThinkingSelection?
    public let preserveThinking: Bool

    public init(
        sessionID: String,
        modelID: String? = nil,
        workingDirectoryPath: String,
        systemPrompt: String?,
        cacheKey: String?,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        self.sessionID = sessionID.nilIfBlank ?? "agent-core-\(UUID().uuidString.lowercased())"
        self.modelID = modelID?.nilIfBlank
        self.workingDirectoryPath = workingDirectoryPath
        self.systemPrompt = systemPrompt?.nilIfBlank
        self.cacheKey = cacheKey?.nilIfBlank
        self.history = history
        self.allowedToolNames = allowedToolNames
        self.thinkingSelection = thinkingSelection
        self.preserveThinking = preserveThinking
    }
}

extension AgentRuntimeSessionSnapshot {
    public func replacingHistory(
        _ history: [AgentRuntimeMessage]
    ) -> AgentRuntimeSessionSnapshot {
        AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectoryPath: workingDirectoryPath,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    /// Builds the message list used as compaction input: the optional system
    /// prompt followed by the recorded history. Shared by every local
    /// compaction flow so the system-prompt handling stays consistent.
    public var compactionInputMessages: [AgentRuntimeMessage] {
        var messages: [AgentRuntimeMessage] = []
        if let systemPrompt = systemPrompt?.nilIfBlank {
            messages.append(AgentRuntimeMessage(role: .system, content: systemPrompt))
        }
        messages.append(contentsOf: history)
        return messages
    }

    /// Rebuilds a snapshot from a compaction result, extracting the compacted
    /// system prompt from the head of the compacted messages when present.
    public func applyingCompaction(
        _ compactionResult: AgentConversationCompactionResult
    ) -> AgentRuntimeSessionSnapshot {
        var history = compactionResult.messages
        let systemPrompt: String?
        if history.first?.role == .system {
            systemPrompt = history.removeFirst().content
        } else {
            systemPrompt = self.systemPrompt
        }
        return AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectoryPath: workingDirectoryPath,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }
}

public struct AgentRuntimeSessionCompactionResult: Sendable {
    public let snapshot: AgentRuntimeSessionSnapshot
    public let wasCompacted: Bool
    public let originalEstimatedTokenCount: Int
    public let estimatedTokenCount: Int
    public let maxTokens: Int?
    public let keptRecentMessageCount: Int

    public init(
        snapshot: AgentRuntimeSessionSnapshot,
        wasCompacted: Bool,
        originalEstimatedTokenCount: Int,
        estimatedTokenCount: Int,
        maxTokens: Int?,
        keptRecentMessageCount: Int
    ) {
        self.snapshot = snapshot
        self.wasCompacted = wasCompacted
        self.originalEstimatedTokenCount = originalEstimatedTokenCount
        self.estimatedTokenCount = estimatedTokenCount
        self.maxTokens = maxTokens
        self.keptRecentMessageCount = keptRecentMessageCount
    }

    public init(
        snapshot: AgentRuntimeSessionSnapshot,
        compactionResult: AgentConversationCompactionResult
    ) {
        self.init(
            snapshot: snapshot,
            wasCompacted: compactionResult.wasCompacted,
            originalEstimatedTokenCount: compactionResult.originalEstimatedTokenCount,
            estimatedTokenCount: compactionResult.estimatedTokenCount,
            maxTokens: compactionResult.maxTokens,
            keptRecentMessageCount: compactionResult.keptRecentMessageCount
        )
    }
}

public struct AgentRuntimeConfiguration: Sendable {
    public let modelID: String?
    public let bearerToken: String?
    public let workingDirectory: URL
    public let configuredContextWindowLimit: Int?
    public let generationParameterOverrides: AgentGenerationParameterOverrides
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let verboseLogging: Bool
    public let appMode: Bool
    public let toolAuthorizationHandler: AgentToolAuthorizationHandler?

    public init(
        modelID: String?,
        bearerToken: String?,
        workingDirectory: URL,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides = AgentGenerationParameterOverrides(),
        maxToolRounds: Int,
        maxOutputTokens: Int? = nil,
        verboseLogging: Bool,
        appMode: Bool = false,
        toolAuthorizationHandler: AgentToolAuthorizationHandler?
    ) {
        self.modelID = modelID?.nilIfBlank
        self.bearerToken = bearerToken?.nilIfBlank
        self.workingDirectory = workingDirectory
        self.configuredContextWindowLimit = configuredContextWindowLimit.map {
            min(max($0, 1), 1_048_576)
        }
        self.generationParameterOverrides = generationParameterOverrides.normalized()
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens
        self.verboseLogging = verboseLogging
        self.appMode = appMode
        self.toolAuthorizationHandler = toolAuthorizationHandler
    }

    public func withModelID(_ modelID: String?) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID?.nilIfBlank,
            bearerToken: bearerToken,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            toolAuthorizationHandler: toolAuthorizationHandler
        )
    }

    public func withLocalModelSettings(
        configuredContextWindowLimit: Int?,
        generationParameterOverrides: AgentGenerationParameterOverrides?
    ) -> AgentRuntimeConfiguration {
        withModelSettings(
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides
        )
    }

    public func withModelSettings(
        configuredContextWindowLimit: Int?,
        generationParameterOverrides: AgentGenerationParameterOverrides?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            bearerToken: bearerToken,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit.map {
                min(max($0, 1), 1_048_576)
            },
            generationParameterOverrides: generationParameterOverrides?
                .normalized()
                ?? AgentGenerationParameterOverrides(),
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            toolAuthorizationHandler: toolAuthorizationHandler
        )
    }

    public func withToolAuthorizationHandler(
        _ toolAuthorizationHandler: AgentToolAuthorizationHandler?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            bearerToken: bearerToken,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            toolAuthorizationHandler: toolAuthorizationHandler
        )
    }
}

public enum AgentStandaloneSystemPrompt {
    public static func prompt(
        cwd: String,
        memoryToolEnabled: Bool = false,
        allowedToolNames: Set<String>? = nil,
        fileManager: FileManager = .default,
        globalAgentsDirectoryURL: URL? = nil,
        selectedAgentSection: String? = nil,
        selectedSkillSection: String? = nil,
        responseLanguageSection: String? = nil
    ) -> String {
        let workingDirectory = URL(fileURLWithPath: cwd)
        let agentsNotice = AgentsContextService(
            fileManager: fileManager,
            globalAgentsDirectoryURL: globalAgentsDirectoryURL
        )
        .promptSection(workingDirectory: workingDirectory)
        let agentsSection = [selectedAgentSection, agentsNotice]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: "\n\n")
            .nilIfBlank
        return SystemPromptBuilder.standalonePrompt(
            cwd: cwd,
            agentsSection: agentsSection,
            memorySection: memoryToolEnabled ? MemoryService.toolUsagePromptSection() : nil,
            memoryToolEnabled: memoryToolEnabled,
            allowedToolNames: allowedToolNames,
            selectedSkillSection: selectedSkillSection,
            responseLanguageSection: responseLanguageSection
        )
    }
}

public protocol AgentRuntimeBackend: Actor {
    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    )

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    )

    func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    )

    func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async

    func closeSubAgent(id: String) async -> Bool

    func interruptSubAgents(rootSessionID: String) async -> Int

    func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async

    func updateToolProviders(_ providers: [AgentToolProvider]) async

    func closeSession(id: String) async
    func shutdown() async

    func saveSessionRuntimeCache(id: String) async
    func restoreSessionRuntimeCache(id: String) async

    func compactSession(
        id: String,
        force: Bool
    ) async -> AgentRuntimeSessionCompactionResult?

    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String

    func activeToolDescriptors() async -> [DirectToolDescriptor]

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot]

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot?
}

extension AgentRuntimeBackend {
    public func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {}

    public func closeSubAgent(id: String) async -> Bool {
        false
    }

    public func interruptSubAgents(rootSessionID: String) async -> Int {
        0
    }

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {}

    public func updateToolProviders(_ providers: [AgentToolProvider]) async {}

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        []
    }

    public func saveSessionRuntimeCache(id _: String) async {}

    public func restoreSessionRuntimeCache(id _: String) async {}

    public func compactSession(
        id _: String,
        force _: Bool
    ) async -> AgentRuntimeSessionCompactionResult? {
        nil
    }

    public func snapshotSession(id _: String) -> AgentRuntimeSessionSnapshot? {
        nil
    }
}

extension String {
    public var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
