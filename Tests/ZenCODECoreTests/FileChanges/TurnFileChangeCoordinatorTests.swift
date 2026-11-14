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
    func undoLatestRestoresFilesFromTheirSnapshots() async throws {
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

        let undoneSummary = try await TurnFileChangeUndoService.undoLatest(
            summary: summary,
            baseDirectoryURL: directory
        )

        #expect(undoneSummary == summary)
        #expect(try Data(contentsOf: fileURL) == before)
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
        #expect(await coordinator.peekNetSummary() == summary)
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
        }
        // No live checkpoint published the summary: the turn's publication
        // still returns it.
        let final = try #require(await coordinator.publishSummaryIfNeeded())
        #expect(final.entries.first?.beforeDataBase64 == Data("user edit\n".utf8).base64EncodedString())
        #expect(await coordinator.matchingLiveArtifactPaths() == [file.path])
        try await TurnFileChangeUndoService.undoLatest(summary: final, baseDirectoryURL: repository)
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

extension TurnFileChangeCoordinatorTests {
    @Test(arguments: [false, true])
    func largeFileCompactEditsRemainUsefulInFinalArtifactHistory(laterOpaqueEdit: Bool) async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        let file = repository.appendingPathComponent("CHANGELOG.md")
        let before = (0..<2000).map { "entry \($0): " + String(repeating: "context ", count: 8) + "\n" }.joined()
        #expect(before.utf8.count > OperationFileChangeRecorder.maximumTextBytes)
        try before.write(to: file, atomically: true, encoding: .utf8)
        try initializeGitRepository(at: repository)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()
        let history = SessionFileArtifactHistory(sessionID: "compact")
        let turnID = try #require(await history.beginTurn(sessionID: "compact"))
        // Background-exec tests intentionally invalidate local evidence for the
        // process lifetime. Exercise history with captured compact evidence here;
        // real tool capture is covered separately in LocalToolsSupportTests.
        let after = before.replacingOccurrences(of: "entry 1000:", with: "direct change:")
        try after.write(to: file, atomically: true, encoding: .utf8)
        let lines = before.components(separatedBy: "\n")
        let patch = "@@ -998,7 +998,7 @@\n"
            + lines[997..<1000].map { " \($0)\n" }.joined()
            + "-\(lines[1000])\n"
            + "+\(lines[1000].replacingOccurrences(of: "entry 1000:", with: "direct change:"))\n"
            + lines[1001..<1004].map { " \($0)\n" }.joined()
        let changes = [OperationFileChange(
            path: file.path, oldText: nil, newText: nil,
            compactDiff: .init(patch: patch, additions: 1, deletions: 1)
        )]
        let live = try #require(await history.recordLive(changes, agentID: nil, callID: "edit", turnID: turnID, workingDirectory: repository))
        #expect(live.artifacts.first?.patch?.contains("+direct change:") == true)
        // Patch-only evidence is not a full postimage: checkpoint collection
        // still captures it, without changing the original undo baseline.
        if let checkpoint = await coordinator.collectLiveSummary(matching: changes) {
            _ = await history.recordLiveSummary(checkpoint, turnID: turnID, workingDirectory: repository)
        }
        if laterOpaqueEdit {
            let final = before.replacingOccurrences(of: "entry 1000:", with: "opaque final change:")
            try final.write(to: file, atomically: true, encoding: .utf8)
        }
        let latest = await history.sealTurn(turnID)
        let summary = try #require(await coordinator.publishSummaryIfNeeded(matching: latest))
        #expect(summary.entries.first?.beforeDataBase64 == Data(before.utf8).base64EncodedString())
        let matched = await coordinator.matchingLiveArtifactPaths()
        if laterOpaqueEdit { #expect(!matched.contains(file.path)) }
        _ = await history.finishTurn(turnID, summary: summary, matchingLivePaths: matched, workingDirectory: repository)
        let turns = await history.snapshot()
        let artifact = try #require(turns.first?.artifacts.first)
        #expect(artifact.oldText == nil && artifact.newText == nil)
        #expect(artifact.explanation == nil)
        #expect(artifact.status == .modified && artifact.hasLineCounts)
        #expect(artifact.additions == 1 && artifact.deletions == 1)
        #expect((artifact.patch?.utf8.count ?? .max) <= OperationFileChangeRecorder.maximumTextBytes)
        // Rendering remains based on captured final evidence even after removal.
        try FileManager.default.removeItem(at: file)
        let rendered = TerminalChat.renderFileArtifacts(turns, includeHistoryHeadings: true)
        #expect(rendered.contains("**modified `CHANGELOG.md`**  +1 -1"))
        #expect(rendered.contains(laterOpaqueEdit ? "+opaque final change:" : "+direct change:"))
        #expect(!rendered.contains("Diff unavailable"))
    }
}

extension TurnFileChangeCoordinatorTests {
    @Test
    func oversizedAddedFileIsShownTruncatedWhileTheSummaryKeepsTheFullPatchForUndo() async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        try Data("seed\n".utf8).write(to: repository.appendingPathComponent("seed.txt"))
        try initializeGitRepository(at: repository)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()
        let lines = (1...3142).map { "let value\($0) = \"generated line \($0)\"" }
        let added = repository.appendingPathComponent("Scripts/Gen.swift")
        try FileManager.default.createDirectory(
            at: added.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: added)

        let live = try #require(await coordinator.collectLiveSummary(matching: []))
        let entry = try #require(live.entries.first)
        let fullPatch = try #require(entry.patch)
        #expect(entry.status == .added && entry.additions == 3142)
        #expect(fullPatch.utf8.count > OperationFileChangeRecorder.maximumTextBytes)
        #expect(fullPatch.contains("+\(lines[3141])\n"))

        let artifact = try #require(
            FileChangeArtifactMapper.artifacts(from: live, workingDirectory: repository).first
        )
        let patch = try #require(artifact.patch)
        let kept = patch.components(separatedBy: "\n").count - 7
        #expect(kept > 0 && kept < 3142)
        #expect(patch.utf8.count <= OperationFileChangeRecorder.maximumTextBytes)
        #expect(patch.hasPrefix("diff --git a/Scripts/Gen.swift b/Scripts/Gen.swift\nnew file mode 100644\nindex "))
        #expect(patch.contains(
            "--- /dev/null\n+++ b/Scripts/Gen.swift\n@@ -0,0 +1,\(kept) @@\n+\(lines[0])\n+\(lines[1])\n"
        ))
        #expect(patch.hasSuffix("+\(lines[kept - 1])\n"))
        #expect(!patch.contains(lines[kept]))
        #expect(artifact.status == .added)
        #expect(artifact.additions == 3142 && artifact.deletions == 0 && artifact.hasLineCounts)
        #expect(artifact.explanation == FileChangeArtifactMapper.truncatedPatchExplanation(shown: kept, total: 3142))

        let rendered = TerminalChat.renderFileArtifacts([.init(number: 1, artifacts: [artifact])], includeHistoryHeadings: true)
        #expect(rendered.contains("**added `Scripts/Gen.swift`**  +3142 -0\nExplanation: Diff truncated: showing the first \(kept) of 3142 diff lines;"))
        #expect(rendered.contains("1 │ +\(lines[0])\n"))
        #expect(rendered.contains(" │ +\(lines[kept - 1])\n"))
        #expect(!rendered.contains(lines[kept]))

        // /artifacts history uses the same mapper on the published summary.
        let final = try #require(await coordinator.publishSummaryIfNeeded())
        #expect(final.entries.first?.patch == fullPatch)
        let history = SessionFileArtifactHistory(sessionID: "session")
        let turn = try #require(await history.append(summary: final, sessionID: "session", workingDirectory: repository))
        #expect(turn.artifacts.first?.patch == patch)
        #expect(turn.artifacts.first?.explanation == artifact.explanation)

        // Undo reverses the complete patch, not the truncated artifact.
        try await TurnFileChangeUndoService.undoLatest(summary: final, baseDirectoryURL: repository)
        #expect(!FileManager.default.fileExists(atPath: added.path))
    }
}

extension TurnFileChangeCoordinatorTests {
    @Test
    func oversizedModifiedFileIsShownTruncatedWhileTheSummaryKeepsTheFullPatchForUndo() async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        let lines = (1...8000).map { "line \($0): " + String(repeating: "abcdefghij", count: 2) }
        let original = Data((lines.joined(separator: "\n") + "\n").utf8)
        let file = repository.appendingPathComponent("data/big.txt")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try original.write(to: file)
        try initializeGitRepository(at: repository)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()
        // Many distant one-line edits, plus one long run of changed lines that forms a single
        // huge hunk in the middle: the early hunks fit whole and the huge one is cut.
        var edited = lines
        let editedIndices = Array(stride(from: 9, to: 1000, by: 20)) + Array(2000..<3500)
            + Array(stride(from: 5009, to: 8000, by: 20))
        for index in editedIndices { edited[index] = "edited " + lines[index] }
        try Data((edited.joined(separator: "\n") + "\n").utf8).write(to: file)

        let live = try #require(await coordinator.collectLiveSummary(matching: []))
        #expect(live.entries.count == 1)
        let entry = try #require(live.entries.first)
        let fullPatch = try #require(entry.patch)
        #expect(entry.status == .modified && entry.additions == 1700 && entry.deletions == 1700)
        #expect(fullPatch.utf8.count > OperationFileChangeRecorder.maximumTextBytes)

        let artifact = try #require(
            FileChangeArtifactMapper.artifacts(from: live, workingDirectory: repository).first
        )
        let patch = try #require(artifact.patch)
        #expect(patch.utf8.count <= OperationFileChangeRecorder.maximumTextBytes)
        #expect(artifact.status == .modified && artifact.oldText == nil && artifact.newText == nil)
        #expect(artifact.additions == 1700 && artifact.deletions == 1700 && artifact.hasLineCounts)

        // Whole hunks are verbatim; the last one is a line prefix with its header recounted.
        let fullHunks = fullPatch.components(separatedBy: "\n@@ ")
        let hunks = patch.components(separatedBy: "\n@@ ")
        // File headers, 50 early hunks, the huge one and 150 late ones.
        #expect(fullHunks.count == 202)
        // Fifty small hunks fit whole before the huge one, which is therefore the last kept.
        #expect(hunks.count == 52)
        #expect(Array(hunks.dropLast()) == Array(fullHunks[0..<(hunks.count - 1)]))
        let cut = try #require(hunks.last)
        let fullCut = fullHunks[hunks.count - 1]
        let cutHeader = String(try #require(cut.split(separator: "\n", omittingEmptySubsequences: false).first))
        let fullHeader = String(try #require(fullCut.split(separator: "\n", omittingEmptySubsequences: false).first))
        let cutBody = String(cut.dropFirst(cutHeader.count + 1))
        let fullBody = String(fullCut.dropFirst(fullHeader.count + 1))
        #expect(!cutBody.isEmpty && cutBody.hasSuffix("\n") && cutBody.utf8.count < fullBody.utf8.count)
        #expect((fullBody + "\n").hasPrefix(cutBody))
        let cutRows = cutBody.split(separator: "\n").map(String.init)
        let old = cutRows.filter { $0.hasPrefix(" ") || $0.hasPrefix("-") }.count
        let new = cutRows.filter { $0.hasPrefix(" ") || $0.hasPrefix("+") }.count
        let fullTokens = fullHeader.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let oldStart = try #require(fullTokens[0].dropFirst().split(separator: ",").first)
        let newStart = try #require(fullTokens[1].dropFirst().split(separator: ",").first)
        let section = fullTokens.count > 3 ? " " + fullTokens[3...].joined(separator: " ") : ""
        #expect(!section.isEmpty)
        #expect(cutHeader == "-\(oldStart),\(old) +\(newStart),\(new) @@\(section)")

        func diffLines(_ text: String) -> Int {
            text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(4)
                .filter { [" ", "+", "-"].contains($0.first) }.count
        }
        let shown = diffLines(patch)
        let total = diffLines(fullPatch)
        let earlyLines = 400 // fifty whole hunks of eight diff lines
        let lateLines = 1200 // 150 hunks of eight diff lines
        #expect(shown == earlyLines + cutRows.count)
        #expect(total == earlyLines + 3006 + lateLines)
        #expect(artifact.explanation == FileChangeArtifactMapper.truncatedPatchExplanation(shown: shown, total: total))

        let rendered = TerminalChat.renderFileArtifacts([.init(number: 1, artifacts: [artifact])], includeHistoryHeadings: true)
        #expect(rendered.contains("**modified `data/big.txt`**  +1700 -1700\nExplanation: Diff truncated: showing the first \(shown) of \(total) diff lines;"))
        #expect(rendered.contains("10 │ -\(lines[9])\n"))
        #expect(rendered.contains("10 │ +edited \(lines[9])\n"))
        // Git lists the 1500 removals before their additions, so the cut falls among the additions.
        #expect(rendered.contains("-\(lines[3499])\n") && !rendered.contains("+edited \(lines[3499])"))
        #expect(!rendered.contains(lines[7989]))

        let final = try #require(await coordinator.publishSummaryIfNeeded())
        #expect(final.entries.first?.patch == fullPatch)
        try await TurnFileChangeUndoService.undoLatest(summary: final, baseDirectoryURL: repository)
        #expect(try Data(contentsOf: file) == original)
    }
}
