import Foundation
@testable import ZenCODECore
import ZenPackageMetadata
import Testing

@Suite(.serialized)
struct BundledFeatureCatalogParityTests {
    @Test
    func runtimeDefinitionsUseStableDistributionIdentity() {
        let definitionsByID = Dictionary(
            uniqueKeysWithValues: SwiftFeatureRuntime.bundledFeatureDefinitions().map { ($0.id, $0) }
        )

        #expect(definitionsByID.count == ZenBundledFeatureCatalog.all.count)
        for feature in ZenBundledFeatureCatalog.all {
            let definition = definitionsByID[feature.id]
            #expect(definition?.executableName == feature.productName)
            #expect(definition?.sourceRelativePath == feature.sourceRelativePath)
        }
    }

    @Test
    func sourcePathsAndPackageProductsMatchDistributionCatalog() throws {
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let packageProducts = try dumpedPackageProductNames(at: packageRoot)

        for feature in ZenBundledFeatureCatalog.all {
            #expect(
                FileManager.default.fileExists(
                    atPath: packageRoot.appendingPathComponent(feature.sourceRelativePath).path
                )
            )
            #expect(packageProducts.contains(feature.productName))
        }
    }

    @Test
    func installerCatalogMatchesDistributionPlatformSets() throws {
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let catalogURL = packageRoot.appendingPathComponent("Scripts/feature-catalog.sh")

        let macOSProducts = try installerProducts(from: catalogURL, platform: "macos")
        let linuxProducts = try installerProducts(from: catalogURL, platform: "linux")

        #expect(macOSProducts == ZenBundledFeatureCatalog.macOSInstallerProductNames)
        #expect(linuxProducts == ZenBundledFeatureCatalog.linuxInstallerProductNames)
    }

    private func dumpedPackageProductNames(at packageRoot: URL) throws -> Set<String> {
        var environment = ProcessInfo.processInfo.environment
        environment["ZENCODE_BUILD_LOCAL_MLX"] = "0"
        environment["ZENCODE_BUILD_DS4"] = "0"
        environment.removeValue(forKey: "ZENCODE_DS4_ROOT")
        environment.removeValue(forKey: "DS4_ROOT")

        let scratchPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-dump-package-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: scratchPath)
        }

        let data = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "swift",
                "package",
                "--scratch-path",
                scratchPath.path,
                "dump-package"
            ],
            currentDirectoryURL: packageRoot,
            environment: environment
        )
        let object = try JSONSerialization.jsonObject(with: data)
        let package = try #require(object as? [String: Any])
        let products = try #require(package["products"] as? [[String: Any]])
        return Set(products.compactMap { $0["name"] as? String })
    }

    private func installerProducts(from catalogURL: URL, platform: String) throws -> [String] {
        let data = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "-c",
                "source \"$1\"; zencode_select_feature_products \"$2\"; printf '%s\\n' \"${FEATURE_PRODUCTS[@]}\"",
                "bash",
                catalogURL.path,
                platform
            ],
            currentDirectoryURL: catalogURL.deletingLastPathComponent()
        )
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String]? = nil
    ) throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain the pipe before waiting. `swift package dump-package` emits a
        // full manifest JSON document, which can exceed a pipe buffer and
        // otherwise leave both processes waiting on one another.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: outputData, as: UTF8.self)
            throw CatalogProcessError(
                executable: executableURL.path,
                status: process.terminationStatus,
                errorText: errorText
            )
        }
        return outputData
    }

    private struct CatalogProcessError: LocalizedError {
        let executable: String
        let status: Int32
        let errorText: String

        var errorDescription: String? {
            "\(executable) exited with status \(status): \(errorText)"
        }
    }
}
