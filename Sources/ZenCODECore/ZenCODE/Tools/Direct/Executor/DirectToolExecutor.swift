//
//  DirectToolExecutor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(XcodeToolsFeature)
import XcodeToolsFeature
#endif

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
    public let todoRuntime = DirectTodoRuntime()
    public let taskToolAdapter = DirectTaskToolAdapter()
    public let execJobRuntime = DirectExecJobRuntime()
    public let preferredWorkspaceRootURL: URL?
    public var borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?
    public var toolProviderRegistry = AgentToolProviderRegistry()

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
            subAgentContextualBackendFactory: { _ in subAgentBackendFactory() }
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
        subAgentProfileResolver: @escaping DirectSubAgentProfileResolver = DirectSubAgentRuntime.defaultProfileResolver
    ) {
        self.outputLimit = outputLimit
        self.authorizationHandler = authorizationHandler
        self.mcpRuntime = mcpRuntime
        self.swiftFeatureRuntime = swiftFeatureRuntime
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
            profileResolver: subAgentProfileResolver
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

    public func updateToolProviders(_ providers: [AgentToolProvider]) {
        toolProviderRegistry.update(providers)
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

    public func descriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        if allowedToolNames?.isEmpty == true {
            return []
        }
        let preferredWorkspaceRootURL = preferredWorkspaceRootURL
            ?? self.preferredWorkspaceRootURL

        let coreDescriptors = Self.filtered(
            Self.canonicalized(
                DirectToolCatalog.baseDescriptors + toolProviderRegistry.descriptors
            ),
            allowedToolNames: allowedToolNames
        )
        let mcpDescriptors = await mcpRuntime.descriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        let excludingFeatureIDs = Self.mcpManagedSwiftFeatureIDs(
            mcpDescriptors: mcpDescriptors
        )
        let featureDescriptors = await swiftFeatureRuntime.descriptors(
            allowedToolNames: allowedToolNames,
            excludingFeatureIDs: excludingFeatureIDs
        )

        let result = Self.canonicalized(
            coreDescriptors + featureDescriptors + mcpDescriptors
        )

        // Diagnostic: if xcode tools are requested but none ended up in the
        // final descriptor set, log which source failed to help debugging.
        let requestsXcode = allowedToolNames?.contains(where: XcodeToolIntegration.isToolName) == true
            || allowedToolNames == nil
        if requestsXcode,
           !result.contains(where: { XcodeToolIntegration.isToolName($0.name) }) {
            let mcpHasXcode = mcpDescriptors.contains(where: { XcodeToolIntegration.isToolName($0.name) })
            let featureExcluded = excludingFeatureIDs.contains(XcodeToolIntegration.featureID)
            let featureHasXcode = featureDescriptors.contains(where: { XcodeToolIntegration.isToolName($0.name) })
            ZenLogger.debug(
                .xcodeToolExecutor,
                "No xcode descriptors in result — MCP provided xcode: \(mcpHasXcode), "
                    + "feature excluded: \(featureExcluded), "
                    + "feature provided xcode: \(featureHasXcode), "
                    + "preferredWorkspaceRootURL: \(preferredWorkspaceRootURL?.path ?? "nil")"
            )
        }

        return result
    }

    public func chatCompletionToolPayloads(
        allowedToolNames: Set<String>? = nil
    ) async -> [[String: Any]] {
        let descriptors = await descriptors(allowedToolNames: allowedToolNames)
        return descriptors.compactMap { descriptor in
            guard let schema = descriptor.schemaObject else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": descriptor.name,
                    "description": descriptor.description,
                    "parameters": schema
                ]
            ]
        }
    }

    public func responsesToolPayloads(
        allowedToolNames: Set<String>? = nil
    ) async -> [[String: Any]] {
        let descriptors = await descriptors(allowedToolNames: allowedToolNames)
        return descriptors.compactMap { descriptor in
            guard let schema = descriptor.schemaObject else {
                return nil
            }
            return [
                "type": "function",
                "name": descriptor.name,
                "description": descriptor.description,
                "parameters": schema
            ]
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
            let output = try await executeThrowing(
                sessionID: sessionID,
                toolCall: toolCall,
                workingDirectory: workingDirectory,
                allowedToolNames: allowedToolNames
            )
            return DirectAgentToolResult(
                output: truncated(output),
                summary: summary(from: output),
                modelOutput: modelOutput(from: output, toolName: toolCall.name)
            )
        } catch {
            if let executorError = error as? DirectToolExecutorError,
               case let .authorizationDenied(denialOutput) = executorError {
                return DirectAgentToolResult(
                    output: truncated(denialOutput),
                    summary: summary(from: denialOutput),
                    modelOutput: modelOutput(from: denialOutput, toolName: toolCall.name),
                    status: .permissionDenied
                )
            }
            let output = "Tool error: \(error.localizedDescription)"
            return DirectAgentToolResult(
                output: output,
                summary: output,
                status: Self.toolResultStatus(for: error)
            )
        }
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
        XcodeToolIntegration.isPermissionDenied(error)
    }

    public static func filtered(
        _ descriptors: [DirectToolDescriptor],
        allowedToolNames: Set<String>?
    ) -> [DirectToolDescriptor] {
        guard let allowedToolNames else {
            return descriptors.filter { !XcodeToolIntegration.isToolName($0.name) }
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
            return !XcodeToolIntegration.isToolName(toolName)
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

        if XcodeToolIntegration.isToolName(toolName) {
            if allowedToolNames.contains(XcodeToolIntegration.toolPrefix) {
                return true
            }
            if let canonicalXcodeToolName = XcodeToolIntegration.canonicalToolName(for: toolName),
               allowedToolNames.contains(canonicalXcodeToolName) {
                return true
            }
        }

        for prefix in [XcodeToolIntegration.toolPrefix, "figma."] where toolName.hasPrefix(prefix) {
            let unprefixedName = String(toolName.dropFirst(prefix.count))
            if allowedToolNames.contains(unprefixedName) {
                return true
            }
        }

        return false
    }

    /// Feature IDs whose tools are provided by MCP and therefore must be excluded
    /// from the Swift feature descriptor stream to avoid duplicates.
    ///
    /// Exclusion is driven solely by the MCP descriptors actually materialized for
    /// the current session. This keeps the Swift feature runtime as a valid fallback
    /// when MCP does not surface a feature's tools (e.g. the Xcode server is not
    /// matched for the subagent's workspace), while still preventing duplication when
    /// MCP does provide them.
    static func mcpManagedSwiftFeatureIDs(
        mcpDescriptors: [DirectToolDescriptor]
    ) -> Set<String> {
        var featureIDs = Set<String>()
        if mcpDescriptors.contains(where: { XcodeToolIntegration.isToolName($0.name) }) {
            featureIDs.insert(XcodeToolIntegration.featureID)
        }
        return featureIDs
    }

    public static func isSubAgentCoordinationToolName(_ toolName: String) -> Bool {
        DirectSubAgentRuntime.isSubAgentToolName(toolName)
            || DirectTodoTaskRuntime.isTodoOrTaskToolName(toolName)
    }
}
