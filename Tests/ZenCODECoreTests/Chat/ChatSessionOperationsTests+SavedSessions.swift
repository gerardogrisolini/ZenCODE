//
//  ChatSessionOperationsTests+SavedSessions.swift
//  ZenCODE
//
//  The first half of the session operations tests: saving, listing, loading,
//  restoring, and deleting saved sessions, and compaction, with the helper
//  only these tests use.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension ChatSessionOperationsTests {
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
            controller.selection.skillNames = [skill.canonicalName]
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
            #expect(controller.selection.skillNames == [skill.canonicalName])

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
            #expect(calls[3] == .updatePromptSkillSelection(skillNames: [skill.canonicalName], sessionID: savedSessionID))
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
    func theQueuedPlansAreSavedWithTheSessionAndRestoredWithIt() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            let savedSessionID = controller.sessionID
            let queued = [Self.plan(id: "plan-queued-2"), Self.plan(id: "plan-queued-3")]
            controller.activePlan = Self.plan()
            controller.queuedPlans = queued
            _ = await controller.saveSession(named: "sequence", contextWindow: nil)
            let saved = try Self.stored("sequence", in: harness)
            #expect(saved.activePlan?.id == "plan-save")
            #expect(saved.queuedPlans == queued)

            // A new session starts without a queue.
            _ = try await controller.startNewSession(newSessionID: "channel-session-2")
            #expect(controller.activePlan == nil)
            #expect(controller.queuedPlans.isEmpty)

            _ = try await controller.loadSavedSession(saved)
            #expect(controller.sessionID == savedSessionID)
            #expect(controller.activePlan?.id == "plan-save")
            #expect(controller.queuedPlans == queued)

            // Without a queue the session stores none.
            controller.queuedPlans = []
            _ = await controller.saveSession(named: "single", contextWindow: nil)
            #expect(try Self.stored("single", in: harness).queuedPlans == nil)
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
            guard case let .available(choices) = try controller.checkpointEntryMenu() else {
                Issue.record("The active saved session has no checkpoint menu.")
                return
            }
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
}
