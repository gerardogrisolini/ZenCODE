import Foundation
import ToolCore
import ZenPackageMetadata

extension SwiftFeatureRuntime {
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
        let contents = try preparedFeaturePackageContents(
            definition: definition,
            sourceDirectoryURL: sourceDirectoryURL,
            zenPackageRootURL: zenPackageRootURL,
            displayName: displayName,
            enabled: false,
            destinationDirectoryURL: destinationDirectoryURL,
            featureRootURL: featureRootURL
        )

        let stagingDirectoryURL = featureRootURL.appendingPathComponent(
            ".zencode-feature-install-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        do {
            try copyFeatureDirectoryContents(from: sourceDirectoryURL, to: stagingDirectoryURL)
            try Self.write(contents, to: stagingDirectoryURL)
        } catch {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw error
        }

        return Self.materializedFeaturePackage(
            definition: definition,
            sourceDirectoryURL: sourceDirectoryURL,
            directoryURL: stagingDirectoryURL,
            copied: false
        )
    }

    /// Publishes a candidate only after it has passed validation/build. The
    /// complete sibling candidate replaces the installed directory with backup
    /// rollback if publication cannot be completed.
    func publishStagedOptionalFeaturePackage(stagedDirectoryURL: URL, destinationDirectoryURL: URL) throws {
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
        let contents = try preparedFeaturePackageContents(
            definition: definition,
            sourceDirectoryURL: sourceDirectoryURL,
            zenPackageRootURL: zenPackageRootURL,
            displayName: displayName,
            enabled: enabled,
            destinationDirectoryURL: destinationDirectoryURL,
            featureRootURL: featureRootURL
        )

        let copied = try installFeatureDirectory(
            sourceDirectoryURL: sourceDirectoryURL,
            destinationDirectoryURL: destinationDirectoryURL,
            overwrite: overwrite
        ) { stagingURL in
            try Self.write(contents, to: stagingURL)
        }

        return Self.materializedFeaturePackage(
            definition: definition,
            sourceDirectoryURL: sourceDirectoryURL,
            directoryURL: destinationDirectoryURL,
            copied: copied
        )
    }

    /// The `Package.swift` and the `feature.json` a feature package gets when
    /// it is installed.
    private struct FeaturePackageContents {
        let package: String
        let manifest: String
    }

    /// Checks that `destinationDirectoryURL` is inside the feature root and
    /// that `sourceDirectoryURL` is a SwiftPM package, then returns its
    /// `Package.swift` pointing at `zenPackageRootURL` and its generated
    /// `feature.json`.
    private func preparedFeaturePackageContents(
        definition: BundledFeatureDefinition,
        sourceDirectoryURL: URL,
        zenPackageRootURL: URL,
        displayName: String,
        enabled: Bool,
        destinationDirectoryURL: URL,
        featureRootURL: URL
    ) throws -> FeaturePackageContents {
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
        return FeaturePackageContents(
            package: try Self.packageManifestRewritingZenPackagePath(
                String(contentsOf: sourcePackageURL, encoding: .utf8),
                zenPackagePath: zenPackageRootURL.path,
                packageURL: sourcePackageURL
            ),
            manifest: try Self.adoptedFeatureManifestContents(
                definition: definition,
                displayName: displayName,
                enabled: enabled
            )
        )
    }

    private static func write(_ contents: FeaturePackageContents, to directoryURL: URL) throws {
        try contents.package.write(
            to: directoryURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try contents.manifest.write(
            to: directoryURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func materializedFeaturePackage(
        definition: BundledFeatureDefinition,
        sourceDirectoryURL: URL,
        directoryURL: URL,
        copied: Bool
    ) -> MaterializedFeaturePackage {
        MaterializedFeaturePackage(
            sourceDirectoryURL: sourceDirectoryURL,
            destinationDirectoryURL: directoryURL,
            packageURL: directoryURL.appendingPathComponent("Package.swift"),
            manifestURL: directoryURL
                .appendingPathComponent(SwiftFeatureRegistry.manifestFilename),
            executableURL: directoryURL
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("release", isDirectory: true)
                .appendingPathComponent(definition.executableName),
            copied: copied
        )
    }

    /// Rewrites the `.package(name: "ZenCODE", path: "…")` dependency that follows the
    /// `// zencode:package-path` marker so a copied feature package points at an
    /// absolute ZenCODE checkout instead of its in-repository relative path. The
    /// legacy unnamed `.package(path: "…")` form is accepted and normalized to the
    /// named form on output.
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
                before its ZenCODE '.package(name: "ZenCODE", path: "…")' dependency.
                """
            )
        }

        var dependencyIndex = markerIndex + 1
        while dependencyIndex < lines.count,
              lines[dependencyIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            dependencyIndex += 1
        }
        guard dependencyIndex < lines.count,
              let rewritten = rewrittenPackagePathLine(lines[dependencyIndex], zenPackagePath: zenPackagePath) else {
            throw DirectToolError.permissionDenied(
                """
                \(packageURL.path) must declare a '.package(name: "ZenCODE", path: "…")' \
                dependency on the line following '\(zenPackagePathMarker)'.
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
        let pattern = #"^(\s*)\.package\(\s*(?:name:\s*"ZenCODE"\s*,\s*)?path:\s*"(?:[^"\\]|\\.)*"\s*\)(.*)$"#
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
            + ".package(name: \"ZenCODE\", path: \(swiftStringLiteral(zenPackagePath)))"
            + line[trailingRange]
    }
}
