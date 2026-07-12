//
//  XcodeToolIntegration.swift
//  ZenCODE
//

import FeatureMCPBridgeKit
import Foundation
import ToolCore

/// Public Xcode integration boundary consumed by the application host. It owns
/// Xcode naming, routing, availability, MCP candidate detection, and error
/// classification while the host retains only session orchestration.
public nonisolated enum XcodeToolIntegration {
    public static let featureID = "xcode-tools"
    public static let toolPrefix = "xcode."
    public static let legacyToolPrefix = "Xcode"
    public static let descriptionPrefix = "Xcode: "

    public static let toolNameAliases: [String] = [
        "BuildProject",
        "DocumentationSearch",
        "ExecuteSnippet",
        "GetBuildLog",
        "GetTestList",
        "RenderPreview",
        "RunAllTests",
        "RunSomeTests"
    ]

    private static let unprefixedToolNames = Set(toolNameAliases)

    public static func isAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        XcodeMCPServerConfiguration.isRunning(environment: environment)
            && XcodeMCPServerConfiguration.configuration(fromEnvironment: environment) != nil
    }

    public static func isRunning(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        XcodeMCPServerConfiguration.isRunning(environment: environment)
    }

    public static func defaultConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPServerConfiguration? {
        XcodeMCPServerConfiguration.configuration(fromEnvironment: environment)
    }

    public static func localTransportPolicy() -> LocalMCPTransportPolicy {
        XcodeMCPTransportPolicy.make()
    }

    public static func isBridgeConfiguration(_ configuration: MCPServerConfiguration) -> Bool {
        XcodeMCPServerConfiguration.isBridgeConfiguration(configuration)
    }

    public static func isServerCandidate(
        name: String,
        configuration: MCPServerConfiguration
    ) -> Bool {
        if name.localizedCaseInsensitiveContains("xcode") {
            return true
        }
        if isBridgeConfiguration(configuration) {
            return true
        }

        let commandName = URL(fileURLWithPath: configuration.executablePath)
            .lastPathComponent
            .lowercased()
        if commandName == "xcrun",
           configuration.arguments.contains(where: { $0.lowercased() == "mcpbridge" }) {
            return true
        }
        return configuration.environment.keys.contains { $0.hasPrefix("MCP_XCODE") }
    }

    public static func canonicalToolName(for toolName: String) -> String? {
        normalizedRequest(ToolRequest(name: toolName, arguments: [:]))?.name
    }

    public static func normalizedRequest(_ request: ToolRequest) -> ToolRequest? {
        if let normalized = XcodeToolRequestCompatibility.normalize(request) {
            return normalized
        }

        guard request.name.hasPrefix(toolPrefix) else {
            return nil
        }
        let rawName = String(request.name.dropFirst(toolPrefix.count))
        return XcodeToolRequestCompatibility.normalize(
            ToolRequest(name: rawName, arguments: request.arguments)
        )
    }

    public static func isToolName(_ toolName: String) -> Bool {
        toolName.hasPrefix(toolPrefix)
            || canonicalToolName(for: toolName) != nil
            || unprefixedToolNames.contains(toolName)
    }

    public static func publicToolName(for rawToolName: String) -> String {
        "\(toolPrefix)\(Self.rawToolName(fromPublicName: rawToolName))"
    }

    public static func rawToolName(fromPublicName toolName: String) -> String {
        toolName.hasPrefix(toolPrefix)
            ? String(toolName.dropFirst(toolPrefix.count))
            : toolName
    }

    public static func canonicalAllowedToolName(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }
        if trimmedValue.caseInsensitiveCompare("xcode") == .orderedSame
            || trimmedValue == toolPrefix {
            return toolPrefix
        }
        if let canonicalName = canonicalToolName(for: trimmedValue) {
            return canonicalName
        }
        return isToolName(trimmedValue) ? trimmedValue : nil
    }

    public static func isFeatureReference(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("xcode") == .orderedSame
            || isToolName(value)
    }

    public static func publicDescription(_ description: String) -> String {
        description.hasPrefix(descriptionPrefix)
            ? description
            : "\(descriptionPrefix)\(description)"
    }

    public static func presentationKind(for toolName: String) -> String {
        switch rawToolName(fromPublicName: toolName) {
        case "XcodeUpdate", "XcodeWrite", "XcodeMakeDir":
            return "edit"
        case "XcodeRM":
            return "delete"
        case "XcodeMV":
            return "move"
        case "BuildProject", "RunAllTests", "RunSomeTests", "ExecuteSnippet", "RenderPreview":
            return "execute"
        case "XcodeGrep", "XcodeGlob", "DocumentationSearch":
            return "search"
        default:
            return "read"
        }
    }

    public static func matchedWorkspaceContext(
        in contexts: [XcodeWorkspaceContext],
        preferredWorkspaceRootURL: URL?
    ) -> XcodeWorkspaceContext? {
        guard let preferredWorkspaceRootURL else {
            return contexts.first ?? XcodeWorkspaceContext(
                workspacePath: nil,
                defaultTabIdentifier: nil
            )
        }

        let preferredRootPath = preferredWorkspaceRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return contexts.first { context in
            XcodeWorkspaceContext.workspaceRootPath(
                context.normalizedWorkspaceRootPath,
                matchesPreferredRootPath: preferredRootPath
            )
        }
    }

    public static func workspaceMatches(
        workspaceRootPath: String?,
        preferredWorkspaceRootURL: URL?
    ) -> Bool {
        guard let preferredWorkspaceRootURL,
              let workspaceRootPath else {
            return true
        }
        let preferredRootPath = preferredWorkspaceRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return XcodeWorkspaceContext.workspaceRootPath(
            workspaceRootPath,
            matchesPreferredRootPath: preferredRootPath
        )
    }

    public static func unavailableToolPrefixes(isRunning: Bool) -> Set<String> {
        isRunning ? [] : [toolPrefix, "Xcode"]
    }

    public static func isPermissionDenied(_ error: MCPClientError) -> Bool {
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

    public static func messageLooksLikePermissionDenied(_ message: String) -> Bool {
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
}
