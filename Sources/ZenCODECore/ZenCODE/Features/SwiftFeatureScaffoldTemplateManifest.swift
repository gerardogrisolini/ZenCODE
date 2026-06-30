//
//  SwiftFeatureScaffoldTemplateManifest.swift
//  ZenCODE
//

import Foundation

extension SwiftFeatureRuntime {
    static func featureManifestContents(
        id: String,
        displayName: String,
        description: String,
        toolName: String,
        enabled: Bool
    ) throws -> String {
        let object: [String: Any] = [
            "schemaVersion": SwiftFeatureManifest.currentSchemaVersion,
            "id": id,
            "displayName": displayName,
            "description": description,
            "enabled": enabled,
            "executable": ".build/release/\(id)",
            "toolNamePrefixes": [toolNamePrefix(from: toolName)],
            "build": [
                "system": "swiftpm",
                "packagePath": ".",
                "product": id,
                "configuration": "release",
                "executablePath": ".build/release/\(id)"
            ],
            "generated": [
                "by": "ZenCODE",
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ],
            "tools": [
                [
                    "name": toolName,
                    "description": "Echoes the provided text. Replace this implementation with the generated feature logic.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "text": [
                                "type": "string"
                            ]
                        ],
                        "required": ["text"]
                    ]
                ]
            ]
        ]
        let data = try JSONValue(jsonObject: object).jsonData(
            outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func mcpBridgeFeatureManifestContents(
        id: String,
        displayName: String,
        description: String,
        toolPrefix: String,
        enabled: Bool
    ) throws -> String {
        let object: [String: Any] = [
            "schemaVersion": SwiftFeatureManifest.currentSchemaVersion,
            "id": id,
            "displayName": displayName,
            "description": description,
            "enabled": enabled,
            "executable": ".build/release/\(id)",
            "discoversToolsAtRuntime": true,
            "toolNamePrefixes": [toolPrefix],
            "toolNameAliases": [],
            "build": [
                "system": "swiftpm",
                "packagePath": ".",
                "product": id,
                "configuration": "release",
                "executablePath": ".build/release/\(id)"
            ],
            "generated": [
                "by": "ZenCODE",
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ],
            "tools": []
        ]
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

    static func swiftStringDictionaryLiteral(_ values: [String: String]) -> String {
        guard !values.isEmpty else {
            return "[:]"
        }
        let renderedValues = values
            .sorted { $0.key < $1.key }
            .map { "\(swiftStringLiteral($0.key)): \(swiftStringLiteral($0.value))" }
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
