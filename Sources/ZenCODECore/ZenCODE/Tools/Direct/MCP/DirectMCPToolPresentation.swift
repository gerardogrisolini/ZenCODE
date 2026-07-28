//
//  DirectMCPToolPresentation.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension DirectMCPToolRuntime {
    nonisolated static func presentation(
        for tool: ToolDescriptor,
        family: ServerFamily
    ) -> ToolPresentationDefinition {
        guard tool.presentation.isAutomatic else {
            return tool.presentation
        }
        switch family {
        case .figma:
            return .standard(
                title: tool.title ?? "Figma",
                action: "Inspect",
                kind: .inspect,
                targetKeyPaths: [
                    "nodeId", "node_id", "fileKey", "file_key",
                    "url", "name", "query"
                ]
            )
        case .xcode:
            return xcodePresentation(for: tool)
        case .external:
            // Arbitrary third-party MCP tools remain automatic unless the
            // server/feature wire supplies the semantic extension explicitly.
            return .automatic
        }
    }

    private nonisolated static func xcodePresentation(
        for tool: ToolDescriptor
    ) -> ToolPresentationDefinition {
        let rawName = tool.name.split(separator: ".").last.map(String.init) ?? tool.name
        let lowered = rawName.lowercased()
        let pathKeys = ["filePath", "file_path", "path"]
        if lowered.contains("write") {
            return .fileWrite(
                title: tool.title ?? "Xcode file",
                action: "Write",
                targetKeyPaths: pathKeys
            )
        }
        if lowered.contains("update") || lowered.contains("edit") {
            return .fileEdit(
                title: tool.title ?? "Xcode file",
                action: "Edit",
                targetKeyPaths: pathKeys
            )
        }

        let kind: ToolPresentationKind
        let action: String
        if lowered.contains("delete") || lowered.hasSuffix("rm") {
            kind = .delete
            action = "Delete"
        } else if lowered.contains("move") || lowered.hasSuffix("mv") {
            kind = .move
            action = "Move"
        } else if lowered.contains("search") || lowered.contains("find") {
            kind = .search
            action = "Search"
        } else if lowered.contains("read") || lowered.contains("list") || lowered.contains("show") {
            kind = .read
            action = "Read"
        } else if lowered.contains("build") || lowered.contains("test") || lowered.contains("run") {
            kind = .execute
            action = "Run"
        } else {
            kind = .inspect
            action = "Inspect"
        }
        return .standard(
            title: tool.title ?? rawName,
            action: action,
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
}
