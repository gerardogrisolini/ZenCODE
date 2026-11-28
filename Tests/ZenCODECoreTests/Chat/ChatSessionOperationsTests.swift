//
//  ChatSessionOperationsTests.swift
//  ZenCODE
//
//  The session operations of the shared controller (`/sessions` and its
//  subcommands) against a scripted runtime, host, and presenter. Every test
//  runs in a support directory and a working directory named by UUIDs, so the
//  saved sessions, their index, and the engine checkpoints never touch the
//  real application state.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Chat session operations")
struct ChatSessionOperationsTests {
    typealias Fixtures = ChatTestFixtures

    // MARK: - Helpers

    static func plan(id: String = "plan-save") -> TerminalSessionPlan {
        TerminalSessionPlan(
            id: id,
            originalGoal: "Fix the parser",
            consolidatedText: "1. Read the parser.",
            createdAt: Date(timeIntervalSince1970: 1_000),
            isApproved: true,
            points: [TerminalSessionPlanPoint(id: "\(id)-1", text: "Read the parser")]
        )
    }

    static let contextWindow = DirectAgentContextWindowStatus(
        usedTokens: 1_200,
        maxTokens: 8_000,
        modelID: "alpha-model",
        isApproximate: true
    )

    /// The saved session `name` as the project's store holds it.
    @ChatSessionActor
    static func stored(
        _ name: String,
        in harness: ChatManagementHarness
    ) throws -> TerminalSavedSession {
        try #require(
            try TerminalSessionStore.savedSessions(for: harness.workspace)
                .first { $0.name == name }
        )
    }

    // MARK: - New session

    @Test
    func aNewSessionTakesTheIDTheChannelChoosesAndKeepsTheSelection() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["files"]
            controller.selection.modelIDOverride = Fixtures.beta.id
            try await harness.startSession(conversation: Fixtures.longConversation)
            let previousSessionID = controller.sessionID
            controller.cacheKey = "previous-cache"
            controller.activePlan = Self.plan()
            controller.pendingPlanApprovalPlanID = "plan-save"
            _ = await controller.saveSession(named: "before", contextWindow: nil)
            controller.savedSessionState.systemPromptOverride = "A restored prompt."
            controller.savedSessionState.dynamicContextOverride = "A restored context."
            await harness.clearRecords()

            let outcome = try await controller.startNewSession(newSessionID: "channel-session-42")

            #expect(outcome == ChatSessionOperationOutcome(notices: [.sessionStarted]))
            #expect(controller.sessionID == "channel-session-42")
            // The conversation, the artifacts, the link, and the plan are gone.
            #expect(controller.cacheKey == nil)
            #expect(controller.history.isEmpty)
            #expect(controller.transcript.isEmpty)
            #expect(controller.savedSessionState == ChatSavedSessionState())
            #expect(controller.activePlan == nil)
            #expect(controller.pendingPlanApprovalPlanID == nil)
            // The selection stays.
            #expect(controller.selection.toolKeys == ["files"])
            #expect(controller.selection.modelIDOverride == Fixtures.beta.id)
            #expect(await harness.presenter.states.last?.savedSession == ChatSavedSessionState())

            let calls = await harness.runtime.calls
            #expect(calls.map(\.name) == ["resetSession", "createSession", "updatePromptSkillSelection"])
            #expect(calls[0] == .resetSession(previousSessionID))
            let created = try #require(calls[1].digest)
            #expect(created.sessionID == "channel-session-42")
            #expect(created.modelID == Fixtures.beta.id)
            #expect(created.historyContents.isEmpty)
            #expect(calls[2] == .updatePromptSkillSelection(skillNames: [], sessionID: "channel-session-42"))
            #expect(await harness.runtime.sessionIDs == ["channel-session-42"])
        }
    }

    @Test
    func aNewSessionDropsTheArmedWorkflow() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.longConversation)
            var workflow = WorkflowCommandRuntimeState(goal: "Ship the release", graphID: "workflow_new_session")
            workflow.armForRecoverableFailure(reason: "cancelled")
            controller.activeWorkflow = workflow
            #expect(controller.activeWorkflow == workflow)

            _ = try await controller.startNewSession(newSessionID: "channel-session-43")

            #expect(controller.activeWorkflow == nil)
        }
    }

    // MARK: - DS4 engine checkpoint

    @Test
    func aSaveReportsWhatBecameOfTheEngineCheckpointAndDropsAStaleOne() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let runtime = harness.runtime
            try await harness.startSession(conversation: Fixtures.conversation)
            let checkpoint = TerminalSessionStore.engineCheckpointURL(
                name: "ds4",
                workingDirectory: harness.workspace
            )

            // The engine wrote its KV cache next to the saved session.
            await runtime.setEngineSaveOutcome(.saved)
            let saved = await controller.saveSession(named: "ds4", contextWindow: nil)
            #expect(saved == ChatSessionOperationOutcome(notices: [.engineCheckpoint(.saved)]))
            #expect(FileManager.default.fileExists(atPath: checkpoint.path))
            // The saved notice comes first, as the session is already on disk.
            #expect(await harness.presenter.notices == [.sessionSaved(name: "ds4", messageCount: 2)])

            // Whenever no new checkpoint is written, the old one goes.
            let outcomes: [(AgentEngineCheckpointSaveOutcome, [ChatSessionNotice])] = [
                (.skippedNoLiveState, [.engineCheckpoint(.skippedNoLiveState)]),
                (.skippedImages, [.engineCheckpoint(.skippedImages)]),
                (.notApplicable, []),
            ]
            for (outcome, notices) in outcomes {
                await runtime.setEngineSaveOutcome(.saved)
                _ = await controller.saveSession(named: "ds4", contextWindow: nil)
                #expect(FileManager.default.fileExists(atPath: checkpoint.path))

                await runtime.setEngineSaveOutcome(outcome)
                let result = await controller.saveSession(named: "ds4", contextWindow: nil)

                #expect(result == ChatSessionOperationOutcome(notices: notices), "\(outcome)")
                #expect(!FileManager.default.fileExists(atPath: checkpoint.path), "\(outcome)")
            }

            // A failure is reported, the saved session stays valid, and the old
            // checkpoint cannot outlive its session state.
            await runtime.setEngineSaveOutcome(.saved)
            _ = await controller.saveSession(named: "ds4", contextWindow: nil)
            await runtime.setEngineSaveError(ScriptedChatRuntime.ScriptedFailure(message: "Out of memory."))
            let failed = await controller.saveSession(named: "ds4", contextWindow: nil)
            #expect(failed == ChatSessionOperationOutcome(notices: [
                .engineCheckpoint(.saveFailed(description: "Out of memory.")),
            ]))
            #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
            #expect(try Self.stored("ds4", in: harness).name == "ds4")
        }
    }

    @Test
    func aLoadRestoresTheEngineCheckpointAndReportsItsOutcome() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let runtime = harness.runtime
            try await harness.startSession(conversation: Fixtures.conversation)
            await runtime.setEngineSaveOutcome(.saved)
            _ = await controller.saveSession(named: "ds4", contextWindow: nil)
            let saved = try Self.stored("ds4", in: harness)
            let fileName = TerminalSessionStore.engineCheckpointURL(
                name: "ds4",
                workingDirectory: harness.workspace
            ).lastPathComponent

            let cases: [(AgentEngineCheckpointRestoreOutcome, [ChatSessionNotice])] = [
                (.restored, [.engineCheckpoint(.restored)]),
                (.incompatible, [.engineCheckpoint(.incompatible)]),
                (.failed("The cache is corrupt."), [.engineCheckpoint(.restoreFailed(reason: "The cache is corrupt."))]),
                (.notApplicable, []),
            ]
            for (restoreOutcome, notices) in cases {
                await runtime.setEngineRestore(
                    outcome: restoreOutcome,
                    events: [.status("Evaluating the prompt"), .content("ignored")]
                )
                await harness.clearRecords()

                let outcome = try await controller.loadSavedSession(saved)

                #expect(outcome.notices == notices, "\(restoreOutcome)")
                // The checkpoint is read last, after the session is restored.
                let calls = await runtime.calls
                #expect(calls.last == .restoreEngineCheckpoint(sessionID: saved.sessionID, fileName: fileName))
                #expect(calls.map(\.name).contains("restoreSession"))
                // The backend's progress is presented as it happens, after the
                // loaded notice; only status lines count.
                #expect(await harness.presenter.notices == [
                    .sessionLoaded(name: "ds4", messageCount: 2),
                    .engineCheckpoint(.status("Evaluating the prompt")),
                ], "\(restoreOutcome)")
            }
        }
    }
}
