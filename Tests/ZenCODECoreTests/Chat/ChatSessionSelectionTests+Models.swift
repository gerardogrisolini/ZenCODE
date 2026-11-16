//
//  ChatSessionSelectionTests+Models.swift
//  ZenCODE
//
//  The first part of the selection tests: the model and thinking commands
//  (`/models`, `/think`), how a choice is persisted to settings.json, and the
//  model menu on a host without a single-choice capability.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension ChatSessionSelectionTests {
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
}
