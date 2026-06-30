//
//  SwiftFeatureScaffoldTemplates.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//
import Foundation

extension SwiftFeatureRuntime {
    enum ScaffoldTemplate {
        case basic
        case mcpBridge
    }

    static func scaffoldTemplate(arguments: [String: Any]) -> ScaffoldTemplate {
        let rawValue = arguments
            .string("template", "kind", "scaffoldTemplate", "scaffold_template")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch rawValue {
        case "mcp", "mcp-bridge", "mcp_bridge", "mcpbridge":
            return .mcpBridge
        default:
            return .basic
        }
    }

    static func defaultScaffoldDescription(
        template: ScaffoldTemplate,
        displayName: String
    ) -> String {
        switch template {
        case .basic:
            return "Swift feature generated for ZenCODE."
        case .mcpBridge:
            return "Swift MCP bridge feature for \(displayName)."
        }
    }

    static func normalizedToolPrefix(_ rawPrefix: String) -> String {
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else {
            return prefix
        }
        return prefix.hasSuffix(".") ? prefix : "\(prefix)."
    }

    static func validateMCPBridgeToolPrefix(_ prefix: String) throws {
        guard prefix.nilIfBlank != nil else {
            throw DirectToolError.permissionDenied("MCP bridge toolPrefix cannot be empty.")
        }
        if prefix.hasPrefix("feature.") {
            throw DirectToolError.permissionDenied(
                "Tool namespace 'feature.' is reserved for kernel feature management: \(prefix)"
            )
        }
        if prefix.hasPrefix("local.") || prefix.hasPrefix("text.") {
            throw DirectToolError.permissionDenied(
                "Tool prefix '\(prefix)' conflicts with a core tool namespace."
            )
        }
    }

    static func defaultMLXServerPackagePath(fileManager: FileManager) -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        if fileManager.fileExists(
            atPath: sourceURL.appendingPathComponent("Package.swift").path
        ) {
            return sourceURL.path
        }

        let workingDirectoryURL = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        if fileManager.fileExists(
            atPath: workingDirectoryURL.appendingPathComponent("Package.swift").path
        ) {
            return workingDirectoryURL.path
        }

        return sourceURL.path
    }

    static func stringArrayArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> [String] {
        for key in keys {
            if let values = arguments[key] as? [String] {
                return values.compactMap(\.nilIfBlank)
            }
            if let values = arguments[key] as? [Any] {
                return values.compactMap { value in
                    String(describing: value).nilIfBlank
                }
            }
            if let value = arguments[key] as? String {
                let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedValue.isEmpty else {
                    return []
                }
                if trimmedValue.contains("\n") {
                    return trimmedValue
                        .split(separator: "\n")
                        .compactMap { String($0).nilIfBlank }
                }
                return [trimmedValue]
            }
        }
        return []
    }

    static func stringDictionaryArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> [String: String] {
        for key in keys {
            if let values = arguments[key] as? [String: String] {
                return values.filter { !$0.key.isEmpty }
            }
            if let values = arguments[key] as? [String: Any] {
                var output: [String: String] = [:]
                for (entryKey, value) in values where !entryKey.isEmpty {
                    output[entryKey] = String(describing: value)
                }
                return output
            }
        }
        return [:]
    }

    static func targetName(for id: String) -> String {
        let words = id
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let name = words.map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined()
        guard let first = name.first, first.isLetter else {
            return "Feature\(name.nilIfBlank ?? "Generated")"
        }
        return name.nilIfBlank ?? "GeneratedFeature"
    }

    static func defaultToolPrefix(for id: String) -> String {
        let normalized = id
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        let value = String(normalized)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.nilIfBlank ?? "generated"
    }

    static func packageManifestContents(
        productName: String,
        targetName: String
    ) -> String {
        """
        // swift-tools-version: \(generatedSwiftToolsVersion)

        import PackageDescription

        let package = Package(
            name: "\(productName)",
            platforms: [
                .macOS(.v26)
            ],
            products: [
                .executable(
                    name: "\(productName)",
                    targets: ["\(targetName)"]
                )
            ],
            targets: [
                .executableTarget(
                    name: "\(targetName)"
                )
            ]
        )
        """
    }

    static func mcpBridgePackageManifestContents(
        productName: String,
        targetName: String,
        mlxServerPackagePath: String
    ) -> String {
        """
        // swift-tools-version: \(generatedSwiftToolsVersion)

        import PackageDescription

        let package = Package(
            name: "\(productName)",
            platforms: [
                .macOS(.v26)
            ],
            products: [
                .executable(
                    name: "\(productName)",
                    targets: ["\(targetName)"]
                )
            ],
            dependencies: [
                .package(path: \(swiftStringLiteral(mlxServerPackagePath)))
            ],
            targets: [
                .executableTarget(
                    name: "\(targetName)",
                    dependencies: [
                        .product(name: "ZenCODECore", package: "ZenCODE"),
                        .product(name: "FeatureKit", package: "ZenCODE")
                    ]
                )
            ]
        )
        """
    }

}
