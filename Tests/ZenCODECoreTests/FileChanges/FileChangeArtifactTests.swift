import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

@Suite
struct FileChangeArtifactTests {
    @Test
    func operationEvidenceNormalizesPathsAndDeduplicatesInInputOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let changes = [
            OperationFileChange(path: "Sources/App.swift", oldText: "old\n", newText: "new\n"),
            OperationFileChange(path: directory.appendingPathComponent("Sources/App.swift").path,
                                oldText: "ignored", newText: "ignored")
        ]
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: changes,
            workingDirectory: directory
        )

        #expect(artifacts.count == 1)
        #expect(artifacts[0].absolutePath == directory.appendingPathComponent("Sources/App.swift").path)
        #expect(artifacts[0].displayPath == "Sources/App.swift")
        #expect(artifacts[0].status == .modified)
        #expect(artifacts[0].oldText == "old\n")
        #expect(artifacts[0].newText == "new\n")
    }

    @Test
    func summaryMapperUsesPostContentForAddedFilesAndExplicitFallbacks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let added = TurnFileChangeSummary.Entry(
            path: "new.txt",
            additions: 1,
            deletions: 0,
            status: .added,
            isBinary: false,
            existedBefore: false,
            beforeDataBase64: nil,
            patch: "@@ -0,0 +1 @@\n+hello"
        )
        let uncertain = TurnFileChangeSummary.Entry(
            path: "unknown.txt",
            additions: 0,
            deletions: 0,
            status: .modified,
            isBinary: false,
            existedBefore: true,
            beforeDataBase64: nil,
            patch: nil
        )
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: TurnFileChangeSummary(entries: [added, uncertain]),
            workingDirectory: directory
        )

        #expect(artifacts[0].patch != nil)
        #expect(artifacts[0].status == .added)
        #expect(artifacts[1].explanation != nil)
    }

    @Test
    func mapperFallsBackForBinaryAndOversizedEvidence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = String(repeating: "x", count: OperationFileChangeRecorder.maximumTextBytes + 1)
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: [
                OperationFileChange(path: "large.txt", oldText: oversized, newText: oversized),
                OperationFileChange(path: "image.bin", oldText: "\0binary", newText: "\0changed")
            ],
            workingDirectory: directory
        )

        #expect(artifacts.count == 2)
        #expect(artifacts[0].oldText == nil)
        #expect(artifacts[0].newText == nil)
        #expect(artifacts[0].explanation?.contains("byte limit") == true)
        #expect(artifacts[1].isBinary)
        #expect(artifacts[1].explanation?.contains("binary") == true)
    }

    @Test
    func historyKeepsOnlyEffectiveTurnsAndRejectsStaleSessions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionFileArtifactHistory(sessionID: "session-1")
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "file.txt",
                additions: 1,
                deletions: 0,
                status: .added,
                isBinary: false,
                existedBefore: false,
                beforeDataBase64: nil,
                patch: nil
            )
        ])

        #expect(await history.append(summary: summary, sessionID: "old", workingDirectory: directory) == nil)
        #expect(await history.append(summary: TurnFileChangeSummary(entries: []), sessionID: "session-1", workingDirectory: directory) == nil)
        let first = await history.append(summary: summary, sessionID: "session-1", workingDirectory: directory)
        let second = await history.append(summary: summary, sessionID: "session-1", workingDirectory: directory)
        #expect(first?.number == 1)
        #expect(second?.number == 2)
        #expect((await history.snapshot()).count == 2)

        await history.reset(for: "session-2")
        #expect((await history.snapshot()).isEmpty)
        #expect(await history.append(summary: summary, sessionID: "session-1", workingDirectory: directory) == nil)
    }

    @Test
    func liveHistoryDeduplicatesEventsNotPathsAndReconcilesOnlyNetFinalTurns() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionFileArtifactHistory(sessionID: "session")
        let id = try #require(await history.beginTurn(sessionID: "session"))
        let first = OperationFileChange(path: "file.txt", oldText: nil, newText: "one\n")
        let second = OperationFileChange(path: "file.txt", oldText: "one\n", newText: "two\n")
        let live = await history.recordLive([first], agentID: nil, callID: "call", turnID: id, workingDirectory: directory)
        #expect(live?.number == 1)
        #expect(await history.recordLive([first], agentID: nil, callID: "call", turnID: id, workingDirectory: directory) == nil)
        let delegated = await history.recordLive([second], agentID: "worker", callID: "call", turnID: id, workingDirectory: directory)
        #expect(delegated?.number == 1)
        #expect(delegated?.artifacts.first?.newText == "two\n")
        let third = OperationFileChange(path: "file.txt", oldText: "two\n", newText: "three\n")
        #expect(await history.recordLive([third], agentID: "worker", callID: "next", turnID: id, workingDirectory: directory) != nil)
        #expect(await history.snapshot().isEmpty)
        let latest = await history.sealTurn(id)
        #expect(latest.count == 1)
        #expect(latest.first?.newText == "three\n")
        #expect(await history.recordLive([first], agentID: nil, callID: "late", turnID: id, workingDirectory: directory) == nil)
        let summary = TurnFileChangeSummary(entries: [addedEntry("file.txt")])
        #expect(await history.finishTurn(
            id, summary: summary, matchingLivePaths: [directory.appendingPathComponent("file.txt").path],
            workingDirectory: directory
        ) == nil)
        let snapshot = await history.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.number == 1)
        #expect(snapshot.first?.artifacts == FileChangeArtifactMapper.artifacts(from: summary, workingDirectory: directory))
        #expect(await history.finishTurn(id, summary: summary, matchingLivePaths: [], workingDirectory: directory) == nil)

        // Provider call identifiers may be reused in a different prompt.
        let nextID = try #require(await history.beginTurn(sessionID: "session"))
        #expect(await history.recordLive([first], agentID: nil, callID: "call", turnID: nextID, workingDirectory: directory)?.number == 2)
    }

    @Test
    func revertedLiveTurnsLeaveStableNumberGapsAndResetFencesOldTokens() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionFileArtifactHistory(sessionID: "session")
        let id = try #require(await history.beginTurn(sessionID: "session"))
        let change = OperationFileChange(path: "file.txt", oldText: nil, newText: "one")
        #expect(await history.recordLive([change], agentID: nil, callID: "call", turnID: id, workingDirectory: directory)?.number == 1)
        _ = await history.sealTurn(id)
        #expect(await history.finishTurn(id, summary: nil, matchingLivePaths: [], workingDirectory: directory) == nil)
        #expect(await history.snapshot().isEmpty)
        let summary = TurnFileChangeSummary(entries: [addedEntry("file.txt")])
        #expect(await history.append(summary: summary, sessionID: "session", workingDirectory: directory)?.number == 2)
        let staleID = try #require(await history.beginTurn(sessionID: "session"))
        await history.reset(for: "session")
        #expect(await history.recordLive([change], agentID: nil, callID: "call", turnID: staleID, workingDirectory: directory) == nil)
        #expect(await history.finishTurn(staleID, summary: summary, matchingLivePaths: [], workingDirectory: directory) == nil)
        #expect(await history.append(summary: summary, sessionID: "session", workingDirectory: directory)?.number == 1)
    }

    private func addedEntry(_ path: String) -> TurnFileChangeSummary.Entry {
        .init(path: path, additions: 1, deletions: 0, status: .added, isBinary: false,
              existedBefore: false, beforeDataBase64: nil, patch: "@@ -0,0 +1 @@\n+three")
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("file-change-artifact-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension FileChangeArtifactTests {
    @Test
    func compactOperationEvidenceKeepsCountsAndPatchWithoutReadingWorktree() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "unrelated later state\n".write(to: directory.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        let patch = "@@ -100,3 +100,3 @@\n context\n-old entry\n+new entry\n context\n"
        let artifacts = FileChangeArtifactMapper.artifacts(from: [
            .init(path: "CHANGELOG.md", oldText: nil, newText: nil,
                  compactDiff: .init(patch: patch, additions: 1, deletions: 1))
        ], workingDirectory: directory)
        let artifact = try #require(artifacts.first)
        #expect(artifact.status == .modified)
        #expect(artifact.hasLineCounts)
        #expect(artifact.additions == 1 && artifact.deletions == 1)
        #expect(artifact.oldText == nil && artifact.newText == nil)
        #expect(artifact.patch == patch)
        #expect(artifact.explanation == nil)
        let rendered = TerminalChat.renderFileArtifacts([.init(number: 1, artifacts: artifacts)])
        #expect(rendered.contains("**modified `CHANGELOG.md`**  +1 -1"))
        #expect(rendered.contains("101 │ -old entry"))
        #expect(rendered.contains("101 │ +new entry"))
        #expect(!rendered.contains("unrelated later state"))
    }

    @Test
    func unavailableCountsAreNotRenderedAsZeroButKnownZerosRemainVisible() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifacts = FileChangeArtifactMapper.artifacts(from: [
            .init(path: "large.txt", oldText: nil, newText: nil,
                  explanation: "Diff unavailable: compact diff exceeds the byte limit."),
            .init(path: "empty.txt", oldText: nil, newText: ""),
            .init(path: "unchanged.txt", oldText: nil, newText: nil,
                  compactDiff: .init(patch: "", additions: 0, deletions: 0))
        ], workingDirectory: directory)
        #expect(!artifacts[0].hasLineCounts)
        #expect(artifacts[1].hasLineCounts && artifacts[2].hasLineCounts)
        let rendered = TerminalChat.renderFileArtifacts([.init(number: 1, artifacts: artifacts)])
        #expect(rendered.contains("**unknown `large.txt`**\nExplanation:"))
        #expect(!rendered.contains("**unknown `large.txt`**  +0 -0"))
        #expect(rendered.contains("**added `empty.txt`**  +0 -0"))
        #expect(rendered.contains("**modified `unchanged.txt`**  +0 -0"))
    }

    @Test
    func mapperAppliesOperationBudgetToCompactPatchesAndDropsCountsOnFallback() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let patch = String(repeating: "+", count: OperationFileChangeRecorder.maximumTextBytes)
        var changes = (0..<5).map {
            OperationFileChange(path: "file\($0)", oldText: nil, newText: nil,
                compactDiff: .init(patch: patch, additions: 10, deletions: 10))
        }
        changes.append(.init(path: "oversized", oldText: nil, newText: nil,
            compactDiff: .init(patch: patch + "+", additions: 1, deletions: 1)))
        let artifacts = FileChangeArtifactMapper.artifacts(from: changes, workingDirectory: directory)
        #expect(artifacts.prefix(4).allSatisfy { $0.patch == patch && $0.hasLineCounts })
        #expect(artifacts.suffix(2).allSatisfy { $0.patch == nil && !$0.hasLineCounts && $0.explanation != nil })
    }

    @Test
    func compactEvidenceSurvivesLiveHistoryPathNormalizationWithoutBecomingPostimage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionFileArtifactHistory(sessionID: "session")
        let id = try #require(await history.beginTurn(sessionID: "session"))
        let diff = OperationFileChange.CompactDiff(patch: "@@ -1,1 +1,1 @@\n-old\n+new\n", additions: 1, deletions: 1)
        let change = OperationFileChange(path: "CHANGELOG.md", oldText: nil, newText: nil, compactDiff: diff)
        let live = try #require(await history.recordLive([change], agentID: nil, callID: "c", turnID: id, workingDirectory: directory))
        #expect(live.artifacts.first?.patch == diff.patch)
        let latest = try #require(await history.sealTurn(id).first)
        #expect(latest.path == directory.appendingPathComponent("CHANGELOG.md").path)
        #expect(latest.compactDiff == diff)
        #expect(latest.oldText == nil && latest.newText == nil)
    }
}
