//
//  SwiftFeatureAdoptionTools.swift
//  ZenCODE
//

import Foundation

extension SwiftFeatureRuntime {
    func adoptFeature(
        arguments: [String: Any]
    ) throws -> SwiftFeatureAdoptReport {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature adoption is unavailable for an explicitly constructed runtime."
            )
        }

        let id = try Self.requiredFeatureID(arguments)
        guard Self.isValidFeatureID(id) else {
            throw DirectToolError.permissionDenied(
                "Feature id '\(id)' is invalid. Use letters, numbers, dots, underscores, and hyphens."
            )
        }

        guard let definition = Self.bundledFeatureDefinition(id: id) else {
            if SwiftFeatureRegistry.featureRecord(
                id: id,
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            ) != nil {
                throw DirectToolError.permissionDenied(
                    "Swift feature '\(id)' is already generated and can be edited directly."
                )
            }
            throw DirectToolError.permissionDenied("Unknown bundled Swift feature: \(id).")
        }

        guard !definition.isCore else {
            throw DirectToolError.permissionDenied(
                "Core Swift feature '\(id)' cannot be adopted or modified."
            )
        }

        let existingGeneratedRecord = SwiftFeatureRegistry.featureRecord(
            id: id,
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        )
        let overwrite = arguments.bool("overwrite") ?? false
        if existingGeneratedRecord != nil, !overwrite {
            throw DirectToolError.permissionDenied(
                "Generated Swift feature '\(id)' already exists. Pass overwrite=true to replace it."
            )
        }

        let sourceDirectoryURL = try bundledFeatureSourceDirectory(
            definition: definition,
            arguments: arguments
        )
        let zenPackageRootURL = try zenCODEPackageRootURL(arguments: arguments)
        let destinationDirectoryURL = featureRootURL()
            .appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL
        let targetName = Self.targetName(for: id)
        let targetDirectoryURL = destinationDirectoryURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(targetName, isDirectory: true)
        let packageURL = destinationDirectoryURL.appendingPathComponent("Package.swift")
        let manifestURL = destinationDirectoryURL
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)

        guard Self.path(destinationDirectoryURL, isDescendantOf: featureRootURL()),
              destinationDirectoryURL.path != featureRootURL().path else {
            throw DirectToolError.permissionDenied(
                "Feature adoption can only create packages under the generated features directory: \(featureRootURL().path)."
            )
        }

        if fileManager.fileExists(atPath: destinationDirectoryURL.path) {
            guard overwrite else {
                throw DirectToolError.permissionDenied(
                    "Generated Swift feature '\(id)' already exists at \(destinationDirectoryURL.path). Pass overwrite=true to replace it."
                )
            }
            try fileManager.removeItem(at: destinationDirectoryURL)
        }

        try fileManager.createDirectory(
            at: targetDirectoryURL,
            withIntermediateDirectories: true
        )
        try copyFeatureDirectoryContents(
            from: sourceDirectoryURL,
            to: targetDirectoryURL
        )
        try Self.adoptedPackageManifestContents(
            productName: id,
            targetName: targetName,
            zenPackagePath: zenPackageRootURL.path
        ).write(to: packageURL, atomically: true, encoding: .utf8)

        let state = SwiftFeatureStateStore.load(fileManager: fileManager)
        let enabled = arguments.bool("enabled")
            ?? existingGeneratedRecord?.manifestEnabled
            ?? state.bundledFeatureIsEnabled(id: id)
        try Self.adoptedFeatureManifestContents(
            definition: definition,
            displayName: Self.adoptedDisplayName(for: definition.id),
            enabled: enabled
        ).write(to: manifestURL, atomically: true, encoding: .utf8)

        let sourcePaths = swiftSourcePaths(in: targetDirectoryURL)
        return SwiftFeatureAdoptReport(
            ok: true,
            id: id,
            adoptedFrom: id,
            sourcePath: sourceDirectoryURL.path,
            destinationPath: destinationDirectoryURL.path,
            manifestPath: manifestURL.path,
            packagePath: packageURL.path,
            sourcePaths: sourcePaths,
            enabled: enabled,
            copied: true
        )
    }

    func editFeature(
        arguments: [String: Any]
    ) throws -> SwiftFeatureEditReport {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature editing is unavailable for an explicitly constructed runtime."
            )
        }

        let id = try Self.requiredFeatureID(arguments)
        if let definition = Self.bundledFeatureDefinition(id: id), definition.isCore {
            throw DirectToolError.permissionDenied(
                "Core Swift feature '\(id)' cannot be modified."
            )
        }

        var adoptReport: SwiftFeatureAdoptReport?
        var record = Self.defaultFeatureRecords(
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        ).first { $0.id == id }

        if let current = record, current.source == .bundled {
            guard !current.isCore else {
                throw DirectToolError.permissionDenied(
                    "Bundled Swift feature '\(id)' cannot be edited."
                )
            }
            guard arguments.bool("adopt", "fork") ?? true else {
                throw DirectToolError.permissionDenied(
                    "Bundled Swift feature '\(id)' must be copied into the generated feature root before editing."
                )
            }
            adoptReport = try adoptFeature(arguments: arguments)
            record = SwiftFeatureRegistry.featureRecord(
                id: id,
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            )
        }

        guard let record,
              record.source == .generated,
              let manifestURL = record.manifestURL else {
            throw DirectToolError.permissionDenied("Unknown editable Swift feature: \(id).")
        }

        return editReport(for: record, manifestURL: manifestURL, adoptReport: adoptReport)
    }

    private func editReport(
        for record: SwiftFeatureRecord,
        manifestURL: URL,
        adoptReport: SwiftFeatureAdoptReport?
    ) -> SwiftFeatureEditReport {
        let featureDirectoryURL = manifestURL.deletingLastPathComponent().standardizedFileURL
        let packageDirectoryURL = record.build.map {
            Self.resolveBuildPackageDirectory(
                build: $0,
                featureDirectoryURL: featureDirectoryURL
            )
        } ?? featureDirectoryURL
        let packageURL = packageDirectoryURL.appendingPathComponent("Package.swift")
        let packagePath = fileManager.fileExists(atPath: packageURL.path) ? packageURL.path : nil
        let sourceRootURL = packageDirectoryURL.appendingPathComponent("Sources", isDirectory: true)
        let sourcePaths = swiftSourcePaths(
            in: fileManager.fileExists(atPath: sourceRootURL.path) ? sourceRootURL : featureDirectoryURL
        )

        var warnings: [String] = []
        if let adoptedFrom = record.adoptedFrom {
            warnings.append(
                "This feature is a local editable copy of bundled feature '\(adoptedFrom)'; future app updates will not update this local copy automatically."
            )
        }
        if !record.executableAvailable {
            warnings.append("Executable has not been built yet: \(record.executableURL.path)")
        }

        return SwiftFeatureEditReport(
            ok: true,
            id: record.id,
            source: record.source,
            adopted: adoptReport != nil,
            adoptedFrom: record.adoptedFrom,
            directoryPath: featureDirectoryURL.path,
            manifestPath: manifestURL.path,
            packagePath: packagePath,
            sourcePaths: sourcePaths,
            executablePath: record.executableURL.path,
            enabled: record.manifestEnabled,
            instructions: [
                "Edit the Swift package in directoryPath using the file editing tools.",
                "Keep the feature id and tool names stable unless the user explicitly asks to rename them.",
                "Run feature.validate for '\(record.id)' after edits.",
                "Run feature.build for '\(record.id)' when validation passes.",
                "Run feature.reload after a successful build so the current session sees the updated tools."
            ],
            warnings: warnings,
            adopt: adoptReport
        )
    }

    private func bundledFeatureSourceDirectory(
        definition: BundledFeatureDefinition,
        arguments: [String: Any]
    ) throws -> URL {
        if let rawSourcePath = arguments
            .string("sourcePath", "source_path")?
            .nilIfBlank {
            let sourceURL = resolvedInstallPath(rawSourcePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw DirectToolError.permissionDenied(
                    "Bundled feature source directory not found: \(sourceURL.path)"
                )
            }
            return sourceURL
        }

        guard let sourceRelativePath = definition.sourceRelativePath else {
            throw DirectToolError.permissionDenied(
                "Bundled Swift feature '\(definition.id)' does not declare a source directory for adoption."
            )
        }
        let packageRootURL = try zenCODEPackageRootURL(arguments: arguments)
        let sourceURL = packageRootURL
            .appendingPathComponent(sourceRelativePath, isDirectory: true)
            .standardizedFileURL
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DirectToolError.permissionDenied(
                "Bundled feature source directory not found: \(sourceURL.path). Pass sourcePath to adopt from an explicit source checkout."
            )
        }
        return sourceURL
    }

    private func zenCODEPackageRootURL(arguments: [String: Any]) throws -> URL {
        if let rawPackagePath = arguments
            .string("zenPackagePath", "zen_package_path", "dependencyPath", "dependency_path")?
            .nilIfBlank {
            let packageURL = resolvedInstallPath(rawPackagePath)
            guard fileManager.fileExists(
                atPath: packageURL.appendingPathComponent("Package.swift").path
            ) else {
                throw DirectToolError.permissionDenied(
                    "ZenCODE package root not found at \(packageURL.path)."
                )
            }
            return packageURL
        }

        if let packageURL = Self.sourcePackageRootURL(fileManager: fileManager) {
            return packageURL
        }

        let workingDirectoryURL = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        if fileManager.fileExists(
            atPath: workingDirectoryURL.appendingPathComponent("Package.swift").path
        ) {
            return workingDirectoryURL
        }

        throw DirectToolError.permissionDenied(
            "Could not locate a ZenCODE source checkout to adopt bundled feature sources. Pass zenPackagePath or sourcePath."
        )
    }

    private func swiftSourcePaths(in rootURL: URL) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else {
                continue
            }
            paths.append(url.standardizedFileURL.path)
        }
        return paths.sorted()
    }

    static func adoptedPackageManifestContents(
        productName: String,
        targetName: String,
        zenPackagePath: String
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
                .package(path: \(swiftStringLiteral(zenPackagePath)))
            ],
            targets: [
                .executableTarget(
                    name: "\(targetName)",
                    dependencies: [
                        .product(name: "FeatureKit", package: "ZenCODE"),
                        .product(name: "ToolCore", package: "ZenCODE"),
                        .product(name: "FeatureMCPBridgeKit", package: "ZenCODE")
                    ]
                )
            ]
        )
        """
    }

    static func adoptedFeatureManifestContents(
        definition: BundledFeatureDefinition,
        displayName: String,
        enabled: Bool
    ) throws -> String {
        var object: [String: Any] = [
            "schemaVersion": SwiftFeatureManifest.currentSchemaVersion,
            "id": definition.id,
            "displayName": displayName,
            "description": definition.description ?? "Adopted Swift feature for ZenCODE.",
            "enabled": enabled,
            "executable": ".build/release/\(definition.id)",
            "discoversToolsAtRuntime": definition.discoversToolsAtRuntime,
            "build": [
                "system": "swiftpm",
                "packagePath": ".",
                "product": definition.id,
                "configuration": "release",
                "executablePath": ".build/release/\(definition.id)"
            ],
            "generated": [
                "by": "ZenCODE",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "adoptedFrom": definition.id
            ],
            "tools": definition.tools.map(Self.manifestToolObject)
        ]
        if !definition.toolNamePrefixes.isEmpty {
            object["toolNamePrefixes"] = definition.toolNamePrefixes
        }
        if !definition.toolNameAliases.isEmpty {
            object["toolNameAliases"] = definition.toolNameAliases
        }
        let data = try JSONValue(jsonObject: object).jsonData(
            outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func manifestToolObject(_ tool: ToolDescriptor) -> [String: Any] {
        var object: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": tool.inputSchema
        ]
        if let title = tool.title?.nilIfBlank {
            object["title"] = title
        }
        if let outputSchema = tool.outputSchema?.nilIfBlank {
            object["outputSchema"] = outputSchema
        }
        return object
    }

    private static func adoptedDisplayName(for id: String) -> String {
        let base = id.hasSuffix("-tools")
            ? String(id.dropLast("-tools".count))
            : id
        let words = base
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
        let displayName = words
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
        return displayName.nilIfBlank ?? id
    }
}
