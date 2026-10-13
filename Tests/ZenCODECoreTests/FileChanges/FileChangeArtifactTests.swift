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
