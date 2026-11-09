//  Created by Gerardo Grisolini on 30/05/26.
//
// SwiftFeaturePromotion.swift
//
// Transactional promotion of Builder-generated Swift packages into a ZenCODE
// source checkout. This operation never commits, pushes, or creates a PR.

import Foundation
import ToolCore
import ZenPackageMetadata
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension SwiftFeatureRuntime {
    /// Promotion runs as a fixed sequence of phases. Staging and transaction
    /// directories are removed, and the publication lock is released, when
    /// this function returns: the lock stays held from publication through
    /// the Git status read and the report.
    func promoteFeature(arguments: [String: Any]) async throws -> SwiftFeaturePromotionReport {
        let source = try resolvePromotionSource(arguments: arguments)
        let target = try await resolvePromotionCheckout(source: source, arguments: arguments)
        try validatePromotionSource(source)

        let stagingURL = target.featuresRoot.deletingLastPathComponent()
            .appendingPathComponent(".zencode-feature-promotion-\(UUID().uuidString)", isDirectory: true)
        let transactionURL = target.rootURL
            .appendingPathComponent(".zencode-feature-promotion-transaction-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: transactionURL)
        }
        let staged = try stagePromotionPackage(
            source: source,
            target: target,
            stagingURL: stagingURL,
            arguments: arguments
        )
        let preflight = try await preflightStagedPackage(staged, source: source, arguments: arguments)
        try finalizeStagedPackage(staged, source: source, target: target)

        let promotionLockDescriptor = try acquirePromotionPublicationLock(gitCommonDirectoryURL: target.git.commonDirectory)
        defer { releasePromotionPublicationLock(promotionLockDescriptor) }

        let catalogUpdates = try await publishPromotion(staged, target: target, transactionURL: transactionURL)
        return await promotionReport(
            source: source,
            target: target,
            catalogUpdates: catalogUpdates,
            preflight: preflight
        )
    }

    // MARK: - Promotion phases

    /// The registered generated feature being promoted.
    private struct PromotionSource {
        let id: String
        let url: URL
        let manifestURL: URL
        let resolvedData: Data?
        let manifest: SwiftFeatureManifest
    }

    /// The Git checkout and the destination the feature is published to.
    private struct PromotionTarget {
        let checkoutURL: URL
        let git: PromotionGitCheckout
        let branch: String
        let rootURL: URL
        let featuresRoot: URL
        let destinationURL: URL
        let overwrite: Bool
        let destinationExists: Bool
    }

    /// The package copied into staging, before preflight.
    private struct PromotionStagedPackage {
        let stagingURL: URL
        let packageURL: URL
        let stagedManifestURL: URL
        let metadata: PromotionCatalogMetadata
    }

    /// Staged validation and the optional build and `--list-tools` results.
    private struct PromotionPreflight {
        let validation: SwiftFeatureValidationReport
        let buildReport: SwiftFeatureBuildReport?
        let listedTools: [String]
    }

    private func resolvePromotionSource(arguments: [String: Any]) throws -> PromotionSource {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature promotion is unavailable for an explicitly constructed runtime."
            )
        }
        let id = try Self.requiredFeatureID(arguments)
        guard Self.isValidFeatureID(id) else {
            throw DirectToolError.invalidInput(
                "Feature id '\(id)' is invalid. Use letters, numbers, dots, underscores, and hyphens."
            )
        }
        guard Self.bundledFeatureDefinition(id: id) == nil else {
            throw DirectToolError.permissionDenied(
                "Bundled feature '\(id)' is already in the catalog. Promote a generated feature with a new id."
            )
        }

        let sourceURL = try promotionSourceURL(id: id, arguments: arguments)
        let sourceManifestURL = sourceURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
        let sourceResolvedData = try Self.promotionPackageResolvedData(in: sourceURL, fileManager: fileManager)
        guard fileManager.fileExists(atPath: sourceManifestURL.path) else {
            throw DirectToolError.notFound("Feature manifest not found: \(sourceManifestURL.path)")
        }
        let sourceManifest: SwiftFeatureManifest
        do {
            sourceManifest = try JSONDecoder().decode(
                SwiftFeatureManifest.self,
                from: Data(contentsOf: sourceManifestURL)
            )
        } catch {
            throw DirectToolError.permissionDenied(
                "Invalid feature manifest at \(sourceManifestURL.path): \(error.localizedDescription)"
            )
        }
        guard sourceManifest.id == id else {
            throw DirectToolError.permissionDenied(
                "Feature id '\(id)' does not match manifest id '\(sourceManifest.id)'."
            )
        }
        guard sourceManifest.generated != nil else {
            throw DirectToolError.permissionDenied(
                "Feature '\(id)' is not a Builder-generated feature and cannot be promoted."
            )
        }
        guard sourceManifest.generated?.adoptedFrom?.nilIfBlank == nil else {
            throw DirectToolError.permissionDenied(
                "Adopted feature '\(id)' cannot be promoted; promote the original generated feature instead."
            )
        }
        try Self.assertPromotionManifestPathsAreConfined(sourceManifest, featureDirectoryURL: sourceURL)
        return PromotionSource(
            id: id,
            url: sourceURL,
            manifestURL: sourceManifestURL,
            resolvedData: sourceResolvedData,
            manifest: sourceManifest
        )
    }

    private func resolvePromotionCheckout(
        source: PromotionSource,
        arguments: [String: Any]
    ) async throws -> PromotionTarget {
        let checkoutArgument = arguments.string(
            "checkoutPath", "checkout_path", "repositoryPath", "repository_path",
            "repository", "zenPackagePath", "zen_package_path", "dependencyPath",
            "dependency_path", "checkout", "root"
        )?.nilIfBlank
        let checkoutURL = try Self.zenCODESourceCheckoutURL(
            explicitURL: checkoutArgument.map(resolvedInstallPath),
            fileManager: fileManager
        )
        let git = try await requirePromotionGitCheckout(at: checkoutURL)
        guard let branch = git.branch else {
            throw DirectToolError.permissionDenied(
                "The Git checkout at \(git.root.path) is detached. Check out a branch before promoting."
            )
        }
        let rootURL = git.root
        guard fileManager.fileExists(atPath: rootURL.appendingPathComponent("Package.swift").path) else {
            throw DirectToolError.permissionDenied(
                "The Git checkout is incomplete: Package.swift is missing at \(rootURL.path)."
            )
        }
        for requiredDirectory in ["Sources/ZenCODECore", "Sources/ZenPackageMetadata"] {
            guard fileManager.fileExists(atPath: rootURL.appendingPathComponent(requiredDirectory).path) else {
                throw DirectToolError.permissionDenied(
                    "The Git checkout is incomplete: missing \(requiredDirectory)."
                )
            }
        }

        let featuresRoot = rootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("Features", isDirectory: true)
            .standardizedFileURL
        let destinationURL = try promotionDestinationURL(
            id: source.id,
            rootURL: rootURL,
            featuresRoot: featuresRoot,
            arguments: arguments
        )
        let overwrite = arguments.bool("overwrite", "replace") ?? false
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)
        guard !destinationExists || overwrite else {
            throw DirectToolError.permissionDenied(
                "Feature destination already exists at \(destinationURL.path). Pass overwrite=true to replace it."
            )
        }
        guard source.url.standardizedFileURL.path != destinationURL.path else {
            throw DirectToolError.permissionDenied("Promotion source and destination are the same directory.")
        }
        return PromotionTarget(
            checkoutURL: checkoutURL,
            git: git,
            branch: branch,
            rootURL: rootURL,
            featuresRoot: featuresRoot,
            destinationURL: destinationURL,
            overwrite: overwrite,
            destinationExists: destinationExists
        )
    }

    private func validatePromotionSource(_ source: PromotionSource) throws {
        let sourceValidation = try validateFeature(arguments: ["manifestPath": source.manifestURL.path])
        let blockingSourceErrors = Self.blockingValidationErrors(sourceValidation)
        guard blockingSourceErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature validation failed before promotion:\n" + blockingSourceErrors.joined(separator: "\n")
            )
        }
    }

    private func stagePromotionPackage(
        source: PromotionSource,
        target: PromotionTarget,
        stagingURL: URL,
        arguments: [String: Any]
    ) throws -> PromotionStagedPackage {
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try copyPromotionDirectoryContents(from: source.url, to: stagingURL)
        try removePromotionArtifacts(from: stagingURL, removeBuilderManifest: true)

        let packageURL = stagingURL.appendingPathComponent("Package.swift")
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw DirectToolError.permissionDenied("Feature package is missing Package.swift.")
        }
        let packageContents = try String(contentsOf: packageURL, encoding: .utf8)
        // Staging is outside Sources/Features, so the final relative dependency
        // is not valid until publication. Build against the checkout's absolute
        // path, then rewrite to the relocatable final path after preflight.
        let rewritten = try Self.promotionPackageManifestRewritingZenPackagePath(
            packageContents,
            zenPackagePath: target.rootURL.path,
            packageURL: packageURL
        )
        let normalizedPackage = try Self.normalizedPromotionPackageManifest(rewritten, packageURL: packageURL)
        try normalizedPackage.write(to: packageURL, atomically: true, encoding: .utf8)

        let productName = PromotionCatalogMetadata.productName(
            manifest: source.manifest,
            packageContents: normalizedPackage,
            fallback: source.id
        )
        guard Self.packageManifestDeclaresProduct(normalizedPackage, productName: productName) else {
            throw DirectToolError.permissionDenied(
                "Package.swift does not declare the manifest product '\(productName)'."
            )
        }
        let sourceRelativePath = Self.relativePath(from: target.rootURL, to: target.destinationURL)
        guard let linux = Self.platformLinuxArgument(arguments) else {
            throw DirectToolError.invalidInput(
                "Feature promotion requires an explicit Linux decision (linux=true or linux=false)."
            )
        }
        let metadata = try PromotionCatalogMetadata(
            id: source.id,
            manifest: source.manifest,
            packageContents: normalizedPackage,
            sourceRelativePath: sourceRelativePath,
            isInstalledOnLinux: linux,
            productName: productName
        )
        let distributionURL = stagingURL.appendingPathComponent(
            SwiftFeatureRegistry.distributionManifestFilename
        )
        let distributionData = try Self.promotionDistributionManifestData(
            sourceManifest: source.manifest,
            productName: productName,
            sourceRelativePath: sourceRelativePath,
            isInstalledOnLinux: linux,
            normalizedDescription: metadata.description,
            normalizedToolNamePrefixes: metadata.toolNamePrefixes
        )
        try distributionData.write(to: distributionURL, options: [.atomic])

        let stagedManifestURL = stagingURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
        try distributionData.write(to: stagedManifestURL, options: [.atomic])
        return PromotionStagedPackage(
            stagingURL: stagingURL,
            packageURL: packageURL,
            stagedManifestURL: stagedManifestURL,
            metadata: metadata
        )
    }

    private func preflightStagedPackage(
        _ staged: PromotionStagedPackage,
        source: PromotionSource,
        arguments: [String: Any]
    ) async throws -> PromotionPreflight {
        var validation = try validateFeature(arguments: ["manifestPath": staged.stagedManifestURL.path])
        let blockingStagedErrors = Self.blockingValidationErrors(validation)
        guard blockingStagedErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature validation failed in staging:\n" + blockingStagedErrors.joined(separator: "\n")
            )
        }

        let shouldBuild = arguments.bool("build", "verifyBuild") ?? true
        var buildReport: SwiftFeatureBuildReport?
        var listedTools: [String] = []
        if shouldBuild {
            var buildArguments: [String: Any] = ["manifestPath": staged.stagedManifestURL.path]
            if let timeout = arguments.int("timeoutSeconds", "timeout") {
                buildArguments["timeoutSeconds"] = timeout
            }
            buildReport = try await buildFeature(arguments: buildArguments)
            guard buildReport?.ok == true else {
                throw DirectToolError.permissionDenied(
                    "Feature build failed during promotion:\n" + (buildReport?.stderr ?? "No diagnostics.")
                )
            }
            let executable = SwiftFeatureRegistry.resolvedExecutableURL(
                source.manifest.executable,
                relativeTo: staged.stagingURL
            )
            listedTools = try await promotionListTools(
                executableURL: executable,
                workingDirectory: staged.stagingURL
            )
            validation = try validateFeature(arguments: ["manifestPath": staged.stagedManifestURL.path])
        }
        return PromotionPreflight(validation: validation, buildReport: buildReport, listedTools: listedTools)
    }

    /// Drops build artefacts, restores the source `Package.resolved` when the
    /// staged one is missing, and rewrites the ZenCODE dependency to the
    /// relocatable path it has once published.
    private func finalizeStagedPackage(
        _ staged: PromotionStagedPackage,
        source: PromotionSource,
        target: PromotionTarget
    ) throws {
        try removePromotionArtifacts(from: staged.stagingURL, removeBuilderManifest: true)
        let stagedResolvedURL = staged.stagingURL.appendingPathComponent("Package.resolved")
        if !fileManager.fileExists(atPath: stagedResolvedURL.path), let sourceResolvedData = source.resolvedData {
            try sourceResolvedData.write(to: stagedResolvedURL, options: .atomic)
        }

        let finalPackageContents = try String(contentsOf: staged.packageURL, encoding: .utf8)
        let finalRelativeRoot = Self.relativePath(from: target.destinationURL, to: target.rootURL)
        let finalPackage = try Self.promotionPackageManifestRewritingZenPackagePath(
            finalPackageContents,
            zenPackagePath: finalRelativeRoot,
            packageURL: staged.packageURL
        )
        try finalPackage.write(to: staged.packageURL, atomically: true, encoding: .utf8)
    }

    /// Publishes the staged package and the catalogs; the caller holds the
    /// publication lock. A failure while moving the package or writing the
    /// catalogs rolls the destination and every catalog back, and is thrown
    /// as `persistenceFailed` wrapping the original error (or the rollback
    /// error, when the rollback itself is incomplete). Earlier failures
    /// (catalog preparation, the Git safety check, the backups) are thrown
    /// unchanged, before anything is published.
    private func publishPromotion(
        _ staged: PromotionStagedPackage,
        target: PromotionTarget,
        transactionURL: URL
    ) async throws -> [PromotionCatalogUpdate] {
        let catalogUpdates = try preparePromotionCatalogUpdates(
            metadata: staged.metadata,
            rootURL: target.rootURL,
            overwrite: target.overwrite
        )
        try await assertPromotionControlledPathsAreSafe(
            gitRoot: target.rootURL,
            paths: [target.destinationURL] + catalogUpdates.map(\.url),
            destinationExisted: target.destinationExists,
            overwrite: target.overwrite
        )

        try fileManager.createDirectory(at: transactionURL, withIntermediateDirectories: true)
        let destinationBackupURL = transactionURL.appendingPathComponent("destination", isDirectory: true)
        let catalogBackups = try catalogUpdates.map(\.url).reduce(into: [URL: PromotionCatalogBackup]()) { result, url in
            result[url] = fileManager.fileExists(atPath: url.path)
                ? .contents(try Data(contentsOf: url))
                : .absent
        }
        var published = false
        do {
            if target.destinationExists {
                try fileManager.moveItem(at: target.destinationURL, to: destinationBackupURL)
            }
            try fileManager.createDirectory(
                at: target.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: staged.stagingURL, to: target.destinationURL)
            published = true
            for update in catalogUpdates {
                try fileManager.createDirectory(at: update.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try update.data.write(to: update.url, options: [.atomic])
            }
        } catch {
            let publicationError = error
            do {
                try Self.rollbackPromotionPublication(
                    fileManager: fileManager,
                    destinationURL: target.destinationURL,
                    destinationExisted: target.destinationExists,
                    destinationBackupURL: destinationBackupURL,
                    published: published,
                    catalogBackups: catalogBackups
                )
            } catch {
                throw DirectToolError.persistenceFailed(
                    "Feature promotion failed and rollback was incomplete: \(error.localizedDescription)"
                )
            }
            throw DirectToolError.persistenceFailed(
                "Feature promotion failed; package and catalogs were rolled back: \(publicationError.localizedDescription)"
            )
        }
        return catalogUpdates
    }

    private func promotionReport(
        source: PromotionSource,
        target: PromotionTarget,
        catalogUpdates: [PromotionCatalogUpdate],
        preflight: PromotionPreflight
    ) async -> SwiftFeaturePromotionReport {
        let changedPaths = await promotionGitChangedPaths(
            rootURL: target.rootURL,
            paths: [target.destinationURL] + catalogUpdates.map(\.url)
        )
        var warnings: [String] = []
        if source.manifest.generated?.promotionReady != true {
            warnings.append("This package predates promotion-ready scaffolds; its origin was preserved in feature-distribution.json.")
        }
        if target.branch == "main" {
            warnings.append("Promotion was prepared on main; review the changes and create a feature branch before committing.")
        }
        return SwiftFeaturePromotionReport(
            id: source.id,
            sourcePath: source.url.path,
            checkoutPath: target.checkoutURL.path,
            gitRoot: target.rootURL.path,
            gitBranch: target.branch,
            destinationPath: target.destinationURL.path,
            manifestPath: target.destinationURL.appendingPathComponent(SwiftFeatureRegistry.distributionManifestFilename).path,
            packagePath: target.destinationURL.appendingPathComponent("Package.swift").path,
            catalogPaths: catalogUpdates.map(\.url.path),
            changedPaths: changedPaths,
            overwritten: target.destinationExists,
            built: preflight.buildReport?.ok == true,
            listedTools: preflight.listedTools,
            validation: preflight.validation,
            build: preflight.buildReport,
            warnings: warnings
        )
    }

    static func blockingValidationErrors(_ validation: SwiftFeatureValidationReport) -> [String] {
        validation.errors.filter { !$0.hasPrefix("Executable is missing or not executable:") }
    }

    func promotionSourceURL(id: String, arguments: [String: Any]) throws -> URL {
        guard let record = SwiftFeatureRegistry.featureRecord(
            id: id, searchRoots: featureSearchRoots, fileManager: fileManager
        ), record.source == .generated, let manifestURL = record.manifestURL else {
            throw DirectToolError.notFound("Unknown generated Swift feature: \(id).")
        }
        let registeredURL = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        if let raw = arguments.string("sourcePath", "source_path", "featurePath", "feature_path")?.nilIfBlank {
            let url = resolvedInstallPath(raw)
            let explicitURL = (url.lastPathComponent == SwiftFeatureRegistry.manifestFilename
                ? url.deletingLastPathComponent() : url).resolvingSymlinksInPath().standardizedFileURL
            guard explicitURL == registeredURL else {
                throw DirectToolError.permissionDenied(
                    "sourcePath must identify the registered generated feature '\(id)'."
                )
            }
        }
        return registeredURL
    }

    func promotionDestinationURL(
        id: String,
        rootURL: URL,
        featuresRoot: URL,
        arguments: [String: Any]
    ) throws -> URL {
        let url: URL
        if let raw = arguments.string(
            "directory", "directoryPath", "directory_path", "targetPath", "target_path",
            "destination", "destinationPath", "destination_path"
        )?.nilIfBlank {
            let expanded = NSString(string: raw).expandingTildeInPath
            url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : rootURL.appendingPathComponent(expanded)
        } else {
            url = featuresRoot.appendingPathComponent(Self.targetName(for: id), isDirectory: true)
        }
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == featuresRoot else {
            throw DirectToolError.permissionDenied(
                "Feature promotion destination must be exactly one directory below \(featuresRoot.path)."
            )
        }
        return standardized
    }

    struct PromotionGitCheckout: Sendable {
        let root: URL
        let branch: String?
        let commonDirectory: URL
    }

    enum PromotionCatalogBackup: Sendable {
        case absent
        case contents(Data)
    }

    static func rollbackPromotionPublication(
        fileManager: FileManager,
        destinationURL: URL,
        destinationExisted: Bool,
        destinationBackupURL: URL,
        published: Bool,
        catalogBackups: [URL: PromotionCatalogBackup]
    ) throws {
        if published, fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        if destinationExisted, fileManager.fileExists(atPath: destinationBackupURL.path) {
            try fileManager.moveItem(at: destinationBackupURL, to: destinationURL)
        }
        for (url, backup) in catalogBackups {
            switch backup {
            case .contents(let data):
                try data.write(to: url, options: [.atomic])
            case .absent:
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        }
    }

#if canImport(Darwin) || canImport(Glibc)
    func acquirePromotionPublicationLock(gitCommonDirectoryURL: URL) throws -> Int32 {
        let lockURL = gitCommonDirectoryURL.appendingPathComponent("zencode-feature-promotion.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DirectToolError.persistenceFailed("Could not open promotion lock: \(lockURL.path).")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw DirectToolError.persistenceFailed(
                "Another feature promotion is publishing in this checkout."
            )
        }
        return descriptor
    }

    func releasePromotionPublicationLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
#else
    func acquirePromotionPublicationLock(gitCommonDirectoryURL: URL) throws -> Int32 {
        _ = gitCommonDirectoryURL
        throw DirectToolError.permissionDenied("Feature promotion locking is unavailable on this platform.")
    }

    func releasePromotionPublicationLock(_ descriptor: Int32) { _ = descriptor }
#endif

#if canImport(Darwin) || canImport(Glibc)
    func requirePromotionGitCheckout(at url: URL) async throws -> PromotionGitCheckout {
        let rootResult = try await runPromotionGit(["rev-parse", "--show-toplevel"], at: url)
        guard rootResult.exitCode == 0 else {
            throw DirectToolError.permissionDenied("The promotion target is not a Git checkout: \(url.path).")
        }
        let rootPath = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else {
            throw DirectToolError.permissionDenied("Git did not return a checkout root for \(url.path).")
        }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let commonDirectoryResult = try await runPromotionGit(["rev-parse", "--git-common-dir"], at: root)
        guard commonDirectoryResult.exitCode == 0,
              let commonDirectoryPath = commonDirectoryResult.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            throw DirectToolError.permissionDenied("Git did not return its common directory for \(root.path).")
        }
        let commonDirectory = (commonDirectoryPath.hasPrefix("/")
            ? URL(fileURLWithPath: commonDirectoryPath, isDirectory: true)
            : root.appendingPathComponent(commonDirectoryPath, isDirectory: true))
            .standardizedFileURL
        let branchResult = try await runPromotionGit(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        let branch = branchResult.exitCode == 0
            ? branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            : nil
        return PromotionGitCheckout(root: root, branch: branch, commonDirectory: commonDirectory)
    }

    func runPromotionGit(_ arguments: [String], at directory: URL) async throws -> AsyncProcessResult {
        try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: ["-C", directory.path] + arguments,
            workingDirectory: directory,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 30
        )
    }
#else
    func requirePromotionGitCheckout(at url: URL) async throws -> PromotionGitCheckout {
        _ = url
        throw DirectToolError.permissionDenied("Git-backed feature promotion is unavailable on this platform.")
    }
#endif
}
