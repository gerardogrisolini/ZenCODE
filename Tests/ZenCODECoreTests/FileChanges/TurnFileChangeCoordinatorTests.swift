//
//  TurnFileChangeCoordinatorTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/06/26.
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

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

    @Test
    func summaryReconcilesChangesMadeOutsideTrackedTools() async throws {
        let repository = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: repository)
        }
        let fileURL = repository.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("let value = 1\n".utf8).write(to: fileURL)
        try initializeGitRepository(at: repository)

        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()

        // Simulate a change produced by a tool the tracker cannot predict
        // (e.g. local.exec / sub-agent) by editing without capturing a baseline.
        try Data("let value = 2\n".utf8).write(to: fileURL)

        let summary = await coordinator.publishSummaryIfNeeded()
        let paths = summary?.entries.map(\.path) ?? []
        #expect(paths.contains("Sources/App.swift"))
    }

    @Test
    func summaryExcludesFilesDirtyBeforeTheTurn() async throws {
        let repository = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: repository)
        }
        let fileURL = repository.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("let value = 1\n".utf8).write(to: fileURL)
        try initializeGitRepository(at: repository)

        // File is already modified before the turn begins.
        try Data("let value = 99\n".utf8).write(to: fileURL)

        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()

        // No further change during the turn.
        let summary = await coordinator.publishSummaryIfNeeded()
        #expect(summary == nil)
    }

    @Test
    func finalReconciliationComparesTheLatestLivePostimageNotJustThePath() async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        for name in ["same.txt", "opaque.txt", "deleted.txt"] {
            try Data("before\n".utf8).write(to: repository.appendingPathComponent(name))
        }
        try initializeGitRepository(at: repository)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()
        try Data("live\n".utf8).write(to: repository.appendingPathComponent("same.txt"))
        try Data("shell after live\n".utf8).write(to: repository.appendingPathComponent("opaque.txt"))
        try Data("final only\n".utf8).write(to: repository.appendingPathComponent("shell.txt"))
        try FileManager.default.removeItem(at: repository.appendingPathComponent("deleted.txt"))
        let changes = [
            OperationFileChange(path: "same.txt", oldText: "before\n", newText: "live\n"),
            OperationFileChange(path: "opaque.txt", oldText: "before\n", newText: "live\n"),
            OperationFileChange(path: "deleted.txt", oldText: "before\n", newText: nil)
        ]
        let summary = try #require(await coordinator.publishSummaryIfNeeded(matching: changes))
        #expect(Set(summary.entries.map(\.path)) == ["same.txt", "opaque.txt", "shell.txt", "deleted.txt"])
        #expect(await coordinator.matchingLiveArtifactPaths() == [
            repository.appendingPathComponent("same.txt").path,
            repository.appendingPathComponent("deleted.txt").path
        ])
        #expect(await coordinator.publishSummaryIfNeeded(matching: changes) == nil)
        #expect(await coordinator.latestFileChangeSummary() == summary)
    }

    @Test
    func liveCheckpointsAreIncrementalAndKeepTheOriginalUndoBaseline() async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        let file = repository.appendingPathComponent("file.txt")
        try Data("committed\n".utf8).write(to: file)
        try initializeGitRepository(at: repository)
        try Data("user edit\n".utf8).write(to: file)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()
        #expect(await coordinator.collectLiveSummary(matching: []) == nil)

        for (before, after) in [("user edit\n", "first\n"), ("first\n", "second\n"), ("second\n", "committed\n")] {
            try Data(after.utf8).write(to: file)
            let live = try #require(await coordinator.collectLiveSummary(matching: []))
            let entry = try #require(live.entries.first)
            #expect(entry.beforeDataBase64 == Data(before.utf8).base64EncodedString())
            #expect(entry.patch?.contains("+" + after) == true)
            #expect(await coordinator.collectLiveSummary(matching: []) == nil)
            #expect(await coordinator.latestFileChangeSummary() == nil)
        }
        let final = try #require(await coordinator.publishSummaryIfNeeded())
        #expect(final.entries.first?.beforeDataBase64 == Data("user edit\n".utf8).base64EncodedString())
        #expect(await coordinator.matchingLiveArtifactPaths() == [file.path])
        _ = try await coordinator.undoLatestChanges()
        #expect(try String(contentsOf: file, encoding: .utf8) == "user edit\n")
    }

    @Test
    func liveCheckpointsDetectDirtyFilesReturningToCleanAndUntrackedDeletion() async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        let file = repository.appendingPathComponent("file.txt")
        let untracked = repository.appendingPathComponent("untracked.txt")
        try Data("committed\n".utf8).write(to: file)
        try initializeGitRepository(at: repository)
        try Data("dirty\n".utf8).write(to: file)
        try Data("untracked\n".utf8).write(to: untracked)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()
        try Data("committed\n".utf8).write(to: file)
        try FileManager.default.removeItem(at: untracked)
        let live = try #require(await coordinator.collectLiveSummary(matching: []))
        #expect(live.entries.map(\.path) == ["file.txt", "untracked.txt"])
        #expect(live.entries.last?.status == .deleted)
        #expect(await coordinator.collectLiveSummary(matching: []) == nil)
        let final = try #require(await coordinator.publishSummaryIfNeeded())
        #expect(final.entries.count == 2)
        #expect(await coordinator.matchingLiveArtifactPaths() == [file.path, untracked.path])
    }

    @Test
    func liveCheckpointsDeduplicateDirectEvidenceButDetectSubsequentOpaqueChanges() async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        let file = repository.appendingPathComponent("file.txt")
        try Data("before\n".utf8).write(to: file)
        try initializeGitRepository(at: repository)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()
        try Data("direct\n".utf8).write(to: file)
        let evidence = [OperationFileChange(path: "file.txt", oldText: "before\n", newText: "direct\n")]
        #expect(await coordinator.collectLiveSummary(matching: evidence) == nil)
        try Data("opaque\n".utf8).write(to: file)
        let live = try #require(await coordinator.collectLiveSummary(matching: []))
        #expect(live.entries.first?.beforeDataBase64 == Data("direct\n".utf8).base64EncodedString())
        // Returning to an older direct postimage is still a new change after
        // the opaque checkpoint; stale direct evidence must not hide it.
        try Data("direct\n".utf8).write(to: file)
        #expect(await coordinator.publishSummaryIfNeeded(matching: evidence) != nil)
        #expect(await coordinator.matchingLiveArtifactPaths().isEmpty)
    }

    @Test
    func liveCheckpointsHandleAddedDeletedBinaryAndOversizedFiles() async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        try Data("seed\n".utf8).write(to: repository.appendingPathComponent("seed.txt"))
        try initializeGitRepository(at: repository)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()
        let file = repository.appendingPathComponent("new.txt")
        try Data("new\n".utf8).write(to: file)
        #expect(await coordinator.collectLiveSummary(matching: [])?.entries.first?.status == .added)
        try FileManager.default.removeItem(at: file)
        #expect(await coordinator.collectLiveSummary(matching: [])?.entries.first?.status == .deleted)
        try Data([0, 1, 2]).write(to: repository.appendingPathComponent("binary.dat"))
        try Data(repeating: 97, count: OperationFileChangeRecorder.maximumTextBytes + 1)
            .write(to: repository.appendingPathComponent("large.txt"))
        let live = try #require(await coordinator.collectLiveSummary(matching: []))
        let artifacts = FileChangeArtifactMapper.artifacts(from: live, workingDirectory: repository)
        #expect(artifacts.count == 2)
        #expect(artifacts.first?.isBinary == true)
        #expect(artifacts.last?.explanation != nil)
        #expect(await coordinator.collectLiveSummary(matching: []) == nil)
        let final = try #require(await coordinator.publishSummaryIfNeeded())
        #expect(final.entries.map(\.path) == ["binary.dat", "large.txt"])
        #expect(await coordinator.matchingLiveArtifactPaths().count == 2)
    }

    private func initializeGitRepository(at directory: URL) throws {
        try runGit(["init"], in: directory)
        try runGit(["config", "user.email", "test@example.com"], in: directory)
        try runGit(["config", "user.name", "ZenCODE Test"], in: directory)
        try runGit(["add", "."], in: directory)
        try runGit(["commit", "-m", "initial"], in: directory)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = GitExecutableResolver.executableURL()
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
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
