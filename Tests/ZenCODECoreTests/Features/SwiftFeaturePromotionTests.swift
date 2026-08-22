import Foundation
import Testing
@testable import ZenCODECore
import ToolCore

@Suite(.serialized)
struct SwiftFeaturePromotionTests {
    @Test
    func promotionDescriptorIsValidJSONAndRequiresID() throws {
        let descriptor = try #require(
            SwiftFeatureRuntime.managementToolDescriptors.first { $0.name == "feature.promote" }
        )
        let schema = try #require(
            JSONSerialization.jsonObject(with: Data(descriptor.inputSchema.utf8)) as? [String: Any]
        )
        #expect(schema["required"] as? [String] == ["id"])
    }

    @Test
    func promotionRejectsBuildAndExecutablePathsOutsideStaging() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("promotion-containment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for (executable, packagePath, executablePath, arguments) in [
            ("/tmp/host-tool", ".", ".build/release/fixture", [String]()),
            (".build/release/fixture", "..", ".build/release/fixture", [String]()),
            (".build/release/fixture", ".", "../../host-tool", [String]()),
            (".build/release/fixture", ".", ".build/release/fixture", ["--scratch-path=/tmp/outside"])
        ] {
            let manifest = try promotionManifest(
                executable: executable,
                packagePath: packagePath,
                executablePath: executablePath,
                arguments: arguments
            )
            #expect(throws: DirectToolError.self) {
                try SwiftFeatureRuntime.assertPromotionManifestPathsAreConfined(
                    manifest, featureDirectoryURL: root
                )
            }
        }
    }

    @Test
    func promotionAcceptsNormalizedPathsConfinedToPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("promotion-contained-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = try promotionManifest(
            executable: ".build/release/fixture",
            packagePath: ".",
            executablePath: ".build/release/fixture",
            arguments: ["-Xswiftc", "-warnings-as-errors"]
        )
        try SwiftFeatureRuntime.assertPromotionManifestPathsAreConfined(manifest, featureDirectoryURL: root)
    }

    @Test
    func promotionRejectsPackageResolvedSymlinkBeforeReadingIt() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("promotion-resolved-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: outside) }
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("Package.resolved"),
            withDestinationURL: outside
        )

        #expect(throws: DirectToolError.self) {
            _ = try SwiftFeatureRuntime.promotionPackageResolvedData(in: root, fileManager: fileManager)
        }
    }

    @Test
    func promotionRollbackRestoresDestinationAndUsesAbsentCatalogSentinel() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("promotion-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("Feature", isDirectory: true)
        let backup = root.appendingPathComponent("Feature.backup", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try "new".write(to: destination.appendingPathComponent("value"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try "old".write(to: backup.appendingPathComponent("value"), atomically: true, encoding: .utf8)
        let existingCatalog = root.appendingPathComponent("existing.json")
        let newlyCreatedCatalog = root.appendingPathComponent("new.json")
        try "changed".write(to: existingCatalog, atomically: true, encoding: .utf8)
        try "created".write(to: newlyCreatedCatalog, atomically: true, encoding: .utf8)

        try SwiftFeatureRuntime.rollbackPromotionPublication(
            fileManager: fileManager,
            destinationURL: destination,
            destinationExisted: true,
            destinationBackupURL: backup,
            published: true,
            catalogBackups: [
                existingCatalog: .contents(Data("original".utf8)),
                newlyCreatedCatalog: .absent
            ]
        )

        #expect(try String(contentsOf: destination.appendingPathComponent("value"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: existingCatalog, encoding: .utf8) == "original")
        #expect(!fileManager.fileExists(atPath: newlyCreatedCatalog.path))
    }

    @Test
    func promoteCopiesPackageWithoutBuilderManifestAndUpdatesCatalogs() async throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("zencode-promotion-\(UUID().uuidString)", isDirectory: true)
        let generatedRoot = fixtureRoot.appendingPathComponent("generated", isDirectory: true)
        let checkoutRoot = fixtureRoot.appendingPathComponent("checkout", isDirectory: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        try fileManager.createDirectory(at: generatedRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: checkoutRoot, withIntermediateDirectories: true)

        let featureID = "promotion-fixture"
        let source = generatedRoot.appendingPathComponent(featureID, isDirectory: true)
        let sourceTarget = source.appendingPathComponent("Sources/promotion-fixture", isDirectory: true)
        try fileManager.createDirectory(at: sourceTarget, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.3

        import PackageDescription

        let package = Package(
            name: "promotion-fixture",
            platforms: [.macOS(.v26)],
            products: [.executable(name: "promotion-fixture", targets: ["promotion-fixture"])],
            dependencies: [
                .package(path: "/tmp/old-zencode")
            ],
            targets: [
                .executableTarget(
                    name: "promotion-fixture",
                    dependencies: [
                        .product(name: "FeatureKit", package: "ZenCODE")
                    ]
                )
            ]
        )
        """.write(to: source.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation

        if CommandLine.arguments.contains("--list-tools") {
            print(#"{"tools":[{"name":"promotion.echo","description":"Echo fixture","inputSchema":"{\\"type\\":\\"object\\"}","presentation":{"title":"Echo","action":"Echo","kind":"execute","target":{"source":"arguments","keyPaths":["text"],"format":"text"},"metadata":[],"sections":[]}}]}"#)
        }
        """.write(
            to: sourceTarget.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8
        )
        try Data(contentsOf: try RepositoryTestSupport.packageRoot(containing: #filePath).appendingPathComponent("Package.resolved"))
            .write(to: source.appendingPathComponent("Package.resolved"))
        try "must-not-be-promoted".write(
            to: source.appendingPathComponent("credentials.txt"), atomically: true, encoding: .utf8
        )
        try fileManager.createSymbolicLink(
            at: source.appendingPathComponent("ignored-link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp/does-not-matter")
        )
        try """
        {
          "schemaVersion": 2,
          "id": "promotion-fixture",
          "displayName": "Promotion Fixture",
          "description": "A promotion fixture.",
          "enabled": false,
          "executable": ".build/release/promotion-fixture",
          "build": {"system":"swiftpm","packagePath":".","product":"promotion-fixture","configuration":"release","executablePath":".build/release/promotion-fixture"},
          "generated": {"by":"ZenCODE","createdAt":"2026-01-01T00:00:00Z"},
          "discoversToolsAtRuntime": false,
          "toolNamePrefixes": ["promotion."],
          "toolNameAliases": [],
          "tools": [
            {
              "name": "promotion.echo",
              "description": "Echo fixture",
              "inputSchema": "{\\\"type\\\":\\\"object\\\"}",
              "presentation": {
                "title": "Echo",
                "action": "Echo",
                "kind": "execute",
                "target": {"source":"arguments","keyPaths":["text"],"format":"text"},
                "metadata": [],
                "sections": []
              }
            }
          ]
        }
        """.write(
            to: source.appendingPathComponent("feature.json"), atomically: true, encoding: .utf8
        )

        let metadataRoot = checkoutRoot.appendingPathComponent("Sources/ZenPackageMetadata", isDirectory: true)
        let runtimeRoot = checkoutRoot.appendingPathComponent("Sources/ZenCODECore/ZenCODE/Features", isDirectory: true)
        try fileManager.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let repositoryRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        for path in [
            "Sources/ZenPackageMetadata/ZenBundledFeatureCatalog.swift",
            "Sources/ZenPackageMetadata/feature-catalog.json",
            "Sources/ZenCODECore/ZenCODE/Features/SwiftBundledFeatureCatalog.swift",
            "Sources/FeatureKit",
            "Sources/ToolCore"
        ] {
            let sourcePath = repositoryRoot.appendingPathComponent(path)
            let destinationPath = checkoutRoot.appendingPathComponent(path)
            try fileManager.createDirectory(at: destinationPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourcePath, to: destinationPath)
        }
        let bundledFeaturesRoot = repositoryRoot.appendingPathComponent("Sources/Features", isDirectory: true)
        for packageURL in try fileManager.contentsOfDirectory(
            at: bundledFeaturesRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) where (try? packageURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let manifest = packageURL.appendingPathComponent("feature-distribution.json")
            guard fileManager.fileExists(atPath: manifest.path) else { continue }
            let destination = checkoutRoot
                .appendingPathComponent("Sources/Features", isDirectory: true)
                .appendingPathComponent(packageURL.lastPathComponent, isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            try fileManager.copyItem(
                at: manifest,
                to: destination.appendingPathComponent("feature-distribution.json")
            )
        }
        try """
        // swift-tools-version: 6.3
        import PackageDescription
        let package = Package(
            name: "ZenCODE",
            platforms: [.macOS(.v26)],
            products: [.library(name: "FeatureKit", targets: ["FeatureKit"])],
            dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
            targets: [
                .target(name: "ToolCore"),
                .target(name: "FeatureKit", dependencies: ["ToolCore"])
            ]
        )
        """.write(to: checkoutRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try runGit(["init", "-q"], at: checkoutRoot)
        try runGit(["config", "user.email", "test@example.com"], at: checkoutRoot)
        try runGit(["config", "user.name", "Promotion Test"], at: checkoutRoot)
        try runGit(["add", "."], at: checkoutRoot)
        try runGit(["commit", "-qm", "fixture"], at: checkoutRoot)
        try runGit(["checkout", "-qb", "promotion"], at: checkoutRoot)

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [generatedRoot])
        let output = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "promote-fixture",
                name: "feature.promote",
                argumentsObject: [
                    "id": featureID,
                    "sourcePath": source.path,
                    "repository": checkoutRoot.path,
                    "build": true,
                    "linux": true
                ],
                argumentsJSON: "{}"
            )
        )
        let report = try JSONDecoder().decode(SwiftFeaturePromotionReport.self, from: Data(output.utf8))
        #expect(report.ok)
        let destination = checkoutRoot.appendingPathComponent("Sources/Features/PromotionFixture", isDirectory: true)
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("Package.swift").path))
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("Package.resolved").path))
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("feature-distribution.json").path))
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("feature.json").path))
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("ignored-link").path))
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("credentials.txt").path))
        let package = try String(contentsOf: destination.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(package.contains(".package(name: \"ZenCODE\", path: \"../../..\")"))
        #expect(package.contains("// zencode:package-path"))
        #expect(package.contains("MemberImportVisibility"))
        let distribution = try String(
            contentsOf: destination.appendingPathComponent("feature-distribution.json"),
            encoding: .utf8
        )
        #expect(distribution.contains("promotion-fixture"))
        #expect(!distribution.contains("discoversToolsAtRuntime"))
        let swiftCatalog = try String(
            contentsOf: checkoutRoot.appendingPathComponent("Sources/ZenPackageMetadata/ZenBundledFeatureCatalog.swift"),
            encoding: .utf8
        )
        #expect(swiftCatalog.contains("promotion-fixture"))
        let runtimeCatalog = try String(
            contentsOf: checkoutRoot.appendingPathComponent(
                "Sources/ZenCODECore/ZenCODE/Features/SwiftBundledFeatureCatalog.swift"
            ),
            encoding: .utf8
        )
        #expect(runtimeCatalog.contains("discoversToolsAtRuntime: false"))
        #expect(report.built)
        #expect(report.listedTools == ["promotion.echo"])

        let generator = fixtureRoot.appendingPathComponent("generate-feature-catalog")
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "swiftc",
                repositoryRoot.appendingPathComponent("Scripts/GenerateFeatureCatalog.swift").path,
                "-o", generator.path
            ],
            at: checkoutRoot
        )
        try runProcess(executable: generator, arguments: ["--check"], at: checkoutRoot)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path] + arguments,
            at: directory
        )
    }

    private func promotionManifest(
        executable: String,
        packagePath: String,
        executablePath: String,
        arguments: [String]
    ) throws -> SwiftFeatureManifest {
        let object: [String: Any] = [
            "schemaVersion": 2,
            "id": "fixture",
            "enabled": false,
            "executable": executable,
            "tools": [[String: Any]](),
            "generated": ["by": "ZenCODE"],
            "build": [
                "system": "swiftpm",
                "packagePath": packagePath,
                "product": "fixture",
                "configuration": "release",
                "executablePath": executablePath,
                "arguments": arguments
            ]
        ]
        return try JSONDecoder().decode(
            SwiftFeatureManifest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func runProcess(executable: URL, arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let diagnostics = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
            throw TestError(diagnostics: diagnostics)
        }
    }

    private struct TestError: Error { let diagnostics: String }
}
