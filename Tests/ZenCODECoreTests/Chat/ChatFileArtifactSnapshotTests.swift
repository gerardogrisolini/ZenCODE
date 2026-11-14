//
//  ChatFileArtifactSnapshotTests.swift
//  ZenCODE
//
//  `ChatSessionController.fileArtifactSnapshot()`: the finished turns of the
//  session, then the turn in progress with its net changes so far, read while
//  the turn runs and listed once when the turn finishes. Every test runs in a
//  support directory and a working directory named by UUIDs.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Chat file artifact snapshot", .serialized)
struct ChatFileArtifactSnapshotTests {
    /// An added file with its patch, as a finished turn records it.
    private static let addedSummary = TurnFileChangeSummary(entries: [
        .init(
            path: "Added.swift",
            additions: 1,
            deletions: 0,
            status: .added,
            isBinary: false,
            existedBefore: false,
            beforeDataBase64: nil,
            patch: "@@ -0,0 +1,1 @@\n+let value = 1\n"
        ),
    ])

    private static func writeCall(path: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: "edit", name: "local.writeFile", argumentsObject: ["path": path], argumentsJSON: "{}")
    }

    /// Writes `Value.swift` in the controller's working directory and starts
    /// a recording turn whose coordinator holds its baseline.
    @ChatSessionActor
    private static func beginTurnEditingValue(
        in controller: ChatSessionController
    ) async throws -> (file: URL, coordinator: TurnFileChangeCoordinator, context: ChatFileArtifactTurn) {
        let file = controller.workingDirectory.appendingPathComponent("Value.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: controller.workingDirectory)
        await coordinator.captureBaselineIfNeeded(forAgentToolCall: writeCall(path: "Value.swift"))
        let context = try #require(await controller.beginFileArtifactTurn(coordinator: coordinator))
        return (file, coordinator, context)
    }

    @Test
    func withoutATurnInProgressOnlyTheFinishedTurnsAreListed() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            #expect(await controller.fileArtifactSnapshot()
                == ChatFileArtifactSnapshot(turns: [], activeTurnNumber: nil))

            await controller.fileArtifactHistory.append(
                summary: Self.addedSummary,
                sessionID: controller.sessionID,
                workingDirectory: controller.workingDirectory
            )
            let finished = await controller.fileArtifactHistory.snapshot()
            #expect(finished.count == 1)
            #expect(await controller.fileArtifactSnapshot()
                == ChatFileArtifactSnapshot(turns: finished, activeTurnNumber: nil))

            // A recording turn without a coordinator has nothing to read.
            _ = try #require(await controller.beginFileArtifactTurn())
            #expect(await controller.fileArtifactSnapshot()
                == ChatFileArtifactSnapshot(turns: finished, activeTurnNumber: nil))
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func theTurnInProgressFollowsTheFinishedTurnsWithItsNetChanges() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            await controller.fileArtifactHistory.append(
                summary: Self.addedSummary,
                sessionID: controller.sessionID,
                workingDirectory: controller.workingDirectory
            )
            let finished = await controller.fileArtifactHistory.snapshot()
            let (file, _, context) = try await Self.beginTurnEditingValue(in: controller)
            // Nothing changed yet: the turn in progress is not listed.
            #expect(await controller.fileArtifactSnapshot()
                == ChatFileArtifactSnapshot(turns: finished, activeTurnNumber: nil))

            try Data("let value = 2\n".utf8).write(to: file)
            try Data("let value = 3\n".utf8).write(to: file)
            let snapshot = await controller.fileArtifactSnapshot()
            #expect(snapshot.activeTurnNumber == 2)
            #expect(snapshot.turns.map(\.number) == [1, 2])
            #expect(Array(snapshot.turns.dropLast()) == finished)
            let artifact = try #require(snapshot.turns.last?.artifacts.first)
            #expect(snapshot.turns.last?.artifacts.count == 1)
            #expect(artifact.displayPath == "Value.swift")
            #expect(artifact.status == .modified)
            #expect(artifact.patch?.contains("-let value = 1\n+let value = 3\n") == true)

            // Reading publishes nothing and records nothing.
            #expect(await controller.fileArtifactSnapshot() == snapshot)
            #expect(await harness.presenter.events.isEmpty)
            #expect(await controller.fileArtifactHistory.snapshot() == finished)
            #expect(await context.history.pendingTurnNumber(context.id) == 2)

            // Back to its initial state, the turn is no longer listed.
            try Data("let value = 1\n".utf8).write(to: file)
            #expect(await controller.fileArtifactSnapshot()
                == ChatFileArtifactSnapshot(turns: finished, activeTurnNumber: nil))
        }
    }

    @Test
    func aFinishedTurnIsListedOnceAsFinished() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let (file, coordinator, context) = try await Self.beginTurnEditingValue(in: controller)
            try Data("let value = 2\n".utf8).write(to: file)
            let inProgress = await controller.fileArtifactSnapshot()
            #expect(inProgress.activeTurnNumber == 1)
            #expect(inProgress.turns.map(\.number) == [1])

            _ = try #require(await controller.collectFileChangeSummaryIfNeeded(
                from: coordinator, sessionID: context.sessionID,
                history: context.history, turnID: context.id
            ))
            #expect(controller.activeFileArtifactTurn == nil)
            let finished = await controller.fileArtifactHistory.snapshot()
            let snapshot = await controller.fileArtifactSnapshot()
            #expect(snapshot == ChatFileArtifactSnapshot(turns: finished, activeTurnNumber: nil))
            #expect(snapshot.turns.map(\.number) == [1])
            #expect(snapshot.turns.first?.artifacts == inProgress.turns.first?.artifacts)
        }
    }

    @Test
    func aTurnFinishedWhileStillRecordingIsNotListedTwice() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let (file, coordinator, context) = try await Self.beginTurnEditingValue(in: controller)
            try Data("let value = 2\n".utf8).write(to: file)
            #expect(await controller.fileArtifactSnapshot().activeTurnNumber == 1)

            // The history finishes the turn while it is still the recording one.
            let latest = await context.history.sealTurn(context.id)
            let summary = await coordinator.publishSummaryIfNeeded(matching: latest)
            _ = await context.history.finishTurn(
                context.id, summary: summary, matchingLivePaths: [],
                workingDirectory: controller.workingDirectory
            )
            #expect(controller.activeFileArtifactTurn?.id == context.id)
            let finished = await controller.fileArtifactHistory.snapshot()
            #expect(finished.map(\.number) == [1])
            #expect(await controller.fileArtifactSnapshot()
                == ChatFileArtifactSnapshot(turns: finished, activeTurnNumber: nil))
        }
    }
}
