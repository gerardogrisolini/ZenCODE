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
import FeatureMCPBridgeKit
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
}

private struct XcodeFeatureConfiguration: MCPFeatureConfiguration {
    let featureName = "Xcode"
    let toolNamePrefix = XcodeToolIntegration.toolPrefix
    let descriptionPrefix = XcodeToolIntegration.descriptionPrefix
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
