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
    /// Runs a kernel feature-management command.
    ///
    /// `delegatingSessionID` is the ID of the session that delegated the
    /// calling Builder sub-agent with `agent.create`, or `nil` for any other
    /// caller. With it, `feature.build`, `feature.scaffold`, and
    /// `feature.install` first refuse a feature that would take a namespace it
    /// does not own (see ``ensureDelegatedFeatureNamespace(featureID:toolNames:toolNameAliases:toolNamePrefixes:)``),
    /// `feature.enable` refuses the same way the manifest it would enable
    /// (see ``ensureDelegatedFeatureNamespace(enabling:)``),
    /// and a successful build of a generated feature under the generated
    /// features root exposes it to that session (see
    /// ``recordBuilderOutcome(_:delegatingSessionID:)``). A `feature.delete`
    /// removes the feature from every session regardless of the caller.
    /// Without `delegatingSessionID` the command behaves as it always did,
    /// and the rendered output never changes.
    public func executeManagementTool(
        toolCall: DirectAgentToolCall,
        delegatingSessionID: String? = nil
    ) async throws -> String {
        let arguments = toolCall.argumentsObject
        let canonicalName = Self.managementToolAliases[toolCall.name] ?? toolCall.name
        let isDelegatedBuild = delegatingSessionID?.nilIfBlank != nil
        switch canonicalName {
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
            if isDelegatedBuild {
                // Before the manifest is enabled.
                try ensureDelegatedFeatureNamespace(enabling: id)
            }
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
            recordBuilderOutcome(
                Self.builderOutcome(delete: report),
                delegatingSessionID: delegatingSessionID
            )
            return try renderJSON(report)
        case "feature.edit":
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
            let manifestURL = try featureManifestURL(arguments: arguments)
            if isDelegatedBuild,
               let record = SwiftFeatureRegistry.featureRecord(
                   manifestURL: manifestURL,
                   fileManager: fileManager
               ) {
                // A missing or invalid manifest is reported by the build.
                try ensureDelegatedFeatureNamespace(
                    featureID: record.id,
                    toolNames: record.tools.map(\.name),
                    toolNameAliases: record.toolNameAliases,
                    toolNamePrefixes: record.toolNamePrefixes
                )
            }
            let report = try await buildFeature(
                manifestURL: manifestURL,
                arguments: arguments
            )
            if report.ok {
                await reloadFeatureBundles()
            }
            recordBuilderOutcome(
                Self.builderOutcome(build: report, manifestURL: manifestURL),
                delegatingSessionID: delegatingSessionID
            )
            return try renderJSON(report)
        case "feature.scaffold":
            let report = try await scaffoldFeature(
                arguments: arguments,
                ensuresDelegatedNamespace: isDelegatedBuild
            )
            recordBuilderOutcome(
                Self.builderOutcome(scaffold: report),
                delegatingSessionID: delegatingSessionID
            )
            return try renderJSON(report)
        case "feature.promote":
            let report = try await promoteFeature(arguments: arguments)
            await reloadFeatureBundles()
            return try renderJSON(report)
        case "feature.install":
            let report = try await installFeature(
                arguments: arguments,
                ensuresDelegatedNamespace: isDelegatedBuild
            )
            if report.ok {
                await reloadFeatureBundles()
            }
            recordBuilderOutcome(
                Self.builderOutcome(install: report),
                delegatingSessionID: delegatingSessionID
            )
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

        throw DirectToolError.notFound("Unknown Swift feature: \(id).")
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

    private func installFeature(
        arguments: [String: Any],
        ensuresDelegatedNamespace: Bool
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
        if ensuresDelegatedNamespace {
            // Before anything is copied or built.
            try ensureDelegatedFeatureNamespace(
                featureID: id,
                toolNames: sourceManifest.tools.map(\.name),
                toolNameAliases: sourceManifest.toolNameAliases,
                toolNamePrefixes: sourceManifest.toolNamePrefixes
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
        throw DirectToolError.notFound("Unknown generated Swift feature: \(id).")
    }

    /// Reloads the feature bundles, then revokes the exposure of each
    /// registered feature whose reloaded routing takes a namespace it does
    /// not own (``revokeExposuresOutsideTheirNamespace()``), whoever caused
    /// the reload.
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
        revokeExposuresOutsideTheirNamespace()
        persistentProcessReloadCount -= 1
        if persistentProcessReloadCount == 0, !persistentProcessesWereShutDown {
            acceptsPersistentProcessRequests = true
        }
    }
}
