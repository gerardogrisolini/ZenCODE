import Foundation
@testable import ZenCODECore
import ToolCore
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

        for feature in ZenBundledFeatureCatalog.all {
            let featurePackageURL = packageRoot
                .appendingPathComponent(feature.sourceRelativePath, isDirectory: true)
            let manifestURL = featurePackageURL.appendingPathComponent("Package.swift")
            #expect(
                FileManager.default.fileExists(
                    atPath: manifestURL.path
                )
            )

            let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
            #expect(
                manifest.contains(
                    "\(SwiftFeatureRuntime.zenPackagePathMarker)\n        .package(path: \"../../..\")"
                )
            )

            let products = try dumpedPackageProducts(at: featurePackageURL)
            #expect(products.executable.contains(feature.productName))
        }
    }

    @Test
    func rootPackageDoesNotDeclareOptionalFeatureProducts() throws {
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let rootProducts = try dumpedPackageProducts(at: packageRoot).all
        let featureProducts = Set(ZenBundledFeatureCatalog.all.map(\.productName))

        #expect(rootProducts.isDisjoint(with: featureProducts))
    }

    @Test
    func linuxInstallationEligibilityIsCatalogDrivenAndExcludesXcodeTools() throws {
        let linuxProducts = Set(ZenBundledFeatureCatalog.linuxInstallerProductNames)
        let linuxFeatureIDs = Set(
            ZenBundledFeatureCatalog.all
                .filter(\.isInstalledOnLinux)
                .map(\.id)
        )
        let allFeatureIDs = Set(ZenBundledFeatureCatalog.all.map(\.id))
        let xcode = try #require(ZenBundledFeatureCatalog.feature(id: "xcode-tools"))

        #expect(!xcode.isInstalledOnLinux)
        #expect(linuxFeatureIDs == allFeatureIDs.subtracting(["xcode-tools"]))
        #expect(linuxProducts.contains("swift-tools-feature"))
        #expect(!linuxProducts.contains("xcode-tools-feature"))
    }

    @Test
    func nativeAndStaticallyDeclaredBundledToolsHaveExplicitPresentations() {
        let nativeDescriptors = DirectToolCatalog.baseDescriptors
        let missingNative = nativeDescriptors
            .filter { $0.presentation == nil }
            .map(\.name)
        #expect(missingNative.isEmpty)

        let staticBundledDescriptors = SwiftFeatureRuntime
            .bundledFeatureDefinitions()
            .filter { !$0.discoversToolsAtRuntime }
            .flatMap(\.tools)
        let missingBundled = staticBundledDescriptors
            .filter { $0.presentation == nil }
            .map(\.name)
        #expect(missingBundled.isEmpty)
    }

    private func dumpedPackageProducts(at packageRoot: URL) throws -> DumpedPackageProducts {
        let environment = ProcessInfo.processInfo.environment

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
        return DumpedPackageProducts(
            all: Set(products.compactMap { $0["name"] as? String }),
            executable: Set(products.compactMap { product in
                guard let name = product["name"] as? String,
                      let type = product["type"] as? [String: Any],
                      type.keys.contains("executable") else {
                    return nil
                }
                return name
            })
        )
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

    private struct DumpedPackageProducts {
        let all: Set<String>
        let executable: Set<String>
    }
}
