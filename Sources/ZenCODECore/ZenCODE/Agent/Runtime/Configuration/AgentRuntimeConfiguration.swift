//
//  AgentRuntimeConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

public import ToolCore
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

}

/// Dynamic turn context propagated while a runtime backend executes one prompt.
///
/// Tool executors construct ``AgentToolAuthorizationRequest`` values in several
/// modules. Keeping the turn identity in a task-local lets those existing call
/// sites remain source compatible while still binding every authorization
/// request to the prompt that initiated it.
public enum AgentToolAuthorizationContext {
    @TaskLocal public static var turnID: UUID? = nil
}

public struct AgentToolAuthorizationRequest: Sendable {
    /// Identifies a delegated sub-agent as the origin of an authorization
    /// request, together with the operator session that owns its delegation
    /// tree.
    ///
    /// A sub-agent runs in its own private session and outlives the turn that
    /// spawned it, so its requests can never match a live turn/session pair.
    /// The runner routes them on this identity instead, which is why the
    /// identity is minted by the runtime from the child tool executor's own
    /// state and is never read from model output or tool arguments: a forgeable
    /// identity would let a call borrow another session's operator consent.
    public struct DelegatedIdentity: Sendable, Equatable {
        /// The delegated agent that issued the tool call.
        public let agentID: String
        /// The operator-facing session that started the delegation tree.
        public let rootSessionID: String

        public init(agentID: String, rootSessionID: String) {
            self.agentID = agentID
            self.rootSessionID = rootSessionID
        }
    }

    /// The unique prompt/turn that owns this authorization request.
    ///
    /// This is optional only for source compatibility with callers that build a
    /// request outside a running agent turn. The runner fails such requests
    /// closed rather than guessing a concurrent prompt handler.
    public let turnID: UUID?
    public let sessionID: String?
    public let toolCallID: String
    public let toolName: String
    public let title: String
    public let kind: String
    public let command: String
    public let workingDirectory: String
    /// Non-nil only for requests raised by a delegated sub-agent. The
    /// coordinator's own executor never sets it, so the turn-scoped path stays
    /// exactly as strict as before.
    public let delegatedIdentity: DelegatedIdentity?

    public init(
        turnID: UUID? = AgentToolAuthorizationContext.turnID,
        sessionID: String?,
        toolCallID: String,
        toolName: String,
        title: String,
        kind: String,
        command: String,
        workingDirectory: String,
        delegatedIdentity: DelegatedIdentity? = nil
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.title = title
        self.kind = kind
        self.command = command
        self.workingDirectory = workingDirectory
        self.delegatedIdentity = delegatedIdentity
    }

    /// Returns a copy that differs only in the operator-facing title.
    ///
    /// Presentation is deliberately the only thing this changes: every field
    /// the runner routes on, and every field consent caching keys on (tool name
    /// and command), is carried over untouched.
    public func withTitle(_ title: String) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            turnID: turnID,
            sessionID: sessionID,
            toolCallID: toolCallID,
            toolName: toolName,
            title: title,
            kind: kind,
            command: command,
            workingDirectory: workingDirectory,
            delegatedIdentity: delegatedIdentity
        )
    }
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
    /// Ordered Anthropic assistant content blocks, serialized verbatim for
    /// signed-thinking/tool replay. Optional for backward-compatible snapshots.
    public let anthropicContentBlocksJSON: String?
    public let providerResponseID: String?
    public let attachments: [AgentRuntimeAttachment]
    public let toolCalls: [AgentRuntimeToolCall]
    public let toolCallID: String?
    public let toolName: String?
    /// Anthropic `tool_result.is_error`. Optional so snapshots written before
    /// this field was introduced continue to decode unchanged.
    public let toolResultIsError: Bool?

    public init(
        role: Role,
        content: String,
        reasoningContent: String? = nil,
        reasoningItemsJSON: String? = nil,
        thinkingBlocksJSON: String? = nil,
        anthropicContentBlocksJSON: String? = nil,
        providerResponseID: String? = nil,
        attachments: [AgentRuntimeAttachment] = [],
        toolCalls: [AgentRuntimeToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolResultIsError: Bool? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent?.nilIfBlank
        self.reasoningItemsJSON = reasoningItemsJSON?.nilIfBlank
        self.thinkingBlocksJSON = thinkingBlocksJSON?.nilIfBlank
        self.anthropicContentBlocksJSON = anthropicContentBlocksJSON?.nilIfBlank
        self.providerResponseID = providerResponseID?.nilIfBlank
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID?.nilIfBlank
        self.toolName = toolName?.nilIfBlank
        self.toolResultIsError = toolResultIsError
    }
}

/// Encodes session-specific instructions as one recognisable leading user
/// message. The wire representation remains a normal user message for every
/// provider; the marker lets snapshots, restores, and compaction keep this
/// mutable context out of the durable conversation transcript.
public enum AgentRuntimeDynamicContext {
    public static let marker = "ZenCODE session context:\n"

    public static func message(for context: String?) -> AgentRuntimeMessage? {
        guard let context = context?.nilIfBlank else {
            return nil
        }
        return AgentRuntimeMessage(role: .user, content: marker + context)
    }

    public static func context(from message: AgentRuntimeMessage?) -> String? {
        guard let message,
              message.role == .user,
              message.attachments.isEmpty,
              message.toolCalls.isEmpty,
              message.toolCallID == nil,
              message.toolName == nil,
              message.content.hasPrefix(marker) else {
            return nil
        }
        return String(message.content.dropFirst(marker.count)).nilIfBlank
    }

    public static func separating(
        from history: [AgentRuntimeMessage]
    ) -> (context: String?, history: [AgentRuntimeMessage]) {
        guard let context = context(from: history.first) else {
            return (nil, history)
        }
        return (context, Array(history.dropFirst()))
    }

    public static func inserting(
        _ context: String?,
        into history: [AgentRuntimeMessage]
    ) -> [AgentRuntimeMessage] {
        guard let message = message(for: context) else {
            return history
        }
        return [message] + separating(from: history).history
    }
}

public struct AgentRuntimeSessionSnapshot: Sendable {
    public let sessionID: String
    public let modelID: String?
    public let workingDirectoryPath: String
    public let systemPrompt: String?
    public let dynamicContext: String?
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
        dynamicContext: String? = nil,
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
        self.dynamicContext = dynamicContext?.nilIfBlank
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
            dynamicContext: dynamicContext,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    /// Builds the message list used as compaction input: the optional system
    /// prompt, protected dynamic context, then recorded history. Shared by
    /// every local compaction flow so the context-message invariant stays
    /// consistent.
    public var compactionInputMessages: [AgentRuntimeMessage] {
        var messages: [AgentRuntimeMessage] = []
        if let systemPrompt = systemPrompt?.nilIfBlank {
            messages.append(AgentRuntimeMessage(role: .system, content: systemPrompt))
        }
        if let dynamicContextMessage = AgentRuntimeDynamicContext.message(for: dynamicContext) {
            messages.append(dynamicContextMessage)
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
        let separatedContext = AgentRuntimeDynamicContext.separating(from: history)
        return AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectoryPath: workingDirectoryPath,
            systemPrompt: systemPrompt,
            dynamicContext: separatedContext.context ?? dynamicContext,
            cacheKey: cacheKey,
            history: separatedContext.history,
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
    public let workingDirectory: URL
    public let configuredContextWindowLimit: Int?
    public let generationParameterOverrides: AgentGenerationParameterOverrides
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let verboseLogging: Bool
    public let appMode: Bool
    public let locksModelToSession: Bool
    public let toolAuthorizationHandler: AgentToolAuthorizationHandler?
    public let agentID: String?
    public let agentName: String?

    public init(
        modelID: String?,
        workingDirectory: URL,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides = AgentGenerationParameterOverrides(),
        maxToolRounds: Int,
        maxOutputTokens: Int? = nil,
        verboseLogging: Bool,
        appMode: Bool = false,
        locksModelToSession: Bool = false,
        toolAuthorizationHandler: AgentToolAuthorizationHandler?,
        agentID: String? = nil,
        agentName: String? = nil
    ) {
        self.modelID = modelID?.nilIfBlank
        self.workingDirectory = workingDirectory
        self.configuredContextWindowLimit = configuredContextWindowLimit.map {
            min(max($0, 1), 1_048_576)
        }
        self.generationParameterOverrides = generationParameterOverrides.normalized()
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens
        self.verboseLogging = verboseLogging
        self.appMode = appMode
        self.locksModelToSession = locksModelToSession
        self.toolAuthorizationHandler = toolAuthorizationHandler
        self.agentID = agentID?.nilIfBlank
        self.agentName = agentName?.nilIfBlank
    }

    public func withModelID(_ modelID: String?) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID?.nilIfBlank,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler,
            agentID: agentID,
            agentName: agentName
        )
    }

    public func withModelSettings(
        configuredContextWindowLimit: Int?,
        generationParameterOverrides: AgentGenerationParameterOverrides?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
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
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler,
            agentID: agentID,
            agentName: agentName
        )
    }

    public func withToolAuthorizationHandler(
        _ toolAuthorizationHandler: AgentToolAuthorizationHandler?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler,
            agentID: agentID,
            agentName: agentName
        )
    }

    public func withToolExecutionIdentity(
        agentID: String?,
        agentName: String?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler,
            agentID: agentID,
            agentName: agentName
        )
    }
}

public enum AgentStandaloneSystemPrompt {
    public static func prompt(
        cwd: String,
        memoryToolEnabled: Bool = false,
        allowedToolNames: Set<String>? = nil,
        locksModelToSession: Bool = false,
        fileManager: FileManager = .default,
        globalAgentsDirectoryURL: URL? = nil,
        selectedAgentSection: String? = nil,
        selectedSkillSection: String? = nil,
        responseLanguageSection: String? = nil
    ) -> String {
        promptSections(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled,
            allowedToolNames: allowedToolNames,
            locksModelToSession: locksModelToSession,
            fileManager: fileManager,
            globalAgentsDirectoryURL: globalAgentsDirectoryURL,
            selectedAgentSection: selectedAgentSection,
            selectedSkillSection: selectedSkillSection,
            responseLanguageSection: responseLanguageSection
        )
        .combinedPrompt
    }

    public static func promptSections(
        cwd: String,
        memoryToolEnabled: Bool = false,
        allowedToolNames: Set<String>? = nil,
        locksModelToSession: Bool = false,
        fileManager: FileManager = .default,
        globalAgentsDirectoryURL: URL? = nil,
        selectedAgentSection: String? = nil,
        selectedSkillSection: String? = nil,
        responseLanguageSection: String? = nil
    ) -> SystemPromptSections {
        let workingDirectory = URL(fileURLWithPath: cwd)
        let agentsNotice = AgentsContextService(
            fileManager: fileManager,
            globalAgentsDirectoryURL: globalAgentsDirectoryURL
        )
        .promptSection(workingDirectory: workingDirectory)
        let delegatableSection: String? = locksModelToSession
            ? nil
            : {
                  let liveConfiguration = AgentDelegationCatalog.liveConfiguration(
                      fileManager: fileManager
                  )
                  return SystemPromptBuilder.delegatableAgentsSection(
                      agents: liveConfiguration.profiles,
                      allowedToolNames: allowedToolNames,
                      snapshot: liveConfiguration.catalog
                  )
              }()
        let agentsSection = [selectedAgentSection, agentsNotice, delegatableSection]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: "\n\n")
            .nilIfBlank
        return SystemPromptBuilder.standalonePromptSections(
            cwd: cwd,
            agentsSection: agentsSection,
            memorySection: memoryToolEnabled
                ? MemoryService.toolUsagePromptSection(
                    readOnly: AgentSessionComposition.memoryToolsAreReadOnly(allowedToolNames)
                )
                : nil,
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

    /// Installs the wake-up used by shared-chat renderers. The callback carries
    /// the root room whose bounded transcript changed.
    func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) async

    func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String?
    ) async

    func closeSession(id: String) async
    func shutdown() async

    func compactSession(
        id: String,
        force: Bool
    ) async -> AgentRuntimeSessionCompactionResult?

    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String

    func activeToolDescriptors() async -> [DirectToolDescriptor]
    func activeToolDescriptors(sessionID: String?) async -> [DirectToolDescriptor]

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot]

    func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant]
    func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery
    func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message]
    /// Read-only access to every retained message in a room transcript. Unlike
    /// ``drainCoordinatorSharedChatMessages(rootSessionID:)``, this never
    /// removes messages from a mailbox: it returns the full bounded transcript
    /// so a rendering surface can display agent-to-agent messages that never
    /// enter the coordinator mailbox.
    func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message]

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot?
}

extension AgentRuntimeBackend {
    public func activeToolDescriptors(
        sessionID _: String?
    ) async -> [DirectToolDescriptor] {
        await activeToolDescriptors()
    }

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

    public func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) async {}

    public func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID _: String?
    ) async {}

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        []
    }

    public func sharedChatParticipants(rootSessionID _: String) async -> [AgentSharedChat.Participant] {
        []
    }

    public func sendSharedChatMessage(
        text _: String,
        destination _: AgentSharedChat.Destination,
        rootSessionID _: String
    ) async throws -> AgentSharedChat.Delivery {
        throw AgentSharedChat.Error.unavailable
    }

    public func drainCoordinatorSharedChatMessages(
        rootSessionID _: String
    ) async -> [AgentSharedChat.Message] {
        []
    }

    public func sharedChatTranscriptMessages(
        rootSessionID _: String
    ) async -> [AgentSharedChat.Message] {
        []
    }

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
