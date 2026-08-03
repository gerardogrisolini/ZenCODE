//
//  XcodeToolsFeatureMain.swift
//  ZenCODE
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
}

private struct XcodeFeatureConfiguration: MCPFeatureConfiguration, PersistentMCPFeatureConfiguration {
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

    func listTools(
        environment: [String: String]
    ) async throws -> [FeatureToolDescriptor] {
        guard isAvailable(environment: environment) else {
            return []
        }
        let executor = try await makeExecutor(environment: environment)
        let tools: [ToolDescriptor]
        do {
            tools = try await executor.loadTools()
        } catch {
            await executor.disconnect()
            throw error
        }
        await executor.disconnect()

        return ToolDescriptor.canonicalized(tools).map(
            XcodeToolsFeatureRunner.featureToolDescriptor(for:)
        )
    }

    /// Uses `XcodeToolExecutor` for invoke to get retry-on-indentation-mismatch.
    func invoke(
        toolName: String,
        inputData: Data,
        environment: [String: String]
    ) async throws -> String {
        guard isAvailable(environment: environment),
              let config = XcodeMCPServerConfiguration.configuration(fromEnvironment: environment) else {
            throw MCPFeatureError.unavailable(featureName)
        }

        let arguments = try RemoteMCPFeatureRunner.decodeArguments(from: inputData)
        let request = ToolRequest(name: toolName, arguments: arguments)
        guard let normalizedRequest = XcodeToolIntegration.normalizedRequest(request) else {
            throw MCPFeatureError.unavailable(featureName)
        }

        let rawToolName = normalizedRequest.name.hasPrefix(toolNamePrefix)
            ? String(normalizedRequest.name.dropFirst(toolNamePrefix.count))
            : normalizedRequest.name

        let executor = XcodeToolExecutor(configuration: config)
        do {
            let output = try await executor.execute(
                ToolRequest(name: rawToolName, arguments: normalizedRequest.arguments)
            )
            await executor.disconnect()
            return output.text
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

    private func isXcodeConsentDenied(_ error: Error) -> Bool {
        if let clientError = error as? MCPClientError {
            return XcodeToolIntegration.isPermissionDenied(clientError)
        }
        return messageLooksLikeConsentDenied(error.localizedDescription)
    }

    private func messageLooksLikeConsentDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("xcode.mcpbridge.authorization")
            || lowered.contains("authorization error")
            || lowered.contains("consent denied")
            || lowered.contains("permission denied")
            || lowered.contains("not authorized")
            || lowered.contains("not authorised")
            || lowered.contains("not allowed")
            || lowered.contains("not permitted")
            || lowered.contains("rejected")
            || lowered.contains("declined")
            || lowered.contains("cancelled")
            || lowered.contains("canceled")
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
        let arguments = try RemoteMCPFeatureRunner.decodeArguments(from: inputData)
        let request = ToolRequest(name: toolName, arguments: arguments)
        guard let normalizedRequest = XcodeToolIntegration.normalizedRequest(request) else {
            throw MCPFeatureError.unavailable("Xcode")
        }

        let rawToolName = normalizedRequest.name.hasPrefix(toolNamePrefix)
            ? String(normalizedRequest.name.dropFirst(toolNamePrefix.count))
            : normalizedRequest.name
        let executor = executorOrCreate()
        do {
            let output = try await executor.execute(
                ToolRequest(name: rawToolName, arguments: normalizedRequest.arguments)
            )
            return output.text
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

private enum XcodeFeatureError: LocalizedError {
    case consentDenied

    var errorDescription: String? {
        switch self {
        case .consentDenied:
            return "Xcode MCP consent denied. Open Xcode and allow the connection in the consent dialog, then retry."
        }
    }
}
