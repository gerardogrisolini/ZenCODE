//
//  DirectToolExecutor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import FeatureMCPBridgeKit
import Foundation
import ToolCore

public actor DirectToolExecutor {
    public static let defaultModelOutputLimit = 12_000

    public enum DirectToolExecutorError: LocalizedError {
        case toolNotAllowed(String)
        case authorizationDenied(String)

        public var errorDescription: String? {
            switch self {
            case let .toolNotAllowed(toolName):
                return "The tool '\(toolName)' is not enabled for this agent session."
            case let .authorizationDenied(output):
                return output
            }
        }
    }

    public struct ProcessResult: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool
    }

    public let outputLimit: Int
    public let authorizationHandler: AgentToolAuthorizationHandler?
    public let subAgentRuntime: DirectSubAgentRuntime
    public let mcpRuntime: DirectMCPToolRuntime
    public let swiftFeatureRuntime: SwiftFeatureRuntime
    /// The transient coordinator/agent bus; never part of session snapshots.
    public let sharedChat: AgentSharedChat
    public let sharedChatSenderID: String?
    public let sharedChatRootSessionID: String?
    /// Delegation identity stamped onto every authorization request this
    /// executor raises, or nil for the coordinator's own executor.
    ///
    /// Both halves must be present: the agent id says *who* is asking and the
    /// root session says *which* operator has to be asked. Only a child
    /// executor carries both, so the coordinator keeps producing plain
    /// turn-scoped requests. The value is derived from executor state the
    /// runtime set when the sub-agent was created — never from model output —
    /// because the runner grants delegated requests on the strength of it.
    var delegatedAuthorizationIdentity: AgentToolAuthorizationRequest.DelegatedIdentity? {
        guard let sharedChatSenderID, let sharedChatRootSessionID else {
            return nil
        }
        return AgentToolAuthorizationRequest.DelegatedIdentity(
            agentID: sharedChatSenderID,
            rootSessionID: sharedChatRootSessionID
        )
    }
    public let todoRuntime = DirectTodoRuntime()
    public let taskToolAdapter = DirectTaskToolAdapter()
    public let execJobRuntime = DirectExecJobRuntime()
    public let preferredWorkspaceRootURL: URL?
    public let toolExecutionContext: ToolExecutionContext
    public var borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?
    /// Legacy/global providers used by runtimes that do not identify a session.
    public var toolProviderRegistry = AgentToolProviderRegistry()
    private var toolProviderRegistriesBySessionID: [String: AgentToolProviderRegistry] = [:]

    public init(
        outputLimit: Int = 48_000,
        authorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime(),
        preferredWorkspaceRootURL: URL? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
        sharedChat: AgentSharedChat? = nil,
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil,
        toolExecutionContext: ToolExecutionContext = ToolExecutionContext(),
        subAgentContextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory
    ) {
        self.init(
            outputLimit: outputLimit,
            authorizationHandler: authorizationHandler,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            borrowedSubAgentToolExecutor: borrowedSubAgentToolExecutor,
            subAgentContextualBackendFactory: subAgentContextualBackendFactory,
            subAgentProfileResolver: DirectSubAgentRuntime.liveProfileResolver,
            coordinatesLiveManifestReads: true,
            sharedChat: sharedChat,
            sharedChatSenderID: sharedChatSenderID,
            sharedChatRootSessionID: sharedChatRootSessionID,
            toolExecutionContext: toolExecutionContext
        )
    }

    public init(
        outputLimit: Int = 48_000,
        authorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime(),
        preferredWorkspaceRootURL: URL? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
        toolExecutionContext: ToolExecutionContext = ToolExecutionContext(),
        subAgentContextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        subAgentProfileResolver: @escaping DirectSubAgentProfileResolver
    ) {
        self.init(
            outputLimit: outputLimit,
            authorizationHandler: authorizationHandler,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            borrowedSubAgentToolExecutor: borrowedSubAgentToolExecutor,
            subAgentContextualBackendFactory: subAgentContextualBackendFactory,
            subAgentProfileResolver: subAgentProfileResolver,
            coordinatesLiveManifestReads: false,
            toolExecutionContext: toolExecutionContext
        )
    }

    private init(
        outputLimit: Int,
        authorizationHandler: AgentToolAuthorizationHandler?,
        mcpRuntime: DirectMCPToolRuntime,
        swiftFeatureRuntime: SwiftFeatureRuntime,
        preferredWorkspaceRootURL: URL?,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?,
        subAgentContextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        subAgentProfileResolver: @escaping DirectSubAgentProfileResolver,
        coordinatesLiveManifestReads: Bool,
        sharedChat: AgentSharedChat? = nil,
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil,
        toolExecutionContext: ToolExecutionContext
    ) {
        self.outputLimit = outputLimit
        self.authorizationHandler = authorizationHandler
        self.mcpRuntime = mcpRuntime
        self.swiftFeatureRuntime = swiftFeatureRuntime
        self.sharedChat = sharedChat ?? AgentSharedChat()
        self.sharedChatSenderID = sharedChatSenderID?.nilIfBlank
        self.sharedChatRootSessionID = sharedChatRootSessionID?.nilIfBlank
        self.toolExecutionContext = toolExecutionContext.resolved(
            fallbackAgentID: self.sharedChatSenderID
        )
        self.preferredWorkspaceRootURL = preferredWorkspaceRootURL?
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.borrowedSubAgentToolExecutor = borrowedSubAgentToolExecutor
        // Propagate this executor's SwiftFeatureRuntime to subagent backends so
        // they share the same discovery cache (consent, --list-tools results)
        // rather than each getting a fresh runtime.
        let parentSwiftFeatureRuntime = swiftFeatureRuntime
        self.subAgentRuntime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                try subAgentContextualBackendFactory(
                    context.injecting(swiftFeatureRuntime: parentSwiftFeatureRuntime)
                )
            },
            profileResolver: subAgentProfileResolver,
            modelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: coordinatesLiveManifestReads,
            sharedChat: self.sharedChat,
            sharedChatSenderID: self.sharedChatSenderID,
            sharedChatRootSessionID: self.sharedChatRootSessionID,
            parentProfileID: toolExecutionContext.profileID,
            parentProfileName: toolExecutionContext.profileName
        )
    }

    public func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        await taskToolAdapter.installTaskOrchestrator(orchestrator)
        await subAgentRuntime.installTaskOrchestrator(orchestrator)
    }

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) {
        borrowedSubAgentToolExecutor = executor
    }

    public func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) async {
        await subAgentRuntime.updateSharedChatMessageAvailableHandler(handler)
    }

    public func updateSubAgentToolEventHandler(
        _ handler: DirectSubAgentToolEventHandler?
    ) async {
        await subAgentRuntime.updateSubAgentToolEventHandler(handler)
    }

    public func updateSubAgentResponseLanguageSectionProvider(
        _ provider: DirectSubAgentResponseLanguageSectionProvider?
    ) async {
        await subAgentRuntime.updateResponseLanguageSectionProvider(provider)
    }

    public func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String? = nil
    ) async {
        // Propagate the prompt-skill provider to the sub-agent runtime so that
        // delegated sub-agents inherit the parent session's skill selection and
        // can execute the intrinsic `skills.list` / `skills.read` tools.
        let skillProvider = providers.first { provider in
            provider.tools.contains { PromptSkillToolProvider.toolNames.contains($0.name) }
        }
        await subAgentRuntime.installPromptSkillToolProvider(skillProvider)

        guard let sessionID = sessionID?.nilIfBlank else {
            toolProviderRegistry.update(providers)
            return
        }

        var registry = toolProviderRegistriesBySessionID[sessionID]
            ?? AgentToolProviderRegistry()
        registry.update(providers)
        toolProviderRegistriesBySessionID[sessionID] = registry
    }

    public func removeToolProviders(sessionID: String) {
        toolProviderRegistriesBySessionID.removeValue(forKey: sessionID)
    }

    func toolProviderRegistry(forSessionID sessionID: String?) -> AgentToolProviderRegistry {
        guard let sessionID = sessionID?.nilIfBlank else {
            return toolProviderRegistry
        }
        return toolProviderRegistriesBySessionID[sessionID] ?? toolProviderRegistry
    }

    public func shutdown() async {
        toolProviderRegistriesBySessionID.removeAll()
        await subAgentRuntime.shutdown()
        await execJobRuntime.shutdown()
    }

    func hasToolProviderRegistry(sessionID: String) -> Bool {
        toolProviderRegistriesBySessionID[sessionID] != nil
    }

    public func closeSubAgent(id: String) async -> Bool {
        await subAgentRuntime.closeAgent(id: id)
    }

    public func interruptSubAgents(rootSessionID: String) async -> Int {
        await subAgentRuntime.interruptAgents(rootSessionID: rootSessionID)
    }

    /// Terminates every running `local.exec` background job owned by this
    /// executor, without waiting for them to exit. The exit monitor reaps each
    /// process; final transcripts stay pollable.
    public func interruptBackgroundJobs() async -> Int {
        await execJobRuntime.interruptRunningJobs()
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await subAgentRuntime.overviewSnapshots()
    }

    public func sharedChatParticipants(
        rootSessionID: String
    ) async -> [AgentSharedChat.Participant] {
        await subAgentRuntime.sharedChatParticipants(rootSessionID: rootSessionID)
    }

    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String,
        messageID: UUID = UUID()
    ) async throws -> AgentSharedChat.Delivery {
        try await subAgentRuntime.sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID,
            messageID: messageID
        )
    }

    public func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        await subAgentRuntime.drainCoordinatorSharedChatMessages(rootSessionID: rootSessionID)
    }

    public func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        await subAgentRuntime.sharedChatTranscriptMessages(rootSessionID: rootSessionID)
    }

    public func execute(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>? = nil
    ) async -> DirectAgentToolResult {
        // Fail closed before feature discovery, execution, shared-chat delivery
        // or logging, including a hallucinated tool call in an isolated request.
        if MemoryConsolidationContext.isIsolated {
            return DirectAgentToolResult(output: "Tools unavailable.", summary: "Tools unavailable.", status: .permissionDenied)
        }
        let opaqueMutation = !Self.isCoreLocalFileOrTextToolName(toolCall.name)
            && !toolCall.name.hasPrefix("agent.")
            && !toolCall.name.hasPrefix("tasks.")
            && !toolCall.name.hasPrefix("todo.")
        if opaqueMutation { OperationMutationUncertainty.begin() }
        // Background commands can continue writing after their tool result. Keep
        // evidence conservatively unavailable for this process once launched.
        let requestsBackground = toolCall.name == "local.exec"
            && toolCall.argumentsObject.bool("background") == true
        var mayOutliveCall = false
        defer {
            if opaqueMutation && !mayOutliveCall { OperationMutationUncertainty.end() }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let recorder = OperationFileChangeRecorder()
        let baseResult: DirectAgentToolResult
        var executionError: Error?
        do {
            let isAllowed = Self.isAllowed(
                toolCall.name,
                allowedToolNames: allowedToolNames
            )
            let featureToolIsAllowed = await swiftFeatureRuntime.featureToolIsAllowed(
                toolName: toolCall.name,
                allowedToolNames: allowedToolNames,
                sessionID: featureExposureSessionID(for: sessionID)
            )
            guard isAllowed || featureToolIsAllowed else {
                throw DirectToolExecutorError.toolNotAllowed(toolCall.name)
            }
            let execution = try await OperationFileChangeRecorder.$current.withValue(recorder) {
                try await executeThrowingResult(
                    sessionID: sessionID,
                    toolCall: toolCall,
                    workingDirectory: workingDirectory,
                    allowedToolNames: allowedToolNames
                )
            }
            mayOutliveCall = requestsBackground
            baseResult = self.result(
                output: execution.output,
                toolName: toolCall.name,
                status: .completed,
                attachments: execution.attachments
            )
        } catch {
            executionError = error
            if let executorError = error as? DirectToolExecutorError,
               case let .authorizationDenied(denialOutput) = executorError {
                baseResult = self.result(
                    output: denialOutput,
                    toolName: toolCall.name,
                    status: .permissionDenied,
                    attachments: []
                )
            } else {
                let output = "Tool error: \(error.localizedDescription)"
                baseResult = DirectAgentToolResult(
                    output: output,
                    summary: output,
                    status: Self.toolResultStatus(for: error)
                )
            }
        }
        let evidencedResult = baseResult.replacing(fileChanges: recorder.changes)
        let deliveredResult = await deliveringInlineSharedChatMessages(
            evidencedResult,
            sessionID: sessionID
        )
        // The one measurement of the call: the log records it, and the
        // result carries it to every surface that shows a call's time.
        let duration = started.duration(to: clock.now)
        let result = deliveredResult.withElapsed(duration)
        ToolExecutionLog.record(
            context: toolExecutionContext,
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: workingDirectory,
            result: result,
            duration: duration,
            error: executionError
        )
        return result
    }

    /// Injects live messages into the recipient's next model round while its
    /// current turn is still running. Only model-facing output is extended;
    /// visible tool output stays unchanged because the terminal `Chat` reader
    /// and other observers render the same message from the transient room. `sharedChatSenderID` identifies a delegated agent;
    /// absence of that identity means the coordinator owns the tool execution.
    private func deliveringInlineSharedChatMessages(
        _ result: DirectAgentToolResult,
        sessionID: String?
    ) async -> DirectAgentToolResult {
        let roomID = AgentSharedChat.resolvedRoomID(
            sharedChatRootSessionID: sharedChatRootSessionID,
            sessionID: sessionID
        )
        let participantID = AgentSharedChat.mailboxParticipantID(
            senderID: sharedChatSenderID,
            roomID: roomID
        )
        let messages = await sharedChat.drain(
            roomID: roomID,
            participantID: participantID,
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        let deliverable = messages.filter { $0.sender.id != participantID }
        guard !deliverable.isEmpty else { return result }
        return result.replacing(
            modelOutput: result.modelOutput
                + "\n\n"
                + DirectSubAgentRuntime.inlineSharedChatDeliveryBlock(deliverable)
        )
    }

    private func result(
        output: String,
        toolName: String,
        status: DirectAgentToolResult.Status,
        attachments: [AgentRuntimeAttachment]
    ) -> DirectAgentToolResult {
        DirectAgentToolResult(
            output: truncated(output),
            summary: summary(from: output),
            modelOutput: modelOutput(from: output, toolName: toolName),
            status: status,
            attachments: attachments
        )
    }

    static func toolResultStatus(for error: Error) -> DirectAgentToolResult.Status {
        isPermissionDenied(error) ? .permissionDenied : .failed
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        if let directToolError = error as? DirectToolError,
           case .permissionDenied = directToolError {
            return true
        }
        if let executorError = error as? DirectToolExecutorError,
           case .toolNotAllowed = executorError {
            return true
        }
        if let executorError = error as? DirectToolExecutorError,
           case .authorizationDenied = executorError {
            return true
        }
        if let mcpError = error as? MCPClientError,
           mcpError.indicatesPermissionDenied {
            return true
        }
        return false
    }
}

extension DirectToolExecutor {
    public func subAgentSnapshotEvents(rootSessionID: String) async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]> {
        await subAgentRuntime.snapshotEvents(rootSessionID: rootSessionID)
    }

    public func subAgentTranscript(
        agentID: String,
        rootSessionID: String
    ) async -> ChatSubAgentTranscript? {
        await subAgentRuntime.transcript(agentID: agentID, rootSessionID: rootSessionID)
    }
}
