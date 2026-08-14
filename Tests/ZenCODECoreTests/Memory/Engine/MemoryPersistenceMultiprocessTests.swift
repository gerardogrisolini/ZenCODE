import Foundation
import Testing
@testable import ZenCODECore

/// Two independent engine actors model separate `zen` processes. Their shared
/// JSON persistence must reload the graph under the OS-level lock, otherwise
/// the later atomic replacement would discard the first process's write.
@Suite(.serialized)
struct MemoryPersistenceMultiprocessTests {
    /// This deliberately launches the SwiftPM helper instead of merely making
    /// two actors: actor isolation cannot prove that the advisory lock survives
    /// atomic replacement across independent process descriptor tables.
    @Test func subprocessesCommitAllConcurrentWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-persistence-helper-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let contents = (0..<12).map { "subprocess fact \($0)" }
        let helperURL = try helperExecutableURL()
        let processes = try contents.map {
            try startHelper(
                executableURL: helperURL,
                workspace: workspace,
                support: support,
                content: $0
            )
        }
        for process in processes {
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        let graphs = FileManager.default.enumerator(at: support, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "memory.graph.json" } ?? []
        #expect(graphs.count == 1)
        let persisted = try await JSONMemoryPersistence(url: try #require(graphs.first)).load()
        #expect(Set(persisted.memories.values.map(\.content)) == Set(contents))
    }

    @Test func independentEnginesCommitAllConcurrentWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        let first = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
        let second = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))

        async let firstWrite = first.remember("first process fact", id: "first")
        async let secondWrite = second.remember("second process fact", id: "second")
        _ = try await (firstWrite, secondWrite)

        let persisted = try await JSONMemoryPersistence(url: file).load()
        #expect(persisted.memories.keys.sorted() == ["first", "second"])
    }

    @Test func concurrentCommitMigratesLegacyVersionOnlyWhenWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("memory.graph.json")
        let legacy = #"{"graph_version":1,"memories":{},"tags":{},"clusters":{},"edges":{},"reverse_edges":{},"metadata":{"retrieval_count":0,"link_discovery_count":0}}"#
        try Data(legacy.utf8).write(to: file)

        let first = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
        let second = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
        async let firstWrite = first.remember("one", id: "one")
        async let secondWrite = second.remember("two", id: "two")
        _ = try await (firstWrite, secondWrite)

        let graph = try await JSONMemoryPersistence(url: file).load()
        #expect(graph.graphVersion == MemoryGraph.currentGraphVersion)
        #expect(graph.memories.keys.sorted() == ["one", "two"])
    }

    private func startHelper(
        executableURL: URL,
        workspace: URL,
        support: URL,
        content: String
    ) throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [AppStorageDirectory.testHarnessArgument, workspace.path, content]
        process.currentDirectoryURL = packageRoot
        // Do not inherit XCTest variables or an operator's support-directory
        // override. The helper's explicit argument is its own test-harness
        // identity; this is the sole support path it is allowed to use.
        process.environment = [AppStorageDirectory.supportDirectoryEnvironmentKey: support.path]
        try process.run()
        return process
    }

    /// SwiftPM places executable products next to the test bundle (or next to
    /// the test executable on Linux). Resolve that product directory from the
    /// test bundle path supplied to `swiftpm-testing-helper` instead of asking
    /// SwiftPM to inspect its build directory while tests are running; that
    /// command would contend for SwiftPM's build-directory lock.
    private func helperExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let arguments = CommandLine.arguments
        var executableURLs: [URL] = []

        func appendExecutableURL(from path: String) {
            guard !path.isEmpty else { return }
            executableURLs.append(
                URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
            )
        }

        // SwiftPM's testing helper passes the test executable once as the
        // value of --test-bundle-path and once as a positional argument. Also
        // accept a .xctest path directly for older/newer runner spellings.
        for (index, argument) in arguments.enumerated() {
            if argument == "--test-bundle-path",
               arguments.indices.contains(index + 1) {
                appendExecutableURL(from: arguments[index + 1])
            } else if argument.hasPrefix("--test-bundle-path=") {
                appendExecutableURL(from: String(argument.dropFirst("--test-bundle-path=".count)))
            } else if argument.contains(".xctest") {
                appendExecutableURL(from: argument)
            }
        }
        if let executableURL = Bundle.main.executableURL {
            executableURLs.append(executableURL.standardizedFileURL)
        }
        if let argument = arguments.first {
            appendExecutableURL(from: argument)
        }

        var searchedDirectories: [URL] = []

        func appendSearchDirectory(_ directory: URL) {
            let standardized = directory.standardizedFileURL
            guard !searchedDirectories.contains(where: { $0.path == standardized.path }) else {
                return
            }
            searchedDirectories.append(standardized)
        }

        for executableURL in executableURLs {
            appendSearchDirectory(productDirectory(for: executableURL))
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            appendSearchDirectory(productDirectory(for: bundle.bundleURL))
            if let executableURL = bundle.executableURL {
                appendSearchDirectory(productDirectory(for: executableURL))
            }
        }
        for key in ["BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR", "__XCODE_BUILT_PRODUCTS_DIR_PATHS", "DYLD_LIBRARY_PATH"] {
            guard let value = ProcessInfo.processInfo.environment[key] else { continue }
            for path in value.split(separator: ":") where !path.isEmpty {
                appendSearchDirectory(URL(fileURLWithPath: String(path)))
            }
        }

        for productDirectory in searchedDirectories {
            let candidate = productDirectory.appendingPathComponent("MemoryPersistenceTestHelper")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let searchedFrom = searchedDirectories.map(\.path).joined(separator: ", ")
        throw CocoaError(
            .fileNoSuchFile,
            userInfo: [
                NSFilePathErrorKey: "MemoryPersistenceTestHelper (searched in: \(searchedFrom))"
            ]
        )
    }

    private func productDirectory(for executableURL: URL) -> URL {
        let path = executableURL.standardizedFileURL.path
        let components = path.split(separator: "/")
        if let bundleIndex = components.firstIndex(where: { $0.hasSuffix(".xctest") }) {
            let bundlePath = "/" + components[...bundleIndex].joined(separator: "/")
            return URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        }
        return executableURL.deletingLastPathComponent()
    }

    private var packageRoot: URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        fatalError("Package.swift not found from \(#filePath)")
    }
}
