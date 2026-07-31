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
        // swift-tools-version: 6.3
        import PackageDescription

        let package = Package(
            name: "git-tools-feature",
            dependencies: [
                .package(path: "../vendor/other"),
                // zencode:package-path
                .package(path: "../../.."),
            ]
        )
        """

        let rewritten = try SwiftFeatureRuntime.packageManifestRewritingZenPackagePath(
            contents,
            zenPackagePath: "/opt/zencode/source",
            packageURL: URL(fileURLWithPath: "/tmp/Package.swift")
        )

        #expect(rewritten.contains(#"        .package(path: "/opt/zencode/source"),"#))
        #expect(rewritten.contains(#".package(path: "../vendor/other"),"#))
        #expect(!rewritten.contains(#".package(path: "../../..")"#))
        #expect(rewritten.contains(SwiftFeatureRuntime.zenPackagePathMarker))
        #expect(
            rewritten.components(separatedBy: "\n").count
                == contents.components(separatedBy: "\n").count
        )
    }

    @Test
    func rewritingFailsWithAnActionableErrorWhenTheMarkerIsMissing() throws {
        let contents = """
        // swift-tools-version: 6.3
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

    @Test
    func rewritingFailsWhenTheMarkedLineIsNotAPackagePathDependency() throws {
        let contents = """
        // swift-tools-version: 6.3
        let package = Package(
            dependencies: [
                // zencode:package-path
                .package(url: "https://example.com/pkg", from: "1.0.0")
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
        #expect(package.contains(#".package(path: "/opt/zencode/source")"#))
        #expect(!package.contains(#".package(path: "../../..")"#))

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
    func materializationLeavesThePreviousPackageIntactWhenTheSourceIsInvalid() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-install-atomic-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let featureRootURL = rootURL.appendingPathComponent("features", isDirectory: true)
        let goodSourceURL = rootURL.appendingPathComponent("Good", isDirectory: true)
        try Self.writeFeaturePackage(at: goodSourceURL, productName: "git-tools-feature")

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [featureRootURL])
        let definition = try #require(SwiftFeatureRuntime.bundledFeatureDefinition(id: "git-tools"))
        _ = try await runtime.materializeFeaturePackage(
            definition: definition,
            sourceDirectoryURL: goodSourceURL,
            zenPackageRootURL: URL(fileURLWithPath: "/opt/zencode/source"),
            displayName: "Git",
            enabled: true,
            overwrite: true
        )

        // A source package without the marker must abort before the installed
        // copy is touched.
        let brokenSourceURL = rootURL.appendingPathComponent("Broken", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenSourceURL, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.3\n".write(
            to: brokenSourceURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: (any Error).self) {
            _ = try await runtime.materializeFeaturePackage(
                definition: definition,
                sourceDirectoryURL: brokenSourceURL,
                zenPackageRootURL: URL(fileURLWithPath: "/opt/zencode/source"),
                displayName: "Git",
                enabled: true,
                overwrite: true
            )
        }

        let record = try #require(
            SwiftFeatureRegistry.featureRecord(id: "git-tools", searchRoots: [featureRootURL])
        )
        #expect(record.manifestEnabled)
        #expect(
            FileManager.default.fileExists(
                atPath: featureRootURL
                    .appendingPathComponent("git-tools/Sources/git-tools-feature/main.swift")
                    .path
            )
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
        let report = try await runtime.installOptionalFeature(
            id: definition.id,
            zenPackageRootURL: checkoutURL,
            timeoutSeconds: 30
        )

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
    }

    @Test
    func optionalFeatureReinstallReplacesAnExistingPackage() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-reinstall-\(UUID().uuidString)", isDirectory: true)
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

        let firstReport = try await runtime.installOptionalFeature(
            id: definition.id,
            zenPackageRootURL: checkoutURL,
            build: false,
            enable: false
        )
        #expect(firstReport.ok)
        #expect(firstReport.copied)

        let installedDirectoryURL = featureRootURL
            .appendingPathComponent(definition.id, isDirectory: true)
        let obsoleteURL = installedDirectoryURL.appendingPathComponent("obsolete.txt")
        try "old package only\n".write(to: obsoleteURL, atomically: true, encoding: .utf8)

        let sourceMainURL = sourceURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(definition.executableName, isDirectory: true)
            .appendingPathComponent("main.swift")
        try "print(\"updated version\")\n".write(
            to: sourceMainURL,
            atomically: true,
            encoding: .utf8
        )

        let secondReport = try await runtime.installOptionalFeature(
            id: definition.id,
            zenPackageRootURL: checkoutURL,
            build: false,
            enable: false
        )
        #expect(secondReport.ok)
        #expect(secondReport.copied)
        #expect(
            try String(
                contentsOf: installedDirectoryURL
                    .appendingPathComponent("Sources", isDirectory: true)
                    .appendingPathComponent(definition.executableName, isDirectory: true)
                    .appendingPathComponent("main.swift"),
                encoding: .utf8
            ) == "print(\"updated version\")\n"
        )
        #expect(!FileManager.default.fileExists(atPath: obsoleteURL.path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: featureRootURL.path)
                .allSatisfy { !$0.hasPrefix(".zencode-feature-") }
        )
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

    @Test
    func optionalFeatureUpdateIsReportedOnlyWhenInstalledSourceDiffers() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-update-availability-\(UUID().uuidString)", isDirectory: true)
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
        _ = try await runtime.materializeFeaturePackage(
            definition: definition,
            sourceDirectoryURL: sourceURL,
            zenPackageRootURL: checkoutURL,
            displayName: "Git",
            enabled: true,
            overwrite: true
        )

        let feature = try #require(await runtime.optionalFeatures().first { $0.id == definition.id })
        #expect(
            try await !runtime.isOptionalFeatureUpdateAvailable(
                feature,
                zenPackageRootURL: checkoutURL
            )
        )

        let sourceMainURL = sourceURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(definition.executableName, isDirectory: true)
            .appendingPathComponent("main.swift")
        try "print(\"updated\")\n".write(
            to: sourceMainURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(
            try await runtime.isOptionalFeatureUpdateAvailable(
                feature,
                zenPackageRootURL: checkoutURL
            )
        )
    }

    @Test
    func unknownOptionalFeatureInstallIsRejected() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-unknown-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        await #expect(throws: (any Error).self) {
            _ = try await runtime.installOptionalFeature(id: "not-a-feature")
        }
    }

    // MARK: - Source checkout resolution

    @Test
    func sourceCheckoutResolutionRejectsAnExplicitPathWithoutAPackageManifest() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-source-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            _ = try SwiftFeatureRuntime.zenCODESourceCheckoutURL(explicitURL: rootURL)
        }
    }

    @Test
    func sourceCheckoutResolutionAcceptsAnExplicitCheckout() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("optional-source-ok-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.3\n".write(
            to: rootURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = try SwiftFeatureRuntime.zenCODESourceCheckoutURL(explicitURL: rootURL)
        #expect(resolved.path == rootURL.standardizedFileURL.path)
    }

    @Test
    func supportSourceCheckoutLivesUnderTheSupportDirectory() {
        let supportURL = SwiftFeatureRuntime.supportSourceCheckoutURL()
        #expect(supportURL.lastPathComponent == SwiftFeatureRuntime.supportSourceCheckoutDirectoryName)
        #expect(
            supportURL.deletingLastPathComponent().standardizedFileURL.path
                == AppStorageDirectory.appSupportDirectoryURL().standardizedFileURL.path
        )
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
        // swift-tools-version: 6.3

        import PackageDescription

        let package = Package(
            name: "\(productName)",
            products: [
                .executable(name: "\(productName)", targets: ["\(productName)"])
            ],
            dependencies: [
                // zencode:package-path
                .package(path: "../../..")
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
        // swift-tools-version: 6.3

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
