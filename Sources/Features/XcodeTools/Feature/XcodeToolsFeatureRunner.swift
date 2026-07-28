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

        return ToolDescriptor.canonicalized(tools).map { tool in
            let descriptor = ToolDescriptor(
                name: tool.name,
                title: tool.title,
                description: tool.description,
                inputSchema: tool.inputSchema,
                outputSchema: tool.outputSchema,
                presentation: tool.presentation.isAutomatic
                    ? Self.presentation(for: tool)
                    : tool.presentation
            )
            return FeatureToolDescriptor(
                toolDescriptor: descriptor,
                description: descriptor.description.hasPrefix(descriptionPrefix)
                    ? descriptor.description
                    : "\(descriptionPrefix)\(descriptor.description)"
            )
        }
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

    private static func presentation(
        for tool: ToolDescriptor
    ) -> ToolPresentationDefinition {
        let rawName = tool.name.split(separator: ".").last.map(String.init) ?? tool.name
        let lowered = rawName.lowercased()
        if lowered.contains("write") || lowered == "xcodewrite" {
            return .fileWrite(
                title: tool.title ?? "Xcode file",
                action: "Write",
                targetKeyPaths: ["filePath", "file_path", "path"],
                contentKeyPaths: ["content", "text"]
            )
        }
        if lowered.contains("update") || lowered.contains("edit") {
            return .fileEdit(
                title: tool.title ?? "Xcode file",
                action: "Edit",
                targetKeyPaths: ["filePath", "file_path", "path"]
            )
        }

        let kind: ToolPresentationKind
        switch XcodeToolIntegration.presentationKind(for: tool.name) {
        case "read": kind = .read
        case "search": kind = .search
        case "edit": kind = .edit
        case "delete": kind = .delete
        case "move": kind = .move
        case "execute": kind = .execute
        default: kind = .other
        }
        return .standard(
            title: tool.title ?? rawName,
            action: xcodeAction(for: kind),
            kind: kind,
            targetKeyPaths: [
                "filePath", "file_path", "path", "scheme", "target",
                "workspacePath", "projectPath", "tabIdentifier"
            ],
            targetFormat: kind == .read || kind == .edit || kind == .delete || kind == .move
                ? .path
                : .text
        )
    }

    private static func xcodeAction(for kind: ToolPresentationKind) -> String {
        switch kind {
        case .read: return "Read"
        case .search: return "Search"
        case .create: return "Create"
        case .edit: return "Edit"
        case .delete: return "Delete"
        case .move: return "Move"
        case .execute: return "Run"
        case .inspect: return "Inspect"
        case .communicate: return "Send"
        case .manage: return "Manage"
        case .other: return "Use"
        }
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
