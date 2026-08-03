//
//  SwiftFeatureManagementTools.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import FeatureKit
import Foundation
import ToolCore

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
            await reloadFeatureBundles()
            return try renderJSON(report)
        case "feature.edit", "feature.update":
            let report = try editFeature(arguments: arguments)
            if report.adopt != nil {
                await reloadFeatureBundles()
            }
            return try renderJSON(report)
        case "feature.reload":
            await reloadFeatureBundles()
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
                await reloadFeatureBundles()
            }
            return try renderJSON(report)
        case "feature.scaffold":
            let report = try await scaffoldFeature(arguments: arguments)
            return try renderJSON(report)
        case "feature.install":
            let report = try await installFeature(arguments: arguments)
            if report.ok {
                await reloadFeatureBundles()
            }
            return try renderJSON(report)
        default:
            throw DirectToolError.unknownTool(toolCall.name)
        }
    }

    func setFeature(id: String, enabled: Bool) async throws {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature enable/disable is unavailable for an explicitly constructed runtime."
            )
        }

        if let record = SwiftFeatureRegistry
            .discoverFeatureRecords(
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            )
            .first(where: { $0.id == id }),
            let manifestURL = record.manifestURL {
            if Self.bundledFeatureDefinition(id: id)?.isCore == true {
                throw DirectToolError.permissionDenied(
                    "Core Swift feature '\(id)' cannot be overridden by a generated feature."
                )
            }
            try SwiftFeatureRegistry.setFeatureManifestEnabled(
                manifestURL: manifestURL,
                enabled: enabled,
                fileManager: fileManager
            )
            await reloadFeatureBundles()
            return
        }

        let bundledIDs = Set(Self.bundledFeatureDefinitions().map(\.id))
        if bundledIDs.contains(id) {
            try SwiftFeatureStateStore.setBundledFeature(
                id: id,
                enabled: enabled,
                fileManager: fileManager
            )
            await reloadFeatureBundles()
            return
        }

        throw DirectToolError.permissionDenied("Unknown Swift feature: \(id).")
    }

    func validateFeature(
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
        if Self.bundledFeatureDefinition(id: manifest.id)?.isCore == true {
            errors.append("Core Swift feature id '\(manifest.id)' cannot be implemented by a generated feature.")
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
        errors.append(contentsOf: Self.validationErrorsForRouting(
            toolNamePrefixes: manifest.toolNamePrefixes,
            toolNameAliases: manifest.toolNameAliases
        ))

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

    func buildFeature(
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
        let baseEnvironment = ProcessInfo.processInfo.environment
        let swiftExecutableURL = try Self.swiftExecutableURL(
            fileManager: fileManager,
            environment: baseEnvironment
        )
        var processEnvironment = DeveloperToolEnvironment.processEnvironment(base: baseEnvironment)
        let swiftBinPath = swiftExecutableURL.deletingLastPathComponent().path
        let processSearchPaths = processEnvironment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        if !processSearchPaths.contains(swiftBinPath) {
            processEnvironment["PATH"] = ([swiftBinPath] + processSearchPaths)
                .joined(separator: ":")
        }
        let result: AsyncProcessResult
        do {
            result = try await AsyncProcessRunner.run(
                executableURL: swiftExecutableURL,
                arguments: commandArguments,
                workingDirectory: packageDirectoryURL,
                environment: processEnvironment,
                timeout: timeout
            )
        } catch {
            throw DirectToolError.processFailed(
                "Could not launch Swift at \(swiftExecutableURL.path) to build feature "
                    + "'\(record.id)' in \(packageDirectoryURL.path): \(error.localizedDescription)"
            )
        }
        let executableAvailable = fileManager.isExecutableFile(
            atPath: record.executableURL.path
        )

        guard result.exitCode == 0,
              executableAvailable,
              configuration.lowercased() == "release" else {
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

        let stripExecutableURL = URL(fileURLWithPath: "/usr/bin/strip")
        guard fileManager.isExecutableFile(atPath: stripExecutableURL.path) else {
            return SwiftFeatureBuildReport(
                ok: false,
                id: record.id,
                command: ["swift"] + commandArguments,
                workingDirectory: packageDirectoryURL.path,
                executablePath: record.executableURL.path,
                exitCode: 1,
                timedOut: false,
                stdout: result.stdout,
                stderr: result.stderr + "\nRelease builds require strip at \(stripExecutableURL.path)."
            )
        }

        let stripResult: AsyncProcessResult
        do {
            stripResult = try await AsyncProcessRunner.run(
                executableURL: stripExecutableURL,
                arguments: ["-S", record.executableURL.path],
                workingDirectory: packageDirectoryURL,
                environment: processEnvironment,
                timeout: timeout
            )
        } catch {
            return SwiftFeatureBuildReport(
                ok: false,
                id: record.id,
                command: ["swift"] + commandArguments,
                workingDirectory: packageDirectoryURL.path,
                executablePath: record.executableURL.path,
                exitCode: 1,
                timedOut: false,
                stdout: result.stdout,
                stderr: result.stderr + "\nCould not launch strip: \(error.localizedDescription)"
            )
        }

        return SwiftFeatureBuildReport(
            ok: stripResult.exitCode == 0 && !stripResult.timedOut,
            id: record.id,
            command: ["swift"] + commandArguments,
            workingDirectory: packageDirectoryURL.path,
            executablePath: record.executableURL.path,
            exitCode: stripResult.exitCode,
            timedOut: stripResult.timedOut,
            stdout: result.stdout + stripResult.stdout,
            stderr: result.stderr + stripResult.stderr
        )
    }

    private func scaffoldFeature(
        arguments: [String: Any]
    ) async throws -> SwiftFeatureScaffoldReport {
        let id = try Self.requiredFeatureID(arguments)
        guard Self.isValidFeatureID(id) else {
            throw DirectToolError.permissionDenied(
                "Feature id '\(id)' is invalid. Use letters, numbers, dots, underscores, and hyphens."
            )
        }
        let directoryURL = try scaffoldDirectoryURL(id: id, arguments: arguments)
        let finalManifestURL = directoryURL.appendingPathComponent(
            SwiftFeatureRegistry.manifestFilename
        )
        let overwrite = arguments.bool("overwrite") ?? false
        if fileManager.fileExists(atPath: directoryURL.path),
           !overwrite {
            throw DirectToolError.permissionDenied(
                "Feature already exists at \(directoryURL.path). Pass overwrite=true to replace scaffold files."
            )
        }

        // Render the scaffold outside the live destination. Once every file is
        // present, `installFeatureDirectory` publishes the complete sibling
        // staging directory with rollback, so an overwrite can never expose a
        // half-written Package.swift/source/manifest set.
        let stagingDirectoryURL = directoryURL.deletingLastPathComponent()
            .appendingPathComponent(".zencode-feature-scaffold-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingDirectoryURL) }
        let manifestURL = stagingDirectoryURL.appendingPathComponent(
            SwiftFeatureRegistry.manifestFilename
        )

        let template = Self.scaffoldTemplate(arguments: arguments)
        let displayName = arguments.string("displayName", "display_name", "name")?.nilIfBlank ?? id
        let description = arguments.string("description")?.nilIfBlank
            ?? Self.defaultScaffoldDescription(template: template, displayName: displayName)
        let targetName = Self.targetName(for: id)
        let productName = id
        let sourceDirectoryURL = stagingDirectoryURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(targetName, isDirectory: true)
        let packageURL = stagingDirectoryURL.appendingPathComponent("Package.swift")
        let sourceURL = sourceDirectoryURL.appendingPathComponent("main.swift")
        let packagePath = arguments
            .string("dependencyPath", "dependency_path")?
            .nilIfBlank ?? Self.defaultPackagePath(fileManager: fileManager)

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
                targetName: targetName,
                packagePath: packagePath
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
            let endpointURLString = arguments
                .string("endpointURL", "endpoint_url", "url")?
                .nilIfBlank
            if let endpointURLString,
               let endpointIssue = Self.mcpBridgeEndpointIssue(endpointURLString) {
                switch endpointIssue {
                case .invalidHTTPURL:
                    throw DirectToolError.permissionDenied(
                        "MCP bridge endpointURL must be an absolute http:// or https:// URL."
                    )
                case .embeddedCredentials:
                    throw DirectToolError.permissionDenied(
                        "MCP bridge endpointURL cannot contain credentials, tokens, API keys, passwords, signatures, or other secret query/fragment values. Configure secrets outside generated source."
                    )
                }
            }
            let hasStaticEnvironment = ["environment", "env"].contains { key in
                !Self.stringDictionaryArgument(arguments, keys: [key]).isEmpty
            }
            guard !hasStaticEnvironment else {
                throw DirectToolError.permissionDenied(
                    "MCP bridge scaffolds do not accept static environment values because scaffold configuration is written to generated source. Configure secrets in the environment used to launch ZenCODE; stdio bridges inherit it at runtime."
                )
            }
            let serviceName = arguments
                .string("serviceName", "service_name")?
                .nilIfBlank ?? displayName
            try Self.mcpBridgePackageManifestContents(
                productName: productName,
                targetName: targetName,
                packagePath: packagePath
            ).write(to: packageURL, atomically: true, encoding: .utf8)
            try Self.mcpBridgeMainContents(
                serviceName: serviceName,
                toolPrefix: toolPrefix,
                endpointURLString: endpointURLString,
                executablePath: arguments.string("executablePath", "executable_path", "command")?.nilIfBlank,
                arguments: Self.stringArrayArgument(
                    arguments,
                    keys: ["arguments", "args", "commandArguments", "command_arguments"]
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

        _ = try installFeatureDirectory(
            sourceDirectoryURL: stagingDirectoryURL,
            destinationDirectoryURL: directoryURL,
            overwrite: overwrite
        )
        let finalPackageURL = directoryURL.appendingPathComponent("Package.swift")
        let finalSourceURL = directoryURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(targetName, isDirectory: true)
            .appendingPathComponent("main.swift")

        let scaffoldReport = SwiftFeatureScaffoldReport(
            id: id,
            directoryPath: directoryURL.path,
            manifestPath: finalManifestURL.path,
            packagePath: finalPackageURL.path,
            sourcePath: finalSourceURL.path,
            toolName: reportToolName
        )

        let shouldBuild = arguments.bool("build") ?? false
        let shouldEnable = arguments.bool("enable") ?? false
        guard shouldBuild || shouldEnable else {
            return scaffoldReport
        }
        return try await finalizeScaffoldedFeature(
            report: scaffoldReport,
            manifestURL: finalManifestURL,
            shouldBuild: shouldBuild,
            shouldEnable: shouldEnable,
            arguments: arguments
        )
    }

    private func finalizeScaffoldedFeature(
        report: SwiftFeatureScaffoldReport,
        manifestURL: URL,
        shouldBuild: Bool,
        shouldEnable: Bool,
        arguments: [String: Any]
    ) async throws -> SwiftFeatureScaffoldReport {
        let validation = try validateFeature(
            arguments: ["manifestPath": manifestURL.path]
        )

        var buildReport: SwiftFeatureBuildReport?
        if validation.ok, shouldBuild {
            var buildArguments: [String: Any] = [
                "manifestPath": manifestURL.path
            ]
            if let timeout = arguments.int("timeoutSeconds", "timeout") {
                buildArguments["timeoutSeconds"] = timeout
            }
            buildReport = try await buildFeature(arguments: buildArguments)
        }

        let canEnable = validation.ok && (buildReport?.ok ?? !shouldBuild)
        var enabled = false
        if shouldEnable, canEnable {
            try await setFeature(id: report.id, enabled: true)
            enabled = true
        } else if buildReport?.ok == true {
            await reloadFeatureBundles()
        }

        return SwiftFeatureScaffoldReport(
            id: report.id,
            directoryPath: report.directoryPath,
            manifestPath: report.manifestPath,
            packagePath: report.packagePath,
            sourcePath: report.sourcePath,
            toolName: report.toolName,
            ok: canEnable && (!shouldEnable || enabled),
            built: buildReport?.ok ?? false,
            enabled: enabled,
            validation: validation,
            build: buildReport
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

        // Validate manifest routing before files are copied, built, or enabled.
        // In particular a `feature.` prefix must never reach the kernel router.
        let manifestRoutingErrors = Self.validationErrorsForToolNames(
            sourceManifest.tools.map(\.name)
        ) + Self.validationErrorsForRouting(
            toolNamePrefixes: sourceManifest.toolNamePrefixes,
            toolNameAliases: sourceManifest.toolNameAliases
        )
        guard manifestRoutingErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature manifest validation failed before install:\n"
                    + manifestRoutingErrors.joined(separator: "\n")
            )
        }

        // Validate at the source before replacing any installed package. A
        // source manifest may legitimately refer to an executable that will be
        // produced by the requested build, so that single pre-build condition
        // is deferred; every structural/routing/package error aborts without
        // mutating (or overwriting) the destination.
        let sourceValidation = try validateFeature(
            arguments: ["manifestPath": sourceManifestURL.path]
        )
        let sourceBlockingErrors = sourceValidation.errors.filter {
            !$0.hasPrefix("Executable is missing or not executable:")
        }
        guard sourceBlockingErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature manifest validation failed before install:\n"
                    + sourceBlockingErrors.joined(separator: "\n")
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

        let validation = try validateFeature(
            arguments: ["manifestPath": destinationManifestURL.path]
        )
        guard validation.errors.isEmpty else {
            // Installation has deliberately not enabled the feature. Reloading
            // drops any stale discovery cache before surfacing the failure.
            await reloadFeatureBundles()
            throw DirectToolError.permissionDenied(
                "Feature validation failed before enable:\n"
                    + validation.errors.joined(separator: "\n")
            )
        }

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
            await reloadFeatureBundles()
        }

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
        if Self.bundledFeatureDefinition(id: id)?.isCore == true {
            throw DirectToolError.permissionDenied(
                "Core Swift feature '\(id)' cannot be deleted. Use feature.disable instead."
            )
        }

        if let record = SwiftFeatureRegistry.featureRecord(
            id: id,
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        ),
           let manifestURL = record.manifestURL {
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

        let bundledIDs = Set(Self.bundledFeatureDefinitions().map(\.id))
        guard !bundledIDs.contains(id) else {
            throw DirectToolError.permissionDenied(
                "Bundled Swift feature '\(id)' cannot be deleted. Use feature.disable instead."
            )
        }
        throw DirectToolError.permissionDenied("Unknown generated Swift feature: \(id).")
    }

    func reloadFeatureBundles() async {
        runtimeDiscoveredToolsByFeatureID.removeAll()
        persistentProcessReloadCount += 1
        acceptsPersistentProcessRequests = false
        let processes = Array(persistentProcessesByFeatureID.values)
        persistentProcessesByFeatureID.removeAll()
        for process in processes {
            await process.shutdown()
        }
        features = explicitFeatures ?? Self.defaultFeatureBundles(
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        )
        persistentProcessReloadCount -= 1
        if persistentProcessReloadCount == 0, !persistentProcessesWereShutDown {
            acceptsPersistentProcessRequests = true
        }
    }
}
