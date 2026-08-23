//
//  XcodeWorkspaceContext.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

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
        XcodeWorkspaceContext.normalizedProjectRootPath(
            explicitPath: nil,
            workspacePath: workspacePath
        )
    }

    public static func contexts(fromListWindowsResult result: JSONValue) -> [XcodeWorkspaceContext] {
        guard case let .object(rootObject) = result,
              rootObject["isError"]?.boolValue != true else {
            return []
        }

        let contextsFromWindows = extractFromWindowsArray(rootObject)
        if !contextsFromWindows.isEmpty {
            return contextsFromWindows
        }

        let structuredContentContexts = extractFromStructuredContent(rootObject)
        if !structuredContentContexts.isEmpty {
            return structuredContentContexts
        }

        return []
    }

    private static func extractFromWindowsArray(_ rootObject: [String: JSONValue]) -> [XcodeWorkspaceContext] {
        guard let structuredContent = rootObject["structuredContent"],
              case let .object(contentObject) = structuredContent,
              case let .array(windows) = contentObject["windows"] else {
            return []
        }

        var activeContexts: [XcodeWorkspaceContext] = []
        var inactiveContexts: [XcodeWorkspaceContext] = []

        for window in windows {
            guard case let .object(windowObject) = window else {
                continue
            }
            guard let context = context(fromWindowObject: windowObject) else {
                continue
            }

            if windowObject["isActive"]?.boolValue == true {
                activeContexts.append(context)
            } else {
                inactiveContexts.append(context)
            }
        }

        return uniqueContexts(activeContexts + inactiveContexts)
    }

    /// Extract context from structuredContent.message which contains text like "* tabIdentifier: ..., workspacePath: ..."
    private static func extractFromStructuredContent(_ rootObject: [String: JSONValue]) -> [XcodeWorkspaceContext] {
        guard let structuredContent = rootObject["structuredContent"],
              case let .object(contentObject) = structuredContent,
              let messageValue = contentObject["message"],
              let messageString = messageValue.stringValue else {
            return []
        }

        let contexts = messageString
            .components(separatedBy: .newlines)
            .compactMap(contextFromStructuredContentLine)
        return uniqueContexts(contexts)
    }

    private static func contextFromStructuredContentLine(_ line: String) -> XcodeWorkspaceContext? {
        var tabIdentifier: String?
        var workspacePath: String?

        for component in line.components(separatedBy: ",") {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("* tabIdentifier:") {
                tabIdentifier = String(trimmed.dropFirst("* tabIdentifier:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("tabIdentifier:") {
                tabIdentifier = String(trimmed.dropFirst("tabIdentifier:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("workspacePath:") {
                workspacePath = String(trimmed.dropFirst("workspacePath:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let normalizedWorkspacePath = normalizedPath(workspacePath) ?? normalizedOptional(workspacePath)
        guard normalizedWorkspacePath != nil || normalizedOptional(tabIdentifier) != nil else {
            return nil
        }

        return XcodeWorkspaceContext(
            workspacePath: normalizedProjectRootPath(
                explicitPath: nil,
                workspacePath: normalizedWorkspacePath
            ),
            defaultTabIdentifier: normalizedOptional(tabIdentifier)
        )
    }

    private static func context(fromWindowObject window: [String: JSONValue]) -> XcodeWorkspaceContext? {
        let workspacePath = window["workspacePath"]?.stringValue
        let tabIdentifier = window["tabIdentifier"]?.stringValue
        let normalizedWorkspacePath = normalizedPath(workspacePath) ?? normalizedOptional(workspacePath)
        let normalizedTabIdentifier = normalizedOptional(tabIdentifier)

        guard normalizedWorkspacePath != nil || normalizedTabIdentifier != nil else {
            return nil
        }

        return XcodeWorkspaceContext(
            workspacePath: normalizedProjectRootPath(
                explicitPath: nil,
                workspacePath: normalizedWorkspacePath
            ),
            defaultTabIdentifier: normalizedTabIdentifier
        )
    }

    private static func uniqueContexts(
        _ contexts: [XcodeWorkspaceContext]
    ) -> [XcodeWorkspaceContext] {
        var seen: Set<XcodeWorkspaceContext> = []
        var orderedContexts: [XcodeWorkspaceContext] = []

        for context in contexts where !seen.contains(context) {
            seen.insert(context)
            orderedContexts.append(context)
        }

        return orderedContexts
    }
    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func normalizedPath(_ rawPath: String?) -> String? {
        guard let rawPath = normalizedOptional(rawPath) else {
            return nil
        }

        if rawPath.hasPrefix("file://"),
           let url = URL(string: rawPath),
           url.isFileURL {
            return url.path
        }

        return rawPath
    }

    public static func normalizedProjectRootPath(explicitPath: String?, workspacePath: String?) -> String? {
        if let explicitPath = normalizedPath(explicitPath) {
            return explicitPath
        }

        guard let workspacePath = normalizedPath(workspacePath) else {
            return nil
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath)
        let workspaceExtension = workspaceURL.pathExtension.lowercased()
        if workspaceExtension == "xcodeproj" || workspaceExtension == "xcworkspace" {
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
            .standardizedFileURL
            .pathComponents
        let preferredComponents = URL(fileURLWithPath: preferredRootPath)
            .standardizedFileURL
            .pathComponents

        return workspaceComponents == preferredComponents
            || pathComponents(workspaceComponents, arePrefixOf: preferredComponents)
            || pathComponents(preferredComponents, arePrefixOf: workspaceComponents)
    }

    private static func standardizedRootPath(_ rawPath: String?) -> String? {
        guard let rawPath = normalizedPath(rawPath) else {
            return nil
        }

        let path = URL(fileURLWithPath: rawPath)
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
