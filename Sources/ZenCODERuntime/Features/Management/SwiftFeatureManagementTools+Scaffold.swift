//
//  SwiftFeatureManagementTools+Scaffold.swift
//  ZenCODE
//
//  The `feature.scaffold` management tool: generation of a basic or MCP
//  bridge feature package, its optional build and enablement, and the
//  scaffold tool names.
//

import FeatureKit
import Foundation
import ToolCore

extension SwiftFeatureRuntime {
    func scaffoldFeature(
        arguments: [String: Any],
        ensuresDelegatedNamespace: Bool
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
        if ensuresDelegatedNamespace {
            // Before any file is written: the requested routing must be a
            // namespace of its own.
            switch template {
            case .basic:
                let toolName = Self.scaffoldToolName(id: id, arguments: arguments)
                try ensureDelegatedFeatureNamespace(
                    featureID: id,
                    toolNames: [toolName],
                    toolNameAliases: [],
                    toolNamePrefixes: [Self.toolNamePrefix(from: toolName)]
                )
            case .mcpBridge:
                try ensureDelegatedFeatureNamespace(
                    featureID: id,
                    toolNames: [],
                    toolNameAliases: [],
                    toolNamePrefixes: [Self.scaffoldToolPrefix(id: id, arguments: arguments)]
                )
            }
        }
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
            let toolName = Self.scaffoldToolName(id: id, arguments: arguments)
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
            let toolPrefix = Self.scaffoldToolPrefix(id: id, arguments: arguments)
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
            #if !os(macOS)
            throw DirectToolError.permissionDenied(
                "MCP bridge features are currently supported only on macOS."
            )
            #else
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
            #endif
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

    /// The tool name a `basic` scaffold of `id` declares: the requested
    /// `toolName`, or `<id prefix>.echo`.
    static func scaffoldToolName(id: String, arguments: [String: Any]) -> String {
        arguments
            .string("toolName", "tool_name")?
            .nilIfBlank ?? "\(defaultToolPrefix(for: id)).echo"
    }

    /// The tool name prefix an `mcp-bridge` scaffold of `id` declares: the
    /// requested `toolPrefix`, or `<id prefix>.`, ending in `.`.
    static func scaffoldToolPrefix(id: String, arguments: [String: Any]) -> String {
        normalizedToolPrefix(
            arguments.string("toolPrefix", "tool_prefix", "prefix")?
                .nilIfBlank ?? "\(defaultToolPrefix(for: id))."
        )
    }
}
