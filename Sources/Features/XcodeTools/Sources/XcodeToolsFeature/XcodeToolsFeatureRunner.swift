//
//  XcodeToolsFeatureMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Thin configuration for the Xcode MCP tool feature. Overrides
//  `invoke` to use `XcodeToolExecutor` (which includes retry logic
//  for XcodeUpdate) and `mapError` for consent-denied detection.
//

import Foundation
import FeatureKit
internal import FeatureMCPBridgeKit
import ToolCore

public enum XcodeToolsFeatureRunner {
    public static func run(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        await RemoteMCPFeatureRunner.run(
            configuration: XcodeFeatureConfiguration(),
            arguments: arguments,
            environment: environment
        )
    }

    /// Decorates every model-visible Xcode descriptor with the package-owned
    /// priority instruction. Because this happens in the optional feature's
    /// `--list-tools` response, the guidance exists only while XcodeTools is
    /// installed, available, and selected by the host.
    static func featureToolDescriptor(
        for tool: ToolDescriptor
    ) -> FeatureToolDescriptor {
        let presentation = XcodeToolIntegration.presentation(for: tool)
        let descriptor = ToolDescriptor(
            name: tool.name,
            title: tool.title,
            description: XcodeToolIntegration.publicDescription(tool.description),
            inputSchema: tool.inputSchema,
            outputSchema: tool.outputSchema,
            presentation: presentation
        )
        return FeatureToolDescriptor(
            toolDescriptor: descriptor,
            presentation: presentation
        )
    }

    /// A normal JSON-RPC error belongs to one tool request and does not make the
    /// authenticated Xcode connection unusable. Errors that poison or close the
    /// transport require a fresh executor.
    static func shouldDiscardPersistentExecutor(after error: Error) -> Bool {
        guard let clientError = error as? MCPClientError else {
            return false
        }
        switch clientError {
        case .serverError, .invalidResponse, .unsupportedMessageID:
            return false
        case .missingContentLength,
             .invalidContentLength,
             .malformedTransport,
             .connectionClosed,
             .unsupportedPlatform,
             .authorizationRequired,
             .browserAuthenticationFailed,
             .serverExited:
            return true
        }
    }

    /// Builds the raw bridge request for one public invocation: aliases and
    /// argument names are canonicalized, and a `xcode.`-prefixed name the
    /// compatibility table does not know (a tool the bridge listed under a new
    /// name) is forwarded unchanged so that every listed tool stays callable.
    static func bridgeRequest(
        toolName: String,
        inputData: Data,
        toolNamePrefix: String
    ) throws -> ToolRequest {
        let arguments = try RemoteMCPFeatureRunner.decodeArguments(from: inputData)
        let request = ToolRequest(name: toolName, arguments: arguments)
        if let normalizedRequest = XcodeToolIntegration.normalizedRequest(request) {
            return ToolRequest(
                name: XcodeToolIntegration.rawToolName(fromPublicName: normalizedRequest.name),
                arguments: normalizedRequest.arguments
            )
        }
        let trimmedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.hasPrefix(toolNamePrefix),
              trimmedName.count > toolNamePrefix.count else {
            throw XcodeFeatureError.unknownTool(toolName)
        }
        return ToolRequest(
            name: String(trimmedName.dropFirst(toolNamePrefix.count)),
            arguments: arguments
        )
    }
}

struct XcodeFeatureConfiguration: MCPFeatureConfiguration, PersistentMCPFeatureConfiguration {
    let featureName = "Xcode"
    let toolNamePrefix = XcodeToolIntegration.toolPrefix
    let descriptionPrefix = XcodeToolIntegration.priorityDescriptionPrefix
    let usageText = """
    Usage:
      xcode-tools-feature --list-tools
      xcode-tools-feature --invoke <tool-name> [--working-directory <path>]
    """

    func isAvailable(environment: [String: String]) -> Bool {
        XcodeToolIntegration.isAvailable(environment: environment)
    }

    func makeExecutor(environment: [String: String]) async throws -> RemoteMCPToolExecutor {
        guard let config = XcodeToolIntegration.defaultConfiguration(environment: environment) else {
            throw MCPFeatureError.unavailable(featureName)
        }
        return RemoteMCPToolExecutor(
            configuration: config,
            toolNamePrefix: toolNamePrefix,
            localTransportPolicy: XcodeToolIntegration.localTransportPolicy()
        )
    }

    /// The generic feature runner calls this only for its private `--serve`
    /// mode. Manual `--list-tools` / `--invoke` invocations keep using the
    /// historical methods below and remain intentionally one-shot.
    func makePersistentSession(
        environment: [String: String]
    ) async throws -> any MCPFeaturePersistentSession {
        guard isAvailable(environment: environment),
              let configuration = XcodeMCPServerConfiguration.configuration(fromEnvironment: environment) else {
            throw MCPFeatureError.unavailable(featureName)
        }
        return XcodePersistentMCPFeatureSession(
            configuration: configuration,
            toolNamePrefix: toolNamePrefix
        )
    }

    /// Uses `XcodeToolExecutor` for invoke to get retry-on-indentation-mismatch.
    func invoke(
        toolName: String,
        inputData: Data,
        environment: [String: String]
    ) async throws -> String {
        try await invokeResult(
            toolName: toolName,
            inputData: inputData,
            workingDirectoryPath: nil,
            environment: environment
        ).output
    }

    /// One-shot invocation with on-disk file-change evidence.
    func invokeResult(
        toolName: String,
        inputData: Data,
        workingDirectoryPath: String?,
        environment: [String: String]
    ) async throws -> MCPFeatureInvocationResult {
        guard isAvailable(environment: environment),
              let config = XcodeMCPServerConfiguration.configuration(fromEnvironment: environment) else {
            throw MCPFeatureError.unavailable(featureName)
        }

        let bridgeRequest = try XcodeToolsFeatureRunner.bridgeRequest(
            toolName: toolName,
            inputData: inputData,
            toolNamePrefix: toolNamePrefix
        )

        let executor = XcodeToolExecutor(configuration: config)
        do {
            let result = try await executor.executeCapturingFileChanges(
                bridgeRequest,
                workingDirectoryPath: workingDirectoryPath
            )
            await executor.disconnect()
            return MCPFeatureInvocationResult(
                output: result.output.text,
                fileChanges: result.fileChanges
            )
        } catch {
            await executor.disconnect()
            throw error
        }
    }

    func mapError(_ error: Error) -> Error {
        if isXcodeConsentDenied(error) {
            return XcodeFeatureError.consentDenied
        }
        return error
    }

    // MARK: - Consent detection

    /// Transport-classified consent failures arrive as `MCPClientError`; the
    /// text fallback only covers errors raised outside the MCP client and must
    /// not mistake an ordinary cancellation or rejection for a consent problem.
    private func isXcodeConsentDenied(_ error: Error) -> Bool {
        if let clientError = error as? MCPClientError {
            return XcodeToolIntegration.isPermissionDenied(clientError)
        }
        if error is CancellationError || error is XcodeFeatureError {
            return false
        }
        return messageLooksLikeConsentDenied(error.localizedDescription)
    }

    private func messageLooksLikeConsentDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("xcode.mcpbridge.authorization")
            || lowered.contains("authorization error")
            || XcodeToolIntegration.messageLooksLikePermissionDenied(message)
    }

    func presentation(for tool: ToolDescriptor) -> ToolPresentationDefinition {
        XcodeToolIntegration.presentation(for: tool)
    }
}

/// Stateful implementation used exclusively by the
/// `xcode-tools-feature --serve` subprocess. Keeping this actor package-local guarantees Xcode
/// details never leak into ZenCODECore while the same MCP connection serves
/// discovery and every subsequent tool call.
actor XcodePersistentMCPFeatureSession: MCPFeaturePersistentSession {
    private let configuration: MCPServerConfiguration
    private let toolNamePrefix: String
    private var executor: XcodeToolExecutor?

    init(configuration: MCPServerConfiguration, toolNamePrefix: String) {
        self.configuration = configuration
        self.toolNamePrefix = toolNamePrefix
    }

    func listTools() async throws -> [FeatureToolDescriptor] {
        let executor = executorOrCreate()
        do {
            let tools = try await executor.loadTools()
            let publicTools = tools.map { $0.prefixed(with: toolNamePrefix) }
            return ToolDescriptor.canonicalized(publicTools).map(
                XcodeToolsFeatureRunner.featureToolDescriptor(for:)
            )
        } catch {
            await discardExecutor()
            throw error
        }
    }

    func invoke(toolName: String, inputData: Data) async throws -> String {
        try await invokeResult(
            toolName: toolName,
            inputData: inputData,
            workingDirectoryPath: nil
        ).output
    }

    func invokeResult(
        toolName: String,
        inputData: Data,
        workingDirectoryPath: String?
    ) async throws -> MCPFeatureInvocationResult {
        let bridgeRequest = try XcodeToolsFeatureRunner.bridgeRequest(
            toolName: toolName,
            inputData: inputData,
            toolNamePrefix: toolNamePrefix
        )
        let executor = executorOrCreate()
        do {
            let result = try await executor.executeCapturingFileChanges(
                bridgeRequest,
                workingDirectoryPath: workingDirectoryPath
            )
            return MCPFeatureInvocationResult(
                output: result.output.text,
                fileChanges: result.fileChanges
            )
        } catch {
            if XcodeToolsFeatureRunner.shouldDiscardPersistentExecutor(after: error) {
                await discardExecutor()
            }
            throw error
        }
    }

    func shutdown() async {
        await discardExecutor()
    }

    private func executorOrCreate() -> XcodeToolExecutor {
        if let executor {
            return executor
        }
        let executor = XcodeToolExecutor(configuration: configuration)
        self.executor = executor
        return executor
    }

    private func discardExecutor() async {
        let executor = executor
        self.executor = nil
        await executor?.disconnect()
    }
}

enum XcodeFeatureError: LocalizedError, Equatable {
    case consentDenied
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .consentDenied:
            return "Xcode MCP consent denied. Open Xcode and allow the connection in the consent dialog, then retry."
        case let .unknownTool(name):
            return "Unknown Xcode tool '\(name)'. Use a tool name listed by the xcode-tools feature."
        }
    }
}
