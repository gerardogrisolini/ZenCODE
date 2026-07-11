import Foundation
@testable import ZenCODECore
import Testing

@Suite("Package root resolution")
struct PackageRootResolverTests {
    @Test
    func findsManifestByWalkingAncestorsWithoutKnowingSourceDepth() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-root-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL
            .appendingPathComponent("Sources/Feature/Implementation/Deep", isDirectory: true)
            .appendingPathComponent("Feature.swift")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "// swift-tools-version: 6.3".write(
            to: rootURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = PackageRootResolver.packageRoot(
            forSourceFilePath: sourceURL.path,
            fileManager: .default
        )

        #expect(resolved?.standardizedFileURL == rootURL.standardizedFileURL)
    }

    @Test
    func sourceDirectoryFallbackStopsAtRequestedAncestor() {
        let sourcePath = "/tmp/ZenCODE/Sources/Feature/Feature.swift"

        let resolved = PackageRootResolver.sourceDirectory(
            forSourceFilePath: sourcePath,
            ancestorCount: 1
        )

        #expect(resolved.path == "/tmp/ZenCODE/Sources")
    }
}
