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
            #expect(calls[2] == .updatePromptSkillSelection(skillIDs: [], sessionID: sessionID))
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
    func aModelCanBeNamedByItsModelIDAndIsStoredByItsID() async throws {
        try await withChatHarness { harness in
            let outcome = try await harness.controller.selectModel(id: "test/beta")

            #expect(outcome.change == .sessionRecreated)
            #expect(harness.controller.selection.modelIDOverride == Fixtures.beta.id)
            #expect(try #require(await harness.runtime.calls.first { $0.name == "createSession" }?.digest)
                .modelID == Fixtures.beta.id)
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
    func withoutAnyModelTheMenuAndTheSelectionThrow() async throws {
        try await withChatHarness(
            catalog: .hosted(models: [], agents: [Fixtures.developer]),
            hostCapabilities: [.singleChoice]
        ) { harness in
            let menuError = await capturedError { try await harness.controller.chooseModel() }
            let selectError = await capturedError {
                try await harness.controller.selectModel(id: Fixtures.alpha.id)
            }

            #expect(menuError as? TerminalChatError != nil)
            #expect(selectError as? TerminalChatError != nil)
            #expect(await harness.runtime.calls.isEmpty)
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
    func aCancelledModelMenuLeavesTheModelUnchanged() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let outcome = try await harness.controller.chooseModel()

            #expect(outcome == ChatSelectionOutcome(notices: [.modelUnchanged]))
            #expect(harness.controller.selection.modelIDOverride == nil)
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
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

    @Test
    func withHostedModelsAndNoSettingsFileNothingIsCreated() async throws {
        try await withChatHarness { harness in
            #expect(!FileManager.default.fileExists(atPath: harness.settingsURL.path))

            _ = try await harness.controller.selectModel(id: Fixtures.beta.id)
            _ = try await harness.controller.selectThinking(.high)

            #expect(!FileManager.default.fileExists(atPath: harness.settingsURL.path))
        }
    }

    // MARK: - Thinking

    @Test
    func aModelWithoutConfigurableThinkingGetsTheDedicatedNotice() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let outcome = try await harness.controller.chooseThinking()

            #expect(outcome == ChatSelectionOutcome(
                notices: [.thinkingNotSupported(model: Fixtures.alpha)]
            ))
            #expect(await harness.host.interactions.isEmpty)
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func thinkingWithoutACurrentModelGetsTheDedicatedNotice() async throws {
        let models = [Fixtures.configuredAlpha, Fixtures.configuredBeta]
        try await withChatHarness(
            catalog: .configured(models: models),
            hostCapabilities: [.singleChoice]
        ) { harness in
            let outcome = try await harness.controller.chooseThinking()

            #expect(outcome == ChatSelectionOutcome(notices: [.noCurrentModel]))
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

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

    @Test
    func aCancelledThinkingMenuLeavesTheLevelUnchanged() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            harness.controller.selection.modelIDOverride = Fixtures.beta.id

            let outcome = try await harness.controller.chooseThinking()

            #expect(outcome == ChatSelectionOutcome(notices: [.thinkingUnchanged]))
            #expect(harness.controller.selection.thinkingOverride == nil)
            #expect(await harness.runtime.calls.isEmpty)
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

    @Test
    func theThinkingMenuWithoutASingleChoiceHostListsTheLevelsAndTouchesNothing() async throws {
        try await withChatHarness(hostCapabilities: []) { harness in
            harness.controller.selection.modelIDOverride = Fixtures.beta.id

            let outcome = try await harness.controller.chooseThinking()

            #expect(outcome == ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(
                    .thinkingSelection(
                        model: Fixtures.beta,
                        options: [.low, .high],
                        selected: .low
                    )
                ),
            ]))
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.runtime.queries.isEmpty)
            #expect(await harness.host.interactions.isEmpty)
        }
    }

    @Test
    func theAgentMenuWithoutAFocusedChoiceHostListsTheAgentsAndTouchesNothing() async throws {
        // A host that picks one item or several still cannot show this menu.
        try await withChatHarness(hostCapabilities: [.singleChoice, .multipleChoice]) { harness in
            let outcome = try await harness.controller.chooseProjectAgents()

            #expect(outcome == ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(
                    .agentSelection(
                        agents: [Fixtures.developer, Fixtures.reviewer],
                        selected: Fixtures.developer,
                        manifestPath: AgentProfileStore.agentsManifestURL().path
                    )
                ),
            ]))
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.runtime.queries.isEmpty)
            #expect(await harness.host.interactions.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func theToolMenuWithoutAMultipleChoiceHostShowsTheActiveToolsAndChangesNothing() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["files"]
            let expectedSummary = await controller.activeToolsSummary()
            await harness.clearRecords()

            let outcome = await controller.chooseTools()

            #expect(outcome == ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(.toolSelection(expectedSummary)),
            ]))
            #expect(expectedSummary.groups.map(\.title).contains("Files"))
            // The summary only reads the tool catalog: no operation reaches the
            // runtime (it is only asked which tools it knows), and the selection
            // stays as it was.
            #expect(await harness.runtime.calls.isEmpty)
            let lookups = await harness.runtime.queries
            #expect(!lookups.isEmpty)
            #expect(lookups.allSatisfy { lookup in
                switch lookup {
                case .knownMCPToolDescriptors, .activeToolDescriptors: true
                case .snapshotSession, .taskGraphSnapshot: false
                }
            })
            #expect(await harness.host.interactions.isEmpty)
            #expect(controller.selection.toolKeys == ["files"])
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func theSkillMenusWithoutAMultipleChoiceHostShowTheSkillsAndChangeNothing() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let controller = harness.controller
            let skill = try harness.installSkills("release-review")[0]
            controller.selection.skillIDs = [skill.id]
            await harness.clearRecords()

            let selection = await controller.chooseSkills()
            let uninstall = await controller.chooseSkillsToUninstall()

            #expect(selection == ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(.skillSelection(selected: [skill])),
            ]))
            #expect(uninstall == ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(.skillUninstall),
                .skillSelectionUsage,
            ]))
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.runtime.queries.isEmpty)
            #expect(await harness.host.interactions.isEmpty)
            #expect(controller.selection.skillIDs == [skill.id])
            // The skill is still installed.
            #expect(FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("release-review").path
            ))
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

    @Test
    func aChangedAssociationAndActiveRowAreSavedBeforeTheAgentSwitches() async throws {
        try await withChatHarness(
            catalog: projectAgents,
            hostCapabilities: [.focusedMultipleChoice]
        ) { harness in
            let controller = harness.controller
            let developerID = ChatSessionController.agentChoiceID(Fixtures.developer)
            let reviewerID = ChatSessionController.agentChoiceID(Fixtures.reviewer)
            await harness.host.answerChooseManyWithFocus(
                ChatFocusedChoice(selectedIDs: [developerID, reviewerID], focusedID: reviewerID)
            )

            let outcome = try await controller.chooseProjectAgents()

            #expect(outcome == ChatSelectionOutcome(
                change: .sessionRecreated,
                notices: [.agentSwitched(Fixtures.reviewer)]
            ))
            #expect(await harness.presenter.notices == [
                .projectAgentsAssociated(
                    agents: [Fixtures.developer, Fixtures.reviewer],
                    projectName: harness.workspace.lastPathComponent
                ),
            ])
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: harness.workspace)
                == Set([Fixtures.developer, Fixtures.reviewer]
                    .map(ProjectAgentSelectionStore.selectionKey(for:))))
            // The new session builds its prompt from the saved association.
            #expect(controller.selection.agent == Fixtures.reviewer)
        }
    }

    @Test
    func aCancelledAgentMenuSavesAndChangesNothing() async throws {
        try await withChatHarness(
            catalog: projectAgents,
            hostCapabilities: [.focusedMultipleChoice]
        ) { harness in
            let outcome = try await harness.controller.chooseProjectAgents()

            #expect(outcome == ChatSelectionOutcome(notices: [.selectedAgent(Fixtures.developer)]))
            #expect(!FileManager.default.fileExists(atPath: projectAgentsFile(harness).path))
            #expect(harness.controller.selection.agent == Fixtures.developer)
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func confirmingTheMenuAsItWasOpenedChangesNothing() async throws {
        try await withChatHarness(
            catalog: projectAgents,
            hostCapabilities: [.focusedMultipleChoice]
        ) { harness in
            let developerID = ChatSessionController.agentChoiceID(Fixtures.developer)
            await harness.host.answerChooseManyWithFocus(
                ChatFocusedChoice(selectedIDs: [developerID], focusedID: developerID)
            )

            let outcome = try await harness.controller.chooseProjectAgents()

            #expect(outcome == ChatSelectionOutcome(notices: [.selectedAgent(Fixtures.developer)]))
            #expect(!FileManager.default.fileExists(atPath: projectAgentsFile(harness).path))
            #expect(await harness.runtime.calls.isEmpty)
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
            skills: [AgentProfileSkill(id: "alpha-skill", canonicalName: "alpha-skill")]
        )
        try await withChatHarness(
            catalog: .hosted(agents: [Fixtures.developer, skilled])
        ) { harness in
            let controller = harness.controller
            let alpha = try harness.installSkills("alpha-skill", "beta-skill")[0]

            _ = try await controller.selectAgent(skilled)

            #expect(controller.selection.toolKeys == ["files"])
            #expect(controller.selection.skillIDs == [alpha.id])
            let calls = await harness.runtime.calls
            let created = try #require(calls.first { $0.name == "createSession" }?.digest)
            let allowed = try #require(created.allowedToolNames)
            #expect(allowed.contains("local.readFile"))
            #expect(!allowed.contains("local.exec"))
            // The skills reach the new session before the model loads.
            #expect(calls.contains(
                .updatePromptSkillSelection(skillIDs: [alpha.id], sessionID: controller.sessionID)
            ))
            #expect(await harness.runtime.promptSkills(for: controller.sessionID).map(\.id) == [alpha.id])
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
            controller.selection.skillIDs = [skill.id]
            controller.selection.toolKeys = ["shell", "files"]
            try await harness.startSession(conversation: Fixtures.conversation)
            let sessionID = controller.sessionID
            let initial = try #require(await harness.runtime.configuration(for: sessionID))
            let initialAllowed = try #require(initial.allowedToolNames)
            #expect(initialAllowed.contains("local.exec"))
            // The runtime session holds the skills from its creation on.
            #expect(await harness.runtime.promptSkills(for: sessionID).map(\.id) == [skill.id])

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
            #expect(calls[2] == .updatePromptSkillSelection(skillIDs: [skill.id], sessionID: sessionID))
            #expect(await harness.runtime.promptSkills(for: sessionID).map(\.id) == [skill.id])
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
    func rebuildingAnEmptyConversationAddsNoNotice() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["shell", "files"]
            try await harness.startSession()

            let outcome = await controller.selectTools(keys: ["files"])

            #expect(outcome.change == .sessionRecreated)
            let created = try #require(await harness.runtime.calls.first { $0.name == "createSession" }?.digest)
            #expect(created.historyContents.isEmpty)
            #expect(controller.history.isEmpty)
        }
    }

    @Test
    func aFailingUpdateIsPresentedAndTheSelectionStillReportsTheActiveTools() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["files"]
            try await harness.startSession()
            await harness.runtime.setUpdateSessionOptionsError(
                ScriptedChatRuntime.ScriptedFailure(message: "The backend is gone.")
            )

            let outcome = await controller.selectTools(keys: ["files"])

            #expect(outcome.change == .sessionUpdated)
            #expect(await harness.presenter.notices == [
                .operationFailed(description: "The backend is gone."),
            ])
            guard case .activeTools = try #require(outcome.notices.first) else {
                Issue.record("The closing notice reports the active tools")
                return
            }
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

    @Test
    func aCancelledToolMenuReportsTheActiveToolsAndChangesNothing() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["files"]
            let expectedSummary = await controller.activeToolsSummary()
            await harness.clearRecords()

            let outcome = await controller.chooseTools()

            #expect(outcome == ChatSelectionOutcome(notices: [.activeTools(expectedSummary)]))
            #expect(controller.selection.toolKeys == ["files"])
            #expect(await harness.runtime.calls.isEmpty)
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

            let outcome = await controller.selectSkills(ids: [alpha.id])

            #expect(outcome == ChatSelectionOutcome(change: .sessionUpdated, notices: [.selectedSkills([alpha])]))
            // The prompt, the allowlist, and the history are not touched.
            #expect(await harness.runtime.calls == [
                .updatePromptSkillSelection(skillIDs: [alpha.id], sessionID: sessionID),
            ])
            #expect(controller.selection.skillIDs == [alpha.id])
            #expect(await harness.presenter.states.last?.selection.skillIDs == [alpha.id])

            // The same selection, spelled in the command arguments.
            let all = try await controller.selectSkills(rawSelection: "all")
            #expect(all.notices == [.selectedSkills([alpha, beta])])
            let byName = try await controller.selectSkills(rawSelection: "beta-skill")
            #expect(byName.notices == [.selectedSkills([beta])])
            let none = try await controller.selectSkills(rawSelection: "none")
            #expect(none.notices == [.selectedSkills([])])
            #expect(controller.selection.skillIDs.isEmpty)

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
            await harness.host.answerChooseMany([skills[1].id])
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
            #expect(items.map(\.id) == skills.map(\.id))
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
            #expect(controller.selection.skillIDs == [skill.id])
            #expect(controller.availableSkills().map(\.id) == [skill.id])
            #expect(await harness.runtime.calls == [
                .updatePromptSkillSelection(skillIDs: [skill.id], sessionID: sessionID),
            ])
            #expect(await harness.presenter.states.last?.selection.skillIDs == [skill.id])
        }
    }

    @Test
    func aFailedInstallReportsTheErrorAndTheUsageWithoutTouchingTheSession() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let missing = harness.workspace
                .appendingPathComponent("missing", isDirectory: true)
                .standardizedFileURL.path

            let outcome = await controller.installSkill(source: "./missing")

            #expect(outcome == ChatSelectionOutcome(notices: [
                .operationFailed(description: "No SKILL.md found at \(missing)."),
                .skillSelectionUsage,
            ]))
            #expect(await harness.presenter.notices == [.skillInstallStarted(source: missing)])
            #expect(controller.selection.skillIDs.isEmpty)
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func anInstallSourceThatIsNeitherAGitHubURLNorAPathIsRefused() async throws {
        try await withChatHarness { harness in
            for source in ["release-review", "", "  "] {
                let outcome = await harness.controller.installSkill(source: source)

                #expect(outcome == ChatSelectionOutcome(notices: [
                    .skillInstallSourceRequired,
                    .skillSelectionUsage,
                ]))
            }
            #expect(await harness.presenter.events.isEmpty)
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func uninstallingRemovesTheSkillDeselectsItAndUpdatesTheSession() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller
            let skills = try harness.installSkills("alpha-skill", "beta-skill")
            let alpha = skills[0]
            let beta = skills[1]
            controller.selection.skillIDs = [alpha.id, beta.id]
            await harness.host.answerChooseMany([alpha.id])

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
            #expect(items.map(\.id) == [alpha.id, beta.id])
            #expect(selectedIDs.isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("alpha-skill").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("beta-skill").path
            ))
            #expect(controller.selection.skillIDs == [beta.id])
            #expect(controller.availableSkills().map(\.id) == [beta.id])
            #expect(await harness.runtime.calls == [
                .updatePromptSkillSelection(skillIDs: [beta.id], sessionID: controller.sessionID),
            ])
        }
    }

    @Test
    func uninstallingNothingSaysSoAndACancelledMenuPresentsNothing() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller

            let none = await controller.chooseSkillsToUninstall()
            #expect(none == ChatSelectionOutcome(notices: [.noPromptSkillsInstalled]))

            let skills = try harness.installSkills("alpha-skill")
            let cancelled = await controller.chooseSkillsToUninstall()
            #expect(cancelled == ChatSelectionOutcome())

            await harness.host.answerChooseMany([])
            let empty = await controller.chooseSkillsToUninstall()
            #expect(empty == ChatSelectionOutcome(notices: [.noSkillsSelectedForUninstall]))

            // Nothing was removed or handed to the runtime.
            #expect(FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("alpha-skill").path
            ))
            #expect(controller.availableSkills().map(\.id) == skills.map(\.id))
            #expect(await harness.runtime.calls.isEmpty)
        }
    }
}

// MARK: - Test doubles

/// The scripted host answers from its queues in order, cancels when a queue
/// is empty (except for the workspace access, which it grants), and records
/// every interaction, so the suites can trust what they read from it.
@Suite("Chat session scripted host", .serialized)
struct ChatSessionScriptedHostTests {
    @Test
    func answersComeFromTheQueuesInOrderAndEveryInteractionIsRecorded() async {
        let host = ScriptedChatInteractionHost(
            capabilities: [.singleChoice, .focusedMultipleChoice],
            chooseOne: ["one"],
            chooseMany: [["a", "b"]],
            chooseManyWithFocus: [ChatFocusedChoice(selectedIDs: ["a"], focusedID: "a")],
            readLine: ["typed"],
            workspaceAccess: [false]
        )
        let item = ChatChoiceItem(id: "a", title: "A")
        let request = ChatWorkspaceAccessRequest(
            workspaceURL: URL(fileURLWithPath: "/tmp/project"),
            toolTitles: ["Shell"]
        )

        #expect(host.capabilities == [.singleChoice, .focusedMultipleChoice])
        #expect(await host.chooseOne(title: "One", items: [item], selectedID: nil) == "one")
        #expect(await host.chooseMany(title: "Many", items: [item], selectedIDs: ["a"]) == ["a", "b"])
        #expect(
            await host.chooseManyWithFocus(
                title: "Focus",
                items: [item],
                selectedIDs: [],
                focusedID: "a",
                toggleLabel: "agents",
                confirmLabel: "use agent"
            ) == ChatFocusedChoice(selectedIDs: ["a"], focusedID: "a")
        )
        #expect(await host.readLine(prompt: "Name:") == "typed")
        #expect(await host.requestWorkspaceAccess(request) == false)

        // Empty queues: the operator cancelled, and the workspace is granted.
        #expect(await host.chooseOne(title: "One", items: [], selectedID: nil) == nil)
        #expect(await host.chooseMany(title: "Many", items: [], selectedIDs: []) == nil)
        #expect(await host.readLine(prompt: "Name:") == nil)
        #expect(await host.requestWorkspaceAccess(request))

        // Answers queued later are served in the order they arrive.
        await host.answerChooseOne("later")
        await host.answerChooseOne(nil)
        #expect(await host.chooseOne(title: "One", items: [], selectedID: nil) == "later")
        #expect(await host.chooseOne(title: "One", items: [], selectedID: nil) == nil)

        let interactions = await host.interactions
        #expect(interactions.count == 11)
        #expect(interactions.first == .chooseOne(title: "One", items: [item], selectedID: nil))
        #expect(interactions[2] == .chooseManyWithFocus(
            title: "Focus",
            items: [item],
            selectedIDs: [],
            focusedID: "a",
            toggleLabel: "agents",
            confirmLabel: "use agent"
        ))
        #expect(interactions[3] == .readLine(prompt: "Name:"))
        #expect(interactions[4] == .requestWorkspaceAccess(request))
        await host.clearInteractions()
        #expect(await host.interactions.isEmpty)
    }
}

// MARK: - Texts

/// The texts of the selection notices, spelled out as the terminal wrote them
/// before they moved to `ChatSessionNoticeText`. The expectations are literal
/// strings taken from the terminal chat of that time, not calls to the
/// functions that now delegate to the notice text.
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

    private static let skillTwo = PromptSkill(
        canonicalName: "changelog",
        title: "Changelog",
        summary: "Write the changelog.",
        promptBody: "Body",
        sourceHash: "hash-two"
    )

    // MARK: Models and thinking

    @Test
    func modelNotices() {
        #expect(text(.modelSelected(Fixtures.beta, thinking: nil)) == "Selected model: Beta Model\n")
        #expect(text(.modelSelected(Fixtures.beta, thinking: .high)) == "Selected model: Beta Model (thinking: High)\n")
        #expect(text(.modelUnchanged) == "Model unchanged.\n")
        #expect(text(.noCurrentModel) == "No current model selected. Use /models to choose a model first.\n")
        #expect(text(.thinkingNotSupported(model: Fixtures.alpha)) == "Alpha Model does not support configurable thinking.\n")
        #expect(text(.thinkingUnchanged) == "Thinking unchanged.\n")
    }

    @Test
    func theNonInteractiveModelAndThinkingLists() {
        #expect(
            text(.requiresInteractiveHost(
                .modelSelection(models: [Fixtures.alpha, Fixtures.beta], selectedModelID: "beta-model")
            )) == """

            Available models:
              RemoteAPI:
                1. Alpha Model
                2. Beta Model *

            Model selection requires an interactive terminal.

            """
        )
        #expect(
            text(.requiresInteractiveHost(
                .modelSelection(models: [Fixtures.alpha, Fixtures.beta], selectedModelID: nil)
            )) == "\nAvailable models:\n  RemoteAPI:\n    1. Alpha Model\n    2. Beta Model\n\n"
                + "Model selection requires an interactive terminal.\n"
        )
        #expect(
            text(.requiresInteractiveHost(
                .thinkingSelection(model: Fixtures.beta, options: [.low, .high], selected: .low)
            )) == """

            Thinking levels for Beta Model:
              1. Low thinking *
              2. High thinking

            Thinking selection requires an interactive terminal.

            """
        )
    }

    // MARK: Agents

    @Test
    func agentNoticesAndTheAgentSwitchMessage() {
        let detailed = AgentProfile(
            id: "detailed",
            name: "Detailed",
            role: .reviewer,
            skills: [AgentProfileSkill(id: "s1", canonicalName: "s1")],
            modelBindings: [
                AgentModelBinding(id: "a", modelID: "model-a", thinkingSelection: .high, capability: 5),
                AgentModelBinding(id: "b", modelID: "model-b", capability: 7),
            ],
            defaultModelBindingID: "a"
        )
        #expect(text(.selectedAgent(Fixtures.developer)) == "Selected agent: Developer\n")
        #expect(text(.selectedAgent(nil)) == "Selected agent: unavailable\n")
        #expect(text(.agentSelectionUsage) == "Usage: /agents [list|<agent name>|<number>]\n")
        #expect(
            text(.availableAgents(
                agents: [Fixtures.developer, Fixtures.reviewer, detailed],
                selected: Fixtures.reviewer,
                manifestPath: "/tmp/agents.json"
            )) == "\nAvailable agents:\n"
                + "  1. Developer - General software development; the default agent\n"
                + "  2. Reviewer - /review delegates to it *\n"
                + "  3. Detailed - /review delegates to it · default model: model-a · thinking: High"
                + " · bindings: 2 · skills: 1\n"
                + "\n"
        )
        #expect(
            text(.availableAgents(agents: [], selected: nil, manifestPath: "/tmp/agents.json"))
                == "No agents configured in /tmp/agents.json.\n"
        )
        #expect(
            text(.requiresInteractiveHost(
                .agentSelection(
                    agents: [Fixtures.developer, Fixtures.reviewer],
                    selected: Fixtures.developer,
                    manifestPath: "/tmp/agents.json"
                )
            )) == "Selected agent: Developer\n"
                + "\nAvailable agents:\n"
                + "  1. Developer - General software development; the default agent *\n"
                + "  2. Reviewer - /review delegates to it\n"
                + "\n"
                + "Usage: /agents [list|<agent name>|<number>]\n"
        )
        #expect(
            text(.projectAgentsAssociated(
                agents: [Fixtures.developer, Fixtures.reviewer],
                projectName: "workspace"
            )) == "Project agents for workspace: Developer, Reviewer.\n"
        )
        #expect(
            text(.projectAgentsAssociated(agents: [], projectName: "workspace"))
                == "No agent profile is associated with project workspace; "
                + "the sub-agents tool cannot delegate until some are associated with /agents.\n"
        )
        #expect(
            text(.projectAgentsSaveFailed(description: "disk full"))
                == "ZenCODE: unable to save the project agents: disk full\n"
        )
        // The agent switch no longer says the session was reset: the
        // conversation is kept, the plan and the task graph are not.
        #expect(
            text(.agentSwitched(Fixtures.reviewer))
                == "Switched to agent: Reviewer. Plan and task graph reset; conversation kept.\n"
        )
    }

    // MARK: Tools and skills

    @Test
    func toolNotices() {
        let summary = ChatActiveToolsSummary(groups: [
            ChatActiveToolsSummary.Group(title: "Shell", toolCount: 2),
            ChatActiveToolsSummary.Group(title: "Skills", toolCount: 2),
        ])
        #expect(text(.activeTools(summary)) == "Active tools: Shell (2), Skills (2)\n")
        #expect(text(.activeTools(ChatActiveToolsSummary(groups: []))) == "Active tools: none\n")
        #expect(text(.toolSelectionUsage) == "Usage: /tools [all|none|tool-name|package-name|tool-number|logs]\n")
        #expect(
            text(.requiresInteractiveHost(.toolSelection(summary)))
                == "Active tools: Shell (2), Skills (2)\n"
                + "Usage: /tools [all|none|tool-name|package-name|tool-number|logs]\n"
        )
    }

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
    func skillNotices() {
        let usage = "Usage: /skills [all|none|skill-name|skill-number|install <github-url|local-path>"
            + "|uninstall|<github-url|local-path>]\n"
        #expect(text(.selectedSkills([])) == "Selected skills: none\n")
        #expect(
            text(.selectedSkills([Self.skillOne, Self.skillTwo]))
                == "Selected skills: Release Review, Changelog\n"
        )
        #expect(text(.skillSelectionUsage) == usage)
        #expect(
            text(.skillInstallSourceRequired)
                == "ZenCODE: /skills install requires a GitHub URL or local path.\n"
        )
        #expect(text(.noPromptSkillsInstalled) == "No prompt skills installed by the app.\n")
        #expect(text(.noSkillsSelectedForUninstall) == "No skills selected for uninstall.\n")
        #expect(text(.skillsUninstalled([Self.skillOne])) == "Uninstalled skill: Release Review\n")
        #expect(
            text(.skillsUninstalled([Self.skillOne, Self.skillTwo]))
                == "Uninstalled skills: Release Review, Changelog\n"
        )
        #expect(
            text(.skillInstallStarted(source: "https://github.com/acme/skills"))
                == "Installing skill from https://github.com/acme/skills...\n"
        )
        #expect(text(.skillInstalled(Self.skillOne)) == "Installed and selected skill: Release Review\n")
        #expect(
            text(.requiresInteractiveHost(.skillSelection(selected: [Self.skillOne])))
                == "Selected skills: Release Review\n" + usage
        )
        #expect(
            text(.requiresInteractiveHost(.skillUninstall))
                == "ZenCODE: /skills uninstall requires an interactive terminal.\n"
        )
    }

    // MARK: Workspace and failures

    @Test
    func workspaceAndFailureNotices() {
        let request = ChatWorkspaceAccessRequest(
            workspaceURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            toolTitles: ["Shell", "Files"]
        )
        #expect(
            text(.workspaceAccessDenied(request))
                == "Workspace access was not granted for /tmp/project.\nDisabled tools: Shell, Files.\n"
        )
        #expect(text(.operationFailed(description: "boom")) == "ZenCODE: boom\n")
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
