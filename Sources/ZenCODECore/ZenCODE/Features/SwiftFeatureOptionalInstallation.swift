//
//  SwiftFeatureOptionalInstallation.swift
//  ZenCODE
//

import Foundation
import ToolCore
import ZenPackageMetadata

/// One optional ZenCODE feature package as offered to the user.
///
/// Optional features are *not* shipped as executables next to `zen`: they are
/// SwiftPM packages that live in the ZenCODE source checkout and are installed
/// from source into `~/.zencode/features/<id>/`. Once installed they are
/// indistinguishable from a package created by the local feature Builder, so
/// `feature.validate`, `feature.build`, `feature.reload`, and the `/feature`
/// wizard keep working without any special case.
public struct SwiftFeatureOptionalFeature: Codable, Sendable, Hashable {
    /// Catalog identity (`search-tools`, `git-tools`, …).
    public let id: String
    /// Human readable name used by the setup wizard (`Search`, `Git`, …).
    public let displayName: String
    /// Short capability description shown next to the checkbox.
    public let description: String
    /// SwiftPM product name, equal to the executable and target name.
    public let productName: String
    /// Package directory relative to the ZenCODE checkout root.
    public let sourceRelativePath: String?
    /// `false` when the current platform cannot run the feature at all.
    public let supportedOnCurrentPlatform: Bool
    /// `true` when a package already exists under the user feature root.
    public let installed: Bool
    /// `true` when the installed package is enabled *and* built.
    public let enabled: Bool
    /// `true` when the release executable exists and is runnable.
    public let built: Bool
    /// Destination directory, whether or not the feature is installed yet.
    public let installPath: String
    /// Reason the feature is currently unusable, if any.
    public let issue: String?

    public init(
        id: String,
        displayName: String,
        description: String,
        productName: String,
        sourceRelativePath: String?,
        supportedOnCurrentPlatform: Bool,
        installed: Bool,
        enabled: Bool,
        built: Bool,
        installPath: String,
        issue: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.productName = productName
        self.sourceRelativePath = sourceRelativePath
        self.supportedOnCurrentPlatform = supportedOnCurrentPlatform
        self.installed = installed
        self.enabled = enabled
        self.built = built
        self.installPath = installPath
        self.issue = issue
    }
}

/// Structured outcome of installing one optional feature from source.
public struct SwiftFeatureOptionalInstallReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let productName: String
    public let sourcePath: String
    public let zenPackagePath: String
    public let destinationPath: String
    public let packagePath: String
    public let manifestPath: String
    public let executablePath: String
    public let command: [String]
    public let copied: Bool
    public let built: Bool
    public let enabled: Bool
    public let errors: [String]
    public let validation: SwiftFeatureValidationReport
    public let build: SwiftFeatureBuildReport?

    public init(
        ok: Bool,
        id: String,
        productName: String,
        sourcePath: String,
        zenPackagePath: String,
        destinationPath: String,
        packagePath: String,
        manifestPath: String,
        executablePath: String,
        command: [String],
        copied: Bool,
        built: Bool,
        enabled: Bool,
        errors: [String],
        validation: SwiftFeatureValidationReport,
        build: SwiftFeatureBuildReport?
    ) {
        self.ok = ok
        self.id = id
        self.productName = productName
        self.sourcePath = sourcePath
        self.zenPackagePath = zenPackagePath
        self.destinationPath = destinationPath
        self.packagePath = packagePath
        self.manifestPath = manifestPath
        self.executablePath = executablePath
        self.command = command
        self.copied = copied
        self.built = built
        self.enabled = enabled
        self.errors = errors
        self.validation = validation
        self.build = build
    }
}

extension SwiftFeatureRuntime {
    /// Marker line that precedes the ZenCODE `.package(path:)` dependency in
    /// every optional feature `Package.swift`. Copying a feature package out of
    /// the checkout only requires rewriting the line that follows it.
    public static let zenPackagePathMarker = "// zencode:package-path"

    /// Directory holding the persistent ZenCODE source copy kept by the
    /// installer under `${ZENCODE_SUPPORT_DIRECTORY:-~/.zencode}`.
    public static let supportSourceCheckoutDirectoryName = "source"

    /// Issue reported for an optional feature that has not been installed yet.
    public static let optionalFeatureNotInstalledIssue =
        "Not installed. Install it from zen --setup (Features) or the installer."

    public static let defaultOptionalFeatureInstallTimeoutSeconds: TimeInterval = 900

    // MARK: - Catalog

    /// Every optional feature the current build can install, with its live
    /// installation state resolved from the user feature root.
    public static func optionalFeatures(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [SwiftFeatureOptionalFeature] {
        let records = defaultFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        )
        let recordsByID = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let featureRootURL = optionalFeatureRootURL(
            searchRoots: searchRoots,
            fileManager: fileManager
        )

        return bundledFeatureDefinitions()
            .filter { !$0.isCore }
            .map { definition in
                let metadata = ZenBundledFeatureCatalog.feature(id: definition.id)
                let record = recordsByID[definition.id]
                let installed = record?.source == .generated
                return SwiftFeatureOptionalFeature(
                    id: definition.id,
                    displayName: adoptedDisplayName(for: definition.id),
                    description: definition.description ?? "Optional Swift feature for ZenCODE.",
                    productName: definition.executableName,
                    sourceRelativePath: definition.sourceRelativePath,
                    supportedOnCurrentPlatform: isOptionalFeatureSupportedOnCurrentPlatform(
                        metadata: metadata
                    ),
                    installed: installed,
                    enabled: record?.enabled ?? false,
                    built: record?.executableAvailable ?? false,
                    installPath: featureRootURL
                        .appendingPathComponent(definition.id, isDirectory: true)
                        .path,
                    issue: record?.issue
                )
            }
    }

    /// Instance overload that honours the runtime's configured feature roots.
    public func optionalFeatures() -> [SwiftFeatureOptionalFeature] {
        Self.optionalFeatures(
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        )
    }

    /// Returns whether the installed package differs from the package in the
    /// currently resolved ZenCODE source checkout.
    ///
    /// Build products, generated manifests, package-resolution state, and the
    /// absolute ZenCODE dependency path are deliberately ignored. Only source
    /// package changes make an installed feature eligible for an update.
    public func isOptionalFeatureUpdateAvailable(
        _ feature: SwiftFeatureOptionalFeature,
        zenPackageRootURL: URL
    ) throws -> Bool {
        guard feature.installed,
              feature.supportedOnCurrentPlatform,
              let definition = Self.bundledFeatureDefinition(id: feature.id),
              !definition.isCore,
              let sourceRelativePath = definition.sourceRelativePath else {
            return false
        }

        let sourceRootURL = zenPackageRootURL.standardizedFileURL
        let sourceDirectoryURL = sourceRootURL
            .appendingPathComponent(sourceRelativePath, isDirectory: true)
            .standardizedFileURL
        let installedDirectoryURL = featureRootURL()
            .appendingPathComponent(definition.id, isDirectory: true)
            .standardizedFileURL
        guard Self.path(sourceDirectoryURL, isDescendantOf: sourceRootURL),
              fileManager.fileExists(atPath: sourceDirectoryURL.path),
              fileManager.fileExists(atPath: installedDirectoryURL.path) else {
            return false
        }

        return try normalizedOptionalFeaturePackageFiles(at: sourceDirectoryURL)
            != normalizedOptionalFeaturePackageFiles(at: installedDirectoryURL)
    }

    private func normalizedOptionalFeaturePackageFiles(
        at packageDirectoryURL: URL
    ) throws -> [String: Data] {
        var files: [String: Data] = [:]
        try collectNormalizedOptionalFeaturePackageFiles(
            at: packageDirectoryURL,
            relativePath: "",
            into: &files
        )
        return files
    }

    private func collectNormalizedOptionalFeaturePackageFiles(
        at directoryURL: URL,
        relativePath: String,
        into files: inout [String: Data]
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        )

        for entryURL in entries {
            let name = entryURL.lastPathComponent
            guard !Self.excludedInstallEntryNames.contains(name),
                  name != "Package.resolved" else {
                continue
            }
            let entryRelativePath = relativePath.isEmpty
                ? name
                : "\(relativePath)/\(name)"
            guard entryRelativePath != SwiftFeatureRegistry.manifestFilename else {
                continue
            }

            let values = try entryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else {
                throw DirectToolError.permissionDenied(
                    "Refusing to inspect a symbolic link in feature package: \(entryURL.path)"
                )
            }
            if values.isDirectory == true {
                try collectNormalizedOptionalFeaturePackageFiles(
                    at: entryURL,
                    relativePath: entryRelativePath,
                    into: &files
                )
            } else if values.isRegularFile == true {
                if entryRelativePath == "Package.swift" {
                    let contents = try String(contentsOf: entryURL, encoding: .utf8)
                    let normalized = try Self.packageManifestRewritingZenPackagePath(
                        contents,
                        zenPackagePath: "/__zencode_package_root__",
                        packageURL: entryURL
                    )
                    files[entryRelativePath] = Data(normalized.utf8)
                } else {
                    files[entryRelativePath] = try Data(contentsOf: entryURL)
                }
            } else {
                throw DirectToolError.permissionDenied(
                    "Refusing to inspect a non-regular feature package entry: \(entryURL.path)"
                )
            }
        }
    }

    static func isOptionalFeatureSupportedOnCurrentPlatform(
        metadata: ZenBundledFeatureMetadata?
    ) -> Bool {
        #if os(macOS)
        return true
        #else
        // `isInstalledOnLinux` is the distribution authority for features whose
        // platform integration only exists on macOS.
        return metadata?.isInstalledOnLinux ?? true
        #endif
    }

    static func optionalFeatureRootURL(
        searchRoots: [URL]?,
        fileManager: FileManager
    ) -> URL {
        (searchRoots?.first ?? SwiftFeatureRegistry.appFeatureRootURL(fileManager: fileManager))
            .standardizedFileURL
    }

    // MARK: - Source checkout resolution

    /// Persistent ZenCODE source copy maintained by the installer.
    public static func supportSourceCheckoutURL(
        fileManager: FileManager = .default
    ) -> URL {
        AppStorageDirectory
            .appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(supportSourceCheckoutDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    /// Resolves the ZenCODE checkout used both as feature source and as the
    /// rewritten `.package(path:)` dependency.
    ///
    /// Resolution order: explicit argument, the checkout this binary was built
    /// from, the persistent installer copy under the support directory, then the
    /// current working directory.
    public static func zenCODESourceCheckoutURL(
        explicitURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let supportSourceURL = supportSourceCheckoutURL(fileManager: fileManager)
        if let explicitURL = explicitURL?.standardizedFileURL {
            // An explicit root is authoritative: never silently fall back to a
            // different checkout than the caller asked for.
            guard fileManager.fileExists(
                atPath: explicitURL.appendingPathComponent("Package.swift").path
            ) else {
                throw DirectToolError.permissionDenied(
                    "ZenCODE package root not found at \(explicitURL.path)."
                )
            }
            return explicitURL
        }

        let candidates: [URL] = [
            sourcePackageRootURL(fileManager: fileManager),
            supportSourceURL,
            URL(
                fileURLWithPath: fileManager.currentDirectoryPath,
                isDirectory: true
            ).standardizedFileURL
        ].compactMap { $0 }

        for candidate in candidates where fileManager.fileExists(
            atPath: candidate.appendingPathComponent("Package.swift").path
        ) {
            return candidate
        }

        throw DirectToolError.permissionDenied(
            """
            Could not locate a ZenCODE source checkout to install optional features from.
            Pass an explicit package root, run the command from a ZenCODE checkout, or keep \
            the installer copy at \(supportSourceURL.path).
            """
        )
    }

    // MARK: - Install

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
        timeoutSeconds: TimeInterval = SwiftFeatureRuntime.defaultOptionalFeatureInstallTimeoutSeconds
    ) async throws -> SwiftFeatureOptionalInstallReport {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature installation is unavailable for an explicitly constructed runtime."
            )
        }
        guard Self.isValidFeatureID(id) else {
            throw DirectToolError.permissionDenied(
                "Feature id '\(id)' is invalid. Use letters, numbers, dots, underscores, and hyphens."
            )
        }
        guard let definition = Self.bundledFeatureDefinition(id: id), !definition.isCore else {
            throw DirectToolError.permissionDenied("Unknown optional Swift feature: \(id).")
        }
        guard Self.isOptionalFeatureSupportedOnCurrentPlatform(
            metadata: ZenBundledFeatureCatalog.feature(id: id)
        ) else {
            throw DirectToolError.permissionDenied(
                "Optional Swift feature '\(id)' is not available on this platform."
            )
        }

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

        let validation = try validateFeature(
            arguments: ["manifestPath": staged.manifestURL.path]
        )
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
            buildReport = try await buildFeature(
                arguments: [
                    "manifestPath": staged.manifestURL.path,
                    "timeoutSeconds": Int(timeoutSeconds)
                ]
            )
        }

        let built = buildReport?.ok ?? false
        var errors: [String] = []
        if let buildReport, !buildReport.ok {
            errors.append(
                "swift build failed for product '\(definition.executableName)' (exit code \(buildReport.exitCode))."
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
            try SwiftFeatureRegistry.setFeatureManifestEnabled(
                manifestURL: staged.manifestURL,
                enabled: true,
                fileManager: fileManager
            )
        }
        try publishStagedOptionalFeaturePackage(
            stagedDirectoryURL: staged.destinationDirectoryURL,
            destinationDirectoryURL: destinationDirectoryURL
        )
        reloadFeatureBundles()

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
            throw DirectToolError.permissionDenied(
                "Optional feature source package not found: \(sourceURL.path)."
            )
        }
        return sourceURL
    }

    // MARK: - Materialization

    struct MaterializedFeaturePackage {
        let sourceDirectoryURL: URL
        let destinationDirectoryURL: URL
        let packageURL: URL
        let manifestURL: URL
        let executableURL: URL
        let copied: Bool
    }

    /// Creates an unpublished package that can be validated and built without
    /// changing an installed feature. The directory is hidden so registry scans
    /// do not observe an in-flight candidate.
    func stageOptionalFeaturePackage(
        definition: BundledFeatureDefinition,
        sourceDirectoryURL: URL,
        zenPackageRootURL: URL,
        displayName: String,
        destinationDirectoryURL: URL
    ) throws -> MaterializedFeaturePackage {
        let featureRootURL = featureRootURL()
        guard Self.path(destinationDirectoryURL, isDescendantOf: featureRootURL),
              destinationDirectoryURL.path != featureRootURL.path else {
            throw DirectToolError.permissionDenied(
                "Features can only be installed under the generated features directory: \(featureRootURL.path)."
            )
        }

        let sourcePackageURL = sourceDirectoryURL.appendingPathComponent("Package.swift")
        guard fileManager.fileExists(atPath: sourcePackageURL.path) else {
            throw DirectToolError.permissionDenied(
                """
                Feature package manifest not found: \(sourcePackageURL.path).
                Optional features must be self-contained SwiftPM packages.
                """
            )
        }
        let packageContents = try Self.packageManifestRewritingZenPackagePath(
            String(contentsOf: sourcePackageURL, encoding: .utf8),
            zenPackagePath: zenPackageRootURL.path,
            packageURL: sourcePackageURL
        )
        let manifestContents = try Self.adoptedFeatureManifestContents(
            definition: definition,
            displayName: displayName,
            enabled: false
        )

        let stagingDirectoryURL = featureRootURL.appendingPathComponent(
            ".zencode-feature-install-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
        do {
            try copyFeatureDirectoryContents(
                from: sourceDirectoryURL,
                to: stagingDirectoryURL
            )
            try packageContents.write(
                to: stagingDirectoryURL.appendingPathComponent("Package.swift"),
                atomically: true,
                encoding: .utf8
            )
            try manifestContents.write(
                to: stagingDirectoryURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw error
        }

        return MaterializedFeaturePackage(
            sourceDirectoryURL: sourceDirectoryURL,
            destinationDirectoryURL: stagingDirectoryURL,
            packageURL: stagingDirectoryURL.appendingPathComponent("Package.swift"),
            manifestURL: stagingDirectoryURL
                .appendingPathComponent(SwiftFeatureRegistry.manifestFilename),
            executableURL: stagingDirectoryURL
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("release", isDirectory: true)
                .appendingPathComponent(definition.executableName),
            copied: false
        )
    }

    /// Publishes a candidate only after it has passed validation/build. The
    /// complete sibling candidate replaces the installed directory with backup
    /// rollback if publication cannot be completed.
    func publishStagedOptionalFeaturePackage(
        stagedDirectoryURL: URL,
        destinationDirectoryURL: URL
    ) throws {
        try replaceFeatureDirectory(
            stagedDirectoryURL: stagedDirectoryURL,
            destinationDirectoryURL: destinationDirectoryURL
        )
    }

    /// Copies a feature package into the user feature root and turns it into a
    /// self-contained, Builder-shaped feature.
    ///
    /// The copy, the rewritten `Package.swift`, and the generated `feature.json`
    /// are all produced inside the staging directory, so the visible destination
    /// is only ever replaced by a complete package.
    func materializeFeaturePackage(
        definition: BundledFeatureDefinition,
        sourceDirectoryURL: URL,
        zenPackageRootURL: URL,
        displayName: String,
        enabled: Bool,
        overwrite: Bool
    ) throws -> MaterializedFeaturePackage {
        let featureRootURL = featureRootURL()
        let destinationDirectoryURL = featureRootURL
            .appendingPathComponent(definition.id, isDirectory: true)
            .standardizedFileURL
        guard Self.path(destinationDirectoryURL, isDescendantOf: featureRootURL),
              destinationDirectoryURL.path != featureRootURL.path else {
            throw DirectToolError.permissionDenied(
                "Features can only be installed under the generated features directory: \(featureRootURL.path)."
            )
        }

        let sourcePackageURL = sourceDirectoryURL.appendingPathComponent("Package.swift")
        guard fileManager.fileExists(atPath: sourcePackageURL.path) else {
            throw DirectToolError.permissionDenied(
                """
                Feature package manifest not found: \(sourcePackageURL.path).
                Optional features must be self-contained SwiftPM packages.
                """
            )
        }
        let packageContents = try Self.packageManifestRewritingZenPackagePath(
            String(contentsOf: sourcePackageURL, encoding: .utf8),
            zenPackagePath: zenPackageRootURL.path,
            packageURL: sourcePackageURL
        )
        let manifestContents = try Self.adoptedFeatureManifestContents(
            definition: definition,
            displayName: displayName,
            enabled: enabled
        )

        let copied = try installFeatureDirectory(
            sourceDirectoryURL: sourceDirectoryURL,
            destinationDirectoryURL: destinationDirectoryURL,
            overwrite: overwrite
        ) { stagingURL in
            try packageContents.write(
                to: stagingURL.appendingPathComponent("Package.swift"),
                atomically: true,
                encoding: .utf8
            )
            try manifestContents.write(
                to: stagingURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename),
                atomically: true,
                encoding: .utf8
            )
        }

        return MaterializedFeaturePackage(
            sourceDirectoryURL: sourceDirectoryURL,
            destinationDirectoryURL: destinationDirectoryURL,
            packageURL: destinationDirectoryURL.appendingPathComponent("Package.swift"),
            manifestURL: destinationDirectoryURL
                .appendingPathComponent(SwiftFeatureRegistry.manifestFilename),
            executableURL: destinationDirectoryURL
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("release", isDirectory: true)
                .appendingPathComponent(definition.executableName),
            copied: copied
        )
    }

    /// Rewrites the `.package(path:)` dependency that follows the
    /// `// zencode:package-path` marker so a copied feature package points at an
    /// absolute ZenCODE checkout instead of its in-repository relative path.
    static func packageManifestRewritingZenPackagePath(
        _ contents: String,
        zenPackagePath: String,
        packageURL: URL
    ) throws -> String {
        var lines = contents.components(separatedBy: "\n")
        guard let markerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == zenPackagePathMarker
        }) else {
            throw DirectToolError.permissionDenied(
                """
                \(packageURL.path) does not declare the '\(zenPackagePathMarker)' marker \
                before its ZenCODE '.package(path:)' dependency.
                """
            )
        }

        var dependencyIndex = markerIndex + 1
        while dependencyIndex < lines.count,
              lines[dependencyIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            dependencyIndex += 1
        }
        guard dependencyIndex < lines.count,
              let rewritten = rewrittenPackagePathLine(
                  lines[dependencyIndex],
                  zenPackagePath: zenPackagePath
              ) else {
            throw DirectToolError.permissionDenied(
                """
                \(packageURL.path) must declare a '.package(path: "…")' dependency \
                on the line following '\(zenPackagePathMarker)'.
                """
            )
        }
        lines[dependencyIndex] = rewritten
        return lines.joined(separator: "\n")
    }

    private static func rewrittenPackagePathLine(
        _ line: String,
        zenPackagePath: String
    ) -> String? {
        let pattern = #"^(\s*)\.package\(\s*path:\s*"(?:[^"\\]|\\.)*"\s*\)(.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let indentRange = Range(match.range(at: 1), in: line),
              let trailingRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return line[indentRange]
            + ".package(path: \(swiftStringLiteral(zenPackagePath)))"
            + line[trailingRange]
    }
}
