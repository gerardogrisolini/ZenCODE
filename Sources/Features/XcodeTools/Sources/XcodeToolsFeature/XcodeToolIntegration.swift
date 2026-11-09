//
//  XcodeToolIntegration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

internal import FeatureMCPBridgeKit
import Foundation
import ToolCore

/// Package-internal Xcode integration boundary used by the feature runner. It
/// owns Xcode naming, request normalization, availability, presentation, and
/// error classification; only `XcodeToolsFeatureRunner` is public.
nonisolated enum XcodeToolIntegration {
    static let toolPrefix = "xcode."
    static let descriptionPrefix = "Xcode: "
    static let priorityDescriptionPrefix =
        "Xcode: Always prefer this Xcode tool over generic shell, filesystem, search, text, "
        + "SwiftPM, or xcodebuild alternatives when it applies to the current Xcode project. "

    static func isAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        XcodeMCPServerConfiguration.isRunning(environment: environment)
            && XcodeMCPServerConfiguration.configuration(fromEnvironment: environment) != nil
    }

    static func defaultConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPServerConfiguration? {
        XcodeMCPServerConfiguration.configuration(fromEnvironment: environment)
    }

    static func localTransportPolicy() -> LocalMCPTransportPolicy {
        XcodeMCPTransportPolicy.make()
    }

    static func normalizedRequest(_ request: ToolRequest) -> ToolRequest? {
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

    static func rawToolName(fromPublicName toolName: String) -> String {
        toolName.hasPrefix(toolPrefix)
            ? String(toolName.dropFirst(toolPrefix.count))
            : toolName
    }

    static func publicDescription(_ description: String) -> String {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.hasPrefix(priorityDescriptionPrefix) {
            return description
        }
        let toolDescription = description.hasPrefix(descriptionPrefix)
            ? String(description.dropFirst(descriptionPrefix.count))
            : description
        return "\(priorityDescriptionPrefix)\(toolDescription)"
    }

    /// Builds, tests, snippets, and previews run inside Xcode, not in a shell.
    /// ACP clients present the `execute` kind as a terminal command, so these
    /// tools publish the generic `other` kind while keeping the `Run` action.
    private static let xcodeRunToolNames: Set<String> = [
        "BuildProject", "RunAllTests", "RunSomeTests", "ExecuteSnippet", "RenderPreview"
    ]

    static func presentationKind(for toolName: String) -> String {
        let rawName = rawToolName(fromPublicName: toolName)
        if xcodeRunToolNames.contains(rawName) {
            return "other"
        }
        switch rawName {
        case "XcodeUpdate", "XcodeWrite", "XcodeMakeDir":
            return "edit"
        case "XcodeRM":
            return "delete"
        case "XcodeMV":
            return "move"
        case "XcodeGrep", "XcodeGlob", "DocumentationSearch":
            return "search"
        default:
            return "read"
        }
    }

    static func presentation(for tool: ToolDescriptor) -> ToolPresentationDefinition {
        let rawName = rawToolName(fromPublicName: tool.name)
        let pathKeys = ["filePath", "file_path", "path"]
        switch rawName {
        case "XcodeWrite":
            return .fileWrite(
                title: tool.title ?? "Xcode file",
                action: "Write",
                targetKeyPaths: pathKeys,
                contentKeyPaths: ["content", "text"]
            )
        case "XcodeUpdate":
            return .fileEdit(
                title: tool.title ?? "Xcode file",
                action: "Edit",
                targetKeyPaths: pathKeys,
                oldKeyPaths: ["oldString", "old_string", "old"],
                newKeyPaths: ["newString", "new_string", "new"]
            )
        case "XcodeMakeDir":
            return .standard(
                title: tool.title ?? "Xcode directory",
                action: "Create",
                kind: .create,
                targetKeyPaths: pathKeys,
                targetFormat: .path
            )
        case "XcodeRM":
            return .standard(
                title: tool.title ?? "Xcode file",
                action: "Delete",
                kind: .delete,
                targetKeyPaths: pathKeys,
                targetFormat: .path
            )
        case "XcodeMV":
            return ToolPresentationDefinition(
                title: tool.title ?? "Xcode file",
                action: "Move",
                kind: .move,
                target: .argument(
                    ["destinationPath", "destination_path", "to"],
                    format: .path
                ),
                metadata: [
                    ToolPresentationMetadataDefinition(
                        label: "from",
                        value: .argument(
                            ["sourcePath", "source_path", "from"],
                            format: .path
                        )
                    )
                ],
                summary: ToolPresentationSummaryDefinition(
                    value: .resultSummary(),
                    strategy: .firstLine,
                    label: "summary"
                )
            )
        default:
            break
        }

        let kind: ToolPresentationKind
        switch presentationKind(for: tool.name) {
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
            action: xcodeRunToolNames.contains(rawName)
                ? "Run"
                : presentationAction(for: kind),
            kind: kind,
            targetKeyPaths: pathKeys + [
                "scheme", "target", "workspacePath", "projectPath",
                "tabIdentifier"
            ],
            targetFormat: kind == .read || kind == .edit || kind == .delete || kind == .move
                ? .path
                : .text
        )
    }

    private static func presentationAction(for kind: ToolPresentationKind) -> String {
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

    static func isPermissionDenied(_ error: MCPClientError) -> Bool {
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

    static func messageLooksLikePermissionDenied(_ message: String) -> Bool {
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
