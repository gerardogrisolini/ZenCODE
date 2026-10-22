import FeatureKit
import FeatureMCPBridgeKit
import Foundation
import ToolCore
@testable import XcodeToolsFeature
import Testing

@Suite
struct XcodeFileChangeCaptureTests {
    private func makeProject() throws -> (root: URL, sources: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-capture-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("App/Core", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        return (root, sources)
    }

    @Test
    func resolvesNavigatorPathsWithAndWithoutTheProjectGroupPrefix() {
        let root = URL(fileURLWithPath: "/tmp/Project")
        let candidates = XcodeFileChangeCapture.candidates(
            for: "Project/App/Core/Net.swift",
            roots: [root]
        ).map(\.path)

        #expect(candidates == [
            "/tmp/Project/Project/App/Core/Net.swift",
            "/tmp/Project/App/Core/Net.swift"
        ])
        #expect(XcodeFileChangeCapture.candidates(for: "/abs/File.swift", roots: [root])
            .map(\.path) == ["/abs/File.swift"])
        #expect(XcodeFileChangeCapture.candidates(for: "../Escape.swift", roots: [root]).isEmpty)
        #expect(XcodeFileChangeCapture.candidates(for: "Relative.swift", roots: []).isEmpty)
    }

    @Test
    func updateReportsOnlyTheCandidateThatChangedOnDisk() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let file = project.sources.appendingPathComponent("Net.swift")
        try "let reachable = false\n".write(to: file, atomically: true, encoding: .utf8)

        let request = ToolRequest(
            name: "XcodeUpdate",
            arguments: ["filePath": .string("Project/App/Core/Net.swift")]
        )
        let capture = try #require(XcodeFileChangeCapture(request: request, roots: [project.root]))
        try "let reachable = true\n".write(to: file, atomically: true, encoding: .utf8)

        let changes = capture.finish(succeeded: true)
        #expect(changes == [
            FeatureInvocationFileChange(
                path: file.standardizedFileURL.path,
                oldText: "let reachable = false\n",
                newText: "let reachable = true\n"
            )
        ])
    }

    @Test
    func writeOfANewFileIsReportedAsAnAddition() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let file = project.sources.appendingPathComponent("New.swift")

        let request = ToolRequest(
            name: "XcodeWrite",
            arguments: ["filePath": .string("Project/App/Core/New.swift")]
        )
        let capture = try #require(XcodeFileChangeCapture(request: request, roots: [project.root]))
        try "struct New {}\n".write(to: file, atomically: true, encoding: .utf8)

        let change = try #require(capture.finish(succeeded: true).first)
        #expect(change.path == file.standardizedFileURL.path)
        #expect(change.oldText == nil)
        #expect(change.newText == "struct New {}\n")
        #expect(change.explanation == nil)
    }

    @Test
    func removeAndMoveReportDeletionAndAddition() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let removed = project.sources.appendingPathComponent("Old.swift")
        let source = project.sources.appendingPathComponent("A.swift")
        let destination = project.sources.appendingPathComponent("B.swift")
        try "old\n".write(to: removed, atomically: true, encoding: .utf8)
        try "moved\n".write(to: source, atomically: true, encoding: .utf8)

        let remove = try #require(XcodeFileChangeCapture(
            request: ToolRequest(name: "XcodeRM", arguments: ["path": .string("App/Core/Old.swift")]),
            roots: [project.root]
        ))
        let move = try #require(XcodeFileChangeCapture(
            request: ToolRequest(name: "XcodeMV", arguments: [
                "sourcePath": .string("App/Core/A.swift"),
                "destinationPath": .string("App/Core/B.swift")
            ]),
            roots: [project.root]
        ))
        try FileManager.default.removeItem(at: removed)
        try FileManager.default.moveItem(at: source, to: destination)

        #expect(remove.finish(succeeded: true) == [
            FeatureInvocationFileChange(path: removed.standardizedFileURL.path, oldText: "old\n", newText: nil)
        ])
        #expect(move.finish(succeeded: true) == [
            FeatureInvocationFileChange(path: source.standardizedFileURL.path, oldText: "moved\n", newText: nil),
            FeatureInvocationFileChange(path: destination.standardizedFileURL.path, oldText: nil, newText: "moved\n")
        ])
    }

    @Test
    func successWithoutAnOnDiskChangeKeepsThePathVisibleWithAnExplanation() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let file = project.sources.appendingPathComponent("Same.swift")
        try "same\n".write(to: file, atomically: true, encoding: .utf8)
        let request = ToolRequest(
            name: "XcodeUpdate",
            arguments: ["filePath": .string("Project/App/Core/Same.swift")]
        )

        let succeeded = try #require(XcodeFileChangeCapture(request: request, roots: [project.root]))
        #expect(succeeded.finish(succeeded: true) == [
            FeatureInvocationFileChange(
                path: file.standardizedFileURL.path,
                oldText: nil,
                newText: nil,
                explanation: XcodeFileChangeCapture.notFoundExplanation
            )
        ])

        let failed = try #require(XcodeFileChangeCapture(request: request, roots: [project.root]))
        #expect(failed.finish(succeeded: false).isEmpty)
    }

    @Test
    func navigatorPathsOfNestedPackagesAreFoundBySearchingTheProject() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let modules = project.root.appendingPathComponent("Modules", isDirectory: true)
        let views = modules.appendingPathComponent("Institutional/Sources/Institutional/View", isDirectory: true)
        try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
        let file = views.appendingPathComponent("Prize.swift")
        try "let padding = 16\n".write(to: file, atomically: true, encoding: .utf8)

        let capture = try #require(XcodeFileChangeCapture(
            request: ToolRequest(name: "XcodeUpdate", arguments: [
                "filePath": .string("Institutional/Sources/Institutional/View/Prize.swift")
            ]),
            roots: [project.root]
        ))
        try "let padding = 24\n".write(to: file, atomically: true, encoding: .utf8)

        let changes = capture.finish(succeeded: true)
        #expect(changes == [
            FeatureInvocationFileChange(
                path: file.standardizedFileURL.path,
                oldText: "let padding = 16\n",
                newText: "let padding = 24\n"
            )
        ])
        #expect(capture.confirmedSearchBases(in: changes).map(\.path) == [modules.standardizedFileURL.path])

        // A confirmed base resolves sibling packages without another search.
        let catalog = modules.appendingPathComponent("Catalog/Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let list = catalog.appendingPathComponent("List.swift")
        try "list\n".write(to: list, atomically: true, encoding: .utf8)
        let sibling = try #require(XcodeFileChangeCapture(
            request: ToolRequest(name: "XcodeUpdate", arguments: [
                "filePath": .string("Catalog/Sources/List.swift")
            ]),
            roots: [project.root],
            knownBases: [modules]
        ))
        #expect(sibling.paths.first?.urls.map(\.path).contains(list.standardizedFileURL.path) == true)
        #expect(sibling.paths.allSatisfy { $0.searchBases.isEmpty })
    }

    @Test
    func newFilesOfNestedPackagesAreLocatedThroughTheirDirectory() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let sources = project.root.appendingPathComponent("Modules/Feature/Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("New.swift")

        let capture = try #require(XcodeFileChangeCapture(
            request: ToolRequest(name: "XcodeWrite", arguments: [
                "filePath": .string("Feature/Sources/Feature/New.swift")
            ]),
            roots: [project.root]
        ))
        try "struct New {}\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(capture.finish(succeeded: true) == [
            FeatureInvocationFileChange(
                path: file.standardizedFileURL.path,
                oldText: nil,
                newText: "struct New {}\n"
            )
        ])
    }

    @Test
    func searchSkipsHiddenAndBuildDirectoriesAndIsBounded() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        for directory in [".build/checkouts", "DerivedData/SourcePackages"] {
            let sources = project.root.appendingPathComponent("\(directory)/Pkg/Sources", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try "x\n".write(to: sources.appendingPathComponent("X.swift"), atomically: true, encoding: .utf8)
        }
        let components = ["Pkg", "Sources", "X.swift"]
        #expect(XcodeFileChangeCapture.search(components, in: [project.root]).isEmpty)

        let visible = project.root.appendingPathComponent("Modules/Pkg/Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        try "x\n".write(to: visible.appendingPathComponent("X.swift"), atomically: true, encoding: .utf8)
        #expect(XcodeFileChangeCapture.search(components, in: [project.root]).map(\.url.path) == [
            visible.appendingPathComponent("X.swift").standardizedFileURL.path
        ])
        #expect(XcodeFileChangeCapture.search(components, in: [project.root], entryLimit: 1).isEmpty)
    }

    @Test
    func binaryContentIsReportedWithoutText() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let file = project.sources.appendingPathComponent("Blob.bin")
        try Data([0x00, 0x01]).write(to: file)
        let capture = try #require(XcodeFileChangeCapture(
            request: ToolRequest(name: "XcodeWrite", arguments: ["filePath": .string(file.path)]),
            roots: []
        ))
        try Data([0x00, 0x02]).write(to: file)

        let change = try #require(capture.finish(succeeded: true).first)
        #expect(change.oldText == nil && change.newText == nil)
        #expect(change.explanation == XcodeFileChangeCapture.unavailableExplanation)
    }

    @Test
    func symlinkedSourceFilesReportTheTargetContents() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let target = project.root.appendingPathComponent("Shared.swift")
        let link = project.sources.appendingPathComponent("Linked.swift")
        try "v1\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let capture = try #require(XcodeFileChangeCapture(
            request: ToolRequest(name: "XcodeUpdate", arguments: ["filePath": .string("App/Core/Linked.swift")]),
            roots: [project.root]
        ))
        // Edit through the link without replacing it, as an editor would.
        try "v2\n".write(to: link, atomically: false, encoding: .utf8)

        #expect(capture.finish(succeeded: true) == [
            FeatureInvocationFileChange(
                path: link.standardizedFileURL.path,
                oldText: "v1\n",
                newText: "v2\n"
            )
        ])

        let dangling = project.sources.appendingPathComponent("Dangling.swift")
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: project.root.appendingPathComponent("Missing.swift")
        )
        guard case .opaque = XcodeFileChangeCapture.snapshot(dangling) else {
            Issue.record("A dangling symlink must stay opaque, not absent or readable.")
            return
        }
    }

    @Test
    func failedResultsIncludeStructuredSuccessFlags() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let file = project.sources.appendingPathComponent("Same.swift")
        try "same\n".write(to: file, atomically: true, encoding: .utf8)
        let capture = try #require(XcodeFileChangeCapture(
            request: ToolRequest(name: "XcodeUpdate", arguments: ["filePath": .string(file.path)]),
            roots: []
        ))

        #expect(capture.finish(succeeded: !XcodeToolExecutor.isErrorResult(.object([
            "structuredContent": .object(["success": .bool(false), "message": .string("No match")])
        ]))).isEmpty)
        #expect(XcodeToolExecutor.isErrorResult(.object(["isError": .bool(true)])))
        #expect(!XcodeToolExecutor.isErrorResult(.object([
            "structuredContent": .object(["success": .bool(true)])
        ])))
        #expect(!XcodeToolExecutor.isErrorResult(.string("plain")))
    }

    @Test
    func readOnlyAndDirectoryToolsAreNotTracked() {
        #expect(!XcodeFileChangeCapture.tracksChanges(toolName: "XcodeRead"))
        #expect(!XcodeFileChangeCapture.tracksChanges(toolName: "XcodeMakeDir"))
        #expect(!XcodeFileChangeCapture.tracksChanges(toolName: "BuildProject"))
        #expect(XcodeFileChangeCapture.tracksChanges(toolName: "XcodeUpdate"))
        #expect(XcodeFileChangeCapture(
            request: ToolRequest(name: "XcodeRead", arguments: ["filePath": .string("/tmp/x")]),
            roots: []
        ) == nil)
    }

    @Test
    func invocationEnvelopeCarriesFileChangesOnlyWhenPresent() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            InvocationResponse(ok: true, output: .string("done"), error: nil)
        )) as? [String: Any]
        #expect(plain?.keys.sorted() == ["ok", "output"])

        let evidenced = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            InvocationResponse(
                ok: true,
                output: .string("done"),
                error: nil,
                fileChanges: [
                    FeatureInvocationFileChange(path: "/tmp/A.swift", oldText: "a", newText: "b")
                ]
            )
        )) as? [String: Any]
        let changes = try #require(evidenced?["fileChanges"] as? [[String: Any]])
        #expect(changes.first?["path"] as? String == "/tmp/A.swift")
        #expect(changes.first?["newText"] as? String == "b")
    }
}
