//
//  SwiftFeatureOptionalInstallation+Install.swift
//  ZenCODE
//
//  Installation of one optional feature from source into the user feature
//  root, built in a staging directory before it replaces the installed
//  version, and the lookup of its source directory.
//

import Foundation
import ToolCore
import ZenPackageMetadata

extension SwiftFeatureRuntime {
    private static let optionalFeatureBuildProgressIntervalSeconds = 15

    /// Installs one optional feature from source into the user feature root.
    ///
    /// The package is prepared in an unpublished staging directory (`.build` and
    /// other local artefacts excluded), its ZenCODE dependency path is rewritten
    /// to the resolved checkout, a Builder-shaped `feature.json` is generated,
    /// and the release product is built before the complete directory replaces
    /// the installed version. This keeps an existing feature available when a
    /// candidate fails validation, building, or times out.
    @discardableResult
    public func installOptionalFeature(
        id: String,
        zenPackageRootURL explicitZenPackageRootURL: URL? = nil,
        build shouldBuild: Bool = true,
        enable shouldEnable: Bool = true,
        timeoutSeconds: TimeInterval = SwiftFeatureRuntime.defaultOptionalFeatureInstallTimeoutSeconds,
        progress: SwiftFeatureOptionalInstallProgress? = nil
    ) async throws -> SwiftFeatureOptionalInstallReport {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw DirectToolError.invalidInput(
                "timeoutSeconds must be a finite positive value (got \(timeoutSeconds))."
            )
        }
        guard !inProgressInstallations.contains(id) else {
            throw DirectToolError.invalidInput(
                "Feature '\(id)' is already being installed. Wait for the current installation to complete."
            )
        }
        inProgressInstallations.insert(id)
        defer { inProgressInstallations.remove(id) }
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature installation is unavailable for an explicitly constructed runtime."
            )
        }
        guard Self.isValidFeatureID(id) else {
            throw DirectToolError.invalidInput(
                "Feature id '\(id)' is invalid. Use letters, numbers, dots, underscores, and hyphens."
            )
        }
        guard let definition = Self.bundledFeatureDefinition(id: id), !definition.isCore else {
            throw DirectToolError.notFound("Unknown optional Swift feature: \(id).")
        }
        guard Self.isOptionalFeatureSupportedOnCurrentPlatform(
            metadata: ZenBundledFeatureCatalog.feature(id: id)
        ) else {
            throw DirectToolError.permissionDenied("Optional Swift feature '\(id)' is not available on this platform.")
        }

        await progress?("Resolving ZenCODE source checkout…")
        let zenPackageRootURL = try Self.zenCODESourceCheckoutURL(
            explicitURL: explicitZenPackageRootURL,
            fileManager: fileManager
        )
        let sourceDirectoryURL = try optionalFeatureSourceDirectoryURL(
            definition: definition,
            zenPackageRootURL: zenPackageRootURL
        )
        let destinationDirectoryURL = featureRootURL()
            .appendingPathComponent(definition.id, isDirectory: true)
            .standardizedFileURL
        let destinationPackageURL = destinationDirectoryURL
            .appendingPathComponent("Package.swift")
        let destinationManifestURL = destinationDirectoryURL
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
        let destinationExecutableURL = destinationDirectoryURL
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent(definition.executableName)

        await progress?("Source package: \(sourceDirectoryURL.path)")
        await progress?("Preparing staged package for \(destinationDirectoryURL.path)…")

        // The manifest is written disabled: enabling happens only after the
        // release product exists, exactly like a Builder-created feature.
        let staged = try stageOptionalFeaturePackage(
            definition: definition,
            sourceDirectoryURL: sourceDirectoryURL,
            zenPackageRootURL: zenPackageRootURL,
            displayName: Self.adoptedDisplayName(for: definition.id),
            destinationDirectoryURL: destinationDirectoryURL
        )
        defer { try? fileManager.removeItem(at: staged.destinationDirectoryURL) }

        await progress?("Validating staged package and feature manifest…")
        let validation = try validateFeature(arguments: ["manifestPath": staged.manifestURL.path])
        let blockingErrors = validation.errors.filter {
            !$0.hasPrefix("Executable is missing or not executable:")
        }
        let command = ["swift", "build", "-c", "release", "--product", definition.executableName]

        guard blockingErrors.isEmpty else {
            return SwiftFeatureOptionalInstallReport(
                ok: false,
                id: id,
                productName: definition.executableName,
                sourcePath: sourceDirectoryURL.path,
                zenPackagePath: zenPackageRootURL.path,
                destinationPath: destinationDirectoryURL.path,
                packagePath: destinationPackageURL.path,
                manifestPath: destinationManifestURL.path,
                executablePath: destinationExecutableURL.path,
                command: command,
                copied: false,
                built: false,
                enabled: false,
                errors: blockingErrors,
                validation: validation,
                build: nil
            )
        }

        // An executable from the source is deliberately excluded from the
        // staging copy. Publishing an enabled feature without a fresh build
        // would therefore advertise a feature that cannot be executed.
        guard shouldBuild || !shouldEnable else {
            return SwiftFeatureOptionalInstallReport(
                ok: false,
                id: id,
                productName: definition.executableName,
                sourcePath: sourceDirectoryURL.path,
                zenPackagePath: zenPackageRootURL.path,
                destinationPath: destinationDirectoryURL.path,
                packagePath: destinationPackageURL.path,
                manifestPath: destinationManifestURL.path,
                executablePath: destinationExecutableURL.path,
                command: command,
                copied: false,
                built: false,
                enabled: false,
                errors: [
                    "Optional feature '\(id)' cannot be enabled when build=false. Build it successfully first."
                ],
                validation: validation,
                build: nil
            )
        }

        var buildReport: SwiftFeatureBuildReport?
        if shouldBuild {
            await progress?("Running: \(command.joined(separator: " "))")
            await progress?("Build directory: \(staged.destinationDirectoryURL.path)")

            let buildStartedAt = Date()
            var buildProgressTask: Task<Void, Never>?
            if let progress {
                let intervalSeconds = Self.optionalFeatureBuildProgressIntervalSeconds
                buildProgressTask = Task(name: "optional feature \(id) SwiftPM build progress") {
                    var elapsedSeconds = intervalSeconds
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(intervalSeconds))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else {
                            return
                        }
                        await progress("Still building \(definition.executableName)… " + "\(elapsedSeconds)s elapsed.")
                        elapsedSeconds += intervalSeconds
                    }
                }
            }

            do {
                buildReport = try await buildFeature(
                    arguments: [
                        "manifestPath": staged.manifestURL.path,
                        "timeoutSeconds": Int(timeoutSeconds)
                    ]
                )
            } catch {
                buildProgressTask?.cancel()
                if let buildProgressTask {
                    await buildProgressTask.value
                }
                throw error
            }
            buildProgressTask?.cancel()
            if let buildProgressTask {
                await buildProgressTask.value
            }
            if let buildReport {
                let elapsedSeconds = max(0, Int(Date().timeIntervalSince(buildStartedAt)))
                await progress?(
                    "SwiftPM build finished in \(elapsedSeconds)s "
                        + "(exit code \(buildReport.exitCode))."
                )
            }
        }

        let built = buildReport?.ok ?? false
        var errors: [String] = []
        if let buildReport, !buildReport.ok {
            errors.append(
                "Feature build or release-symbol stripping failed for product '\(definition.executableName)' "
                    + "(exit code \(buildReport.exitCode))."
            )
        }

        guard errors.isEmpty else {
            return SwiftFeatureOptionalInstallReport(
                ok: false,
                id: id,
                productName: definition.executableName,
                sourcePath: sourceDirectoryURL.path,
                zenPackagePath: zenPackageRootURL.path,
                destinationPath: destinationDirectoryURL.path,
                packagePath: destinationPackageURL.path,
                manifestPath: destinationManifestURL.path,
                executablePath: destinationExecutableURL.path,
                command: buildReport?.command ?? command,
                copied: false,
                built: false,
                enabled: false,
                errors: errors,
                validation: validation,
                build: buildReport
            )
        }

        // Enable the staged manifest before publication. `setFeature(id:)`
        // discovers the live package and would leave a successfully replaced
        // package disabled if that post-swap mutation failed.
        if shouldEnable {
            await progress?("Enabling the feature manifest…")
            try SwiftFeatureRegistry.setFeatureManifestEnabled(
                manifestURL: staged.manifestURL,
                enabled: true,
                fileManager: fileManager
            )
        }
        await progress?("Publishing feature to \(destinationDirectoryURL.path)…")
        try publishStagedOptionalFeaturePackage(
            stagedDirectoryURL: staged.destinationDirectoryURL,
            destinationDirectoryURL: destinationDirectoryURL
        )
        await progress?("Refreshing the feature registry…")
        await reloadFeatureBundles()

        return SwiftFeatureOptionalInstallReport(
            ok: true,
            id: id,
            productName: definition.executableName,
            sourcePath: sourceDirectoryURL.path,
            zenPackagePath: zenPackageRootURL.path,
            destinationPath: destinationDirectoryURL.path,
            packagePath: destinationPackageURL.path,
            manifestPath: destinationManifestURL.path,
            executablePath: destinationExecutableURL.path,
            command: buildReport?.command ?? command,
            copied: true,
            built: built,
            enabled: shouldEnable,
            errors: errors,
            validation: validation,
            build: buildReport
        )
    }

    func optionalFeatureSourceDirectoryURL(
        definition: BundledFeatureDefinition,
        zenPackageRootURL: URL
    ) throws -> URL {
        guard let sourceRelativePath = definition.sourceRelativePath else {
            throw DirectToolError.permissionDenied(
                "Optional Swift feature '\(definition.id)' does not declare a source directory."
            )
        }
        let sourceURL = zenPackageRootURL
            .appendingPathComponent(sourceRelativePath, isDirectory: true)
            .standardizedFileURL
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DirectToolError.permissionDenied("Optional feature source package not found: \(sourceURL.path).")
        }
        return sourceURL
    }
}
