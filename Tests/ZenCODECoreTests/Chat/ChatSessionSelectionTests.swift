//
//  ChatSessionSelectionTests.swift
//  ZenCODE
//
//  The selection commands of the shared controller (`/models`, `/think`,
//  `/agents`, `/tools`, `/skills`) against a scripted runtime, host, and
//  presenter. Every test runs in a support directory and a working directory
//  named by UUIDs, so nothing touches the real application state.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Chat session selections", .serialized)
struct ChatSessionSelectionTests {
    private typealias Fixtures = ChatTestFixtures

    // MARK: - Model

    @Test
    func theSameModelOnlyUpdatesTheSessionOptions() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)

            let outcome = try await controller.selectModel(id: Fixtures.alpha.id)

            #expect(outcome == ChatSelectionOutcome(change: .sessionUpdated))
            #expect(await harness.callNames() == ["updateSessionOptions"])
            let digest = try #require(await harness.runtime.calls.first?.digest)
            #expect(digest.sessionID == controller.sessionID)
            #expect(digest.modelID == Fixtures.alpha.id)
            #expect(digest.historyContents == Fixtures.conversation.map(\.content))
            #expect(await harness.presenter.states.last?.selection.modelIDOverride == Fixtures.alpha.id)
        }
    }

    @Test
    func anotherModelShutsTheBackendDownCreatesTheSessionAgainAndPreloads() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            let sessionID = controller.sessionID
            controller.savedSessionState.systemPromptOverride = "A prompt restored from a saved session."

            let outcome = try await controller.selectModel(id: Fixtures.beta.id)

            #expect(outcome == ChatSelectionOutcome(change: .sessionRecreated))
            #expect(await harness.callNames() == [
                "shutdownBackendKeepingExternalTools",
                "createSession",
                "updatePromptSkillSelection",
                "preloadModel",
            ])
            let calls = await harness.runtime.calls
            let created = try #require(calls[1].digest)
            #expect(created.sessionID == sessionID)
            #expect(created.modelID == Fixtures.beta.id)
            // The conversation survives the model change.
            #expect(created.historyContents == Fixtures.conversation.map(\.content))
            #expect(calls[2] == .updatePromptSkillSelection(skillNames: [], sessionID: sessionID))
            #expect(try #require(calls[3].digest).modelID == Fixtures.beta.id)

            // No hooks are set, so the backend's events reach the presenter.
            #expect(await harness.presenter.events.contains(.modelLoaded(Fixtures.beta.id)))
            #expect(controller.selection.modelIDOverride == Fixtures.beta.id)
            // The model's default level, since neither an agent binding nor the
            // previous model decides it.
            #expect(controller.selection.thinkingOverride == .low)
            #expect(controller.savedSessionState.systemPromptOverride == nil)
        }
    }

    @Test
    func theThinkingLevelFollowsTheAgentBindingOrStaysWithTheSameModel() async throws {
        let bound = AgentProfile(
            id: "BBBBBBBB-0000-0000-0000-000000000009",
            name: "Bound",
            role: .developer,
            modelBindings: [
                AgentModelBinding(
                    id: "beta-binding",
                    modelID: Fixtures.beta.id,
                    thinkingSelection: .high,
                    capability: 5
                ),
            ]
        )
        try await withChatHarness(
            catalog: .hosted(agents: [Fixtures.developer, bound])
        ) { harness in
            let controller = harness.controller

            // Another model: the agent's binding for it names the level.
            controller.selection.agent = bound
            controller.selection.modelIDOverride = Fixtures.alpha.id
            let switched = try await controller.selectModel(id: Fixtures.beta.id)
            #expect(switched.change == .sessionRecreated)
            #expect(controller.selection.thinkingOverride == .high)

            // The same model: the level the session had stays.
            controller.selection.agent = Fixtures.developer
            controller.selection.modelIDOverride = Fixtures.beta.id
            controller.selection.thinkingOverride = .high
            let kept = try await controller.selectModel(id: Fixtures.beta.id)
            #expect(kept.change == .sessionUpdated)
            #expect(controller.selection.thinkingOverride == .high)
        }
    }

    @Test
    func anUnknownModelThrowsAndLeavesTheRuntimeAlone() async throws {
        try await withChatHarness { harness in
            let error = await capturedError {
                try await harness.controller.selectModel(id: "no-such-model")
            }

            #expect(error as? ChatSelectionError == .unknownModel("no-such-model"))
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func theModelMenuListsTheModelsByProviderAndAppliesTheAnswer() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            await harness.host.answerChooseOne(Fixtures.beta.id)

            let outcome = try await harness.controller.chooseModel()

            #expect(outcome == ChatSelectionOutcome(change: .sessionRecreated))
            #expect(await harness.host.interactions == [
                .chooseOne(
                    title: "Available models",
                    items: [
                        ChatChoiceItem(id: Fixtures.alpha.id, title: "Alpha Model", group: "RemoteAPI"),
                        ChatChoiceItem(id: Fixtures.beta.id, title: "Beta Model", group: "RemoteAPI"),
                    ],
                    selectedID: Fixtures.alpha.id
                ),
            ])
            #expect(harness.controller.selection.modelIDOverride == Fixtures.beta.id)
            #expect(await harness.callNames().first == "shutdownBackendKeepingExternalTools")
        }
    }

    @Test
    func aSessionStartedWithoutAModelAsksForOneAndNeverPersistsIt() async throws {
        let models = [Fixtures.configuredAlpha, Fixtures.configuredBeta]
        try await withChatHarness(
            catalog: .configured(models: models),
            hostCapabilities: [.singleChoice]
        ) { harness in
            let controller = harness.controller
            let settingsBefore = try Data(contentsOf: harness.settingsURL)

            // A cancelled menu leaves the session without a model: startup fails.
            let host = harness.host
            let refused = await capturedError { try await controller.resolveInitialModel() }
            #expect(refused as? TerminalChatError != nil)

            await host.answerChooseOne(Fixtures.configuredBeta.id)
            await host.answerChooseOne(AgentThinkingSelection.high.rawValue)
            let notice = try await controller.resolveInitialModel()

            #expect(notice == .modelSelected(Fixtures.configuredBeta, thinking: .high))
            #expect(controller.selection.modelIDOverride == Fixtures.configuredBeta.id)
            #expect(controller.selection.thinkingOverride == .high)
            let interactions = await host.interactions
            guard case let .chooseOne(modelTitle, _, _) = try #require(interactions.first),
                  case let .chooseOne(thinkingTitle, thinkingItems, thinkingSelected) =
                    try #require(interactions.last) else {
                Issue.record("The host was asked for a model and a thinking level")
                return
            }
            #expect(modelTitle == "No model selected for ZenCODE.")
            #expect(thinkingTitle == "Thinking / effort for Configured Beta")
            #expect(thinkingItems.map(\.id) == ["low", "high"])
            #expect(thinkingSelected == "low")
            // Nothing is persisted by the startup choice.
            #expect(try Data(contentsOf: harness.settingsURL) == settingsBefore)

            // Once the session has a model, there is nothing left to resolve.
            #expect(try await controller.resolveInitialModel() == nil)
        }
    }

    // MARK: - Persistence

    @Test
    func withoutHostedModelsTheChoicesAreWrittenToSettingsJSON() async throws {
        let models = [Fixtures.configuredAlpha, Fixtures.configuredBeta]
        try await withChatHarness(
            catalog: .configured(models: models, selectedModelID: Fixtures.configuredAlpha.id)
        ) { harness in
            let controller = harness.controller
            try await harness.startSession()
            let settingsBefore = try Data(contentsOf: harness.settingsURL)
            #expect(try AgentSettingsManifestStore.loadRequired(from: harness.settingsURL)
                .selectedModelID == Fixtures.configuredAlpha.id)

            let selected = try await controller.selectModel(id: Fixtures.configuredBeta.id)

            #expect(selected.change == .sessionRecreated)
            var manifest = try AgentSettingsManifestStore.loadRequired(from: harness.settingsURL)
            #expect(manifest.selectedModelID == Fixtures.configuredBeta.id)
            // The model's default level is saved with it.
            #expect(manifest.selectedThinkingSelection == .low)
            #expect(try Data(contentsOf: harness.settingsURL) != settingsBefore)

            let thinking = try await controller.selectThinking(.high)

            #expect(thinking.change == .sessionUpdated)
            manifest = try AgentSettingsManifestStore.loadRequired(from: harness.settingsURL)
            #expect(manifest.selectedModelID == Fixtures.configuredBeta.id)
            #expect(manifest.selectedThinkingSelection == .high)
        }
    }

    @Test
    func withHostedModelsAChoiceNeverWritesSettingsJSON() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            // A user's own settings that the hosted choices must leave alone.
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(
                    models: [Fixtures.configuredAlpha],
                    selectedModelID: Fixtures.configuredAlpha.id
                ),
                to: harness.settingsURL
            )
            let settingsBefore = try Data(contentsOf: harness.settingsURL)

            _ = try await controller.selectModel(id: Fixtures.beta.id)
            _ = try await controller.selectThinking(.high)

            #expect(controller.selection.modelIDOverride == Fixtures.beta.id)
            #expect(controller.selection.thinkingOverride == .high)
            #expect(try Data(contentsOf: harness.settingsURL) == settingsBefore)
        }
    }

    // MARK: - Thinking

    @Test
    func theThinkingMenuUpdatesTheSessionInPlace() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let controller = harness.controller
            controller.selection.modelIDOverride = Fixtures.beta.id
            try await harness.startSession(conversation: Fixtures.conversation)
            await harness.host.answerChooseOne("high")

            let outcome = try await controller.chooseThinking()

            #expect(outcome == ChatSelectionOutcome(change: .sessionUpdated))
            #expect(await harness.host.interactions == [
                .chooseOne(
                    title: "Thinking / effort for Beta Model",
                    items: [
                        ChatChoiceItem(id: "low", title: "Low thinking"),
                        ChatChoiceItem(id: "high", title: "High thinking"),
                    ],
                    selectedID: "low"
                ),
            ])
            // Only the options change: no shutdown, no new session, no preload.
            #expect(await harness.callNames() == ["updateSessionOptions"])
            #expect(try #require(await harness.runtime.calls.first?.digest).thinkingSelection == .high)
            #expect(controller.selection.thinkingOverride == .high)
            #expect(await harness.presenter.states.last?.selection.thinkingOverride == .high)
        }
    }

    // MARK: - Host without capability

    @Test
    func theModelMenuWithoutASingleChoiceHostListsTheModelsAndTouchesNothing() async throws {
        try await withChatHarness(hostCapabilities: []) { harness in
            let outcome = try await harness.controller.chooseModel()

            #expect(outcome == ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(
                    .modelSelection(
                        models: [Fixtures.alpha, Fixtures.beta],
                        selectedModelID: Fixtures.alpha.id
                    )
                ),
            ]))
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.runtime.queries.isEmpty)
            #expect(await harness.host.interactions.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    // MARK: - Project agents

    private var projectAgents: ChatTestCatalog {
        .hosted(agents: [Fixtures.developer, Fixtures.reviewer, Fixtures.reporter])
    }

    private func projectAgentsFile(_ harness: ChatManagementHarness) -> URL {
        ProjectAgentSelectionStore.manifestURL(workspaceRootURL: harness.workspace)
    }

    @Test
    func aChangedAssociationIsSavedAndTheActiveAgentKeepsItsSession() async throws {
        try await withChatHarness(
            catalog: projectAgents,
            hostCapabilities: [.focusedMultipleChoice]
        ) { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            controller.savedSessionState.systemPromptOverride = "A stale prompt."
            let developerID = ChatSessionController.agentChoiceID(Fixtures.developer)
            let reviewerID = ChatSessionController.agentChoiceID(Fixtures.reviewer)
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: harness.workspace) == nil)
            await harness.host.answerChooseManyWithFocus(
                ChatFocusedChoice(selectedIDs: [developerID, reviewerID], focusedID: developerID)
            )

            let outcome = try await controller.chooseProjectAgents()

            let projectName = harness.workspace.lastPathComponent
            #expect(await harness.host.interactions == [
                .chooseManyWithFocus(
                    title: "Agent profiles · project: \(projectName)",
                    items: [
                        ChatChoiceItem(
                            id: developerID,
                            title: "Developer",
                            detail: "General software development; the default agent",
                            isCurrent: true
                        ),
                        ChatChoiceItem(
                            id: reviewerID,
                            title: "Reviewer",
                            detail: "/review delegates to it"
                        ),
                        ChatChoiceItem(
                            id: ChatSessionController.agentChoiceID(Fixtures.reporter),
                            title: "Reporter",
                            detail: ChatSessionNoticeText.agentDetail(Fixtures.reporter)
                        ),
                    ],
                    // A project without a saved selection starts with the system
                    // profiles ticked.
                    selectedIDs: [developerID],
                    focusedID: developerID,
                    toggleLabel: "agents",
                    confirmLabel: "use agent"
                ),
            ])
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: harness.workspace)
                == Set([Fixtures.developer, Fixtures.reviewer]
                    .map(ProjectAgentSelectionStore.selectionKey(for:))))
            #expect(await harness.presenter.notices == [
                .projectAgentsAssociated(
                    agents: [Fixtures.developer, Fixtures.reviewer],
                    projectName: projectName
                ),
            ])
            // Same agent: the prompt is rebuilt in place, the conversation kept.
            #expect(outcome == ChatSelectionOutcome(change: .sessionUpdated))
            #expect(await harness.callNames() == ["updateSessionOptions"])
            #expect(controller.savedSessionState.systemPromptOverride == nil)
            #expect(controller.selection.agent == Fixtures.developer)
        }
    }

    @Test
    func aChangedActiveRowSwitchesTheAgentWithoutWritingAnUnchangedAssociation() async throws {
        try await withChatHarness(
            catalog: projectAgents,
            hostCapabilities: [.focusedMultipleChoice]
        ) { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            let developerID = ChatSessionController.agentChoiceID(Fixtures.developer)
            let reviewerID = ChatSessionController.agentChoiceID(Fixtures.reviewer)
            await harness.host.answerChooseManyWithFocus(
                ChatFocusedChoice(selectedIDs: [developerID], focusedID: reviewerID)
            )

            let outcome = try await controller.chooseProjectAgents()

            #expect(outcome == ChatSelectionOutcome(
                change: .sessionRecreated,
                notices: [.agentSwitched(Fixtures.reviewer)]
            ))
            #expect(controller.selection.agent == Fixtures.reviewer)
            // Confirming an unchanged association writes no file.
            #expect(!FileManager.default.fileExists(
                atPath: projectAgentsFile(harness).path
            ))
            #expect(await harness.presenter.notices.isEmpty)
            #expect(await harness.callNames() == [
                "shutdownBackendKeepingExternalTools",
                "clearTaskGraphs",
                "createSession",
                "updatePromptSkillSelection",
                "preloadModel",
            ])
        }
    }

    // MARK: - Workspace access

    @Test
    func deniedWorkspaceAccessDeselectsTheWorkspaceToolsAndSaysSo() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["shell", "files", "sub-agents"]
            await harness.host.answerWorkspaceAccess(false)

            await controller.ensureWorkspaceAccess()

            let request = ChatWorkspaceAccessRequest(
                workspaceURL: harness.workspace,
                toolTitles: ["Shell", "Files"]
            )
            // Only the groups that need the folder are dropped.
            #expect(controller.selection.toolKeys == ["sub-agents"])
            #expect(await harness.host.interactions == [.requestWorkspaceAccess(request)])
            #expect(await harness.presenter.notices == [.workspaceAccessDenied(request)])
            #expect(await harness.presenter.states.last?.selection.toolKeys == ["sub-agents"])
        }
    }

    @Test
    func grantedWorkspaceAccessAndToolsThatNeedNoFolderChangeNothing() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["shell", "files"]
            await harness.host.answerWorkspaceAccess(true)

            await controller.ensureWorkspaceAccess()

            #expect(controller.selection.toolKeys == ["shell", "files"])
            #expect(await harness.host.interactions.count == 1)
            #expect(await harness.presenter.events.isEmpty)

            // No selected group reaches the folder, so the host is not asked.
            controller.selection.toolKeys = ["sub-agents"]
            await harness.clearRecords()
            await controller.ensureWorkspaceAccess()
            #expect(await harness.host.interactions.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func deniedWorkspaceAccessDuringAToolSelectionRemovesTheKeysFromTheSession() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            await harness.host.answerWorkspaceAccess(false)

            let outcome = await controller.selectTools(keys: ["files", "sub-agents"])

            #expect(controller.selection.toolKeys == ["sub-agents"])
            #expect(await harness.presenter.notices.contains(
                .workspaceAccessDenied(
                    ChatWorkspaceAccessRequest(workspaceURL: harness.workspace, toolTitles: ["Files"])
                )
            ))
            // The session never receives the tools the platform refused.
            let digest = try #require(await harness.runtime.calls.first?.digest)
            #expect(try #require(digest.allowedToolNames).contains("local.readFile") == false)
            guard case let .activeTools(summary) = try #require(outcome.notices.first) else {
                Issue.record("The closing notice reports the active tools")
                return
            }
            #expect(!summary.groups.map(\.title).contains("Files"))
        }
    }

    @Test
    func deniedWorkspaceAccessDuringAnAgentSwitchDeselectsTheAgentTools() async throws {
        let shellAgent = AgentProfile(
            id: "BBBBBBBB-0000-0000-0000-000000000010",
            name: "Shell Agent",
            role: .developer,
            tools: ["shell"]
        )
        try await withChatHarness(
            catalog: .hosted(agents: [Fixtures.developer, shellAgent])
        ) { harness in
            await harness.host.answerWorkspaceAccess(false)

            let outcome = try await harness.controller.selectAgent(shellAgent)

            #expect(outcome.notices == [.agentSwitched(shellAgent)])
            #expect(harness.controller.selection.toolKeys.isEmpty)
            #expect(await harness.presenter.notices == [
                .workspaceAccessDenied(
                    ChatWorkspaceAccessRequest(workspaceURL: harness.workspace, toolTitles: ["Shell"])
                ),
            ])
        }
    }

    // MARK: - Agent

    @Test
    func selectingAnAgentResetsThePlanAndTheTaskGraphButKeepsTheConversation() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            let sessionID = controller.sessionID
            controller.activePlan = TerminalSessionPlan(
                id: "plan-to-reset",
                originalGoal: "Fix the parser",
                consolidatedText: "1. Read the parser.",
                createdAt: Date(timeIntervalSince1970: 1_000),
                isApproved: true,
                points: [TerminalSessionPlanPoint(id: "plan-to-reset-1", text: "Read the parser")]
            )
            controller.pendingPlanApprovalPlanID = "plan-to-reset"
            controller.savedSessionState.systemPromptOverride = "A stale prompt."
            try await harness.runtime.seedTaskGraph(Fixtures.taskGraph(id: "graph-1"), sessionID: sessionID)
            #expect(try await harness.runtime.taskGraphSnapshot(sessionID: sessionID, graphID: nil)?.id == "graph-1")
            await harness.clearRecords()

            let outcome = try await controller.selectAgent(Fixtures.reviewer)

            #expect(outcome == ChatSelectionOutcome(
                change: .sessionRecreated,
                notices: [.agentSwitched(Fixtures.reviewer)]
            ))
            #expect(ChatSessionNoticeText.text(for: try #require(outcome.notices.first))
                == "Switched to agent: Reviewer. Plan and task graph reset; conversation kept.\n")
            #expect(controller.selection.agent == Fixtures.reviewer)
            #expect(controller.activePlan == nil)
            #expect(controller.pendingPlanApprovalPlanID == nil)
            #expect(controller.savedSessionState.systemPromptOverride == nil)
            #expect(try await harness.runtime.taskGraphSnapshot(sessionID: sessionID, graphID: nil) == nil)

            // The conversation stays in the controller and in the new session.
            #expect(controller.history.map(\.content) == Fixtures.conversation.map(\.content))
            #expect(controller.transcript.map(\.content) == Fixtures.conversation.map(\.content))
            let calls = await harness.runtime.calls
            #expect(calls.map(\.name) == [
                "shutdownBackendKeepingExternalTools",
                "clearTaskGraphs",
                "createSession",
                "updatePromptSkillSelection",
                "preloadModel",
            ])
            #expect(calls[1] == .clearTaskGraphs(sessionID: sessionID))
            let created = try #require(calls[2].digest)
            #expect(created.sessionID == sessionID)
            #expect(created.agentID == Fixtures.reviewer.id)
            #expect(created.historyContents == Fixtures.conversation.map(\.content))
            #expect(await harness.presenter.states.last?.selection.agent == Fixtures.reviewer)
        }
    }

    @Test
    func selectingAnAgentKeepsAModelChosenThroughModelsAndOtherwiseFallsBack() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            // A model chosen explicitly is session state, not the agent's.
            controller.selection.modelIDOverride = Fixtures.beta.id
            controller.selection.thinkingOverride = .high
            _ = try await controller.selectAgent(Fixtures.reviewer)
            #expect(controller.selection.modelIDOverride == Fixtures.beta.id)
            #expect(controller.selection.thinkingOverride == .high)
            let created = try #require(await harness.runtime.calls.first { $0.name == "createSession" }?.digest)
            #expect(created.modelID == Fixtures.beta.id)
            #expect(created.thinkingSelection == .high)

            // Without one, a hosted session falls back to the launch model and
            // forgets a stale level.
            controller.selection.modelIDOverride = nil
            controller.selection.thinkingOverride = .high
            _ = try await controller.selectAgent(Fixtures.developer)
            #expect(controller.selection.modelIDOverride == nil)
            #expect(controller.selection.thinkingOverride == nil)
        }
    }

    @Test
    func theNewAgentBringsItsToolsAndSkills() async throws {
        let skilled = AgentProfile(
            id: "BBBBBBBB-0000-0000-0000-000000000011",
            name: "Skilled",
            role: .developer,
            tools: ["files"],
            skills: [AgentProfileSkill(name: "alpha-skill")]
        )
        try await withChatHarness(
            catalog: .hosted(agents: [Fixtures.developer, skilled])
        ) { harness in
            let controller = harness.controller
            let alpha = try harness.installSkills("alpha-skill", "beta-skill")[0]

            _ = try await controller.selectAgent(skilled)

            #expect(controller.selection.toolKeys == ["files"])
            #expect(controller.selection.skillNames == [alpha.canonicalName])
            let calls = await harness.runtime.calls
            let created = try #require(calls.first { $0.name == "createSession" }?.digest)
            let allowed = try #require(created.allowedToolNames)
            #expect(allowed.contains("local.readFile"))
            #expect(!allowed.contains("local.exec"))
            // The skills reach the new session before the model loads.
            #expect(calls.contains(
                .updatePromptSkillSelection(skillNames: [alpha.canonicalName], sessionID: controller.sessionID)
            ))
            #expect(await harness.runtime.promptSkills(for: controller.sessionID).map(\.canonicalName) == [alpha.canonicalName])
        }
    }

    @Test
    func anAgentIsSelectedByNumberOrByNameAndAnUnknownOneThrows() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            let byNumber = try await controller.selectAgent(rawSelection: "2")
            #expect(byNumber.notices == [.agentSwitched(Fixtures.reviewer)])

            let byName = try await controller.selectAgent(rawSelection: "  DEVELOPER ")
            #expect(byName.notices == [.agentSwitched(Fixtures.developer)])
            #expect(controller.selection.agent == Fixtures.developer)

            await harness.clearRecords()
            let error = await capturedError { try await controller.selectAgent(rawSelection: "nobody") }
            guard case let .unknownAgent(name) = try #require(error as? TerminalAgentSelectionError) else {
                Issue.record("An unknown agent throws unknownAgent")
                return
            }
            #expect(name == "nobody")
            #expect(await harness.runtime.calls.isEmpty)
            #expect(controller.selection.agent == Fixtures.developer)
        }
    }

    // MARK: - Tools

    @Test
    func aToolChangeThatAltersTheAllowlistRebuildsTheSessionAndReappliesTheSkills() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let skill = try harness.installSkills("release-review")[0]
            controller.selection.skillNames = [skill.canonicalName]
            controller.selection.toolKeys = ["shell", "files"]
            try await harness.startSession(conversation: Fixtures.conversation)
            let sessionID = controller.sessionID
            let initial = try #require(await harness.runtime.configuration(for: sessionID))
            let initialAllowed = try #require(initial.allowedToolNames)
            #expect(initialAllowed.contains("local.exec"))
            // The runtime session holds the skills from its creation on.
            #expect(await harness.runtime.promptSkills(for: sessionID).map(\.canonicalName) == [skill.canonicalName])

            let outcome = await controller.selectTools(keys: ["files"])

            #expect(outcome.change == .sessionRecreated)
            guard case let .activeTools(summary) = try #require(outcome.notices.first),
                  outcome.notices.count == 1 else {
                Issue.record("The closing notice reports the active tools")
                return
            }
            #expect(summary.groups.map(\.title).contains("Files"))
            #expect(!summary.groups.map(\.title).contains("Shell"))

            let calls = await harness.runtime.calls
            #expect(calls.map(\.name) == ["rebuildSession", "createSession", "updatePromptSkillSelection"])
            #expect(calls[0] == .rebuildSession(sessionID))
            let created = try #require(calls[1].digest)
            let allowed = try #require(created.allowedToolNames)
            #expect(allowed.contains("local.readFile"))
            #expect(!allowed.contains("local.exec"))
            // The model is told what changed, after the conversation it kept.
            let message = ChatSessionController.toolSelectionChangedMessage(
                previousAllowedToolNames: initialAllowed,
                currentAllowedToolNames: allowed
            )
            #expect(created.historyContents == Fixtures.conversation.map(\.content) + [message.content])
            #expect(controller.history.last?.content == message.content)
            #expect(message.role == .system)
            #expect(message.content.hasPrefix("Tool selection changed during this session.\n"))
            #expect(message.content.contains("Removed tool names:"))
            #expect(message.content.contains("local.exec"))
            // The rebuild dropped the skills; they are handed over again.
            #expect(calls[2] == .updatePromptSkillSelection(skillNames: [skill.canonicalName], sessionID: sessionID))
            #expect(await harness.runtime.promptSkills(for: sessionID).map(\.canonicalName) == [skill.canonicalName])
        }
    }

    @Test
    func aToolChangeThatKeepsTheAllowlistOnlyUpdatesTheOptions() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["shell", "files"]
            try await harness.startSession(conversation: Fixtures.conversation)

            let outcome = await controller.selectTools(keys: ["shell", "files"])

            #expect(outcome.change == .sessionUpdated)
            #expect(await harness.callNames() == ["updateSessionOptions"])
            // No rebuild, so no message is added to the conversation.
            #expect(controller.history.map(\.content) == Fixtures.conversation.map(\.content))
        }
    }

    @Test
    func aToolSelectionIsParsedFromTheCommandArguments() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            let files = try await controller.selectTools(rawSelection: "files")
            #expect(files.change == .sessionUpdated)
            #expect(controller.selection.toolKeys == ["files"])

            _ = try await controller.selectTools(rawSelection: "none")
            #expect(controller.selection.toolKeys.isEmpty)

            _ = try await controller.selectTools(rawSelection: "all")
            let items = await controller.toolSelectionItems()
            #expect(controller.selection.toolKeys == Set(items.map(\.key)))

            await harness.clearRecords()
            let error = await capturedError { try await controller.selectTools(rawSelection: "bogus") }
            #expect(error is TerminalToolSelectionError)
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func theToolMenuListsTheGroupsAndAppliesTheAnswer() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["shell"]
            await harness.host.answerChooseMany(["files", "sub-agents"])

            let outcome = await controller.chooseTools()

            #expect(outcome.change == .sessionUpdated)
            #expect(controller.selection.toolKeys == ["files", "sub-agents"])
            guard case let .chooseMany(title, items, selectedIDs) = try #require(
                await harness.host.interactions.first
            ) else {
                Issue.record("The host was asked for the tool groups")
                return
            }
            #expect(title == "Tools")
            #expect(items.map(\.id).prefix(2) == ["shell", "files"])
            #expect(items.first?.title == "Shell")
            #expect(items.first?.group == "Core")
            #expect(selectedIDs == ["shell"])
        }
    }

    // MARK: - Skills

    @Test
    func selectingSkillsOnlyUpdatesThePromptSkillSelection() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let skills = try harness.installSkills("alpha-skill", "beta-skill")
            let alpha = skills[0]
            let beta = skills[1]
            try await harness.startSession(conversation: Fixtures.conversation)
            let sessionID = controller.sessionID

            let outcome = await controller.selectSkills(names: [alpha.canonicalName])

            #expect(outcome == ChatSelectionOutcome(change: .sessionUpdated, notices: [.selectedSkills([alpha])]))
            // The prompt, the allowlist, and the history are not touched.
            #expect(await harness.runtime.calls == [
                .updatePromptSkillSelection(skillNames: [alpha.canonicalName], sessionID: sessionID),
            ])
            #expect(controller.selection.skillNames == [alpha.canonicalName])
            #expect(await harness.presenter.states.last?.selection.skillNames == [alpha.canonicalName])

            // The same selection, spelled in the command arguments.
            let all = try await controller.selectSkills(rawSelection: "all")
            #expect(all.notices == [.selectedSkills([alpha, beta])])
            let byName = try await controller.selectSkills(rawSelection: "beta-skill")
            #expect(byName.notices == [.selectedSkills([beta])])
            let none = try await controller.selectSkills(rawSelection: "none")
            #expect(none.notices == [.selectedSkills([])])
            #expect(controller.selection.skillNames.isEmpty)

            let error = await capturedError { try await controller.selectSkills(rawSelection: "zzz") }
            #expect(error is TerminalSkillSelectionError)
        }
    }

    @Test
    func theSkillMenuListsTheInstalledSkillsAndAppliesTheAnswer() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller

            // Nothing installed: no menu, the selection is reported.
            let empty = await controller.chooseSkills()
            #expect(empty == ChatSelectionOutcome(notices: [.noPromptSkillsInstalled, .selectedSkills([])]))
            #expect(await harness.host.interactions.isEmpty)

            let skills = try harness.installSkills("alpha-skill", "beta-skill")
            await harness.host.answerChooseMany([skills[1].canonicalName])
            let applied = await controller.chooseSkills()
            #expect(applied == ChatSelectionOutcome(
                change: .sessionUpdated,
                notices: [.selectedSkills([skills[1]])]
            ))
            guard case let .chooseMany(title, items, selectedIDs) = try #require(
                await harness.host.interactions.first
            ) else {
                Issue.record("The host was asked for the prompt skills")
                return
            }
            #expect(title == "Prompt skills")
            #expect(items.map(\.id) == skills.map(\.canonicalName))
            #expect(selectedIDs.isEmpty)

            // A cancelled menu keeps the selection and reports it.
            let cancelled = await controller.chooseSkills()
            #expect(cancelled == ChatSelectionOutcome(notices: [.selectedSkills([skills[1]])]))
        }
    }

    @Test
    func installingFromALocalPathCopiesSelectsAndHandsTheSkillToTheSession() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession()
            let sessionID = controller.sessionID
            let source = harness.workspace.appendingPathComponent("vendor", isDirectory: true)
            try Fixtures.writeSkill(named: "release-review", in: source)

            // A relative path resolves against the working directory.
            let outcome = await controller.installSkill(source: "./vendor/release-review")

            #expect(await harness.presenter.notices == [
                .skillInstallStarted(
                    source: harness.workspace
                        .appendingPathComponent("vendor/release-review", isDirectory: true)
                        .standardizedFileURL.path
                ),
            ])
            guard case let .skillInstalled(skill) = try #require(outcome.notices.first),
                  outcome.notices.count == 1 else {
                Issue.record("The closing notice reports the installed skill")
                return
            }
            #expect(outcome.change == .sessionUpdated)
            #expect(skill.canonicalName == "release-review")
            #expect(FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("release-review/SKILL.md").path
            ))
            #expect(controller.selection.skillNames == [skill.canonicalName])
            #expect(controller.availableSkills().map(\.canonicalName) == [skill.canonicalName])
            #expect(await harness.runtime.calls == [
                .updatePromptSkillSelection(skillNames: [skill.canonicalName], sessionID: sessionID),
            ])
            #expect(await harness.presenter.states.last?.selection.skillNames == [skill.canonicalName])
        }
    }

    @Test
    func uninstallingRemovesTheSkillDeselectsItAndUpdatesTheSession() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller
            let skills = try harness.installSkills("alpha-skill", "beta-skill")
            let alpha = skills[0]
            let beta = skills[1]
            controller.selection.skillNames = [alpha.canonicalName, beta.canonicalName]
            await harness.host.answerChooseMany([alpha.canonicalName])

            let outcome = await controller.chooseSkillsToUninstall()

            #expect(outcome == ChatSelectionOutcome(
                change: .sessionUpdated,
                notices: [.skillsUninstalled([alpha])]
            ))
            guard case let .chooseMany(title, items, selectedIDs) = try #require(
                await harness.host.interactions.first
            ) else {
                Issue.record("The host was asked which skills to uninstall")
                return
            }
            #expect(title == "Uninstall prompt skills")
            #expect(items.map(\.id) == [alpha.canonicalName, beta.canonicalName])
            #expect(selectedIDs.isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("alpha-skill").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("beta-skill").path
            ))
            #expect(controller.selection.skillNames == [beta.canonicalName])
            #expect(controller.availableSkills().map(\.canonicalName) == [beta.canonicalName])
            #expect(await harness.runtime.calls == [
                .updatePromptSkillSelection(skillNames: [beta.canonicalName], sessionID: controller.sessionID),
            ])
        }
    }
}

// MARK: - Texts

/// The active-tool count and the channel of the selection notices, as the
/// terminal wrote them before they moved to `ChatSessionNoticeText`.
@Suite("Chat session selection texts", .serialized)
struct ChatSessionSelectionTextTests {
    private typealias Fixtures = ChatTestFixtures

    private func text(_ notice: ChatSessionNotice) -> String {
        ChatSessionNoticeText.text(for: notice)
    }

    private static let skillOne = PromptSkill(
        canonicalName: "release-review",
        title: "Release Review",
        summary: "Review release changes.",
        promptBody: "Body",
        sourceHash: "hash-one"
    )

    // MARK: Tools and skills

    @Test
    func theActiveToolGroupsAreCountedAsTheTerminalCountedThem() {
        let items = TerminalToolSelectionCatalog.items(featureStatuses: [])
        let summary = ChatActiveToolsSummary(
            toolNames: ["local.exec", "exec.job", "local.readFile", "skills.list", "skills.read"],
            items: items,
            selectedKeys: ["shell", "files"]
        )

        #expect(text(.activeTools(summary)) == "Active tools: Shell (2), Files (1), Skills (2)\n")
        // Feature-management tools are never listed, and no tool means none.
        let hidden = ChatActiveToolsSummary(
            toolNames: Array(AgentProfileStore.featureManagementToolNames),
            items: items,
            selectedKeys: ["shell", "files"]
        )
        #expect(text(.activeTools(hidden)) == "Active tools: none\n")
    }

    @Test
    func eachNoticeIsWrittenInTheToneTheTerminalWroteItIn() {
        let request = ChatWorkspaceAccessRequest(
            workspaceURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            toolTitles: ["Shell"]
        )
        let failures: [ChatSessionNotice] = [
            .operationFailed(description: "boom"),
            .projectAgentsSaveFailed(description: "disk full"),
            .skillInstallSourceRequired,
            .requiresInteractiveHost(.skillUninstall),
        ]
        let system: [ChatSessionNotice] = [
            .modelSelected(Fixtures.beta, thinking: nil),
            .modelUnchanged,
            .noCurrentModel,
            .thinkingNotSupported(model: Fixtures.alpha),
            .thinkingUnchanged,
            .selectedAgent(nil),
            .agentSelectionUsage,
            .agentSwitched(Fixtures.reviewer),
            .toolSelectionUsage,
            .skillSelectionUsage,
            .noPromptSkillsInstalled,
            .skillInstalled(Self.skillOne),
            .workspaceAccessDenied(request),
            .requiresInteractiveHost(.modelSelection(models: [Fixtures.alpha], selectedModelID: nil)),
            .requiresInteractiveHost(.skillSelection(selected: [])),
        ]

        #expect(failures.allSatisfy { $0.channel == .failure })
        #expect(system.allSatisfy { $0.channel == .system })
    }
}
