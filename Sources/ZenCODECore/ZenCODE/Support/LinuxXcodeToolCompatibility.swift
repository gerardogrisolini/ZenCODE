//
//  LinuxXcodeToolCompatibility.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if !canImport(XcodeToolsFeature)
import FeatureMCPBridgeKit
import Foundation
import ToolCore

/// Source-compatible Xcode types used by shared session APIs on platforms
/// where the Xcode feature target is intentionally absent.
public nonisolated struct XcodeWorkspaceContext: Hashable, Sendable {
    public let workspacePath: String?
    public let defaultTabIdentifier: String?

    public init(
        workspacePath: String?,
        defaultTabIdentifier: String?
    ) {
        self.workspacePath = workspacePath
        self.defaultTabIdentifier = defaultTabIdentifier
    }

    public var normalizedWorkspaceRootPath: String? {
        Self.normalizedProjectRootPath(
            explicitPath: nil,
            workspacePath: workspacePath
        )
    }

    public static func normalizedProjectRootPath(
        explicitPath: String?,
        workspacePath: String?
    ) -> String? {
        if let explicitPath = normalizedPath(explicitPath) {
            return explicitPath
        }
        guard let workspacePath = normalizedPath(workspacePath) else {
            return nil
        }
        let workspaceURL = URL(fileURLWithPath: workspacePath)
        if ["xcodeproj", "xcworkspace"].contains(
            workspaceURL.pathExtension.lowercased()
        ) {
            return workspaceURL.deletingLastPathComponent().path
        }
        return workspaceURL.path
    }

    public static func workspaceRootPath(
        _ workspaceRootPath: String?,
        matchesPreferredRootPath preferredRootPath: String?
    ) -> Bool {
        guard let workspaceRootPath = standardizedRootPath(workspaceRootPath),
              let preferredRootPath = standardizedRootPath(preferredRootPath) else {
            return false
        }
        let workspaceComponents = URL(fileURLWithPath: workspaceRootPath)
            .standardizedFileURL.pathComponents
        let preferredComponents = URL(fileURLWithPath: preferredRootPath)
            .standardizedFileURL.pathComponents
        return workspaceComponents == preferredComponents
            || pathComponents(workspaceComponents, arePrefixOf: preferredComponents)
            || pathComponents(preferredComponents, arePrefixOf: workspaceComponents)
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("file://"),
           let url = URL(string: value),
           url.isFileURL {
            return url.path
        }
        return value
    }

    private static func standardizedRootPath(_ value: String?) -> String? {
        guard let value = normalizedPath(value) else {
            return nil
        }
        let path = URL(fileURLWithPath: value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func pathComponents(
        _ candidatePrefix: [String],
        arePrefixOf path: [String]
    ) -> Bool {
        guard !candidatePrefix.isEmpty,
              candidatePrefix.count < path.count else {
            return false
        }
        return zip(candidatePrefix, path).allSatisfy(==)
    }
}

public nonisolated enum XcodeToolRequestCompatibility {
    public static func normalize(_ request: ToolRequest) -> ToolRequest? {
        _ = request
        return nil
    }
}

public enum XcodeToolUnavailableError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        "Xcode tools are unavailable on this platform."
    }
}

public actor XcodeToolExecutor {
    public init(configuration: MCPServerConfiguration) {
        _ = configuration
    }

    public func loadTools() async throws -> [ToolDescriptor] {
        throw XcodeToolUnavailableError.unavailable
    }

    public func loadWorkspaceContexts() async throws -> [XcodeWorkspaceContext] {
        throw XcodeToolUnavailableError.unavailable
    }

    public func execute(_ request: ToolRequest) async throws -> ToolExecutionOutput {
        _ = request
        throw XcodeToolUnavailableError.unavailable
    }

    public func disconnect() async {}
}

public nonisolated enum XcodeToolIntegration {
    public static let featureID = "xcode-tools"
    public static let toolPrefix = "xcode."
    public static let legacyToolPrefix = "Xcode"
    public static let toolNameAliases = [
        "BuildProject",
        "DocumentationSearch",
        "ExecuteSnippet",
        "GetBuildLog",
        "GetTestList",
        "RenderPreview",
        "RunAllTests",
        "RunSomeTests"
    ]

    public static func isRunning(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        _ = environment
        return false
    }

    public static func defaultConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPServerConfiguration? {
        _ = environment
        return nil
    }

    public static func localTransportPolicy() -> LocalMCPTransportPolicy {
        .standard
    }

    public static func isBridgeConfiguration(
        _ configuration: MCPServerConfiguration
    ) -> Bool {
        _ = configuration
        return false
    }

    public static func isServerCandidate(
        name: String,
        configuration: MCPServerConfiguration
    ) -> Bool {
        _ = name
        _ = configuration
        return false
    }

    public static func canonicalToolName(for toolName: String) -> String? {
        let rawName = rawToolName(fromPublicName: toolName)
        if rawName.hasPrefix(legacyToolPrefix)
            || toolNameAliases.contains(rawName) {
            return rawName
        }
        return nil
    }

    public static func normalizedRequest(_ request: ToolRequest) -> ToolRequest? {
        guard let canonicalName = canonicalToolName(for: request.name) else {
            return nil
        }
        return ToolRequest(name: canonicalName, arguments: request.arguments)
    }

    public static func isToolName(_ toolName: String) -> Bool {
        toolName.hasPrefix(toolPrefix)
            || canonicalToolName(for: toolName) != nil
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
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.caseInsensitiveCompare("xcode") == .orderedSame
            || value == toolPrefix {
            return toolPrefix
        }
        return canonicalToolName(for: value)
    }

    public static func isFeatureReference(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("xcode") == .orderedSame
            || isToolName(value)
    }

    public static func publicDescription(_ description: String) -> String {
        description.hasPrefix("Xcode: ")
            ? description
            : "Xcode: \(description)"
    }

    public static func presentationKind(for toolName: String) -> String {
        switch rawToolName(fromPublicName: toolName) {
        case "XcodeUpdate", "XcodeWrite", "XcodeMakeDir":
            return "edit"
        case "XcodeRM":
            return "delete"
        case "XcodeMV":
            return "move"
        case "BuildProject", "RunAllTests", "RunSomeTests", "ExecuteSnippet",
             "RenderPreview":
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
            return contexts.first
        }
        return contexts.first { context in
            XcodeWorkspaceContext.workspaceRootPath(
                context.normalizedWorkspaceRootPath,
                matchesPreferredRootPath: preferredWorkspaceRootURL.path
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
        return XcodeWorkspaceContext.workspaceRootPath(
            workspaceRootPath,
            matchesPreferredRootPath: preferredWorkspaceRootURL.path
        )
    }

    public static func unavailableToolPrefixes(isRunning: Bool) -> Set<String> {
        _ = isRunning
        return [toolPrefix, legacyToolPrefix]
    }

    public static func isPermissionDenied(_ error: MCPClientError) -> Bool {
        _ = error
        return false
    }
}
#endif
