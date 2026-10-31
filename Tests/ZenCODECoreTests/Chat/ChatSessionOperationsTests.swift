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

@Suite("Chat session operations", .serialized)
struct ChatSessionOperationsTests {
    private typealias Fixtures = ChatTestFixtures

    // MARK: - Helpers

    private static func plan(id: String = "plan-save") -> TerminalSessionPlan {
        TerminalSessionPlan(
            id: id,
            originalGoal: "Fix the parser",
            consolidatedText: "1. Read the parser.",
            createdAt: Date(timeIntervalSince1970: 1_000),
            isApproved: true,
            points: [TerminalSessionPlanPoint(id: "\(id)-1", text: "Read the parser")]
        )
    }

    private static let contextWindow = DirectAgentContextWindowStatus(
        usedTokens: 1_200,
        maxTokens: 8_000,
        modelID: "alpha-model",
        isApproximate: true
    )

    /// The saved session `name` as the project's store holds it.
    @ChatSessionActor
    private static func stored(
        _ name: String,
        in harness: ChatManagementHarness
    ) throws -> TerminalSavedSession {
        try #require(
            try TerminalSessionStore.savedSessions(for: harness.workspace)
                .first { $0.name == name }
        )
    }

    private static func contents(_ messages: [AgentRuntimeMessage]) -> [String] {
        messages.map(\.content)
    }

    // MARK: - Save

    @Test
    func savingWritesTheSessionWithItsCheckpointTreeAndTaskGraphAndIndexesIt() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["files"]
            try await harness.startSession(conversation: Fixtures.conversation)
            let sessionID = controller.sessionID
            controller.activePlan = Self.plan()
            try await harness.runtime.seedTaskGraph(Fixtures.taskGraph(id: "graph-save"), sessionID: sessionID)
            await harness.clearRecords()

            let outcome = await controller.saveSession(
                named: "  parser fix  ",
                contextWindow: Self.contextWindow
            )

            // The saved notice is presented as soon as the session is on disk;
            // a model without an engine checkpoint adds no closing notice.
            #expect(outcome == ChatSessionOperationOutcome())
            #expect(await harness.presenter.notices == [.sessionSaved(name: "parser fix", messageCount: 2)])

            let saved = try Self.stored("parser fix", in: harness)
            #expect(saved.sessionID == sessionID)
            #expect(saved.modelID == Fixtures.alpha.id)
            #expect(saved.agentID == Fixtures.developer.id)
            #expect(saved.selectedTools == ["files"])
            #expect(Self.contents(saved.history) == Self.contents(Fixtures.conversation))
            #expect(saved.transcriptHistory.map(Self.contents) == Self.contents(Fixtures.conversation))
            #expect(saved.contextWindow == TerminalSavedSessionContextWindow(Self.contextWindow))
            #expect(saved.activePlan?.id == "plan-save")
            #expect(saved.taskGraph?.id == "graph-save")
            #expect(saved.taskGraph?.tasks.map(\.id) == ["graph-save-1"])
            // The checkpoint tree is the transcript, one entry per message.
            #expect(saved.checkpointTree.sessionID == sessionID)
            #expect(Self.contents(saved.checkpointTree.activeMessages) == Self.contents(Fixtures.conversation))
            #expect(saved.checkpointTree.entries.count == 2)

            // The controller is now linked to the saved session.
            #expect(controller.savedSessionState.savedSessionName == "parser fix")
            #expect(controller.savedSessionState.checkpointTree == saved.checkpointTree)
            #expect(await harness.presenter.states.last?.savedSession.savedSessionName == "parser fix")

            // The project's saved-session index follows the save.
            let index = SavedSessionsStore().sessions()
            #expect(index.map(\.sessionName) == ["parser fix"])
            #expect(index.first?.sessionID == sessionID)

            // A save is the only moment the engine is asked for its checkpoint.
            #expect(await harness.runtime.calls == [
                .saveEngineCheckpoint(
                    sessionID: sessionID,
                    fileName: TerminalSessionStore.engineCheckpointURL(
                        name: "parser fix",
                        workingDirectory: harness.workspace
                    ).lastPathComponent
                ),
            ])
        }
    }

    @Test
    func savingAgainKeepsTheCreationTimeExtendsTheTreeAndReplacesTheIndexEntry() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            _ = await controller.saveSession(named: "growing", contextWindow: nil)
            let first = try Self.stored("growing", in: harness)

            // The conversation grows by one exchange.
            controller.history = Fixtures.longConversation
            controller.transcript = Fixtures.longConversation
            await harness.runtime.setSessionHistory(
                Fixtures.longConversation,
                sessionID: controller.sessionID
            )
            _ = await controller.saveSession(named: "growing", contextWindow: nil)

            let second = try Self.stored("growing", in: harness)
            #expect(second.createdAt == first.createdAt)
            #expect(second.savedAt >= first.savedAt)
            // The earlier entries keep their IDs: the tree grows, it is not rebuilt.
            #expect(second.checkpointTree.entries.count == 4)
            #expect(second.checkpointTree.entries.prefix(2).map(\.id) == first.checkpointTree.entries.map(\.id))
            #expect(Self.contents(second.checkpointTree.activeMessages) == Self.contents(Fixtures.longConversation))
            #expect(try TerminalSessionStore.savedSessions(for: harness.workspace).count == 1)
            #expect(SavedSessionsStore().sessions().map(\.sessionName) == ["growing"])
        }
    }

    @Test
    func savingTheActiveSessionUsesItsNameOrDerivesOneFromTheFirstPrompt() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            // Nothing was said yet, so there is no name to derive.
            let nothing = await controller.saveActiveSession(contextWindow: nil)
            #expect(nothing == ChatSessionOperationOutcome(notices: [.nothingToSave]))

            // A prompt gives the name, but the runtime holds no session yet.
            controller.transcript = Fixtures.conversation
            let unavailable = await controller.saveActiveSession(contextWindow: nil)
            #expect(unavailable == ChatSessionOperationOutcome(notices: [.sessionUnavailableToSave]))
            #expect(try TerminalSessionStore.savedSessions(for: harness.workspace).count == 0)

            try await harness.startSession(conversation: Fixtures.conversation)
            _ = await controller.saveActiveSession(contextWindow: nil)
            #expect(controller.savedSessionState.savedSessionName == "Where is the bug?")
            #expect(await harness.presenter.notices == [
                .sessionSaved(name: "Where is the bug?", messageCount: 2),
            ])

            // Once saved, the session keeps its name whatever was said first.
            controller.transcript = [Fixtures.message(.user, "Something else entirely")]
                + Fixtures.conversation
            _ = await controller.saveActiveSession(contextWindow: nil)
            #expect(try TerminalSessionStore.savedSessions(for: harness.workspace).map(\.name)
                == ["Where is the bug?"])
        }
    }

    @Test
    func aBlankNameGetsTheUsageAndASessionTheRuntimeLacksCannotBeSaved() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            let blank = await controller.saveSession(named: "   ", contextWindow: nil)
            let unavailable = await controller.saveSession(named: "no session", contextWindow: nil)

            #expect(blank == ChatSessionOperationOutcome(notices: [.sessionSelectionUsage]))
            #expect(unavailable == ChatSessionOperationOutcome(notices: [.sessionUnavailableToSave]))
            let storedSessions = try TerminalSessionStore.savedSessions(for: harness.workspace)
            #expect(storedSessions.isEmpty)
            #expect(SavedSessionsStore().sessions().isEmpty)
            #expect(controller.savedSessionState.savedSessionName == nil)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    // MARK: - List

    @Test
    func theSavedSessionsOfTheProjectAreListedMostRecentFirst() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            #expect(try controller.savedSessions().count == 0)

            // The names sort the other way round, so the order is the recency.
            _ = await controller.saveSession(named: "a-older", contextWindow: nil)
            _ = await controller.saveSession(named: "b-newer", contextWindow: nil)

            #expect(try controller.savedSessions().map(\.name) == ["b-newer", "a-older"])
        }
    }

    // MARK: - Load

    @Test
    func loadingASavedSessionRestoresTheConversationTheSelectionAndTheTaskGraph() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let skill = try harness.installSkills("release-review")[0]

            // A session with a selection of its own, a plan, and a task graph.
            controller.selection.agent = Fixtures.reviewer
            controller.selection.modelIDOverride = Fixtures.beta.id
            controller.selection.thinkingOverride = .high
            controller.selection.toolKeys = ["files"]
            controller.selection.skillIDs = [skill.id]
            try await harness.startSession(conversation: Fixtures.longConversation)
            let savedSessionID = controller.sessionID
            controller.activePlan = Self.plan()
            try await harness.runtime.seedTaskGraph(Fixtures.taskGraph(id: "graph-full"), sessionID: savedSessionID)
            _ = await controller.saveSession(named: "full session", contextWindow: Self.contextWindow)
            let saved = try Self.stored("full session", in: harness)

            // Another session takes over, with another selection.
            _ = try await controller.startNewSession(newSessionID: "channel-session-2")
            controller.selection = ChatSessionSelection(agent: Fixtures.developer)
            #expect(controller.sessionID == "channel-session-2")
            #expect(controller.history.isEmpty)
            await harness.clearRecords()

            let outcome = try await controller.loadSavedSession(saved)

            // The conversation and the session link come back.
            #expect(controller.sessionID == savedSessionID)
            #expect(Self.contents(controller.history) == Self.contents(saved.history))
            #expect(Self.contents(controller.transcript) == Self.contents(saved.displayHistory))
            #expect(controller.cacheKey == saved.cacheKey)
            #expect(controller.activePlan?.id == "plan-save")
            #expect(controller.pendingPlanApprovalPlanID == nil)
            #expect(controller.activeWorkflow == nil)
            #expect(controller.savedSessionState.savedSessionName == "full session")
            #expect(controller.savedSessionState.checkpointTree == saved.checkpointTree)
            #expect(controller.savedSessionState.systemPromptOverride == saved.systemPrompt)
            #expect(controller.savedSessionState.dynamicContextOverride == saved.dynamicContext)
            // So does the selection the session was saved with.
            #expect(controller.selection.agent == Fixtures.reviewer)
            #expect(controller.selection.modelIDOverride == Fixtures.beta.id)
            #expect(controller.selection.thinkingOverride == .high)
            #expect(controller.selection.toolKeys == ["files"])
            #expect(controller.selection.skillIDs == [skill.id])

            // The runtime steps, in the order the terminal always ran them.
            let calls = await harness.runtime.calls
            #expect(calls.map(\.name) == [
                "resetSession",
                "preloadModel",
                "restoreSession",
                "updatePromptSkillSelection",
                "restoreTaskGraph",
            ])
            #expect(calls[0] == .resetSession("channel-session-2"))
            let preloaded = try #require(calls[1].digest)
            #expect(preloaded.modelID == Fixtures.beta.id)
            let restored = try #require(calls[2].digest)
            #expect(restored.sessionID == savedSessionID)
            #expect(restored.modelID == Fixtures.beta.id)
            #expect(restored.agentID == Fixtures.reviewer.id)
            #expect(restored.thinkingSelection == .high)
            #expect(restored.historyContents == Self.contents(saved.history))
            #expect(calls[3] == .updatePromptSkillSelection(skillIDs: [skill.id], sessionID: savedSessionID))
            #expect(calls[4] == .restoreTaskGraph(graphID: "graph-full", sessionID: savedSessionID))
            #expect(try await harness.runtime.taskGraphSnapshot(sessionID: savedSessionID, graphID: nil)?.id
                == "graph-full")

            // The loaded notice is presented, and the result carries the
            // conversation to show.
            #expect(await harness.presenter.notices == [.sessionLoaded(name: "full session", messageCount: 4)])
            #expect(await harness.presenter.events.contains(.modelLoaded(Fixtures.beta.id)))
            #expect(outcome == ChatSessionOperationOutcome(
                restoredSession: ChatRestoredSession(
                    name: "full session",
                    transcript: saved.displayHistory,
                    contextWindow: saved.contextWindow
                )
            ))
            #expect(await harness.runtime.sessionIDs == [savedSessionID])
        }
    }

    @Test
    func theSavedSessionMenuLoadsTheChosenSessionAndReportsTheListWhenCancelled() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            _ = await controller.saveSession(named: "first", contextWindow: nil)
            _ = await controller.saveSession(named: "second", contextWindow: nil)
            let sessions = try controller.savedSessions()
            await harness.clearRecords()

            // Cancelled: the list is shown, nothing is loaded.
            let cancelled = try await controller.chooseSavedSession()
            #expect(cancelled == ChatSessionOperationOutcome(notices: [
                .savedSessions(sessions.map(ChatSavedSessionSummary.init), activeName: "second"),
            ]))
            #expect(await harness.runtime.calls.isEmpty)

            await harness.host.answerChooseOne("first")
            let loaded = try await controller.chooseSavedSession()

            #expect(loaded.restoredSession?.name == "first")
            #expect(controller.savedSessionState.savedSessionName == "first")
            #expect(await harness.host.interactions.last == .chooseOne(
                title: "Saved sessions",
                items: ChatSessionController.savedSessionChoiceItems(sessions),
                selectedID: "second"
            ))
            #expect(await harness.callNames().contains("restoreSession"))
        }
    }

    // MARK: - Restore from a checkpoint entry

    @Test
    func restoringFromAnEntryRebuildsTheConversationUpToIt() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.longConversation)
            _ = await controller.saveSession(named: "branching", contextWindow: nil)
            let saved = try Self.stored("branching", in: harness)
            let entry = saved.checkpointTree.entries[1]
            await harness.clearRecords()

            // The menu lists every entry, the active leaf selected.
            let choices = try #require(try controller.checkpointEntryChoices())
            #expect(choices.title == "Restore 'branching' from checkpoint entry")
            #expect(choices.items.map(\.id) == saved.checkpointTree.entries.map(\.id))
            #expect(choices.selectedIDs == [saved.checkpointTree.activeLeafID])
            #expect(choices.items.last?.detail == "active")

            await harness.host.answerChooseOne(entry.id)
            let outcome = try await controller.chooseCheckpointEntry()

            #expect(outcome.notices == [.checkpointRestored(entryID: entry.id, messageCount: 2)])
            #expect(Self.contents(try #require(outcome.restoredSession).transcript)
                == Self.contents(Fixtures.conversation))
            #expect(Self.contents(controller.history) == Self.contents(Fixtures.conversation))
            // New messages branch from the entry instead of the old leaf.
            #expect(controller.savedSessionState.checkpointTree?.activeLeafID == entry.id)
            #expect(controller.savedSessionState.savedSessionName == "branching")
            #expect(await harness.host.interactions == [
                .chooseOne(title: choices.title, items: choices.items, selectedID: choices.selectedIDs.first),
            ])
            #expect(await harness.callNames().contains("restoreSession"))
            // The loaded notice counts the messages of the saved session, as the
            // terminal always did, not those of the branch.
            #expect(await harness.presenter.notices == [.sessionLoaded(name: "branching", messageCount: 4)])
        }
    }

    @Test
    func restoringByEntryIDChecksTheEntryAndTheActiveSavedSession() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let controller = harness.controller

            // No saved session is linked to the active one.
            let unlinked = try await controller.restoreFromCheckpoint(entryID: "a1b2c3d4")
            let unlinkedMenu = try await controller.chooseCheckpointEntry()
            #expect(unlinked == ChatSessionOperationOutcome(notices: [.noActiveSavedSession]))
            #expect(unlinkedMenu == ChatSessionOperationOutcome(notices: [.noActiveSavedSession]))

            // A link to a session the project's store does not hold.
            controller.savedSessionState.savedSessionName = "vanished"
            let missing = try await controller.restoreFromCheckpoint(entryID: "a1b2c3d4")
            #expect(missing == ChatSessionOperationOutcome(notices: [.activeSavedSessionNotFound(name: "vanished")]))

            // A saved session, but not that entry.
            controller.savedSessionState.savedSessionName = nil
            try await harness.startSession(conversation: Fixtures.conversation)
            _ = await controller.saveSession(named: "kept", contextWindow: nil)
            let saved = try Self.stored("kept", in: harness)
            await harness.clearRecords()
            let unknown = try await controller.restoreFromCheckpoint(entryID: "ffffffff")
            #expect(unknown == ChatSessionOperationOutcome(notices: [.checkpointEntryUnknown(specifier: "ffffffff")]))
            let notInTree = try await controller.restoreFromCheckpoint(saved, entryID: "ffffffff")
            #expect(notInTree == ChatSessionOperationOutcome(notices: [
                .checkpointEntryNotFound(entryID: "ffffffff", sessionName: "kept"),
            ]))
            #expect(await harness.runtime.calls.isEmpty)

            // A cancelled menu restores nothing.
            let cancelled = try await controller.chooseCheckpointEntry()
            #expect(cancelled == ChatSessionOperationOutcome())
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func aHostWithoutASingleChoiceMenuRestoresNothingFromTheEntryPicker() async throws {
        try await withChatHarness(hostCapabilities: []) { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            _ = await controller.saveSession(named: "kept", contextWindow: nil)
            await harness.clearRecords()

            let outcome = try await controller.chooseCheckpointEntry()

            #expect(outcome == ChatSessionOperationOutcome())
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.host.interactions.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    // MARK: - Delete

    @Test
    func deletingRemovesTheSessionItsIndexEntryAndItsEngineCheckpoint() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            _ = await controller.saveSession(named: "first", contextWindow: nil)
            _ = await controller.saveSession(named: "second", contextWindow: nil)
            let checkpoint = TerminalSessionStore.engineCheckpointURL(
                name: "first",
                workingDirectory: harness.workspace
            )
            try FileManager.default.createDirectory(
                at: checkpoint.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("kv-cache".utf8).write(to: checkpoint)
            // The index holds the latest saved session of the project.
            #expect(SavedSessionsStore().sessions().map(\.sessionName) == ["second"])
            await harness.clearRecords()

            let outcome = try await controller.deleteSavedSessions(names: ["first", "ghost"])

            // Names that match no saved session are ignored.
            #expect(outcome == ChatSessionOperationOutcome(notices: [.sessionDeleted(name: "first")]))
            #expect(try controller.savedSessions().map(\.name) == ["second"])
            // Another session than the indexed one: the entry stays.
            #expect(SavedSessionsStore().sessions().map(\.sessionName) == ["second"])
            #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
            // The active session was saved as "second", which stays linked.
            #expect(controller.savedSessionState.savedSessionName == "second")

            let active = try await controller.deleteSavedSessions(names: ["second"])

            #expect(active == ChatSessionOperationOutcome(notices: [.sessionDeleted(name: "second")]))
            #expect(try controller.savedSessions().count == 0)
            // The indexed session is gone, and so is its entry.
            #expect(SavedSessionsStore().sessions().isEmpty)
            // Deleting the session the active one is linked to unlinks it.
            #expect(controller.savedSessionState.savedSessionName == nil)
            #expect(await harness.presenter.states.last?.savedSession.savedSessionName == nil)
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func theDeletionMenuDeletesTheTickedSessionsAndPresentsNothingWhenCancelled() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller

            let none = try await controller.chooseSavedSessionsToDelete()
            #expect(none == ChatSessionOperationOutcome(notices: [.noSavedSessions]))

            try await harness.startSession(conversation: Fixtures.conversation)
            _ = await controller.saveSession(named: "first", contextWindow: nil)
            _ = await controller.saveSession(named: "second", contextWindow: nil)
            let sessions = try controller.savedSessions()
            await harness.clearRecords()

            let cancelled = try await controller.chooseSavedSessionsToDelete()
            #expect(cancelled == ChatSessionOperationOutcome())
            await harness.host.answerChooseMany([])
            let nothingTicked = try await controller.chooseSavedSessionsToDelete()
            #expect(nothingTicked == ChatSessionOperationOutcome())
            #expect(try controller.savedSessions().count == 2)

            await harness.host.answerChooseMany(["first"])
            let deleted = try await controller.chooseSavedSessionsToDelete()

            #expect(deleted == ChatSessionOperationOutcome(notices: [.sessionDeleted(name: "first")]))
            #expect(try controller.savedSessions().map(\.name) == ["second"])
            #expect(await harness.host.interactions.last == .chooseMany(
                title: "Delete saved sessions",
                items: ChatSessionController.savedSessionChoiceItems(sessions),
                selectedIDs: []
            ))
        }
    }

    // MARK: - Host without capability

    @Test
    func theSessionMenusWithoutTheirCapabilityListTheSessionsAndTouchNothing() async throws {
        try await withChatHarness(hostCapabilities: []) { harness in
            let controller = harness.controller

            // Nothing saved: the same two lines whatever the host.
            let empty = try await controller.chooseSavedSession()
            #expect(empty == ChatSessionOperationOutcome(notices: [.noSavedSessions, .sessionSelectionUsage]))

            try await harness.startSession(conversation: Fixtures.conversation)
            _ = await controller.saveSession(named: "first", contextWindow: nil)
            let sessions = try controller.savedSessions()
            let summaries = sessions.map(ChatSavedSessionSummary.init)
            await harness.clearRecords()

            let selection = try await controller.chooseSavedSession()
            let deletion = try await controller.chooseSavedSessionsToDelete()

            #expect(selection == ChatSessionOperationOutcome(notices: [
                .requiresInteractiveHost(.savedSessionSelection(summaries, activeName: "first")),
            ]))
            #expect(deletion == ChatSessionOperationOutcome(notices: [
                .requiresInteractiveHost(.savedSessionDeletion(summaries, activeName: "first")),
            ]))
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.runtime.queries.isEmpty)
            #expect(await harness.host.interactions.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
            // Nothing was loaded or deleted.
            #expect(try controller.savedSessions().map(\.name) == ["first"])
        }
    }

    // MARK: - Compaction

    @Test
    func compactingAdoptsTheCompactedSessionAndReturnsTheContextWindow() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.longConversation)
            let sessionID = controller.sessionID
            let compactedHistory = [
                Fixtures.message(.assistant, "Summary of the earlier work."),
                Fixtures.message(.assistant, "Fixed."),
            ]
            await harness.runtime.setCompactionResult(
                AgentRuntimeSessionCompactionResult(
                    snapshot: AgentRuntimeSessionSnapshot(
                        sessionID: sessionID,
                        modelID: "alpha-model",
                        workingDirectoryPath: harness.workspace.path,
                        systemPrompt: "Compacted system prompt.",
                        dynamicContext: "Compacted dynamic context.",
                        cacheKey: "compacted-cache",
                        history: compactedHistory,
                        allowedToolNames: nil,
                        thinkingSelection: nil,
                        preserveThinking: false
                    ),
                    wasCompacted: true,
                    originalEstimatedTokenCount: 12_345,
                    estimatedTokenCount: 950,
                    maxTokens: 8_000,
                    keptRecentMessageCount: 2
                )
            )

            let outcome = try await controller.compactSession(maxTokensOverride: 4_096)

            #expect(outcome.notice == .sessionCompacted(
                originalTokenCount: 12_345,
                tokenCount: 950,
                keptRecentMessageCount: 2
            ))
            let window = try #require(outcome.contextWindow)
            #expect(window.usedTokens == 950)
            #expect(window.maxTokens == 8_000)
            #expect(window.modelID == "alpha-model")
            #expect(window.isApproximate)
            #expect(await harness.runtime.calls == [
                .compactSession(sessionID: sessionID, force: true, maxTokensOverride: 4_096),
            ])
            // The compacted session replaces the controller's copy of it.
            #expect(controller.cacheKey == "compacted-cache")
            #expect(Self.contents(controller.history) == Self.contents(compactedHistory))
            #expect(controller.savedSessionState.systemPromptOverride == "Compacted system prompt.")
            #expect(controller.savedSessionState.dynamicContextOverride == "Compacted dynamic context.")
            #expect(await harness.presenter.states.last?.savedSession.systemPromptOverride
                == "Compacted system prompt.")
        }
    }

    @Test
    func compactingAShortSessionSaysThereIsNothingToCompact() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)

            let outcome = try await controller.compactSession(maxTokensOverride: nil)

            #expect(outcome.notice == .nothingToCompact)
            #expect(outcome.contextWindow == nil)
            #expect(Self.contents(controller.history) == Self.contents(Fixtures.conversation))
            #expect(controller.cacheKey == nil)
            #expect(controller.savedSessionState == ChatSavedSessionState())
            #expect(await harness.presenter.events.isEmpty)
        }
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
            #expect(calls[2] == .updatePromptSkillSelection(skillIDs: [], sessionID: "channel-session-42"))
            #expect(await harness.runtime.sessionIDs == ["channel-session-42"])
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

    @Test
    func aLoadWithoutACheckpointFileNeverAsksTheEngine() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            _ = await controller.saveSession(named: "plain", contextWindow: nil)
            let saved = try Self.stored("plain", in: harness)
            await harness.runtime.setEngineRestore(outcome: .restored)
            await harness.clearRecords()

            let outcome = try await controller.loadSavedSession(saved)

            #expect(outcome.notices.isEmpty)
            #expect(!(await harness.callNames()).contains("restoreEngineCheckpoint"))
        }
    }
}

// MARK: - Texts

/// The texts of the session notices, spelled out as the terminal wrote them
/// before they moved to `ChatSessionNoticeText`. The expectations are literal
/// strings taken from the terminal chat of that time, not calls to the
/// functions that now delegate to the notice text.
@Suite("Chat session operation texts", .serialized)
struct ChatSessionOperationTextTests {
    private func text(_ notice: ChatSessionNotice) -> String {
        ChatSessionNoticeText.text(for: notice)
    }

    /// The short date and time the terminal showed a saved session with.
    private static func legacyTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private static let summaries: [ChatSavedSessionSummary] = [
        ChatSavedSessionSummary(
            name: "alpha",
            modelID: "openrouter:auto",
            messageCount: 12,
            contextUsedTokens: 1_234,
            savedAt: savedAt
        ),
        ChatSavedSessionSummary(
            name: "beta",
            modelID: nil,
            messageCount: 0,
            contextUsedTokens: nil,
            savedAt: savedAt.addingTimeInterval(3_600)
        ),
        ChatSavedSessionSummary(
            name: "gamma",
            modelID: "chatgpt:gpt-5",
            messageCount: 3,
            contextUsedTokens: 2_500_000,
            savedAt: savedAt.addingTimeInterval(86_400)
        ),
    ]

    private static let usage = """
        Usage: /sessions                    List and select saved sessions
               /sessions <name>             Save or overwrite a named snapshot
               /sessions save               Save the current session
               /sessions new                Start a new session
               /sessions compact            Compact context
               /sessions delete             Delete a session
               /sessions restore [entry-id] Restore in-place from a checkpoint
                                            (interactive picker when omitted)
        """

    private static var listText: String {
        "\nSaved sessions:\n"
            + "  1. alpha - openrouter:auto · 12 messages · ctx 1.2k · saved \(legacyTimestamp(savedAt)) *\n"
            + "  2. beta - 0 messages · saved \(legacyTimestamp(savedAt.addingTimeInterval(3_600)))\n"
            + "  3. gamma - chatgpt:gpt-5 · 3 messages · ctx 2.5m · saved "
            + "\(legacyTimestamp(savedAt.addingTimeInterval(86_400)))\n"
            + "\n"
    }

    @Test
    func sessionLifecycleNotices() {
        #expect(text(.sessionStarted) == "Started a new session.\n")
        #expect(text(.noSavedSessions) == "No saved sessions for this project.\n")
        #expect(text(.sessionDeleted(name: "old")) == "Deleted session: old.\n")
        #expect(text(.savedSessionNotFound(name: "old")) == "ZenCODE: saved session not found: old.\n")
        #expect(
            text(.nothingToSave)
                == "ZenCODE: nothing to save yet. Send a prompt first, or use /sessions <session name>.\n"
        )
        #expect(text(.sessionUnavailableToSave) == "ZenCODE: current session is not available to save.\n")
        #expect(text(.sessionSaved(name: "parser fix", messageCount: 4)) == "Saved session: parser fix (4 messages).\n")
        #expect(text(.sessionLoaded(name: "parser fix", messageCount: 4)) == "Loaded session: parser fix (4 messages).\n")
        #expect(text(.operationFailed(description: "The file is locked.")) == "ZenCODE: The file is locked.\n")
    }

    @Test
    func theUsageBlockHasNoTrailingNewline() {
        #expect(text(.sessionSelectionUsage) == Self.usage)
        #expect(!text(.sessionSelectionUsage).hasSuffix("\n"))
        #expect(text(.sessionSelectionUsage).hasSuffix("(interactive picker when omitted)"))
    }

    @Test
    func theSavedSessionListAndItsInteractiveForms() {
        #expect(text(.savedSessions(Self.summaries, activeName: "alpha")) == Self.listText)
        #expect(
            text(.requiresInteractiveHost(.savedSessionSelection(Self.summaries, activeName: "alpha")))
                == Self.listText + Self.usage
        )
        #expect(
            text(.requiresInteractiveHost(.savedSessionDeletion(Self.summaries, activeName: "alpha")))
                == Self.listText + Self.usage
        )
    }

    @Test
    func compactionNoticesFormatTheTokenCounts() {
        #expect(
            text(.nothingToCompact)
                == "Nothing to compact yet. The session may be too short or the current model has no context-window limit.\n"
        )
        #expect(
            text(.sessionCompacted(originalTokenCount: 12_345, tokenCount: 950, keptRecentMessageCount: 4))
                == "Compacted session context from 12.3k to 950 estimated tokens, keeping 4 recent messages.\n"
        )
        #expect(
            text(.sessionCompacted(originalTokenCount: 1_234_567, tokenCount: 1_000, keptRecentMessageCount: 1))
                == "Compacted session context from 1.2m to 1.0k estimated tokens, keeping 1 recent messages.\n"
        )
    }

    @Test
    func checkpointNotices() {
        #expect(
            text(.noActiveSavedSession)
                == "No active saved session. Save first with /sessions save.\n"
        )
        #expect(
            text(.activeSavedSessionNotFound(name: "old"))
                == "Active session 'old' not found. Try /sessions save first.\n"
        )
        #expect(
            text(.checkpointEntryUnknown(specifier: "ffffffff"))
                == "Entry 'ffffffff' not found. Use /sessions restore to choose an entry.\n"
        )
        #expect(
            text(.checkpointEntryNotFound(entryID: "ffffffff", sessionName: "old"))
                == "Checkpoint entry ffffffff not found in session old.\n"
        )
        #expect(
            text(.checkpointRestored(entryID: "a1b2c3d4", messageCount: 2))
                == "Restored from checkpoint a1b2c3d4 (2 messages on this branch).\n"
        )
    }

    @Test
    func engineCheckpointNotices() {
        #expect(text(.engineCheckpoint(.saved)) == "Saved DS4 KV checkpoint.\n")
        #expect(text(.engineCheckpoint(.skippedImages)) == "KV checkpoint skipped: session contains images.\n")
        #expect(
            text(.engineCheckpoint(.skippedNoLiveState))
                == "DS4 KV checkpoint skipped: no live DS4 state for this session.\n"
        )
        #expect(
            text(.engineCheckpoint(.saveFailed(description: "Out of memory.")))
                == "ZenCODE: DS4 KV checkpoint not saved: Out of memory.\n"
        )
        #expect(text(.engineCheckpoint(.status("Evaluating the prompt"))) == "Evaluating the prompt\n")
        #expect(text(.engineCheckpoint(.restored)) == "Restored DS4 KV checkpoint.\n")
        #expect(
            text(.engineCheckpoint(.incompatible))
                == "DS4 checkpoint not compatible, the prompt will be re-evaluated.\n"
        )
        #expect(
            text(.engineCheckpoint(.restoreFailed(reason: "The cache is corrupt.")))
                == "ZenCODE: DS4 KV checkpoint not restored: The cache is corrupt.\n"
        )
    }

    @Test
    func eachNoticeIsWrittenInTheToneTheTerminalWroteItIn() {
        let failures: [ChatSessionNotice] = [
            .operationFailed(description: "boom"),
            .savedSessionNotFound(name: "old"),
            .nothingToSave,
            .sessionUnavailableToSave,
            .noActiveSavedSession,
            .activeSavedSessionNotFound(name: "old"),
            .checkpointEntryUnknown(specifier: "ffffffff"),
            .checkpointEntryNotFound(entryID: "ffffffff", sessionName: "old"),
            .engineCheckpoint(.saveFailed(description: "boom")),
            .engineCheckpoint(.restoreFailed(reason: "boom")),
        ]
        let system: [ChatSessionNotice] = [
            .sessionStarted,
            .noSavedSessions,
            .sessionSelectionUsage,
            .savedSessions(Self.summaries, activeName: nil),
            .sessionDeleted(name: "old"),
            .sessionSaved(name: "old", messageCount: 1),
            .nothingToCompact,
            .sessionCompacted(originalTokenCount: 2, tokenCount: 1, keptRecentMessageCount: 1),
            .sessionLoaded(name: "old", messageCount: 1),
            .checkpointRestored(entryID: "a1b2c3d4", messageCount: 1),
            .engineCheckpoint(.saved),
            .engineCheckpoint(.skippedImages),
            .engineCheckpoint(.skippedNoLiveState),
            .engineCheckpoint(.status("Loading")),
            .engineCheckpoint(.restored),
            .engineCheckpoint(.incompatible),
            .requiresInteractiveHost(.savedSessionSelection(Self.summaries, activeName: nil)),
            .requiresInteractiveHost(.savedSessionDeletion(Self.summaries, activeName: nil)),
        ]

        #expect(failures.allSatisfy { $0.channel == .failure })
        #expect(system.allSatisfy { $0.channel == .system })
    }
}
