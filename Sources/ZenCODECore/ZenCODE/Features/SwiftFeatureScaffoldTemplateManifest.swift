//
//  SwiftFeatureScaffoldTemplateManifest.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension SwiftFeatureRuntime {
    static func featureManifestContents(
        id: String,
        displayName: String,
        description: String,
        toolName: String,
        enabled: Bool
    ) throws -> String {
        try renderedManifest(
            id: id, displayName: displayName, description: description, enabled: enabled,
            toolNamePrefixes: [toolNamePrefix(from: toolName)],
            tools: [[
                "name": toolName,
                "description": "Echoes the provided text. Replace this implementation with the generated feature logic.",
                "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]],
                "presentation": ["title": "Echo", "action": "Echo", "kind": "execute", "target": ["source": "arguments", "keyPaths": ["text"], "format": "text"], "metadata": [], "sections": []]
            ]],
            promotionReady: true
        )
    }

    static func mcpBridgeFeatureManifestContents(
        id: String,
        displayName: String,
        description: String,
        toolPrefix: String,
        enabled: Bool
    ) throws -> String {
        try renderedManifest(
            id: id, displayName: displayName, description: description, enabled: enabled,
            toolNamePrefixes: [toolPrefix], tools: [], discoversToolsAtRuntime: true,
            promotionReady: true
        )
    }

    private static func renderedManifest(
        id: String,
        displayName: String,
        description: String,
        enabled: Bool,
        toolNamePrefixes: [String],
        tools: [[String: Any]],
        discoversToolsAtRuntime: Bool = false,
        promotionReady: Bool = false
    ) throws -> String {
        var object: [String: Any] = [
            "schemaVersion": SwiftFeatureManifest.currentSchemaVersion,
            "id": id, "displayName": displayName, "description": description,
            "enabled": enabled, "executable": ".build/release/\(id)",
            "toolNamePrefixes": toolNamePrefixes,
            "build": ["system": "swiftpm", "packagePath": ".", "product": id, "configuration": "release", "executablePath": ".build/release/\(id)"],
            "generated": ["by": "ZenCODE", "createdAt": ISO8601DateFormatter().string(from: Date()), "promotionReady": promotionReady],
            "tools": tools
        ]
        if discoversToolsAtRuntime {
            object["discoversToolsAtRuntime"] = true
            object["toolNameAliases"] = []
        }
        let data = try JSONValue(jsonObject: object).jsonData(
            outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func toolNamePrefix(from toolName: String) -> String {
        guard let dotIndex = toolName.lastIndex(of: ".") else {
            return "\(toolName)."
        }
        return String(toolName[...dotIndex])
    }

    static func swiftStringArrayLiteral(_ values: [String]) -> String {
        let renderedValues = values
            .map(swiftStringLiteral)
            .joined(separator: ", ")
        return "[\(renderedValues)]"
    }

    static func swiftStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

}
