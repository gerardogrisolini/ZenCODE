//
//  TurnFileChangeCoordinatorTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/06/26.
//
import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct TurnFileChangeCoordinatorTests {
    @Test
    func undoLatestThrowsWhenNoChangesAreTracked() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)

        do {
            _ = try await coordinator.undoLatestChanges()
            Issue.record("undoLatestChanges should throw without a summary.")
        } catch let error as TurnFileChangeUndoError {
            #expect(error == .noTrackedFileChanges)
        }
    }

    @Test
    func undoLatestThrowsWhenSummaryCannotBeUndone() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let summary = TurnFileChangeSummary(
            entries: [
                TurnFileChangeSummary.Entry(
                    path: "Sources/App.swift",
                    additions: 1,
                    deletions: 0,
                    status: .modified,
                    isBinary: false,
                    existedBefore: nil,
                    beforeDataBase64: nil,
                    patch: nil
                )
            ]
        )

        do {
            _ = try await TurnFileChangeUndoService.undoLatest(
                summary: summary,
                baseDirectoryURL: directory
            )
            Issue.record("undoLatest should throw for non-undoable summaries.")
        } catch let error as TurnFileChangeUndoError {
            #expect(error == .unavailable)
        }
    }

    @Test
    func undoLatestRestoresFilesAndClearsCoordinatorSummary() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let before = Data("let value = 1\n".utf8)
        let after = Data("let value = 2\n".utf8)
        try after.write(to: fileURL)
        let summary = TurnFileChangeSummary(
            entries: [
                TurnFileChangeSummary.Entry(
                    path: "Sources/App.swift",
                    additions: 1,
                    deletions: 1,
                    status: .modified,
                    isBinary: false,
                    existedBefore: true,
                    beforeDataBase64: before.base64EncodedString(),
                    patch: nil
                )
            ]
        )
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)
        await coordinator.replaceLatestSummary(summary)

        let undoneSummary = try await coordinator.undoLatestChanges()

        #expect(undoneSummary == summary)
        #expect(try Data(contentsOf: fileURL) == before)
        #expect(await coordinator.latestFileChangeSummary() == nil)
    }

        @Test
    func undoRestoresFilesWhenBaseDirectoryIsGitRepoSubdirectory() async throws {
        let repoDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: repoDirectory)
        }
                // Minimal valid git layout so `git apply` resolves paths against the
        // repository root and silently skips patches outside the subtree.
        let gitDirectory = repoDirectory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("objects", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("refs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ref: refs/heads/main\n".utf8).write(
            to: gitDirectory.appendingPathComponent("HEAD")
        )
        let baseDirectory = repoDirectory.appendingPathComponent("sub", isDirectory: true)
        let fileURL = baseDirectory.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let before = Data("let value = 1\n".utf8)
        let after = Data("let value = 2\n".utf8)
        try after.write(to: fileURL)
        let patch = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 3c37c33..6392506 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1 +1 @@
        -let value = 1
        +let value = 2
        """
        let summary = TurnFileChangeSummary(
            entries: [
                TurnFileChangeSummary.Entry(
                    path: "Sources/App.swift",
                    additions: 1,
                    deletions: 1,
                    status: .modified,
                    isBinary: false,
                    existedBefore: true,
                    beforeDataBase64: before.base64EncodedString(),
                    patch: patch
                )
            ]
        )

        try await TurnFileChangeUndoService.undo(
            summary: summary,
            baseDirectoryURL: baseDirectory
        )

        #expect(try Data(contentsOf: fileURL) == before)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "turn-file-change-coordinator-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
