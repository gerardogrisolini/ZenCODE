//
//  ZenCODEAgentProfileSetupRunnerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/06/26.
//
import Foundation
import ZenCODECore
@testable import ZenCODESetup
import Testing

@Suite
struct ZenCODEAgentProfileSetupRunnerTests {
    @Test
        func setupPreparationPreservesCustomAgentsAndAddsRequiredDefaults() throws {
        let existingAgents = [
            AgentProfile(
                id: AgentProfileStore.defaultAgentID.uuidString,
                name: "Default",
                tools: AgentProfileStore.defaultToolNames
            ),
            AgentProfile(
                id: "11111111-1111-1111-1111-111111111111",
                name: "Custom",
                tools: AgentProfileStore.defaultToolNames
            )
        ]

        let prepared = ZenCODEAgentProfileSetupRunner.preparedAgentsForSave(existingAgents)
        let names = Set(prepared.map(\.name))
        let minimal = try #require(prepared.first { $0.name == "Minimal" })
        let xcode = try #require(prepared.first { $0.name == AgentProfileStore.xcodeAgentName })
        let planner = try #require(prepared.first { $0.name == AgentProfileStore.plannerAgentName })

        #expect(names == ["Default", "Custom", "Minimal", "Builder", "Xcode", "Reviewer", "Planner"])
        #expect(minimal.tools == AgentProfileStore.minimalToolNames)
        #expect(xcode.tools == AgentProfileStore.xcodeToolNames)
        #expect(planner.tools == AgentProfileStore.plannerToolNames)
    }

    @Test
    func setupRecommendedAgentCountMatchesDefaultProfiles() {
        #expect(
            ZenCODEAgentProfileSetupRunner.recommendedAgentCount
                == AgentProfileStore.defaultProfiles().count
        )
    }

    @Test
    func setupDefaultThinkingSelectionKeepsCompatibleExistingValue() {
        let model = setupThinkingModel()

        let selection = ZenCODESetupRunner.setupDefaultThinkingSelection(
            for: model,
            existingSelection: .high
        )

        #expect(selection == .high)
    }

    @Test
    func setupDefaultThinkingSelectionFallsBackToModelDefault() {
        let model = setupThinkingModel()

        let selection = ZenCODESetupRunner.setupDefaultThinkingSelection(
            for: model,
            existingSelection: .xhigh
        )

        #expect(selection == .medium)
    }

    @Test
    func setupDefaultThinkingSelectionSkipsModelsWithoutThinking() {
        let model = AgentSettingsModelManifest(
            id: "plain",
            kind: .remoteAPI,
            modelID: "plain-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "plain-model")
        )

        let selection = ZenCODESetupRunner.setupDefaultThinkingSelection(
            for: model,
            existingSelection: .high
        )

        #expect(selection == nil)
    }

    @Test
    func skillCheckboxItemsPreserveMissingSelectedSkills() {
        let skill = MLXPromptSkill(
            canonicalName: "swift-review",
            title: "Swift Review",
            summary: "Review Swift code.",
            promptBody: "Review the code.",
            sourceHash: "skill-a"
        )

        let items = ZenCODEAgentProfileSetupRunner.skillCheckboxItems(
            availableSkills: [skill],
            selectedSkillIDs: ["skill-a", "missing-skill"]
        )

        #expect(items.map(\.value) == ["skill-a", "missing-skill"])
        #expect(items.last?.detail == "saved skill not currently installed")
    }

    @Test
    func thinkingSelectionItemsUseMenuTitles() {
        let items = ZenCODEAgentProfileSetupRunner.thinkingSelectionItems([.off, .high])

        #expect(items.map(\.value) == [.off, .high])
        #expect(items.map(\.title) == ["Thinking off", "High thinking"])
    }

    @Test
    func modelChoiceItemsExposeNoDedicatedModelChoice() {
        let model = AgentSettingsModelManifest(
            id: "remote",
            kind: .remoteAPI,
            modelID: "remote-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "remote-model")
        )

        let items = ZenCODEAgentProfileSetupRunner.modelChoiceItems(
            models: [model],
            existingModelID: nil
        )

        #expect(items.first?.value == .noDedicatedModel)
        #expect(items.first?.title == "No dedicated model")
        #expect(items.first?.detail?.contains("leave model empty") == true)
        #expect(items.contains { $0.value == .configuredModel(model.id) })
    }

    @Test
    func instructionEditorCommandUsesTextEditOpenCommand() {
        let command = ZenCODEAgentProfileSetupRunner.instructionEditorCommand()

        #expect(command.executable == "/usr/bin/open")
        #expect(command.arguments == ["-W", "-t"])
    }

    @Test
    func instructionEditChoiceItemsOfferKeepOrTextEditForExistingInstructions() {
        let items = ZenCODEAgentProfileSetupRunner.instructionEditChoiceItems(
            hasExistingInstructions: true
        )

        #expect(items.map(\.value) == [.keep, .editInEditor])
        #expect(items[0].title == "Keep current instructions")
        #expect(items[1].detail?.contains("/usr/bin/open -W -t") == true)
    }

    @Test
    func instructionEditChoiceItemsOnlyOfferTextEditForNewInstructions() {
        let items = ZenCODEAgentProfileSetupRunner.instructionEditChoiceItems(
            hasExistingInstructions: false
        )

        #expect(items.map(\.value) == [.editInEditor])
        #expect(items.first?.title == "Enter in TextEdit")
    }

    private func setupThinkingModel() -> AgentSettingsModelManifest {
        AgentSettingsModelManifest(
            id: "thinking",
            kind: .remoteAPI,
            modelID: "thinking-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "thinking-model"),
            thinkingOptions: [.off, .low, .medium, .high],
            defaultThinkingSelection: .medium
        )
    }
}
