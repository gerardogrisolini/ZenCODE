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
        let blockingSourceErrors = sourceValidation.errors.filter {
            !$0.hasPrefix("Executable is missing or not executable:")
        }
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
        let blockingStagedErrors = validation.errors.filter {
            !$0.hasPrefix("Executable is missing or not executable:")
        }
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
            try removePromotionArtifacts(from: stagingURL, removeBuilderManifest: true)
        }
        if !shouldBuild {
            try removePromotionArtifacts(from: stagingURL, removeBuilderManifest: true)
        }
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

    private func promotionSourceURL(id: String, arguments: [String: Any]) throws -> URL {
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

    private func promotionDestinationURL(
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

    private struct PromotionGitCheckout: Sendable {
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
    private func acquirePromotionPublicationLock(gitCommonDirectoryURL: URL) throws -> Int32 {
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

    private func releasePromotionPublicationLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
#else
    private func acquirePromotionPublicationLock(gitCommonDirectoryURL: URL) throws -> Int32 {
        _ = gitCommonDirectoryURL
        throw DirectToolError.permissionDenied("Feature promotion locking is unavailable on this platform.")
    }

    private func releasePromotionPublicationLock(_ descriptor: Int32) { _ = descriptor }
#endif

#if canImport(Darwin) || canImport(Glibc)
    private func requirePromotionGitCheckout(at url: URL) async throws -> PromotionGitCheckout {
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

    private func runPromotionGit(_ arguments: [String], at directory: URL) async throws -> AsyncProcessResult {
        try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: ["-C", directory.path] + arguments,
            workingDirectory: directory,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 30
        )
    }
#else
    private func requirePromotionGitCheckout(at url: URL) async throws -> PromotionGitCheckout {
        _ = url
        throw DirectToolError.permissionDenied("Git-backed feature promotion is unavailable on this platform.")
    }
#endif
}


extension SwiftFeatureRuntime {
    private struct PromotionCatalogMetadata: Sendable {
        let id: String
        let productName: String
        let sourceRelativePath: String
        let description: String
        let toolNamePrefixes: [String]
        let toolNameAliases: [String]
        let discoversToolsAtRuntime: Bool
        let supportsPersistentSession: Bool
        let invocationTimeoutSeconds: TimeInterval?
        let isInstalledOnLinux: Bool

        init(
            id: String,
            manifest: SwiftFeatureManifest,
            packageContents: String,
            sourceRelativePath: String,
            isInstalledOnLinux: Bool,
            productName: String
        ) throws {
            self.id = id
            self.productName = productName.nilIfBlank
                ?? Self.productName(manifest: manifest, packageContents: packageContents, fallback: id)
            self.sourceRelativePath = sourceRelativePath
            self.description = manifest.description?.nilIfBlank
                ?? manifest.displayName?.nilIfBlank
                ?? "Swift feature for ZenCODE."
            self.toolNamePrefixes = Self.prefixes(manifest: manifest, id: id)
            self.toolNameAliases = manifest.toolNameAliases
            self.discoversToolsAtRuntime = manifest.discoversToolsAtRuntime
            self.supportsPersistentSession = manifest.supportsPersistentSession
            self.invocationTimeoutSeconds = manifest.invocationTimeoutSeconds
            self.isInstalledOnLinux = isInstalledOnLinux
        }

        static func productName(
            manifest: SwiftFeatureManifest,
            packageContents: String,
            fallback: String
        ) -> String {
            if let product = manifest.build?.product?.nilIfBlank {
                return product
            }
            let pattern = #"(?:name|product):\s*"([A-Za-z0-9._-]+)""#
            if let expression = try? NSRegularExpression(pattern: pattern),
               let match = expression.firstMatch(
                   in: packageContents,
                   range: NSRange(packageContents.startIndex..<packageContents.endIndex, in: packageContents)
               ),
               let range = Range(match.range(at: 1), in: packageContents),
               let value = String(packageContents[range]).nilIfBlank {
                return value
            }
            return fallback
        }

        private static func prefixes(manifest: SwiftFeatureManifest, id: String) -> [String] {
            if !manifest.toolNamePrefixes.isEmpty { return manifest.toolNamePrefixes }
            if let name = manifest.tools.first?.name, let dot = name.firstIndex(of: ".") {
                return [String(name[...dot])]
            }
            return [SwiftFeatureRuntime.defaultToolPrefix(for: id) + "."]
        }
    }

    private struct PromotionCatalogUpdate: Sendable {
        let url: URL
        let data: Data
    }

    private func preparePromotionCatalogUpdates(
        metadata: PromotionCatalogMetadata,
        rootURL: URL,
        overwrite: Bool
    ) throws -> [PromotionCatalogUpdate] {
        let packageMetadataRoot = rootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("ZenPackageMetadata", isDirectory: true)
        let declarativeURL = packageMetadataRoot
            .appendingPathComponent(ZenBundledFeatureCatalog.declarativeCatalogFilename)
            .standardizedFileURL
        let distributionURL = packageMetadataRoot
            .appendingPathComponent("ZenBundledFeatureCatalog.swift")
            .standardizedFileURL
        let runtimeURL = rootURL
            .appendingPathComponent("Sources/ZenCODECore/ZenCODE/Features/SwiftBundledFeatureCatalog.swift")
            .standardizedFileURL

        let declarativeData = try promotionDeclarativeCatalogData(
            metadata: metadata, url: declarativeURL, overwrite: overwrite
        )
        var updates = [PromotionCatalogUpdate(url: declarativeURL, data: declarativeData)]
        if fileManager.fileExists(atPath: distributionURL.path) {
            updates.append(PromotionCatalogUpdate(
                url: distributionURL,
                data: try promotionDistributionCatalogData(from: declarativeData)
            ))
        }
        if fileManager.fileExists(atPath: runtimeURL.path) {
            let contents = try String(contentsOf: runtimeURL, encoding: .utf8)
            updates.append(PromotionCatalogUpdate(
                url: runtimeURL,
                data: Data(try promotionRuntimeCatalogContents(contents, metadata: metadata, overwrite: overwrite).utf8)
            ))
        }
        return updates
    }

    private func promotionDistributionCatalogData(from declarativeData: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: declarativeData) as? [String: Any],
              let rawFeatures = root["features"] as? [[String: Any]] else {
            throw DirectToolError.permissionDenied("Could not generate the Swift feature catalog.")
        }
        let features = try rawFeatures.map { object -> (String, String, String, Bool) in
            guard let id = object["id"] as? String,
                  let product = object["productName"] as? String,
                  let path = object["sourceRelativePath"] as? String,
                  let linux = object["isInstalledOnLinux"] as? Bool else {
                throw DirectToolError.permissionDenied("Declarative feature catalog contains an incomplete entry.")
            }
            return (id, product, path, linux)
        }.sorted { $0.0 < $1.0 }
        let entries = features.map { feature in
            """
                    ZenBundledFeatureMetadata(
                        id: \(Self.swiftLiteral(feature.0)),
                        productName: \(Self.swiftLiteral(feature.1)),
                        sourceRelativePath: \(Self.swiftLiteral(feature.2)),
                        isInstalledOnLinux: \(feature.3),
                    )
            """
        }.joined(separator: ",\n")
        let output = """
        //
        //  ZenBundledFeatureCatalog.swift
        //  Generated by Scripts/GenerateFeatureCatalog.swift. Do not edit by hand.
        //

        public struct ZenBundledFeatureMetadata: Sendable, Equatable, Hashable {
            public let id: String
            public let productName: String
            public let sourceRelativePath: String
            public let isInstalledOnLinux: Bool

            public init(id: String, productName: String, sourceRelativePath: String, isInstalledOnLinux: Bool) {
                self.id = id
                self.productName = productName
                self.sourceRelativePath = sourceRelativePath
                self.isInstalledOnLinux = isInstalledOnLinux
            }
        }

        public enum ZenBundledFeatureCatalog {
            public static let declarativeCatalogFilename = "feature-catalog.json"

            public static let all: [ZenBundledFeatureMetadata] = [
        \(entries)
            ]

            public static func feature(id: String) -> ZenBundledFeatureMetadata? {
                all.first { $0.id == id }
            }

            public static var linuxInstallerProductNames: [String] {
                all.filter(\\.isInstalledOnLinux).map(\\.productName)
            }
        }
        """ + "\n"
        return Data(output.utf8)
    }

    private func promotionDeclarativeCatalogData(
        metadata: PromotionCatalogMetadata,
        url: URL,
        overwrite: Bool
    ) throws -> Data {
        var root: [String: Any]
        if fileManager.fileExists(atPath: url.path) {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw DirectToolError.permissionDenied("Feature catalog is not a JSON object: \(url.path)")
            }
            root = value
        } else {
            root = ["schemaVersion": 1, "features": [[String: Any]]()]
        }
        var features = root["features"] as? [[String: Any]] ?? []
        let ids = features.compactMap { $0["id"] as? String }
        let duplicateIDs = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        guard duplicateIDs.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature catalog contains duplicate ids: \(duplicateIDs.joined(separator: ", "))."
            )
        }
        let products = features.compactMap { $0["productName"] as? String }
        let duplicateProducts = Dictionary(grouping: products, by: { $0 })
            .filter { $0.value.count > 1 }.keys.sorted()
        guard duplicateProducts.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature catalog contains duplicate products: \(duplicateProducts.joined(separator: ", "))."
            )
        }
        if let collision = features.first(where: {
            ($0["productName"] as? String) == metadata.productName
                && ($0["id"] as? String) != metadata.id
        }), let collisionID = collision["id"] as? String {
            throw DirectToolError.permissionDenied(
                "Product '\(metadata.productName)' is already declared by feature '\(collisionID)'."
            )
        }
        let record = promotionCatalogJSONRecord(metadata)
        if let index = features.firstIndex(where: { $0["id"] as? String == metadata.id }) {
            guard overwrite else {
                throw DirectToolError.permissionDenied(
                    "Feature catalog already contains '\(metadata.id)'. Pass overwrite=true to replace it."
                )
            }
            features[index] = record
        } else {
            features.append(record)
        }
        features.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        root["schemaVersion"] = (root["schemaVersion"] as? Int) ?? 1
        root["features"] = features
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    private func promotionCatalogJSONRecord(_ metadata: PromotionCatalogMetadata) -> [String: Any] {
        var record: [String: Any] = [
            "id": metadata.id,
            "productName": metadata.productName,
            "sourceRelativePath": metadata.sourceRelativePath,
            "isInstalledOnLinux": metadata.isInstalledOnLinux,
            "description": metadata.description,
            "toolNamePrefixes": metadata.toolNamePrefixes
        ]
        if metadata.discoversToolsAtRuntime { record["discoversToolsAtRuntime"] = true }
        if !metadata.toolNameAliases.isEmpty { record["toolNameAliases"] = metadata.toolNameAliases }
        if metadata.supportsPersistentSession { record["supportsPersistentSession"] = true }
        if let timeout = metadata.invocationTimeoutSeconds {
            record["invocationTimeoutSeconds"] = timeout
        }
        return record
    }

    private func promotionDistributionCatalogContents(
        _ contents: String,
        metadata: PromotionCatalogMetadata,
        overwrite: Bool
    ) throws -> String {
        if contents.contains("id: \"\(metadata.id)\"") {
            if overwrite {
                throw DirectToolError.permissionDenied(
                    "Replacing an existing Swift catalog entry is not supported safely; choose a new feature id."
                )
            }
            throw DirectToolError.permissionDenied(
                "Distribution catalog already contains '\(metadata.id)'."
            )
        }
        let marker = "    ]\n\n    public static func feature"
        guard let range = contents.range(of: marker) else {
            throw DirectToolError.permissionDenied("Could not find distribution catalog insertion point.")
        }
        let entry = """
            ,
                    ZenBundledFeatureMetadata(
                        id: \(Self.swiftLiteral(metadata.id)),
                        productName: \(Self.swiftLiteral(metadata.productName)),
                        sourceRelativePath: \(Self.swiftLiteral(metadata.sourceRelativePath)),
                        isInstalledOnLinux: \(metadata.isInstalledOnLinux),
                    )
            """
        return contents.replacingCharacters(in: range, with: entry + String(contents[range.lowerBound...]))
    }

    private func promotionRuntimeCatalogContents(
        _ contents: String,
        metadata: PromotionCatalogMetadata,
        overwrite: Bool
    ) throws -> String {
        if contents.contains("id: \"\(metadata.id)\"") {
            if overwrite {
                throw DirectToolError.permissionDenied(
                    "Replacing an existing Swift catalog entry is not supported safely; choose a new feature id."
                )
            }
            throw DirectToolError.permissionDenied("Runtime catalog already contains '\(metadata.id)'.")
        }
        let marker = "        ]\n    }\n\n    private static func metadata"
        guard let range = contents.range(of: marker) else {
            throw DirectToolError.permissionDenied("Could not find runtime catalog insertion point.")
        }
        let timeout = metadata.invocationTimeoutSeconds.map { "\n                        invocationTimeoutSeconds: \($0)" } ?? ""
        let entry = """
            ,
                    SwiftFeatureRuntime.BundledFeatureDefinition(
                        id: \(Self.swiftLiteral(metadata.id)),
                        executableName: \(Self.swiftLiteral(metadata.productName)),
                        description: \(Self.swiftLiteral(metadata.description)),
                        sourceRelativePath: \(Self.swiftLiteral(metadata.sourceRelativePath)),
                        tools: [],
                        toolNamePrefixes: \(Self.swiftLiteralArray(metadata.toolNamePrefixes)),
                        toolNameAliases: \(Self.swiftLiteralArray(metadata.toolNameAliases)),
                        discoversToolsAtRuntime: \(metadata.discoversToolsAtRuntime),
                        supportsPersistentSession: \(metadata.supportsPersistentSession),\(timeout)
                    )
            """
        return contents.replacingCharacters(in: range, with: entry + String(contents[range.lowerBound...]))
    }


    private static func normalizedPromotionPackageManifest(
        _ contents: String,
        packageURL: URL
    ) throws -> String {
        var normalized = contents
        guard normalized.components(separatedBy: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == SwiftFeatureRuntime.zenPackagePathMarker
        }) else {
            throw DirectToolError.permissionDenied(
                "\(packageURL.path) must contain the '\(SwiftFeatureRuntime.zenPackagePathMarker)' marker before the ZenCODE dependency."
            )
        }
        if normalized.contains("enableUpcomingFeature(\"MemberImportVisibility\")") { return normalized }
        let importMarker = "import PackageDescription\n"
        guard let importRange = normalized.range(of: importMarker) else {
            throw DirectToolError.permissionDenied("\(packageURL.path) must import PackageDescription.")
        }
        normalized.replaceSubrange(importRange, with: """
            import PackageDescription

            let memberImportVisibilitySettings: [SwiftSetting] = [
                .enableUpcomingFeature("MemberImportVisibility")
            ]
            """)
        guard let targetStart = normalized.range(of: ".executableTarget(") else {
            throw DirectToolError.permissionDenied("\(packageURL.path) must declare an executableTarget.")
        }
        let suffix = normalized[targetStart.upperBound...]
        let targetPattern = #"\n(\s*)\](\n\s*)\)"#
        guard let expression = try? NSRegularExpression(pattern: targetPattern),
              let match = expression.firstMatch(
                  in: String(suffix),
                  range: NSRange(suffix.startIndex..<suffix.endIndex, in: suffix)
              ),
              let firstIndentRange = Range(match.range(at: 1), in: suffix),
              let secondIndentRange = Range(match.range(at: 2), in: suffix) else {
            throw DirectToolError.permissionDenied(
                "\(packageURL.path) has an unsupported target layout; add MemberImportVisibility explicitly."
            )
        }
        let firstIndent = suffix[firstIndentRange]
        let secondIndent = suffix[secondIndentRange].dropFirst() // captured newline
        let replacement = "\n\(firstIndent)],\n\(firstIndent)swiftSettings: memberImportVisibilitySettings\n\(secondIndent))"
        var normalizedSuffix = String(suffix)
        normalizedSuffix.replaceSubrange(
            Range(match.range, in: normalizedSuffix)!,
            with: replacement
        )
        normalized.replaceSubrange(targetStart.upperBound..<normalized.endIndex, with: normalizedSuffix)
        return normalized
    }

    /// Promotion accepts old Builder scaffolds that predate the marker, but only
    /// when their manifest contains exactly one local package dependency. This
    /// keeps the compatibility fallback deterministic and avoids rewriting an
    /// unrelated local dependency.
    private static func promotionPackageManifestRewritingZenPackagePath(
        _ contents: String,
        zenPackagePath: String,
        packageURL: URL
    ) throws -> String {
        if contents.components(separatedBy: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == zenPackagePathMarker
        }) {
            var lines = contents.components(separatedBy: "\n")
            guard let markerIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == zenPackagePathMarker
            }) else { return contents }
            var dependencyIndex = markerIndex + 1
            while dependencyIndex < lines.count,
                  lines[dependencyIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                dependencyIndex += 1
            }
            guard dependencyIndex < lines.count,
                  let rewritten = promotionRewrittenPackagePathLine(
                    lines[dependencyIndex], zenPackagePath: zenPackagePath
                  ) else {
                throw DirectToolError.permissionDenied(
                    "\(packageURL.path) must declare .package(path:) after the package-path marker."
                )
            }
            lines[dependencyIndex] = rewritten
            return lines.joined(separator: "\n")
        }

        let pattern = #"(?m)^(\s*)(\.package\(\s*path:\s*\"(?:[^\"\\]|\\.)*\"\s*\).*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            throw DirectToolError.permissionDenied("Could not inspect \(packageURL.path).")
        }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        let matches = expression.matches(in: contents, range: range)
        guard matches.count == 1,
              let match = matches.first,
              let fullRange = Range(match.range(at: 0), in: contents),
              let indentRange = Range(match.range(at: 1), in: contents) else {
            throw DirectToolError.permissionDenied(
                "\(packageURL.path) must contain the package-path marker or exactly one local .package(path:) dependency."
            )
        }
        let indent = contents[indentRange]
        let replacement = "\(indent)\(zenPackagePathMarker)\n\(indent).package(name: \"ZenCODE\", path: \(swiftStringLiteral(zenPackagePath)))"
        return contents.replacingCharacters(in: fullRange, with: replacement)
    }

    private static func promotionRewrittenPackagePathLine(
        _ line: String,
        zenPackagePath: String
    ) -> String? {
        let pattern = #"^(\s*)\.package\(\s*(?:name:\s*\"ZenCODE\"\s*,\s*)?path:\s*\"(?:[^\"\\]|\\.)*\"\s*\)(.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let indentRange = Range(match.range(at: 1), in: line),
              let trailingRange = Range(match.range(at: 2), in: line) else { return nil }
        return line[indentRange]
            + ".package(name: \"ZenCODE\", path: \(swiftStringLiteral(zenPackagePath)))"
            + line[trailingRange]
    }

    private static func packageManifestDeclaresProduct(
        _ contents: String,
        productName: String
    ) -> Bool {
        let quoted = swiftLiteral(productName)
        return contents.contains("name: \(quoted)")
    }
    private static func promotionDistributionManifestData(
        sourceManifest: SwiftFeatureManifest,
        productName: String,
        sourceRelativePath: String,
        isInstalledOnLinux: Bool,
        normalizedDescription: String,
        normalizedToolNamePrefixes: [String]
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(sourceManifest)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw DirectToolError.permissionDenied("Could not encode feature distribution metadata.")
        }
        object["distributionSchemaVersion"] = 1
        object["productName"] = productName
        object["sourceRelativePath"] = sourceRelativePath
        object["isInstalledOnLinux"] = isInstalledOnLinux
        object["platforms"] = isInstalledOnLinux ? ["macOS", "linux"] : ["macOS"]
        object["description"] = normalizedDescription
        object["toolNamePrefixes"] = normalizedToolNamePrefixes
        if let generated = object["generated"] { object["origin"] = generated }
        object.removeValue(forKey: "enabled")
        object.removeValue(forKey: "generated")
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func promotionListTools(
        executableURL: URL,
        workingDirectory: URL
    ) async throws -> [String] {
        let result = try await AsyncProcessRunner.run(
            executableURL: executableURL,
            arguments: ["--list-tools"],
            workingDirectory: workingDirectory,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 120
        )
        guard !result.timedOut, result.exitCode == 0 else {
            throw DirectToolError.processFailed(
                "feature.promote --list-tools failed: \(result.stderr.nilIfBlank ?? "exit code \(result.exitCode)")"
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: result.stdoutData) as? [String: Any],
              let rawTools = object["tools"] as? [[String: Any]], !rawTools.isEmpty else {
            throw DirectToolError.invalidResponse("feature.promote expected a non-empty tools array from --list-tools.")
        }
        var descriptors: [ToolDescriptor] = []
        for rawTool in rawTools {
            let descriptor: ToolDescriptor
            do {
                descriptor = try JSONDecoder().decode(
                    ToolDescriptor.self,
                    from: JSONSerialization.data(withJSONObject: rawTool)
                )
            } catch {
                throw DirectToolError.invalidResponse(
                    "feature.promote received an invalid tool descriptor: \(error.localizedDescription)"
                )
            }
            guard descriptor.presentation?.isSemanticallyValid == true else {
                throw DirectToolError.invalidResponse(
                    "Tool '\(descriptor.name)' lacks explicit valid presentation metadata."
                )
            }
            guard (try? JSONSerialization.jsonObject(with: Data(descriptor.inputSchema.utf8))) != nil else {
                throw DirectToolError.invalidResponse("Tool '\(descriptor.name)' has invalid inputSchema JSON.")
            }
            descriptors.append(descriptor)
        }
        let errors = Self.validationErrorsForToolNames(descriptors.map(\.name))
        guard errors.isEmpty else { throw DirectToolError.permissionDenied(errors.joined(separator: "\n")) }
        return ToolDescriptor.canonicalized(descriptors).map(\.name)
    }

    static func promotionPackageResolvedData(
        in featureDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> Data? {
        let entries = try fileManager.contentsOfDirectory(
            at: featureDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        guard let resolvedURL = entries.first(where: { $0.lastPathComponent == "Package.resolved" }) else {
            return nil
        }
        let values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw DirectToolError.permissionDenied(
                "Package.resolved must be a regular file, not a symbolic link: \(resolvedURL.path)"
            )
        }
        return try Data(contentsOf: resolvedURL)
    }

    static func assertPromotionManifestPathsAreConfined(
        _ manifest: SwiftFeatureManifest,
        featureDirectoryURL: URL
    ) throws {
        let root = featureDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        func confinedURL(_ rawPath: String, field: String) throws -> URL {
            let expanded = NSString(string: rawPath).expandingTildeInPath
            guard !expanded.hasPrefix("/") else {
                throw DirectToolError.permissionDenied("Promotion manifest \(field) must be relative to the feature package.")
            }
            let candidate = root.appendingPathComponent(expanded)
                .resolvingSymlinksInPath().standardizedFileURL
            guard path(candidate, isDescendantOf: root) else {
                throw DirectToolError.permissionDenied("Promotion manifest \(field) escapes the feature package.")
            }
            return candidate
        }

        _ = try confinedURL(manifest.executable, field: "executable")
        if let build = manifest.build {
            if let packagePath = build.packagePath?.nilIfBlank {
                let packageURL = try confinedURL(packagePath, field: "build.packagePath")
                guard packageURL == root else {
                    throw DirectToolError.permissionDenied(
                        "Promotion manifest build.packagePath must identify the package root."
                    )
                }
            }
            if let executablePath = build.executablePath?.nilIfBlank {
                _ = try confinedURL(executablePath, field: "build.executablePath")
            }
            let pathChangingArguments: Set<String> = [
                "--package-path", "--scratch-path", "--build-path", "--cache-path",
                "--config-path", "--security-path"
            ]
            guard !build.arguments.contains(where: { argument in
                pathChangingArguments.contains(argument)
                    || pathChangingArguments.contains(where: { argument.hasPrefix($0 + "=") })
            }) else {
                throw DirectToolError.permissionDenied(
                    "Promotion manifest build arguments cannot override SwiftPM package or storage paths."
                )
            }
        }
    }

#if canImport(Darwin) || canImport(Glibc)
    private func assertPromotionControlledPathsAreSafe(
        gitRoot: URL,
        paths: [URL],
        destinationExisted: Bool,
        overwrite: Bool
    ) async throws {
        let relative = paths.map { Self.relativePath(from: gitRoot, to: $0) }
        let result = try await runPromotionGit(
            ["status", "--short", "--untracked-files=all", "--"] + relative,
            at: gitRoot
        )
        guard result.exitCode == 0 else {
            throw DirectToolError.permissionDenied("Could not inspect controlled promotion paths in Git.")
        }
        let lines = result.stdout
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty }
        if lines.isEmpty { return }
        let destinationPath = relative[0]
        let catalogPaths = Set(relative.dropFirst())
        let destinationOnly = destinationExisted && overwrite && lines.allSatisfy {
            let path = $0.count > 3 ? String($0.dropFirst(3)) : $0
            return path == destinationPath || path.hasPrefix(destinationPath + "/")
        }
        let expectedNewCatalogs = lines.allSatisfy {
            guard $0.hasPrefix("??") else { return false }
            let path = $0.count > 3 ? String($0.dropFirst(3)) : $0
            return catalogPaths.contains(path)
        }
        guard destinationOnly || expectedNewCatalogs else {
            throw DirectToolError.permissionDenied(
                "Controlled promotion paths have uncommitted Git changes:\n"
                    + lines.joined(separator: "\n")
                    + "\nUnrelated changes are allowed; clean or stash package/catalog paths first."
            )
        }
    }
#else
    private func assertPromotionControlledPathsAreSafe(
        gitRoot: URL, paths: [URL], destinationExisted: Bool, overwrite: Bool
    ) async throws { _ = gitRoot; _ = paths; _ = destinationExisted; _ = overwrite }
#endif

    private func copyPromotionDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let allowedTopLevel: Set<String> = [
            "Package.swift", "Package.resolved", "Sources", "Tests",
            "README", "README.md", "LICENSE", "LICENSE.md", "NOTICE", "NOTICE.md"
        ]
        let entries = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries where allowedTopLevel.contains(entry.lastPathComponent) {
            try copyPromotionEntry(entry, to: destinationURL.appendingPathComponent(entry.lastPathComponent))
        }
    }

    private func copyPromotionEntry(_ entry: URL, to destination: URL) throws {
        let forbiddenNames: Set<String> = [".build", ".swiftpm", ".git", ".DS_Store", SwiftFeatureRegistry.manifestFilename]
        guard !forbiddenNames.contains(entry.lastPathComponent) else { return }
        let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { return }
        if values.isDirectory == true {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
            for child in children {
                try copyPromotionEntry(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else if values.isRegularFile == true {
            try fileManager.copyItem(at: entry, to: destination)
        }
    }

    private func removePromotionArtifacts(from directoryURL: URL, removeBuilderManifest: Bool) throws {
        var names = [".build", ".swiftpm", ".git", ".DS_Store"]
        if removeBuilderManifest { names.append(SwiftFeatureRegistry.manifestFilename) }
        for name in names {
            let url = directoryURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    private static func platformLinuxArgument(_ arguments: [String: Any]) -> Bool? {
        if let explicit = arguments.bool(
            "isInstalledOnLinux", "is_installed_on_linux", "linux", "supportedOnLinux", "supported_on_linux"
        ) {
            return explicit
        }
        let platforms = Self.stringArrayArgument(arguments, keys: ["platforms", "supportedPlatforms", "supported_platforms"])
        guard !platforms.isEmpty else { return nil }
        return platforms.contains { $0.lowercased() == "linux" }
    }

    private static func relativePath(from sourceURL: URL, to destinationURL: URL) -> String {
        let source = sourceURL.standardizedFileURL.pathComponents
        let destination = destinationURL.standardizedFileURL.pathComponents
        var common = 0
        while common < source.count, common < destination.count, source[common] == destination[common] { common += 1 }
        let up = Array(repeating: "..", count: max(0, source.count - common))
        let down = Array(destination.dropFirst(common))
        let parts = up + down
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    private static func swiftLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func swiftLiteralArray(_ values: [String]) -> String {
        "[" + values.map(swiftLiteral).joined(separator: ", ") + "]"
    }

    private func promotionGitChangedPaths(rootURL: URL, paths: [URL]) async -> [String] {
#if canImport(Darwin) || canImport(Glibc)
        let relative = paths.map { Self.relativePath(from: rootURL, to: $0) }
        guard let result = try? await runPromotionGit(["status", "--short", "--"] + relative, at: rootURL),
              result.exitCode == 0 else { return relative }
        let lines = result.stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        return lines.isEmpty ? relative : lines
#else
        return paths.map { Self.relativePath(from: rootURL, to: $0) }
#endif
    }
}
