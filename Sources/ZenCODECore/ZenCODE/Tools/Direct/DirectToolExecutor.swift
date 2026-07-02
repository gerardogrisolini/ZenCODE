//
//  DirectToolExecutor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public actor DirectToolExecutor {
    public enum DirectToolExecutorError: LocalizedError {
        case toolNotAllowed(String)

        public var errorDescription: String? {
            switch self {
            case let .toolNotAllowed(toolName):
                return "The tool '\(toolName)' is not enabled for this agent session."
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
    public let orchestrationRuntime = DirectOrchestrationRuntime()
    public let preferredWorkspaceRootURL: URL?
    public var borrowedOrchestrationToolExecutor: AgentBorrowedToolExecutor?
    public var toolProviderRegistry = AgentToolProviderRegistry()

    public init(
        outputLimit: Int,
        authorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime(),
        preferredWorkspaceRootURL: URL? = nil,
        borrowedOrchestrationToolExecutor: AgentBorrowedToolExecutor? = nil,
        subAgentBackendFactory: @escaping DirectSubAgentBackendFactory
    ) {
        self.init(
            outputLimit: outputLimit,
            authorizationHandler: authorizationHandler,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            borrowedOrchestrationToolExecutor: borrowedOrchestrationToolExecutor,
            subAgentContextualBackendFactory: { _ in subAgentBackendFactory() }
        )
    }

    public init(
        outputLimit: Int,
        authorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime(),
        preferredWorkspaceRootURL: URL? = nil,
        borrowedOrchestrationToolExecutor: AgentBorrowedToolExecutor? = nil,
        subAgentContextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        subAgentProfileResolver: @escaping DirectSubAgentProfileResolver = DirectSubAgentRuntime.defaultProfileResolver
    ) {
        self.outputLimit = outputLimit
        self.authorizationHandler = authorizationHandler
        self.mcpRuntime = mcpRuntime
        self.swiftFeatureRuntime = swiftFeatureRuntime
        self.preferredWorkspaceRootURL = preferredWorkspaceRootURL?.standardizedFileURL
        self.borrowedOrchestrationToolExecutor = borrowedOrchestrationToolExecutor
        self.subAgentRuntime = DirectSubAgentRuntime(
            contextualBackendFactory: subAgentContextualBackendFactory,
            profileResolver: subAgentProfileResolver
        )
    }

    public func updateBorrowedOrchestrationToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) {
        borrowedOrchestrationToolExecutor = executor
    }

    public func updateToolProviders(_ providers: [AgentToolProvider]) {
        toolProviderRegistry.update(providers)
    }

    public func shutdown() async {
        await subAgentRuntime.shutdown()
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await subAgentRuntime.snapshots()
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
        let featureDescriptors = await swiftFeatureRuntime.descriptors(
            allowedToolNames: allowedToolNames,
            excludingFeatureIDs: Self.mcpManagedSwiftFeatureIDs(
                allowedToolNames: allowedToolNames,
                mcpDescriptors: mcpDescriptors
            )
        )

        return Self.canonicalized(
            coreDescriptors + featureDescriptors + mcpDescriptors
        )
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
                summary: summary(from: output)
            )
        } catch {
            let output = "Tool error: \(error.localizedDescription)"
            return DirectAgentToolResult(output: output, summary: output)
        }
    }

    public static func filtered(
        _ descriptors: [DirectToolDescriptor],
        allowedToolNames: Set<String>?
    ) -> [DirectToolDescriptor] {
        guard let allowedToolNames else {
            return descriptors.filter { !DirectMCPToolRuntime.isXcodeToolName($0.name) }
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
            return !DirectMCPToolRuntime.isXcodeToolName(toolName)
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

        if let canonicalOrchestrationToolName = OrchestrationToolRequestCompatibility.canonicalToolName(for: toolName),
           allowedToolNames.contains(canonicalOrchestrationToolName) {
            return true
        }

        if DirectMCPToolRuntime.isXcodeToolName(toolName) {
            if allowedToolNames.contains("xcode.") {
                return true
            }
            if let canonicalXcodeToolName = DirectMCPToolRuntime.canonicalXcodeToolName(for: toolName),
               allowedToolNames.contains(canonicalXcodeToolName) {
                return true
            }
        }

        for prefix in ["xcode.", "figma."] where toolName.hasPrefix(prefix) {
            let unprefixedName = String(toolName.dropFirst(prefix.count))
            if allowedToolNames.contains(unprefixedName) {
                return true
            }
        }

        return false
    }

    static func mcpManagedSwiftFeatureIDs(
        allowedToolNames: Set<String>?,
        mcpDescriptors: [DirectToolDescriptor]
    ) -> Set<String> {
        var featureIDs = Set<String>()
        if allowedToolNames?.contains(where: DirectMCPToolRuntime.isXcodeToolName) == true
            || mcpDescriptors.contains(where: { DirectMCPToolRuntime.isXcodeToolName($0.name) }) {
            featureIDs.insert("xcode-tools")
        }
        return featureIDs
    }

    public static func isOrchestrationToolName(_ toolName: String) -> Bool {
        DirectSubAgentRuntime.isSubAgentToolName(toolName)
            || DirectOrchestrationRuntime.isTodoOrTaskToolName(toolName)
    }
}
