//
//  DirectToolExecutor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import FeatureMCPBridgeKit
import Foundation
import ToolCore

private struct DirectToolPayloadInput {
    let name: String
    let description: String
    let parameters: Any
}

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
            subAgentModelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: true,
            sharedChat: sharedChat,
            sharedChatSenderID: sharedChatSenderID,
            sharedChatRootSessionID: sharedChatRootSessionID
        )
    }

    public init(
        outputLimit: Int = 48_000,
        authorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime(),
        preferredWorkspaceRootURL: URL? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
        subAgentBackendFactory: @escaping DirectSubAgentBackendFactory
    ) {
        self.init(
            outputLimit: outputLimit,
            authorizationHandler: authorizationHandler,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            borrowedSubAgentToolExecutor: borrowedSubAgentToolExecutor,
            subAgentContextualBackendFactory: { _ in subAgentBackendFactory() },
            subAgentProfileResolver: DirectSubAgentRuntime.liveProfileResolver,
            subAgentModelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: true
        )
    }

    public init(
        outputLimit: Int = 48_000,
        authorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime(),
        preferredWorkspaceRootURL: URL? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
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
            subAgentModelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: false
        )
    }

    public init(
        outputLimit: Int,
        authorizationHandler: AgentToolAuthorizationHandler?,
        mcpRuntime: DirectMCPToolRuntime,
        swiftFeatureRuntime: SwiftFeatureRuntime,
        preferredWorkspaceRootURL: URL?,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?,
        subAgentContextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        subAgentProfileResolver: @escaping DirectSubAgentProfileResolver,
        subAgentModelCatalogProvider: @escaping DirectSubAgentModelCatalogProvider
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
            subAgentModelCatalogProvider: subAgentModelCatalogProvider,
            coordinatesLiveManifestReads: false
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
        subAgentModelCatalogProvider: @escaping DirectSubAgentModelCatalogProvider,
        coordinatesLiveManifestReads: Bool,
        sharedChat: AgentSharedChat? = nil,
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil
    ) {
        self.outputLimit = outputLimit
        self.authorizationHandler = authorizationHandler
        self.mcpRuntime = mcpRuntime
        self.swiftFeatureRuntime = swiftFeatureRuntime
        self.sharedChat = sharedChat ?? AgentSharedChat()
        self.sharedChatSenderID = sharedChatSenderID?.nilIfBlank
        self.sharedChatRootSessionID = sharedChatRootSessionID?.nilIfBlank
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
            modelCatalogProvider: subAgentModelCatalogProvider,
            coordinatesLiveManifestReads: coordinatesLiveManifestReads,
            sharedChat: self.sharedChat,
            sharedChatSenderID: self.sharedChatSenderID,
            sharedChatRootSessionID: self.sharedChatRootSessionID
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
        await subAgentRuntime.shutdown()
        await execJobRuntime.shutdown()
    }

    public func closeSubAgent(id: String) async -> Bool {
        await subAgentRuntime.closeAgent(id: id)
    }

    public func interruptSubAgents(rootSessionID: String) async -> Int {
        await subAgentRuntime.interruptAgents(rootSessionID: rootSessionID)
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
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        try await subAgentRuntime.sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID
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

    public func descriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil,
        sessionID: String? = nil
    ) async -> [DirectToolDescriptor] {
        if allowedToolNames?.isEmpty == true {
            return []
        }
        let preferredWorkspaceRootURL = preferredWorkspaceRootURL
            ?? self.preferredWorkspaceRootURL

        let providerRegistry = toolProviderRegistry(forSessionID: sessionID)
        let providerDescriptors = providerRegistry.descriptors
        #if canImport(Darwin) || canImport(Glibc)
        let processDescriptors = DirectToolCatalog.coreProcessDescriptors
        #else
        let processDescriptors: [DirectToolDescriptor] = []
        #endif
        let protectedCoreDescriptors = Self.filtered(
            Self.canonicalized(
                DirectToolCatalog.coreLocalFileAndTextDescriptors + processDescriptors
            ),
            allowedToolNames: allowedToolNames
        )
        let providerPriorityDescriptors = Self.filtered(
            Self.canonicalized(
                providerDescriptors + DirectToolCatalog.skillToolDescriptors
            ),
            allowedToolNames: allowedToolNames
        )
        let providerToolNames = Set(providerDescriptors.map(\.name))
        let reservedSkillToolNames = PromptSkillToolProvider.toolNames
        let mcpDescriptors = await mcpRuntime.descriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        .filter { !providerToolNames.contains($0.name) }
        .filter { !reservedSkillToolNames.contains($0.name) }
        let featureDescriptors = await swiftFeatureRuntime.descriptors(
            allowedToolNames: allowedToolNames
        )
        .filter { !reservedSkillToolNames.contains($0.name) }

        let featureManagementDescriptors = Self.filtered(
            DirectToolCatalog.featureDescriptors,
            allowedToolNames: allowedToolNames
        )
        let lateCoreDescriptors = Self.filtered(
            DirectToolCatalog.subAgentDescriptors
                + DirectToolCatalog.todoTaskDescriptors
                + DirectToolCatalog.memoryDescriptors,
            allowedToolNames: allowedToolNames
        )
        let result = Self.canonicalized(
            protectedCoreDescriptors
                + providerPriorityDescriptors
                + mcpDescriptors
                + featureManagementDescriptors
                + featureDescriptors
                + lateCoreDescriptors
        )

        return result
    }

    public func chatCompletionToolPayloads(
        allowedToolNames: Set<String>? = nil
    ) async -> [[String: Any]] {
        let inputs = await toolPayloadInputs(allowedToolNames: allowedToolNames)
        return inputs.map { input in
            [
                "type": "function",
                "function": [
                    "name": input.name,
                    "description": input.description,
                    "parameters": input.parameters
                ]
            ]
        }
    }

    public func responsesToolPayloads(
        allowedToolNames: Set<String>? = nil
    ) async -> [[String: Any]] {
        let inputs = await toolPayloadInputs(allowedToolNames: allowedToolNames)
        return inputs.map { input in
            [
                "type": "function",
                "name": input.name,
                "description": input.description,
                "parameters": input.parameters
            ]
        }
    }

    private func toolPayloadInputs(
        allowedToolNames: Set<String>?
    ) async -> [DirectToolPayloadInput] {
        let descriptors = await descriptors(allowedToolNames: allowedToolNames)
        return descriptors.compactMap { descriptor in
            guard let parameters = descriptor.schemaObject else {
                return nil
            }
            return DirectToolPayloadInput(
                name: descriptor.name,
                description: descriptor.description,
                parameters: parameters
            )
        }
    }

    public func execute(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>? = nil
    ) async -> DirectAgentToolResult {
        do {
            let isAllowed = Self.isAllowed(
                toolCall.name,
                allowedToolNames: allowedToolNames
            )
            let featureToolIsAllowed = await swiftFeatureRuntime.featureToolIsAllowed(
                toolName: toolCall.name,
                allowedToolNames: allowedToolNames
            )
            guard isAllowed || featureToolIsAllowed else {
                throw DirectToolExecutorError.toolNotAllowed(toolCall.name)
            }
            let execution = try await executeThrowingResult(
                sessionID: sessionID,
                toolCall: toolCall,
                workingDirectory: workingDirectory,
                allowedToolNames: allowedToolNames
            )
            return await deliveringInlineSharedChatMessages(
                result(
                    output: execution.output,
                    toolName: toolCall.name,
                    status: .completed,
                    attachments: execution.attachments
                ),
                sessionID: sessionID
            )
        } catch {
            if let executorError = error as? DirectToolExecutorError,
               case let .authorizationDenied(denialOutput) = executorError {
                return await deliveringInlineSharedChatMessages(
                    result(
                        output: denialOutput,
                        toolName: toolCall.name,
                        status: .permissionDenied,
                        attachments: []
                    ),
                    sessionID: sessionID
                )
            }
            let output = "Tool error: \(error.localizedDescription)"
            return await deliveringInlineSharedChatMessages(
                DirectAgentToolResult(
                    output: output,
                    summary: output,
                    status: Self.toolResultStatus(for: error)
                ),
                sessionID: sessionID
            )
        }
    }

    /// Delivers the live shared-chat messages that arrived while the model was
    /// working, at the first tool boundary of the turn instead of after it.
    ///
    /// Invariants encoded here:
    /// * only `modelOutput` grows. `output`, `summary`, `status` and
    ///   `attachments` stay identical because the TUI already renders live
    ///   messages from the room transcript; duplicating them in the tool panel
    ///   would show every message twice.
    /// * an empty mailbox returns the result untouched, so a tool result is
    ///   never rewritten for nothing.
    /// * the drain is bounded by ``AgentSharedChat/maximumMessagesPerInjectedPrompt``
    ///   and never waits for a producer, so a tool call cannot be stalled by the
    ///   chat. Anything left over stays in the bounded mailbox and reaches the
    ///   agent through the next tool boundary or the end-of-turn drain.
    /// * a participant's own messages are dropped: the bus can echo a broadcast
    ///   back to its sender, and re-reading it would loop the agent onto itself.
    private func deliveringInlineSharedChatMessages(
        _ result: DirectAgentToolResult,
        sessionID: String?
    ) async -> DirectAgentToolResult {
        // A child executor carries the delegated agent's identity; the
        // coordinator's executor has none and reads the room's coordinator
        // mailbox instead.
        let roomID = sharedChatRootSessionID ?? sessionID?.nilIfBlank ?? "default"
        let participantID = sharedChatSenderID ?? AgentSharedChat.coordinatorID(for: roomID)
        let messages = await sharedChat.drain(
            roomID: roomID,
            participantID: participantID,
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        let deliverable = messages.filter { $0.sender.id != participantID }
        guard !deliverable.isEmpty else {
            return result
        }
        return DirectAgentToolResult(
            output: result.output,
            summary: result.summary,
            modelOutput: result.modelOutput
                + "\n\n"
                + DirectSubAgentRuntime.inlineSharedChatDeliveryBlock(deliverable),
            status: result.status,
            attachments: result.attachments
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

    private static func toolResultStatus(for error: Error) -> DirectAgentToolResult.Status {
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
           mcpErrorIsPermissionDenied(mcpError) {
            return true
        }
        return false
    }

    private static func mcpErrorIsPermissionDenied(_ error: MCPClientError) -> Bool {
        // Generic, cross-platform detection of MCP permission failures.
        //
        // Keep permission classification generic so every MCP connector follows
        // the same result contract on every supported platform.
        switch error {
        case .authorizationRequired:
            return true
        case let .serverExited(_, message),
             let .serverError(_, message):
            return messageLooksLikePermissionDenied(message)
        default:
            return false
        }
    }

    private static func messageLooksLikePermissionDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("permission denied")
            || lowered.contains("consent denied")
            || lowered.contains("not authorized")
            || lowered.contains("not authorised")
            || lowered.contains("not allowed")
            || lowered.contains("not permitted")
            || lowered.contains("rejected")
            || lowered.contains("declined")
    }

    public static func filtered(
        _ descriptors: [DirectToolDescriptor],
        allowedToolNames: Set<String>?
    ) -> [DirectToolDescriptor] {
        guard let allowedToolNames else {
            return descriptors
        }

        guard !allowedToolNames.isEmpty else {
            return []
        }

        return descriptors.filter {
            isAllowed($0.name, allowedToolNames: allowedToolNames)
        }
    }

    public static func isAllowed(
        _ toolName: String,
        allowedToolNames: Set<String>?
    ) -> Bool {
        guard let allowedToolNames else {
            return true
        }

        guard !allowedToolNames.isEmpty else {
            return false
        }

        if allowedToolNames.contains(toolName) {
            return true
        }

        if allowedToolNames.contains(where: { allowedToolName in
            allowedToolName.hasSuffix(".") && toolName.hasPrefix(allowedToolName)
        }) {
            return true
        }

        if let canonicalSubAgentToolName = DirectSubAgentRuntime.canonicalSubAgentToolName(for: toolName),
           allowedToolNames.contains(canonicalSubAgentToolName) {
            return true
        }

        if let canonicalCoordinationToolName = SubAgentToolRequestCompatibility.canonicalToolName(for: toolName),
           allowedToolNames.contains(canonicalCoordinationToolName) {
            return true
        }

        return false
    }

    /// Returns the catalog-owned coordination tool reached by a compatibility
    /// alias, if any. This intentionally recognizes only names that the direct
    /// executor can dispatch to its Todo, Task, or Sub-Agent runtimes.
    ///
    /// Provider, feature, and MCP dispatch retain precedence over this fallback
    /// path, so an externally registered raw tool name is never reclassified
    /// merely because it resembles a legacy coordination alias.
    static func canonicalCoreCoordinationToolName(
        for rawToolName: String
    ) -> String? {
        guard let canonicalName = SubAgentToolRequestCompatibility.canonicalToolName(
            for: rawToolName
        ), DirectToolCatalog.coreDescriptors.contains(where: { descriptor in
            descriptor.name == canonicalName
        }) else {
            return nil
        }
        return canonicalName
    }

    /// Authorization for a compatibility-dispatched coordination tool must be
    /// evaluated against its canonical catalog name, not the raw alias. A
    /// read-only profile may retain an external grant named like an alias, but
    /// that grant cannot unlock the core action reached by fallback dispatch.
    static func isCoreCoordinationToolAllowed(
        _ rawToolName: String,
        allowedToolNames: Set<String>?
    ) -> Bool {
        guard let canonicalName = canonicalCoreCoordinationToolName(
            for: rawToolName
        ) else {
            return false
        }
        return isAllowed(canonicalName, allowedToolNames: allowedToolNames)
    }

    public static func isSubAgentCoordinationToolName(_ toolName: String) -> Bool {
        DirectSubAgentRuntime.isSubAgentToolName(toolName)
            || DirectTodoTaskRuntime.isTodoOrTaskToolName(toolName)
    }

    /// A child executor borrows only its parent's agent-runtime surface. Todo
    /// storage and task orchestration stay local to the child executor, which
    /// has the shared `SessionTaskOrchestrator` installed separately.
    static func isBorrowedSubAgentToolName(_ toolName: String) -> Bool {
        DirectSubAgentRuntime.isSubAgentToolName(toolName)
    }
}
