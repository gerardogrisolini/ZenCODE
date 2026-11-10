import Foundation
import Testing
import FeatureKit
@testable import LocalToolsSupport

/// search.glob does not descend into VCS and build directories met below the
/// root unless the root is inside one or the pattern names one; search.grep and
/// search.locate stop grep once their cut is filled.
@Suite
struct LocalSearchToolsEarlyStopTests {
    @Test
    func globListsExcludedDirectoriesWithoutTheirContentsUnlessTheRootIsInside() async throws {
        let root = try makeTree(["src/a.swift", ".git/HEAD", ".build/x.o", ".swiftpm/config",
                                 "node_modules/pkg/.git/HEAD", "DerivedData/Build/y.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let context = FeatureContext(workingDirectory: root, environment: [:])
        func glob(_ path: String?) async throws -> [String] {
            let input = SearchGlobTool.Input(pattern: nil, path: path, maxResults: nil, max_results: nil)
            return try await SearchGlobTool().run(input, context: context).components(separatedBy: "\n")
        }
        // Suffix checks only: under `/private` the relative paths carry a stray
        // prefix (pre-existing: `resolvePath` drops `/private`, the enumerator not).
        let listing = try await glob(nil)
        #expect(listing.contains { $0.hasSuffix("src/a.swift") })
        for name in [".git", ".build", ".swiftpm", "node_modules", "DerivedData"] {
            #expect(listing.contains { $0.hasSuffix(name) }, "\(name)")
            #expect(!listing.contains { $0.contains(name + "/") }, "\(name)")
        }
        // Inside an excluded root nothing is pruned, not even a nested `.git`.
        let inside = try await glob("node_modules")
        #expect(inside.contains { $0.hasSuffix("pkg/.git/HEAD") })
    }

    @Test
    func globPatternNamesSearchExcludedDirectoryChecksWholePathComponents() {
        for pattern in [".build/checkouts/**/Package.swift", "node_modules/react/package.json", "**/node_modules/**"] {
            #expect(LocalToolsSupport.globPatternNamesSearchExcludedDirectory(pattern), "\(pattern)")
        }
        for pattern in [nil, "**/*.swift", "src/build/a.swift", ".buildx/a", "my.git/HEAD"] as [String?] {
            #expect(!LocalToolsSupport.globPatternNamesSearchExcludedDirectory(pattern), "\(pattern ?? "nil")")
        }
    }

    @Test
    func globDescendsIntoExcludedDirectoriesNamedByThePatternAndStillPrunesTheOthers() async throws {
        let root = try makeTree(["ws/src/a.swift", "ws/.build/checkouts/dep/Package.swift",
                                 "ws/node_modules/react/package.json", "ws/.git/HEAD"])
        defer { try? FileManager.default.removeItem(at: root) }
        let context = FeatureContext(workingDirectory: root, environment: [:])
        func glob(_ pattern: String) async throws -> [String] {
            let input = SearchGlobTool.Input(pattern: pattern, path: nil, maxResults: nil, max_results: nil)
            return try await SearchGlobTool().run(input, context: context).components(separatedBy: "\n")
        }
        // The leading `*` also crosses `/`, so it absorbs the stray prefix that
        // the relative paths carry under `/private` (see the test above).
        let checkouts = try await glob("*/.build/checkouts/**/Package.swift")
        #expect(checkouts.contains { $0.hasSuffix(".build/checkouts/dep/Package.swift") }, "\(checkouts)")
        let modules = try await glob("*/node_modules/react/package.json")
        #expect(modules.contains { $0.hasSuffix("node_modules/react/package.json") }, "\(modules)")
        // A pattern that names no excluded directory keeps the pruning.
        for pattern in ["*/package.json", "*.json"] {
            let pruned = try await glob(pattern)
            #expect(pruned == ["<empty>"], "\(pattern): \(pruned)")
        }
    }

    @Test
    func grepAndLocateStopAtMaxResultsWithTheFirstLines() async throws {
        // Two files with far more matches than the cut and than a pipe buffer.
        let body = (1...12_000).map { "needle \($0)" }.joined(separator: "\n") + "\n"
        let root = try makeTree(["a.txt", "b.txt"], content: body)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = FeatureContext(workingDirectory: root, environment: [:])
        // From 10_000 grep gets no `-m`: only the line limit stops it.
        let grep = try await SearchGrepTool().run(.init(pattern: "needle", path: nil, maxResults: 10_000,
            max_results: nil, context: nil, filesOnly: nil, files_only: nil), context: context)
            .components(separatedBy: "\n")
        #expect(grep.count == 10_000)
        #expect(Array(grep.prefix(2)) == ["exit_code: 0", "stdout:"])
        #expect(areFirstMatches(grep.dropFirst(2)))

        let locate = try await SearchLocateTool().run(.init(pattern: "needle", path: nil, maxResults: 500,
            max_results: nil, context: nil), context: context).components(separatedBy: "\n")
        #expect(locate.first == "matches: 500")
        #expect(areFirstMatches(locate[1...500]))
    }
}

/// Whether `lines` are lines `1...n` of one corpus file, as `path:line:text`.
private func areFirstMatches(_ lines: ArraySlice<String>) -> Bool {
    lines.enumerated().allSatisfy { $1.hasSuffix(".txt:\($0 + 1):needle \($0 + 1)") }
}

private func makeTree(_ paths: [String], content: String = "x\n") throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-stop-\(UUID().uuidString)")
    for file in paths.map({ root.appendingPathComponent($0) }) {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }
    return root
}
