//
//  TurnFileChangeNetPeekTests.swift
//  ZenCODE
//
//  The read-only view of a turn in progress: `peekNetSummary()` compares
//  every baseline with the worktree now, without moving the live checkpoint
//  or finalizing the summary, and the pending turn number reserves nothing.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite(.serialized)
struct TurnFileChangeNetPeekTests {
    @Test
    func peekIsTheNetChangeAgainstTheBaselineAfterRepeatedEdits() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        try Data("one\n".utf8).write(to: url("edited.txt"))
        try Data("keep\n".utf8).write(to: url("reverted.txt"))
        try Data("gone\n".utf8).write(to: url("deleted.txt"))
        let tracker = TurnFileChangeTracker(baseDirectoryURL: directory)
        for name in ["edited.txt", "reverted.txt", "deleted.txt", "added.txt"] {
            await tracker.captureBaselineIfNeeded(
                for: ToolRequest(name: "local.writeFile", arguments: ["path": .string(name)])
            )
        }
        #expect(await tracker.peekNetSummary() == nil)

        try Data("two\n".utf8).write(to: url("edited.txt"))
        try Data("changed\n".utf8).write(to: url("reverted.txt"))
        // A checkpoint between the edits moves the live state, not the baseline.
        #expect(await tracker.collectLiveSummary(matching: [])?.entries.count == 2)
        try Data("three\n".utf8).write(to: url("edited.txt"))
        try Data("keep\n".utf8).write(to: url("reverted.txt"))
        try Data("new\n".utf8).write(to: url("added.txt"))
        try FileManager.default.removeItem(at: url("deleted.txt"))

        let peek = try #require(await tracker.peekNetSummary())
        // The file back to its initial state is not listed.
        #expect(peek.entries.map(\.path) == ["added.txt", "deleted.txt", "edited.txt"])
        #expect(peek.entries.map(\.status) == [.added, .deleted, .modified])
        let edited = try #require(peek.entries.last)
        #expect(edited.beforeDataBase64 == Data("one\n".utf8).base64EncodedString())
        #expect(edited.additions == 1 && edited.deletions == 1)
        #expect(edited.patch?.contains("-one\n+three\n") == true)
        #expect(edited.patch?.contains("two") == false)
        #expect(peek.entries.first?.patch?.contains("+new\n") == true)
        #expect(peek.entries[1].patch?.contains("-gone\n") == true)
        #expect(await tracker.peekNetSummary() == peek)

        let final = try #require(await tracker.makeSummary())
        #expect(final == peek)
        // Once final, the peek is the final summary, whatever the worktree holds.
        try Data("after the turn\n".utf8).write(to: url("edited.txt"))
        #expect(await tracker.peekNetSummary() == final)
    }

    @Test
    func peeksLeaveTheCheckpointsAndTheFinalSummaryUnchanged() async throws {
        let plain = try await Self.runScriptedTurn(peeking: false)
        let peeked = try await Self.runScriptedTurn(peeking: true)
        #expect(plain.checkpoints.count == 3)
        #expect(plain.checkpoints.allSatisfy { $0 != nil })
        #expect(peeked.checkpoints == plain.checkpoints)
        #expect(plain.final != nil)
        #expect(peeked.final == plain.final)
        #expect(plain.matchingNames == ["direct.txt"])
        #expect(peeked.matchingNames == plain.matchingNames)

        // Cumulative from the start of the turn, for the paths already
        // captured or reconciled: a shell edit waits for the next checkpoint.
        let paths = peeked.peeks.map { $0?.entries.map(\.path) ?? [] }
        #expect(paths == [
            ["direct.txt"],
            ["direct.txt", "tracked.txt"],
            ["direct.txt", "shell.txt"],
            ["direct.txt", "shell.txt"],
        ])
        let tracked = try #require(peeked.peeks[1]?.entries.last)
        #expect(tracked.beforeDataBase64 == Data("committed\n".utf8).base64EncodedString())
        #expect(tracked.patch?.contains("-committed\n+second\n") == true)
        #expect(peeked.peeks[3]?.entries.last?.patch?.contains("+shell 2\n") == true)
        // After publication, the published summary.
        #expect(peeked.peekAfterFinal == peeked.final)
    }

    @Test
    func pendingTurnNumberReservesNothingAndMatchesTheAssignedNumber() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionFileArtifactHistory(sessionID: "session")
        #expect(await history.pendingTurnNumber(UUID()) == nil)
        let first = try #require(await history.beginTurn(sessionID: "session"))
        let second = try #require(await history.beginTurn(sessionID: "session"))
        // Neither turn reserved yet: both read the next free number, repeatedly.
        for _ in 0..<2 {
            #expect(await history.pendingTurnNumber(first) == 1)
            #expect(await history.pendingTurnNumber(second) == 1)
        }
        let change = OperationFileChange(path: "file.txt", oldText: nil, newText: "one\n")
        #expect(await history.recordLive(
            [change], agentID: nil, callID: "call", turnID: first, workingDirectory: directory
        )?.number == 1)
        #expect(await history.pendingTurnNumber(first) == 1)
        #expect(await history.pendingTurnNumber(second) == 2)
        _ = await history.sealTurn(first)
        #expect(await history.pendingTurnNumber(first) == 1)

        let summary = TurnFileChangeSummary(entries: [
            .init(path: "file.txt", additions: 1, deletions: 0, status: .added, isBinary: false,
                  existedBefore: false, beforeDataBase64: nil, patch: "@@ -0,0 +1 @@\n+one")
        ])
        #expect(await history.finishTurn(
            first, summary: summary, matchingLivePaths: [], workingDirectory: directory
        )?.number == 1)
        #expect(await history.pendingTurnNumber(first) == nil)
        #expect(await history.pendingTurnNumber(second) == 2)
        #expect(await history.finishTurn(
            second, summary: summary, matchingLivePaths: [], workingDirectory: directory
        )?.number == 2)
        #expect(await history.snapshot().map(\.number) == [1, 2])
        #expect(await history.append(summary: summary, sessionID: "session", workingDirectory: directory)?.number == 3)

        // A reset fences the pending tokens.
        let stale = try #require(await history.beginTurn(sessionID: "session"))
        #expect(await history.pendingTurnNumber(stale) == 4)
        await history.reset(for: "session")
        #expect(await history.pendingTurnNumber(stale) == nil)
    }

    // MARK: - Support

    private struct ScriptedTurn {
        var peeks: [TurnFileChangeSummary?] = []
        var checkpoints: [TurnFileChangeSummary?] = []
        var final: TurnFileChangeSummary?
        var peekAfterFinal: TurnFileChangeSummary?
        var matchingNames: Set<String> = []
    }

    /// One turn in a new repository: a direct write and shell-like edits,
    /// with a live checkpoint after each step but the last, and the peeks
    /// before each checkpoint and before the final summary when `peeking`.
    private static func runScriptedTurn(peeking: Bool) async throws -> ScriptedTurn {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        func url(_ name: String) -> URL { repository.appendingPathComponent(name) }
        try Data("committed\n".utf8).write(to: url("tracked.txt"))
        try initializeGitRepository(at: repository)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: repository)
        await coordinator.prepareForTurn()
        await coordinator.captureBaselineIfNeeded(forAgentToolCall: DirectAgentToolCall(
            id: "direct", name: "local.writeFile", argumentsObject: ["path": "direct.txt"], argumentsJSON: "{}"
        ))
        let direct = OperationFileChange(path: "direct.txt", oldText: nil, newText: "direct\n")
        let steps: [(edit: () throws -> Void, matching: [OperationFileChange])] = [
            ({
                try Data("direct\n".utf8).write(to: url("direct.txt"))
                try Data("first\n".utf8).write(to: url("tracked.txt"))
            }, [direct]),
            ({
                try Data("second\n".utf8).write(to: url("tracked.txt"))
                try Data("shell\n".utf8).write(to: url("shell.txt"))
            }, []),
            ({ try Data("committed\n".utf8).write(to: url("tracked.txt")) }, []),
        ]
        var turn = ScriptedTurn()
        for step in steps {
            try step.edit()
            if peeking { turn.peeks.append(await coordinator.peekNetSummary()) }
            turn.checkpoints.append(await coordinator.collectLiveSummary(matching: step.matching))
        }
        try Data("shell 2\n".utf8).write(to: url("shell.txt"))
        if peeking { turn.peeks.append(await coordinator.peekNetSummary()) }
        turn.final = await coordinator.publishSummaryIfNeeded(matching: [direct])
        turn.matchingNames = Set(await coordinator.matchingLiveArtifactPaths().map {
            URL(fileURLWithPath: $0).lastPathComponent
        })
        if peeking { turn.peekAfterFinal = await coordinator.peekNetSummary() }
        return turn
    }

    private static func initializeGitRepository(at directory: URL) throws {
        let commit = ["-c", "user.name=ZenCODE Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
        for arguments in [["init"], ["add", "."], commit + ["commit", "-m", "initial"]] {
            let process = Process()
            process.executableURL = GitExecutableResolver.executableURL()
            process.arguments = ["-C", directory.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("turn-file-change-net-peek-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
