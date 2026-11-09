//
//  SwiftFeatureOptionalInstallationTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

@Suite
struct SwiftFeatureOptionalInstallationTests {
    // MARK: - Package path rewriting

    @Test
    func rewritingReplacesOnlyTheMarkedDependencyPreservingLayout() throws {
        let contents = """
        // swift-tools-version: 6.4
        import PackageDescription

        let package = Package(
            name: "git-tools-feature",
            dependencies: [
                .package(path: "../vendor/other"),
                // zencode:package-path
                .package(name: "ZenCODE", path: "../../.."),
            ]
        )
        """

        let rewritten = try SwiftFeatureRuntime.packageManifestRewritingZenPackagePath(
            contents,
            zenPackagePath: "/opt/zencode/source",
            packageURL: URL(fileURLWithPath: "/tmp/Package.swift")
        )

        #expect(rewritten.contains(#"        .package(name: "ZenCODE", path: "/opt/zencode/source"),"#))
        #expect(rewritten.contains(#".package(path: "../vendor/other"),"#))
        #expect(!rewritten.contains(#""../../..""#))
        #expect(rewritten.contains(SwiftFeatureRuntime.zenPackagePathMarker))
        #expect(
            rewritten.components(separatedBy: "\n").count
                == contents.components(separatedBy: "\n").count
        )
    }

    @Test
    func rewritingFailsWithAnActionableErrorWhenTheMarkerIsMissing() throws {
        let contents = """
        // swift-tools-version: 6.4
        let package = Package(
            dependencies: [
                .package(path: "../../..")
            ]
        )
        """

        #expect(throws: (any Error).self) {
            _ = try SwiftFeatureRuntime.packageManifestRewritingZenPackagePath(
                contents,
                zenPackagePath: "/opt/zencode/source",
                packageURL: URL(fileURLWithPath: "/tmp/Package.swift")
            )
        }
    }

    // MARK: - Materialization

    @Test
    func materializationProducesABuilderShapedPackageWithoutBuilding() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-install-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let featureRootURL = rootURL.appendingPathComponent("features", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("WebTools", isDirectory: true)
        try Self.writeFeaturePackage(at: sourceURL, productName: "web-tools-feature")
        // Local build artefacts must never reach the installed copy.
        try FileManager.default.createDirectory(
            at: sourceURL.appendingPathComponent(".build/release", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "stale".write(
            to: sourceURL.appendingPathComponent(".build/release/web-tools-feature"),
            atomically: true,
            encoding: .utf8
        )

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [featureRootURL])
        let definition = try #require(SwiftFeatureRuntime.bundledFeatureDefinition(id: "web-tools"))
        let materialized = try await runtime.materializeFeaturePackage(
            definition: definition,
            sourceDirectoryURL: sourceURL,
            zenPackageRootURL: URL(fileURLWithPath: "/opt/zencode/source"),
            displayName: "Web",
            enabled: false,
            overwrite: true
        )

        let destinationURL = featureRootURL.appendingPathComponent("web-tools", isDirectory: true)
        #expect(materialized.destinationDirectoryURL.path == destinationURL.standardizedFileURL.path)
        #expect(materialized.copied)
        #expect(
            FileManager.default.fileExists(
                atPath: destinationURL.appendingPathComponent("Sources/web-tools-feature/main.swift").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationURL.appendingPathComponent(".build").path
            )
        )

        let package = try String(contentsOf: materialized.packageURL, encoding: .utf8)
        #expect(package.contains(#".package(name: "ZenCODE", path: "/opt/zencode/source")"#))
        #expect(!package.contains(#""../../..""#))

        let manifest = try JSONDecoder().decode(
            SwiftFeatureManifest.self,
            from: Data(contentsOf: materialized.manifestURL)
        )
        #expect(manifest.id == "web-tools")
        #expect(manifest.displayName == "Web")
        #expect(!manifest.enabled)
        #expect(manifest.executable == ".build/release/web-tools-feature")
        #expect(manifest.build?.product == "web-tools-feature")
        #expect(manifest.build?.packagePath == ".")
        #expect(manifest.build?.configuration == "release")
        #expect(manifest.build?.executablePath == ".build/release/web-tools-feature")
        #expect(manifest.discoversToolsAtRuntime)
        #expect(manifest.toolNamePrefixes == ["web."])
        #expect(manifest.invocationTimeoutSeconds == 180)
        #expect(manifest.generated?.adoptedFrom == "web-tools")
        #expect(
            materialized.executableURL.path
                == destinationURL
                    .appendingPathComponent(".build/release/web-tools-feature")
                    .standardizedFileURL
                    .path
        )
    }

    @Test
    func failedOptionalFeatureUpdatePreservesThePreviousBuiltEnabledPackage() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-update-transaction-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let featureRootURL = rootURL.appendingPathComponent("features", isDirectory: true)
        let checkoutURL = rootURL.appendingPathComponent("checkout", isDirectory: true)
        try Self.writeZenPackageRoot(at: checkoutURL)

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [featureRootURL])
        let definition = try #require(SwiftFeatureRuntime.bundledFeatureDefinition(id: "git-tools"))
        let sourceURL = try #require(definition.sourceRelativePath)
            .split(separator: "/")
            .reduce(checkoutURL) { partialURL, component in
                partialURL.appendingPathComponent(String(component), isDirectory: true)
            }
        try Self.writeFeaturePackage(at: sourceURL, productName: definition.executableName)
        let sourceMainURL = sourceURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(definition.executableName, isDirectory: true)
            .appendingPathComponent("main.swift")
        try "print(\"previous version\")\n".write(
            to: sourceMainURL,
            atomically: true,
            encoding: .utf8
        )

        let installed = try await runtime.materializeFeaturePackage(
            definition: definition,
            sourceDirectoryURL: sourceURL,
            zenPackageRootURL: checkoutURL,
            displayName: "Git",
            enabled: true,
            overwrite: true
        )
        try Self.writeExecutable(at: installed.executableURL)
        let previousSource = try String(
            contentsOf: installed.destinationDirectoryURL
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent(definition.executableName, isDirectory: true)
                .appendingPathComponent("main.swift"),
            encoding: .utf8
        )

        // The candidate validates, but its product cannot compile. It must stay
        // in staging and leave the built, enabled package above untouched.
        try "this is not valid Swift\n".write(
            to: sourceMainURL,
            atomically: true,
            encoding: .utf8
        )
        let progressRecorder = OptionalFeatureInstallProgressRecorder()
        let report = try await runtime.installOptionalFeature(
            id: definition.id,
            zenPackageRootURL: checkoutURL,
            timeoutSeconds: 30,
            progress: { message in
                await progressRecorder.append(message)
            }
        )
        let progressMessages = await progressRecorder.snapshot()

        #expect(!report.ok)
        #expect(!report.copied)
        #expect(!report.built)
        #expect(!report.enabled)
        #expect(report.build?.ok == false)
        #expect(
            try String(
                contentsOf: installed.destinationDirectoryURL
                    .appendingPathComponent("Sources", isDirectory: true)
                    .appendingPathComponent(definition.executableName, isDirectory: true)
                    .appendingPathComponent("main.swift"),
                encoding: .utf8
            ) == previousSource
        )
        let record = try #require(
            SwiftFeatureRegistry.featureRecord(
                id: definition.id,
                searchRoots: [featureRootURL]
            )
        )
        #expect(record.manifestEnabled)
        #expect(record.executableAvailable)
        #expect(progressMessages.contains("Running: swift build -c release --product git-tools-feature"))
        #expect(progressMessages.contains { $0.hasPrefix("SwiftPM build finished in ") })
        #expect(!progressMessages.contains { $0.hasPrefix("Publishing feature to ") })
    }

    @Test
    func optionalFeatureCannotBeEnabledWhenBuildIsSkipped() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-build-enable-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let featureRootURL = rootURL.appendingPathComponent("features", isDirectory: true)
        let checkoutURL = rootURL.appendingPathComponent("checkout", isDirectory: true)
        try Self.writeZenPackageRoot(at: checkoutURL)

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [featureRootURL])
        let definition = try #require(SwiftFeatureRuntime.bundledFeatureDefinition(id: "git-tools"))
        let sourceURL = try #require(definition.sourceRelativePath)
            .split(separator: "/")
            .reduce(checkoutURL) { partialURL, component in
                partialURL.appendingPathComponent(String(component), isDirectory: true)
            }
        try Self.writeFeaturePackage(at: sourceURL, productName: definition.executableName)

        let report = try await runtime.installOptionalFeature(
            id: definition.id,
            zenPackageRootURL: checkoutURL,
            build: false,
            enable: true
        )

        #expect(!report.ok)
        #expect(!report.copied)
        #expect(!report.built)
        #expect(!report.enabled)
        #expect(report.errors.contains { $0.contains("build=false") })
        #expect(
            !FileManager.default.fileExists(
                atPath: featureRootURL.appendingPathComponent(definition.id).path
            )
        )
    }

    // MARK: - Catalog

    @Test
    func installedOptionalFeatureIsReportedAsInstalledAndShadowsTheCatalogEntry() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-catalog-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let featureRootURL = rootURL.appendingPathComponent("features", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("FigmaTools", isDirectory: true)
        try Self.writeFeaturePackage(at: sourceURL, productName: "figma-tools-feature")

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [featureRootURL])
        let definition = try #require(SwiftFeatureRuntime.bundledFeatureDefinition(id: "figma-tools"))
        _ = try await runtime.materializeFeaturePackage(
            definition: definition,
            sourceDirectoryURL: sourceURL,
            zenPackageRootURL: URL(fileURLWithPath: "/opt/zencode/source"),
            displayName: "Figma",
            enabled: true,
            overwrite: true
        )

        let features = SwiftFeatureRuntime.optionalFeatures(searchRoots: [featureRootURL])
        let figma = try #require(features.first { $0.id == "figma-tools" })

        #expect(figma.installed)
        // Installed but never built: the release product does not exist yet.
        #expect(!figma.built)
        #expect(!figma.enabled)
        #expect(figma.issue != SwiftFeatureRuntime.optionalFeatureNotInstalledIssue)

        let statuses = SwiftFeatureRuntime.defaultFeatureStatuses(searchRoots: [featureRootURL])
        let figmaStatuses = statuses.filter { $0.id == "figma-tools" }
        #expect(figmaStatuses.count == 1)
        #expect(figmaStatuses.first?.source == .generated)
    }

    // MARK: - Source checkout resolution

    @Test
    func sourceCheckoutResolutionAcceptsAnExplicitCheckout() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-source-ok-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.4\n".write(
            to: rootURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = try SwiftFeatureRuntime.zenCODESourceCheckoutURL(explicitURL: rootURL)
        #expect(resolved.path == rootURL.standardizedFileURL.path)
    }

    // MARK: - Update detection

    @Test
    func updateDetectionComparesNormalizedPackagePathsSizesAndContents() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-update-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let featureRootURL = rootURL.appendingPathComponent("features", isDirectory: true)
        let zenRootURL = rootURL.appendingPathComponent("checkout", isDirectory: true)
        let definition = try #require(SwiftFeatureRuntime.bundledFeatureDefinition(id: "git-tools"))
        let sourceURL = zenRootURL.appendingPathComponent(
            try #require(definition.sourceRelativePath),
            isDirectory: true
        )
        try Self.writeFeaturePackage(at: sourceURL, productName: "git-tools-feature")

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [featureRootURL])
        _ = try await runtime.materializeFeaturePackage(
            definition: definition,
            sourceDirectoryURL: sourceURL,
            zenPackageRootURL: zenRootURL,
            displayName: "Git",
            enabled: false,
            overwrite: true
        )
        let installedURL = featureRootURL.appendingPathComponent("git-tools", isDirectory: true)
        // Build products and package resolution state are not source changes.
        try FileManager.default.createDirectory(
            at: installedURL.appendingPathComponent(".build/release", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "binary".write(
            to: installedURL.appendingPathComponent(".build/release/git-tools-feature"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: installedURL.appendingPathComponent("Package.resolved"),
            atomically: true,
            encoding: .utf8
        )

        let feature = try #require(
            SwiftFeatureRuntime.optionalFeatures(searchRoots: [featureRootURL]).first { $0.id == "git-tools" }
        )
        #expect(feature.installed && feature.supportedOnCurrentPlatform)
        func updateAvailable() async throws -> Bool {
            try await runtime.isOptionalFeatureUpdateAvailable(feature, zenPackageRootURL: zenRootURL)
        }
        func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        // Package.swift differs only by the rewritten ZenCODE path.
        #expect(try await updateAvailable() == false)

        let mainURL = sourceURL.appendingPathComponent("Sources/git-tools-feature/main.swift")
        try write("print(\"no\")\n", to: mainURL)
        #expect(try await updateAvailable(), "Same size, different content")
        try write("print(\"okay\")\n", to: mainURL)
        #expect(try await updateAvailable(), "Different size")
        try write("print(\"ok\")\n", to: mainURL)
        #expect(try await updateAvailable() == false)

        let extraSourceURL = sourceURL.appendingPathComponent("Sources/git-tools-feature/Extra.swift")
        try write("", to: extraSourceURL)
        #expect(try await updateAvailable(), "File only in the source package")
        try FileManager.default.removeItem(at: extraSourceURL)
        let extraInstalledURL = installedURL.appendingPathComponent("NOTES.md")
        try write("", to: extraInstalledURL)
        #expect(try await updateAvailable(), "File only in the installed package")
        try FileManager.default.removeItem(at: extraInstalledURL)
        #expect(try await updateAvailable() == false)
    }

    // MARK: - Helpers

    private static func writeFeaturePackage(
        at directoryURL: URL,
        productName: String
    ) throws {
        let sourceDirectoryURL = directoryURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(productName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectoryURL,
            withIntermediateDirectories: true
        )
        try """
        // swift-tools-version: 6.4

        import PackageDescription

        let package = Package(
            name: "\(productName)",
            products: [
                .executable(name: "\(productName)", targets: ["\(productName)"])
            ],
            dependencies: [
                // zencode:package-path
                .package(name: "ZenCODE", path: "../../..")
            ],
            targets: [
                .executableTarget(name: "\(productName)")
            ]
        )
        """.write(
            to: directoryURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "print(\"ok\")\n".write(
            to: sourceDirectoryURL.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeZenPackageRoot(at directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.4

        import PackageDescription

        let package = Package(name: "ZenCODE")
        """.write(
            to: directoryURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeExecutable(at executableURL: URL) throws {
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }
}

private actor OptionalFeatureInstallProgressRecorder {
    private var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }

    func snapshot() -> [String] {
        messages
    }
}
