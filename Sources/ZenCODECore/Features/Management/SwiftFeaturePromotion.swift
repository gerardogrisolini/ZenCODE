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
    func promoteFeature(arguments: [String: Any]) async throws -> SwiftFeaturePromotionReport {
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
            id: id,
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
        guard sourceURL.standardizedFileURL.path != destinationURL.path else {
            throw DirectToolError.permissionDenied("Promotion source and destination are the same directory.")
        }

        let sourceValidation = try validateFeature(arguments: ["manifestPath": sourceManifestURL.path])
        let blockingSourceErrors = Self.blockingValidationErrors(sourceValidation)
        guard blockingSourceErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature validation failed before promotion:\n" + blockingSourceErrors.joined(separator: "\n")
            )
        }

        let stagingURL = featuresRoot.deletingLastPathComponent()
            .appendingPathComponent(".zencode-feature-promotion-\(UUID().uuidString)", isDirectory: true)
        let transactionURL = rootURL
            .appendingPathComponent(".zencode-feature-promotion-transaction-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: transactionURL)
        }
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try copyPromotionDirectoryContents(from: sourceURL, to: stagingURL)
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
            zenPackagePath: rootURL.path,
            packageURL: packageURL
        )
        let normalizedPackage = try Self.normalizedPromotionPackageManifest(rewritten, packageURL: packageURL)
        try normalizedPackage.write(to: packageURL, atomically: true, encoding: .utf8)

        let productName = PromotionCatalogMetadata.productName(
            manifest: sourceManifest,
            packageContents: normalizedPackage,
            fallback: id
        )
        guard Self.packageManifestDeclaresProduct(normalizedPackage, productName: productName) else {
            throw DirectToolError.permissionDenied(
                "Package.swift does not declare the manifest product '\(productName)'."
            )
        }
        let sourceRelativePath = Self.relativePath(from: rootURL, to: destinationURL)
        guard let linux = Self.platformLinuxArgument(arguments) else {
            throw DirectToolError.invalidInput(
                "Feature promotion requires an explicit Linux decision (linux=true or linux=false)."
            )
        }
        let metadata = try PromotionCatalogMetadata(
            id: id,
            manifest: sourceManifest,
            packageContents: normalizedPackage,
            sourceRelativePath: sourceRelativePath,
            isInstalledOnLinux: linux,
            productName: productName
        )
        let distributionURL = stagingURL.appendingPathComponent(
            SwiftFeatureRegistry.distributionManifestFilename
        )
        let distributionData = try Self.promotionDistributionManifestData(
            sourceManifest: sourceManifest,
            productName: productName,
            sourceRelativePath: sourceRelativePath,
            isInstalledOnLinux: linux,
            normalizedDescription: metadata.description,
            normalizedToolNamePrefixes: metadata.toolNamePrefixes
        )
        try distributionData.write(to: distributionURL, options: [.atomic])

        let stagedManifestURL = stagingURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
        try distributionData.write(to: stagedManifestURL, options: [.atomic])
        var validation = try validateFeature(arguments: ["manifestPath": stagedManifestURL.path])
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
            var buildArguments: [String: Any] = ["manifestPath": stagedManifestURL.path]
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
                sourceManifest.executable,
                relativeTo: stagingURL
            )
            listedTools = try await promotionListTools(
                executableURL: executable,
                workingDirectory: stagingURL
            )
            validation = try validateFeature(arguments: ["manifestPath": stagedManifestURL.path])
        }
        try removePromotionArtifacts(from: stagingURL, removeBuilderManifest: true)
        let stagedResolvedURL = stagingURL.appendingPathComponent("Package.resolved")
        if !fileManager.fileExists(atPath: stagedResolvedURL.path), let sourceResolvedData {
            try sourceResolvedData.write(to: stagedResolvedURL, options: .atomic)
        }

        let finalPackageContents = try String(contentsOf: packageURL, encoding: .utf8)
        let finalRelativeRoot = Self.relativePath(from: destinationURL, to: rootURL)
        let finalPackage = try Self.promotionPackageManifestRewritingZenPackagePath(
            finalPackageContents,
            zenPackagePath: finalRelativeRoot,
            packageURL: packageURL
        )
        try finalPackage.write(to: packageURL, atomically: true, encoding: .utf8)

        let promotionLockDescriptor = try acquirePromotionPublicationLock(gitCommonDirectoryURL: git.commonDirectory)
        defer { releasePromotionPublicationLock(promotionLockDescriptor) }

        let catalogUpdates = try preparePromotionCatalogUpdates(
            metadata: metadata,
            rootURL: rootURL,
            overwrite: overwrite
        )
        try await assertPromotionControlledPathsAreSafe(
            gitRoot: rootURL,
            paths: [destinationURL] + catalogUpdates.map(\.url),
            destinationExisted: destinationExists,
            overwrite: overwrite
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
            if destinationExists {
                try fileManager.moveItem(at: destinationURL, to: destinationBackupURL)
            }
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
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
                    destinationURL: destinationURL,
                    destinationExisted: destinationExists,
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

        let changedPaths = await promotionGitChangedPaths(
            rootURL: rootURL,
            paths: [destinationURL] + catalogUpdates.map(\.url)
        )
        var warnings: [String] = []
        if sourceManifest.generated?.promotionReady != true {
            warnings.append("This package predates promotion-ready scaffolds; its origin was preserved in feature-distribution.json.")
        }
        if branch == "main" {
            warnings.append("Promotion was prepared on main; review the changes and create a feature branch before committing.")
        }
        return SwiftFeaturePromotionReport(
            id: id,
            sourcePath: sourceURL.path,
            checkoutPath: checkoutURL.path,
            gitRoot: rootURL.path,
            gitBranch: branch,
            destinationPath: destinationURL.path,
            manifestPath: destinationURL.appendingPathComponent(SwiftFeatureRegistry.distributionManifestFilename).path,
            packagePath: destinationURL.appendingPathComponent("Package.swift").path,
            catalogPaths: catalogUpdates.map(\.url.path),
            changedPaths: changedPaths,
            overwritten: destinationExists,
            built: buildReport?.ok == true,
            listedTools: listedTools,
            validation: validation,
            build: buildReport,
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
