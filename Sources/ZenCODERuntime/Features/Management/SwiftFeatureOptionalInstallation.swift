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
    /// Catalog identity (`git-tools`, `web-tools`, …).
    public let id: String
    /// Human readable name used by the setup wizard (`Git`, `Web`, …).
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

/// Receives ordered, human-readable status updates while an optional feature
/// package is prepared, built, and published.
public typealias SwiftFeatureOptionalInstallProgress = @Sendable (String) async -> Void

extension SwiftFeatureRuntime {
    /// Marker line that precedes the ZenCODE `.package(name: "ZenCODE", path:)` dependency in
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

    /// Every optional feature the current build can install, with its live
    /// installation state resolved from the user feature root.
    public static func optionalFeatures(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [SwiftFeatureOptionalFeature] {
        let records = defaultFeatureRecords(searchRoots: searchRoots, fileManager: fileManager)
        let recordsByID = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let featureRootURL = optionalFeatureRootURL(searchRoots: searchRoots, fileManager: fileManager)

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
                    supportedOnCurrentPlatform: isOptionalFeatureSupportedOnCurrentPlatform(metadata: metadata),
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
        Self.optionalFeatures(searchRoots: featureSearchRoots, fileManager: fileManager)
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

        return try optionalFeaturePackagesDiffer(
            normalizedOptionalFeaturePackageEntries(at: sourceDirectoryURL),
            normalizedOptionalFeaturePackageEntries(at: installedDirectoryURL)
        )
    }

    /// One comparable file of an optional feature package. `Package.swift` is
    /// carried already normalized; every other file is read only when the
    /// cheaper path and size checks could not tell the packages apart.
    private struct OptionalFeaturePackageEntry {
        let url: URL
        let size: Int?
        let normalizedContents: Data?

        func contents() throws -> Data {
            if let normalizedContents {
                return normalizedContents
            }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
    }

    /// Compares two normalized packages with early exit: the set of relative
    /// paths first, then file sizes, then file contents one pair at a time.
    private func optionalFeaturePackagesDiffer(
        _ source: [String: OptionalFeaturePackageEntry],
        _ installed: [String: OptionalFeaturePackageEntry]
    ) throws -> Bool {
        guard source.count == installed.count,
              source.keys.allSatisfy({ installed[$0] != nil }) else {
            return true
        }
        for (relativePath, sourceEntry) in source {
            if let sourceSize = sourceEntry.size,
               let installedSize = installed[relativePath]?.size,
               sourceSize != installedSize {
                return true
            }
        }
        for relativePath in source.keys.sorted() {
            guard let sourceEntry = source[relativePath],
                  let installedEntry = installed[relativePath] else {
                return true
            }
            if try sourceEntry.contents() != installedEntry.contents() {
                return true
            }
        }
        return false
    }

    private func normalizedOptionalFeaturePackageEntries(
        at packageDirectoryURL: URL
    ) throws -> [String: OptionalFeaturePackageEntry] {
        var entries: [String: OptionalFeaturePackageEntry] = [:]
        try collectNormalizedOptionalFeaturePackageEntries(
            at: packageDirectoryURL,
            relativePath: "",
            into: &entries
        )
        return entries
    }

    private func collectNormalizedOptionalFeaturePackageEntries(
        at directoryURL: URL,
        relativePath: String,
        into files: inout [String: OptionalFeaturePackageEntry]
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
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
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isSymbolicLink != true else {
                throw DirectToolError.permissionDenied(
                    "Refusing to inspect a symbolic link in feature package: \(entryURL.path)"
                )
            }
            if values.isDirectory == true {
                try collectNormalizedOptionalFeaturePackageEntries(
                    at: entryURL,
                    relativePath: entryRelativePath,
                    into: &files
                )
            } else if values.isRegularFile == true {
                if entryRelativePath == "Package.swift" {
                    let contents = try String(contentsOf: entryURL, encoding: .utf8)
                    let normalized = Data(try Self.packageManifestRewritingZenPackagePath(
                        contents,
                        zenPackagePath: "/__zencode_package_root__",
                        packageURL: entryURL
                    ).utf8)
                    files[entryRelativePath] = OptionalFeaturePackageEntry(
                        url: entryURL,
                        size: normalized.count,
                        normalizedContents: normalized
                    )
                } else {
                    files[entryRelativePath] = OptionalFeaturePackageEntry(
                        url: entryURL,
                        size: values.fileSize,
                        normalizedContents: nil
                    )
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
    /// rewritten `.package(name: "ZenCODE", path:)` dependency.
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
            guard fileManager.fileExists(atPath: explicitURL.appendingPathComponent("Package.swift").path) else {
                throw DirectToolError.permissionDenied("ZenCODE package root not found at \(explicitURL.path).")
            }
            return explicitURL
        }

        let candidates: [URL] = [
            sourcePackageRootURL(fileManager: fileManager),
            supportSourceURL,
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true).standardizedFileURL
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
}
