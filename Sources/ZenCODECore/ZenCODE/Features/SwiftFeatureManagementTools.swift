//
//  SwiftFeatureManagementTools.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation

extension SwiftFeatureRuntime {
    public func executeManagementTool(
        toolCall: DirectAgentToolCall
    ) async throws -> String {
        let arguments = toolCall.argumentsObject
        switch toolCall.name {
        case "feature.list":
            let includeTools = arguments.bool("includeTools", "include_tools") ?? true
            let includeDisabled = arguments.bool("includeDisabled", "include_disabled") ?? true
            let discoverRuntimeTools = arguments.bool("discoverRuntimeTools", "discover_runtime_tools") ?? false
            return try await renderFeatureList(
                includeTools: includeTools,
                includeDisabled: includeDisabled,
                discoverRuntimeTools: discoverRuntimeTools
            )
        case "feature.enable":
            let id = try Self.requiredFeatureID(arguments)
            try await setFeature(id: id, enabled: true)
            return try await renderFeatureMutation(
                action: "enabled",
                id: id
            )
        case "feature.disable":
            let id = try Self.requiredFeatureID(arguments)
            try await setFeature(id: id, enabled: false)
            return try await renderFeatureMutation(
                action: "disabled",
                id: id
            )
        case "feature.delete":
            let report = try await deleteFeature(arguments: arguments)
            reloadFeatureBundles()
            return try renderJSON(report)
        case "feature.reload":
            reloadFeatureBundles()
            return try await renderFeatureList(
                prefix: "Reloaded Swift features.",
                includeTools: arguments.bool("includeTools", "include_tools") ?? true,
                includeDisabled: arguments.bool("includeDisabled", "include_disabled") ?? true,
                discoverRuntimeTools: arguments.bool("discoverRuntimeTools", "discover_runtime_tools") ?? false
            )
        case "feature.validate":
            return try renderJSON(
                validateFeature(arguments: arguments)
            )
        case "feature.build":
            let report = try await buildFeature(arguments: arguments)
            if report.ok {
                reloadFeatureBundles()
            }
            return try renderJSON(report)
        case "feature.scaffold":
            return try renderJSON(
                scaffoldFeature(arguments: arguments)
            )
        case "feature.install":
            let report = try await installFeature(arguments: arguments)
            if report.ok {
                reloadFeatureBundles()
            }
            return try renderJSON(report)
        default:
            throw DirectToolError.unknownTool(toolCall.name)
        }
    }

    private func setFeature(id: String, enabled: Bool) async throws {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature enable/disable is unavailable for an explicitly constructed runtime."
            )
        }

        let bundledIDs = Set(Self.bundledFeatureDefinitions().map(\.id))
        if bundledIDs.contains(id) {
            try SwiftFeatureStateStore.setBundledFeature(
                id: id,
                enabled: enabled,
                fileManager: fileManager
            )
            reloadFeatureBundles()
            return
        }

        guard let record = SwiftFeatureRegistry
            .discoverFeatureRecords(
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            )
            .first(where: { $0.id == id }),
            let manifestURL = record.manifestURL else {
            throw DirectToolError.permissionDenied("Unknown Swift feature: \(id).")
        }

        try SwiftFeatureRegistry.setFeatureManifestEnabled(
            manifestURL: manifestURL,
            enabled: enabled,
            fileManager: fileManager
        )
        reloadFeatureBundles()
    }

    private func validateFeature(
        arguments: [String: Any]
    ) throws -> SwiftFeatureValidationReport {
        let manifestURL = try featureManifestURL(arguments: arguments)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return SwiftFeatureValidationReport(
                id: arguments.string("id", "featureID", "feature_id", "name"),
                manifestPath: manifestURL.path,
                executablePath: nil,
                errors: ["Feature manifest not found: \(manifestURL.path)"],
                warnings: [],
                tools: []
            )
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest: SwiftFeatureManifest
        do {
            manifest = try JSONDecoder().decode(SwiftFeatureManifest.self, from: data)
        } catch {
            return SwiftFeatureValidationReport(
                id: nil,
                manifestPath: manifestURL.path,
                executablePath: nil,
                errors: ["Invalid feature manifest: \(error.localizedDescription)"],
                warnings: [],
                tools: []
            )
        }

        var errors: [String] = []
        var warnings: [String] = []
        let featureDirectoryURL = manifestURL.deletingLastPathComponent()
        let executableURL = SwiftFeatureRegistry.resolvedExecutableURL(
            manifest.executable,
            relativeTo: featureDirectoryURL
        )
        let toolNames = manifest.tools.map(\.name)

        if !Self.isValidFeatureID(manifest.id) {
            errors.append("Feature id '\(manifest.id)' is invalid. Use letters, numbers, dots, underscores, and hyphens.")
        }
        if manifest.schemaVersion > SwiftFeatureManifest.currentSchemaVersion {
            errors.append("Unsupported feature schemaVersion \(manifest.schemaVersion). Current supported version is \(SwiftFeatureManifest.currentSchemaVersion).")
        }
        if manifest.enabled,
           !fileManager.isExecutableFile(atPath: executableURL.path) {
            errors.append("Executable is missing or not executable: \(executableURL.path)")
        } else if !fileManager.fileExists(atPath: executableURL.path) {
            warnings.append("Executable has not been built yet: \(executableURL.path)")
        }
        if manifest.tools.isEmpty,
           !manifest.discoversToolsAtRuntime {
            errors.append("Feature must declare at least one tool or set discoversToolsAtRuntime=true.")
        }
        if manifest.discoversToolsAtRuntime,
           manifest.toolNamePrefixes.isEmpty,
           manifest.toolNameAliases.isEmpty,
           manifest.tools.isEmpty {
            warnings.append("Runtime-discovered feature has no toolNamePrefixes or toolNameAliases; declare a prefix or alias so it can be selected explicitly.")
        }

        errors.append(contentsOf: Self.validationErrorsForToolNames(toolNames))

        if let build = manifest.build {
            if build.system.lowercased() != "swiftpm" {
                errors.append("Unsupported build system '\(build.system)'. Only swiftpm is currently supported.")
            }
            let packageDirectoryURL = Self.resolveBuildPackageDirectory(
                build: build,
                featureDirectoryURL: featureDirectoryURL
            )
            errors.append(contentsOf: Self.validatePackageSwiftToolsVersion(
                packageDirectoryURL: packageDirectoryURL
            ))
        }

        return SwiftFeatureValidationReport(
            id: manifest.id,
            manifestPath: manifestURL.path,
            executablePath: executableURL.path,
            errors: errors,
            warnings: warnings,
            tools: toolNames.sorted()
        )
    }

    private func buildFeature(
        arguments: [String: Any]
    ) async throws -> SwiftFeatureBuildReport {
        let manifestURL = try featureManifestURL(arguments: arguments)
        guard let record = SwiftFeatureRegistry.featureRecord(
            manifestURL: manifestURL,
            fileManager: fileManager
        ) else {
            throw DirectToolError.permissionDenied(
                "Feature manifest is missing or invalid: \(manifestURL.path)"
            )
        }

        let validationReport = try validateFeature(
            arguments: ["manifestPath": manifestURL.path]
        )
        let blockingErrors = validationReport.errors.filter {
            !$0.hasPrefix("Executable is missing or not executable:")
        }
        guard blockingErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature validation failed before build:\n\(blockingErrors.joined(separator: "\n"))"
            )
        }

        let build = record.build ?? SwiftFeatureBuildManifest(
            product: record.id,
            configuration: "release",
            executablePath: record.executableURL.path
        )
        guard build.system.lowercased() == "swiftpm" else {
            throw DirectToolError.permissionDenied(
                "Unsupported build system '\(build.system)'. Only swiftpm is currently supported."
            )
        }

        let featureDirectoryURL = manifestURL.deletingLastPathComponent()
        let packageDirectoryURL = Self.resolveBuildPackageDirectory(
            build: build,
            featureDirectoryURL: featureDirectoryURL
        )
        let toolsVersionErrors = Self.validatePackageSwiftToolsVersion(
            packageDirectoryURL: packageDirectoryURL
        )
        guard toolsVersionErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                toolsVersionErrors.joined(separator: "\n")
            )
        }

        let configuration = build.configuration ?? "release"
        let product = build.product ?? record.id
        let commandArguments = [
            "build",
            "-c",
            configuration,
            "--product",
            product
        ] + build.arguments
        let timeout = TimeInterval(arguments.int("timeoutSeconds", "timeout") ?? 300)
        let result = try await AsyncProcessRunner.run(
            executableURL: Self.swiftExecutableURL(fileManager: fileManager),
            arguments: commandArguments,
            workingDirectory: packageDirectoryURL,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: timeout
        )
        let executableAvailable = fileManager.isExecutableFile(
            atPath: record.executableURL.path
        )

        return SwiftFeatureBuildReport(
            ok: result.exitCode == 0 && executableAvailable,
            id: record.id,
            command: ["swift"] + commandArguments,
            workingDirectory: packageDirectoryURL.path,
            executablePath: record.executableURL.path,
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            stdout: result.stdout,
            stderr: executableAvailable
                ? result.stderr
                : result.stderr + "\nExecutable not found after build: \(record.executableURL.path)"
        )
    }

    private func scaffoldFeature(
        arguments: [String: Any]
    ) throws -> SwiftFeatureScaffoldReport {
        let id = try Self.requiredFeatureID(arguments)
        guard Self.isValidFeatureID(id) else {
            throw DirectToolError.permissionDenied(
                "Feature id '\(id)' is invalid. Use letters, numbers, dots, underscores, and hyphens."
            )
        }

        let directoryURL = try scaffoldDirectoryURL(id: id, arguments: arguments)
        let manifestURL = directoryURL.appendingPathComponent(
            SwiftFeatureRegistry.manifestFilename
        )
        let overwrite = arguments.bool("overwrite") ?? false
        if fileManager.fileExists(atPath: manifestURL.path),
           !overwrite {
            throw DirectToolError.permissionDenied(
                "Feature already exists at \(directoryURL.path). Pass overwrite=true to replace scaffold files."
            )
        }

        let template = Self.scaffoldTemplate(arguments: arguments)
        let displayName = arguments.string("displayName", "display_name", "name")?.nilIfBlank ?? id
        let description = arguments.string("description")?.nilIfBlank
            ?? Self.defaultScaffoldDescription(template: template, displayName: displayName)
        let targetName = Self.targetName(for: id)
        let productName = id
        let sourceDirectoryURL = directoryURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(targetName, isDirectory: true)
        let packageURL = directoryURL.appendingPathComponent("Package.swift")
        let sourceURL = sourceDirectoryURL.appendingPathComponent("main.swift")

        try fileManager.createDirectory(
            at: sourceDirectoryURL,
            withIntermediateDirectories: true
        )

        let reportToolName: String
        switch template {
        case .basic:
            let toolName = arguments
                .string("toolName", "tool_name")?
                .nilIfBlank ?? "\(Self.defaultToolPrefix(for: id)).echo"
            let toolErrors = Self.validationErrorsForToolNames([toolName])
            guard toolErrors.isEmpty else {
                throw DirectToolError.permissionDenied(toolErrors.joined(separator: "\n"))
            }
            try Self.packageManifestContents(
                productName: productName,
                targetName: targetName
            ).write(to: packageURL, atomically: true, encoding: .utf8)
            try Self.featureMainContents(
                toolName: toolName,
                toolDescription: "Echoes the provided text. Replace this implementation with the generated feature logic."
            ).write(to: sourceURL, atomically: true, encoding: .utf8)
            try Self.featureManifestContents(
                id: id,
                displayName: displayName,
                description: description,
                toolName: toolName,
                enabled: arguments.bool("enabled") ?? false
            ).write(to: manifestURL, atomically: true, encoding: .utf8)
            reportToolName = toolName
        case .mcpBridge:
            let toolPrefix = Self.normalizedToolPrefix(
                arguments.string("toolPrefix", "tool_prefix", "prefix")?
                    .nilIfBlank ?? "\(Self.defaultToolPrefix(for: id))."
            )
            try Self.validateMCPBridgeToolPrefix(toolPrefix)
            let packagePath = arguments
                .string("mlxServerPackagePath", "mlx_server_package_path", "dependencyPath", "dependency_path")?
                .nilIfBlank ?? Self.defaultMLXServerPackagePath(fileManager: fileManager)
            let serviceName = arguments
                .string("serviceName", "service_name")?
                .nilIfBlank ?? displayName
            try Self.mcpBridgePackageManifestContents(
                productName: productName,
                targetName: targetName,
                mlxServerPackagePath: packagePath
            ).write(to: packageURL, atomically: true, encoding: .utf8)
            try Self.mcpBridgeMainContents(
                serviceName: serviceName,
                toolPrefix: toolPrefix,
                endpointURLString: arguments.string("endpointURL", "endpoint_url", "url")?.nilIfBlank,
                executablePath: arguments.string("executablePath", "executable_path", "command")?.nilIfBlank,
                arguments: Self.stringArrayArgument(
                    arguments,
                    keys: ["arguments", "args", "commandArguments", "command_arguments"]
                ),
                environment: Self.stringDictionaryArgument(
                    arguments,
                    keys: ["environment", "env"]
                )
            ).write(to: sourceURL, atomically: true, encoding: .utf8)
            try Self.mcpBridgeFeatureManifestContents(
                id: id,
                displayName: displayName,
                description: description,
                toolPrefix: toolPrefix,
                enabled: arguments.bool("enabled") ?? false
            ).write(to: manifestURL, atomically: true, encoding: .utf8)
            reportToolName = toolPrefix
        }

        return SwiftFeatureScaffoldReport(
            id: id,
            directoryPath: directoryURL.path,
            manifestPath: manifestURL.path,
            packagePath: packageURL.path,
            sourcePath: sourceURL.path,
            toolName: reportToolName
        )
    }

    private func installFeature(
        arguments: [String: Any]
    ) async throws -> SwiftFeatureInstallReport {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature install is unavailable for an explicitly constructed runtime."
            )
        }

        let sourceManifestURL = try installSourceManifestURL(arguments: arguments)
        guard fileManager.fileExists(atPath: sourceManifestURL.path) else {
            throw DirectToolError.permissionDenied(
                "Feature manifest not found: \(sourceManifestURL.path)"
            )
        }
        let sourceDirectoryURL = sourceManifestURL.deletingLastPathComponent()
        let sourceManifest = try JSONDecoder().decode(
            SwiftFeatureManifest.self,
            from: Data(contentsOf: sourceManifestURL)
        )
        let id = arguments.string("id", "featureID", "feature_id", "name")?.nilIfBlank ?? sourceManifest.id
        guard id == sourceManifest.id else {
            throw DirectToolError.permissionDenied(
                "feature.install id '\(id)' does not match manifest id '\(sourceManifest.id)'."
            )
        }
        guard Self.isValidFeatureID(id) else {
            throw DirectToolError.permissionDenied(
                "Feature id '\(id)' is invalid. Use letters, numbers, dots, underscores, and hyphens."
            )
        }

        let destinationDirectoryURL = featureRootURL()
            .appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL
        let destinationManifestURL = destinationDirectoryURL
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
        let copied = try installFeatureDirectory(
            sourceDirectoryURL: sourceDirectoryURL,
            destinationDirectoryURL: destinationDirectoryURL,
            overwrite: arguments.bool("overwrite") ?? false
        )

        try SwiftFeatureRegistry.setFeatureManifestEnabled(
            manifestURL: destinationManifestURL,
            enabled: false,
            fileManager: fileManager
        )

        let shouldBuild = arguments.bool("build") ?? true
        let shouldEnable = arguments.bool("enable") ?? true
        let buildReport: SwiftFeatureBuildReport?
        if shouldBuild {
            var buildArguments: [String: Any] = [
                "manifestPath": destinationManifestURL.path
            ]
            if let timeout = arguments.int("timeoutSeconds", "timeout") {
                buildArguments["timeoutSeconds"] = timeout
            }
            buildReport = try await buildFeature(arguments: buildArguments)
        } else {
            buildReport = nil
        }

        if shouldEnable,
           buildReport?.ok ?? !shouldBuild {
            try await setFeature(id: id, enabled: true)
        } else {
            reloadFeatureBundles()
        }

        let validation = try validateFeature(
            arguments: ["manifestPath": destinationManifestURL.path]
        )
        return SwiftFeatureInstallReport(
            ok: validation.ok && (buildReport?.ok ?? true) && (!shouldEnable || validation.errors.isEmpty),
            id: id,
            sourcePath: sourceDirectoryURL.path,
            destinationPath: destinationDirectoryURL.path,
            manifestPath: destinationManifestURL.path,
            copied: copied,
            built: buildReport?.ok ?? false,
            enabled: shouldEnable && validation.errors.isEmpty && (buildReport?.ok ?? !shouldBuild),
            validation: validation,
            build: buildReport
        )
    }

    private func deleteFeature(
        arguments: [String: Any]
    ) async throws -> SwiftFeatureDeleteReport {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature delete is unavailable for an explicitly constructed runtime."
            )
        }

        let id = try Self.requiredFeatureID(arguments)
        let bundledIDs = Set(Self.bundledFeatureDefinitions().map(\.id))
        guard !bundledIDs.contains(id) else {
            throw DirectToolError.permissionDenied(
                "Bundled Swift feature '\(id)' cannot be deleted. Use feature.disable instead."
            )
        }

        guard let record = SwiftFeatureRegistry.featureRecord(
            id: id,
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        ),
            let manifestURL = record.manifestURL else {
            throw DirectToolError.permissionDenied("Unknown generated Swift feature: \(id).")
        }

        let rootURLs = featureRootURLs()
        let directoryURL = manifestURL.deletingLastPathComponent().standardizedFileURL
        guard rootURLs.contains(where: { Self.path(directoryURL, isDescendantOf: $0) }),
              !rootURLs.contains(where: { $0.path == directoryURL.path }) else {
            throw DirectToolError.permissionDenied(
                "feature.delete can only remove generated feature packages under the configured features directory."
            )
        }

        try fileManager.removeItem(at: directoryURL)
        return SwiftFeatureDeleteReport(
            ok: true,
            id: id,
            directoryPath: directoryURL.path,
            manifestPath: manifestURL.path,
            removed: true,
            wasEnabled: record.manifestEnabled
        )
    }

    private func reloadFeatureBundles() {
        runtimeDiscoveredToolsByFeatureID.removeAll()
        features = explicitFeatures ?? Self.defaultFeatureBundles(
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        )
    }
}
