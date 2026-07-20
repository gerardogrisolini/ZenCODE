//
//  RemoteTransportArchitectureParityTests.swift
//  ZenCODECoreTests
//
//  Structural guard for the single SwiftNIO generation transport boundary.
//

import Foundation
import Testing

@Suite("Remote transport architecture parity")
struct RemoteTransportArchitectureParityTests {
    @Test("legacy curl target and adapters stay retired")
    func legacyCurlTargetAndAdaptersStayRetired() throws {
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let fileManager = FileManager.default

        for relativePath in [
            "Sources/CLibCURLWebSocket",
            "Sources/ZenCODECore/ZenCODE/Remote/Providers/ChatGPT/Streaming/ChatGPTSubscriptionCurlWebSocket.swift"
        ] {
            #expect(
                !fileManager.fileExists(
                    atPath: packageRoot.appendingPathComponent(relativePath).path
                ),
                "Retired legacy transport path remains present: \(relativePath)"
            )
        }

        let manifest = try source(at: packageRoot.appendingPathComponent("Package.swift"))
        for token in [
            "CLibCURLWebSocket",
            ".linkedLibrary(\"curl\"",
            "zen_curl_ws"
        ] {
            #expect(
                !manifest.contains(token),
                "Package.swift reintroduced retired transport token \(token)."
            )
        }

        let allSourceFiles = try sourceFiles(
            below: packageRoot.appendingPathComponent("Sources"),
            packageRoot: packageRoot,
            extensions: ["swift", "c", "h"]
        )
        for source in allSourceFiles {
            for token in [
                "CLibCURLWebSocket",
                "ChatGPTSubscriptionCurlWebSocket",
                "ZenCurlWebSocket",
                "zen_curl_ws"
            ] {
                #expect(
                    !source.contents.contains(token),
                    "\(source.relativePath) reintroduced retired transport symbol \(token)."
                )
            }
        }
    }

    @Test("generation engines remain independent of platform networking")
    func generationEnginesRemainIndependentOfPlatformNetworking() throws {
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let sourceRoots = [
            "Sources/ZenCODECore/ZenCODE/Remote/Transport",
            "Sources/ZenCODECore/ZenCODE/Remote/Generation/Client",
            "Sources/ZenCODECore/ZenCODE/Remote/Generation/Streaming",
            "Sources/ZenCODECore/ZenCODE/Remote/Providers/ChatGPT/Client",
            "Sources/ZenCODECore/ZenCODE/Remote/Providers/ChatGPT/Requests",
            "Sources/ZenCODECore/ZenCODE/Remote/Providers/ChatGPT/Streaming",
            "Sources/ZenCODECore/ZenCODE/Remote/Providers/Anthropic/Client",
            "Sources/ZenCODECore/ZenCODE/Remote/Providers/Anthropic/Requests",
            "Sources/ZenCODECore/ZenCODE/Remote/Providers/Anthropic/Streaming"
        ]
        let sources = try sourceRoots.flatMap { relativePath in
            try sourceFiles(
                below: packageRoot.appendingPathComponent(relativePath),
                packageRoot: packageRoot,
                extensions: ["swift"]
            )
        }
        #expect(!sources.isEmpty)

        // Auth and callback files are intentionally not in `sourceRoots`: their
        // provider-specific OAuth/browser behavior is not generation transport.
        // Compatibility facades live outside these roots and retain typed legacy
        // values without performing I/O.
        let forbiddenTokens = [
            "FoundationNetworking",
            "URLSession",
            "URLSessionWebSocketTask",
            "import Network",
            "CLibCURL",
            "ChatGPTSubscriptionCurlWebSocket",
            "zen_curl_ws",
            "libcurl",
            "#if os(macOS)",
            "#elseif os(macOS)",
            "#if os(Linux)",
            "#elseif os(Linux)",
            "#if !os(macOS)",
            "#if !os(Linux)"
        ]

        for source in sources {
            for token in forbiddenTokens {
                #expect(
                    !source.contents.contains(token),
                    "\(source.relativePath) reintroduced platform or legacy transport token \(token)."
                )
            }
        }

        let core = try source(
            at: packageRoot.appendingPathComponent(
                "Sources/ZenCODECore/ZenCODE/Remote/Transport/RemoteTransportCore.swift"
            )
        )
        for token in ["import NIOCore", "import NIOHTTP1", "import NIOWebSocket"] {
            #expect(core.contains(token), "RemoteTransportCore lost required NIO import \(token).")
        }
    }

    @Test("ChatGPT transport suites are never macOS-only")
    func chatGPTTransportSuitesAreNeverMacOSOnly() throws {
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let testFiles = [
            "Tests/ZenCODECoreTests/Remote/ChatGPTSubscriptionContinuationTests.swift",
            "Tests/ZenCODECoreTests/Remote/ChatGPTSubscriptionSSETests.swift"
        ]
        let platformGuards = [
            "#if os(macOS)",
            "#elseif os(macOS)",
            "#if canImport(Network)",
            "#if !os(Linux)"
        ]

        for relativePath in testFiles {
            let contents = try source(
                at: packageRoot.appendingPathComponent(relativePath)
            )
            for guardToken in platformGuards {
                #expect(
                    !contents.contains(guardToken),
                    "ChatGPT transport suite \(relativePath) is platform-guarded by \(guardToken)."
                )
            }
        }
    }

    private func sourceFiles(
        below directoryURL: URL,
        packageRoot: URL,
        extensions: Set<String>
    ) throws -> [SourceFile] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw ArchitectureParityError.missingSourceRoot(directoryURL.path)
        }
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ArchitectureParityError.unreadableSourceRoot(directoryURL.path)
        }

        var sources: [SourceFile] = []
        for case let fileURL as URL in enumerator where extensions.contains(fileURL.pathExtension) {
            sources.append(
                SourceFile(
                    relativePath: relativePath(for: fileURL, packageRoot: packageRoot),
                    contents: try source(at: fileURL)
                )
            )
        }
        return sources.sorted { $0.relativePath < $1.relativePath }
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func relativePath(for url: URL, packageRoot: URL) -> String {
        let rootPath = packageRoot.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    private struct SourceFile {
        let relativePath: String
        let contents: String
    }

    private enum ArchitectureParityError: LocalizedError {
        case missingSourceRoot(String)
        case unreadableSourceRoot(String)

        var errorDescription: String? {
            switch self {
            case let .missingSourceRoot(path):
                return "Missing expected remote transport source root: \(path)."
            case let .unreadableSourceRoot(path):
                return "Could not enumerate remote transport source root: \(path)."
            }
        }
    }
}
