//
//  ZenCODEAgentProfileSetupRunnerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/06/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ZenCODEAgentProfileSetupRunnerTests {
    @Test
    func directDeepSeekSetupUsesDocumentedCapabilitiesWithoutRenamingIDs() {
        for modelID in ["deepseek-flash", "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            let manifest = ZenCODESetupRunner.remoteModelManifest(
                from: OpenRouterModelInfo(
                    id: modelID, name: modelID, contextLength: nil, pricing: nil,
                    thinkingSupport: .effort(levels: [.medium, .xhigh], defaultSelection: .medium)
                ),
                providerID: UUID(), providerName: "DeepSeek",
                baseURL: "https://api.deepseek.com/v1", chatEndpoint: .chatCompletions
            )
            #expect(manifest.modelID == modelID)
            #expect(manifest.provider?.modelID == modelID)
            #expect(manifest.thinkingOptions == [.off, .low, .high, .max])
            #expect(manifest.defaultThinkingSelection == .high)
            #expect(manifest.configuredContextWindowLimit == nil)
            let defaults = ZenCODESetupRunner.thinkingSupportDefaultMenuSelection(
                existingOptions: manifest.thinkingOptions
            )
            #expect(defaults == Set([AgentThinkingSelection.off, .low, .high, .max].compactMap {
                AgentThinkingSelection.allCases.firstIndex(of: $0)
            }))
        }
    }

    @Test
    func deepSeekSetupDoesNotInferUnknownOrRoutedModelCapabilities() {
        for modelID in ["deepseek-future", "deepseek-chat", "deepseek-reasoner", "deepseek/deepseek-flash"] {
            #expect(ZenCODESetupRunner.directDeepSeekThinkingSupport(
                modelID: modelID, baseURL: "https://api.deepseek.com"
            ) == nil)
        }
        for baseURL in ["https://openrouter.ai/api/v1", "https://other.example/v1"] {
            let support = ModelThinkingSupport.effort(levels: [.medium, .xhigh], defaultSelection: .medium)
            let manifest = ZenCODESetupRunner.remoteModelManifest(
                from: OpenRouterModelInfo(
                    id: "deepseek-flash", name: "Flash", contextLength: nil,
                    pricing: nil, thinkingSupport: support
                ),
                providerID: UUID(), providerName: "Other", baseURL: baseURL,
                chatEndpoint: .chatCompletions
            )
            #expect(manifest.thinkingOptions == [.off, .medium, .xhigh])
            #expect(manifest.defaultThinkingSelection == .medium)
        }
    }

    @Test(arguments: ["deepseek-flash", "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"])
    func existingDeepSeekMetadataRequiresConfirmationBeforeCapabilityFallback(modelID: String) throws {
        for savedOptions in [nil, []] as [[AgentThinkingSelection]?] {
            let model = metadataPromptModel(modelID: modelID, options: savedOptions)
            for confirmsSupport in [false, true] {
                var levelPromptCount = 0
                let updated = try ZenCODESetupRunner.readModelMetadata(
                    for: model,
                    promptContextWindow: { _, existing in existing },
                    confirmThinkingSupport: { selected in
                        #expect(!selected)
                        return confirmsSupport
                    },
                    selectThinkingLevels: { _, items, selected in
                        levelPromptCount += 1
                        #expect(selected.sorted().map { items[$0].detail } == ["off", "low", "high", "max"])
                        return selected
                    }
                )
                #expect(levelPromptCount == (confirmsSupport ? 1 : 0))
                #expect(updated.thinkingOptions == (confirmsSupport ? [.off, .low, .high, .max] : nil))
                #expect(updated.defaultThinkingSelection == (confirmsSupport ? .high : nil))
                #expect(updated.id == model.id)
                #expect(updated.modelID == modelID)
                #expect(updated.provider == model.provider)
                #expect(updated.configuredContextWindowLimit == model.configuredContextWindowLimit)
                #expect(model.thinkingOptions == nil)
            }
        }
    }

    @Test
    func existingDeepSeekMetadataPreservesExplicitOptionsAndDefaults() throws {
        let cases: [(options: [AgentThinkingSelection], selection: AgentThinkingSelection?)] = [
            ([.off, .low, .medium, .high], .medium),
            ([.off, .high, .max], .off),
            ([.low], .low),
            ([.max], .max),
            ([.off, .low, .high], nil),
        ]
        for item in cases {
            let model = metadataPromptModel(options: item.options, defaultSelection: item.selection)
            let updated = try ZenCODESetupRunner.readModelMetadata(
                for: model,
                promptContextWindow: { _, existing in existing },
                confirmThinkingSupport: { selected in
                    #expect(selected)
                    return true
                },
                selectThinkingLevels: { _, _, selected in
                    #expect(selected == ZenCODESetupRunner.thinkingSupportDefaultMenuSelection(
                        existingOptions: model.thinkingOptions
                    ))
                    return selected
                }
            )
            #expect(updated.thinkingOptions == model.thinkingOptions)
            #expect(updated.defaultThinkingSelection == ZenCODESetupRunner.defaultThinkingSelection(
                existingDefaultSelection: model.defaultThinkingSelection,
                selectedOptions: item.options
            ))
        }
    }

    @Test
    func metadataFallbackLeavesUnknownIDsAndOtherProvidersUnchanged() throws {
        let cases = [
            ("deepseek-future", "https://api.deepseek.com/v1"),
            ("deepseek-flash", "https://openrouter.ai/api/v1"),
            ("deepseek-flash", "https://other.example/v1"),
        ]
        for (modelID, baseURL) in cases {
            for confirmsSupport in [false, true] {
                let model = metadataPromptModel(modelID: modelID, baseURL: baseURL)
                let updated = try ZenCODESetupRunner.readModelMetadata(
                    for: model,
                    promptContextWindow: { _, existing in existing },
                    confirmThinkingSupport: { selected in
                        #expect(!selected)
                        return confirmsSupport
                    },
                    selectThinkingLevels: { _, _, selected in
                        #expect(confirmsSupport)
                        #expect(selected == ZenCODESetupRunner.thinkingSupportDefaultMenuSelection(existingOptions: nil))
                        return selected
                    }
                )
                #expect(updated.thinkingOptions == (confirmsSupport ? [.off, .low, .medium, .high] : nil))
                #expect(updated.defaultThinkingSelection == (confirmsSupport ? .medium : nil))
            }
        }
    }

    private func metadataPromptModel(
        modelID: String = "deepseek-flash",
        baseURL: String = "https://api.deepseek.com/v1",
        options: [AgentThinkingSelection]? = nil,
        defaultSelection: AgentThinkingSelection? = nil
    ) -> AgentSettingsModelManifest {
        let providerID = UUID()
        return AgentSettingsModelManifest(
            id: "saved-model", kind: .remoteAPI, modelID: modelID,
            providerID: providerID,
            provider: AgentRemoteProvider(id: providerID, name: "Saved provider", baseURL: baseURL, modelID: modelID),
            configuredContextWindowLimit: 65536,
            thinkingOptions: options,
            defaultThinkingSelection: defaultSelection
        )
    }

    @Test
    func bindingDisplayTitlePreservesModelNameFormatting() {
        let uuid = "d3eea8e9-eccf-499e-9697-298ede7af8d5"
        let cases: [(modelID: String, provider: String?, expected: String)] = [
            ("remoteapi:\(uuid):vendor:model", nil, "vendor:model"),
            ("REMOTEAPI:\(uuid):vendor:model:", "Remote", "Remote / vendor:model:"),
            (" \tremoteapi:\(uuid): model \n", "Remote", "Remote /  model"),
            ("remoteapi:invalid:vendor:model", nil, "remoteapi:invalid:vendor:model"),
            ("remoteapi:invalid:vendor:model", "Remote", "Remote / model"),
            ("provider:vendor:model", "Provider", "Provider / model"),
            ("provider:vendor:model", nil, "provider:vendor:model"),
            ("provider:vendor:model:", "Provider", "Provider / provider:vendor:model:"),
            ("remoteapi:\(uuid):", "Remote", "Remote / remoteapi:\(uuid):"),
            ("remoteapi:\(uuid): \n", "Remote", "Remote / remoteapi:\(uuid):"),
            ("provider: model \n", "Provider", "Provider /  model"),
            (" model ", nil, "model"),
            ("", nil, ""),
            ("", "Provider", "Provider / "),
            (" \n", nil, ""),
        ]
        for item in cases {
            let binding = AgentModelBinding(id: "unchanged", modelID: item.modelID, modelProvider: item.provider)
            let original = binding
            #expect(ZenCODEAgentProfileSetupRunner.bindingDisplayTitle(binding) == item.expected)
            #expect(binding == original)
            #expect(binding.id == "unchanged")
        }
    }

    @Test
    func setupPreparationPreservesCustomAgentsAndRestoresOnlyDeveloper() throws {
        let existingAgents = [
            AgentProfile(
                id: "11111111-1111-1111-1111-111111111111",
                name: "Custom",
                tools: AgentProfileStore.developerToolNames
            )
        ]

        let prepared = ZenCODEAgentProfileSetupRunner.preparedAgentsForSave(existingAgents)
        let names = Set(prepared.map(\.name))
        let developer = try #require(
            prepared.first { $0.name == AgentProfileStore.developerAgentName }
        )

        #expect(names == ["Developer", "Custom"])
        #expect(developer.tools == AgentProfileStore.developerToolNames)
    }

    @Test
    func setupRecommendedAgentCountMatchesDefaultProfiles() {
        #expect(
            ZenCODEAgentProfileSetupRunner.recommendedAgentCount
                == AgentProfileStore.defaultProfiles().count
        )
    }

    @Test
    func setupAgentDeletionItemsUseTheStandardMultiSelectionLayout() {
        let developer = AgentProfile(
            id: AgentProfileStore.developerAgentID.uuidString,
            name: AgentProfileStore.developerAgentName,
            tools: AgentProfileStore.developerToolNames
        )
        let custom = AgentProfile(
            id: "11111111-1111-1111-1111-111111111111",
            name: "Custom",
            tools: AgentProfileStore.developerToolNames
        )

        let items = ZenCODEAgentProfileSetupRunner.agentDeletionItems([developer, custom])

        #expect(items.map(\.value) == [1])
        #expect(items.map(\.title) == ["Custom"])
        #expect(items.map(\.detail) == [ZenCODEAgentProfileSetupRunner.agentSummary(custom)])
        #expect(items.allSatisfy { $0.groupTitle == nil })
    }

    @Test
    func setupProfileReplacementPreservesMultipleBindingsAndDefault() {
        let original = AgentProfile(
            id: "developer",
            name: "Developer",
            readOnly: true,
            tools: ["shell"],
            modelBindings: [
                AgentModelBinding(id: "fast", modelID: "fast-model", capability: 4),
                AgentModelBinding(
                    id: "deep",
                    modelID: "deep-model",
                    thinkingSelection: .high,
                    capability: 8
                )
            ],
            defaultModelBindingID: "fast"
        )

        let updated = ZenCODEAgentProfileSetupRunner.profile(
            basedOn: original,
            modelBindings: original.modelBindings,
            defaultModelBindingID: "deep"
        )

        #expect(updated.tools == ["shell"])
        #expect(updated.readOnly)
        #expect(updated.modelBindings.count == 2)
        #expect(updated.defaultModelBinding?.id == "deep")
        #expect(updated.defaultModelBinding?.thinkingSelection == .high)
        #expect(ZenCODEAgentProfileSetupRunner.agentModelSummary(updated).contains("2 bindings"))
        #expect(ZenCODEAgentProfileSetupRunner.agentModelSummary(updated).contains("deep-model"))
        #expect(ZenCODEAgentProfileSetupRunner.agentModelSummary(updated).contains("fast-model"))
        #expect(ZenCODEAgentProfileSetupRunner.agentModelSummary(updated).contains("[default] deep-model"))
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
        let skill = PromptSkill(
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
    func instructionEditorCommandUsesPlatformEditorCommand() {
        let command = ZenCODEAgentProfileSetupRunner.instructionEditorCommand()

        #if os(macOS)
        #expect(command.executable == "/usr/bin/open")
        #expect(command.arguments == ["-W", "-t"])
        #else
        let environment = ProcessInfo.processInfo.environment
        let configuredEditor = [environment["VISUAL"], environment["EDITOR"]]
            .compactMap { value -> String? in
                guard let value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return value
            }
            .first ?? "vi"
        let parts = configuredEditor.split(
            separator: " ",
            omittingEmptySubsequences: true
        ).map(String.init)

        #expect(command.executable == (parts.first ?? "vi"))
        #expect(command.arguments == Array(parts.dropFirst()))
        #endif
    }

    @Test
    func instructionEditChoiceItemsOfferKeepOrPlatformEditorForExistingInstructions() {
        let command = ZenCODEAgentProfileSetupRunner.instructionEditorCommand()
        let items = ZenCODEAgentProfileSetupRunner.instructionEditChoiceItems(
            hasExistingInstructions: true
        )

        #expect(items.map(\.value) == [.keep, .editInEditor])
        #expect(items[0].title == "Keep current instructions")
        #expect(items[1].detail?.contains(command.displayText) == true)
    }

    @Test
    func instructionEditChoiceItemsOnlyOfferPlatformEditorForNewInstructions() {
        let editorName = ZenCODEAgentProfileSetupRunner.instructionEditorDisplayName()
        let items = ZenCODEAgentProfileSetupRunner.instructionEditChoiceItems(
            hasExistingInstructions: false
        )

        #expect(items.map(\.value) == [.editInEditor])
        #expect(items.first?.title == "Enter in \(editorName)")
    }

    @Test
    func setupModelMetadataDefaultIndexesSelectOnlyUnconfiguredModels() {
        let missingMetadata = AgentSettingsModelManifest(
            id: "missing-metadata",
            kind: .remoteAPI,
            modelID: "missing-metadata",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "missing-metadata")
        )
        let contextOnly = AgentSettingsModelManifest(
            id: "context-only",
            kind: .remoteAPI,
            modelID: "context-only",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "context-only"),
            configuredContextWindowLimit: 131_072
        )
        let thinkingOnly = AgentSettingsModelManifest(
            id: "thinking-only",
            kind: .remoteAPI,
            modelID: "thinking-only",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "thinking-only"),
            thinkingOptions: [.off, .low, .medium, .high],
            defaultThinkingSelection: .medium
        )

        let indexes = ZenCODESetupRunner.defaultModelMetadataIndexes([
            missingMetadata,
            contextOnly,
            thinkingOnly
        ])

        #expect(indexes == Set([0]))
    }

    @Test
    func setupModelWithMetadataPreservesIdentityAndProvider() {
        let providerID = UUID()
        let provider = AgentRemoteProvider(
            id: providerID,
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            modelID: "deepseek-reasoner",
            chatEndpoint: .chatCompletions
        )
        let model = AgentSettingsModelManifest(
            id: "remoteapi:test:deepseek-reasoner",
            kind: .remoteAPI,
            title: "DeepSeek Reasoner",
            llmID: "remoteapi:test:deepseek-reasoner",
            modelID: "deepseek-reasoner",
            providerID: providerID,
            provider: provider
        )

        let updated = ZenCODESetupRunner.modelWithMetadata(
            model,
            configuredContextWindowLimit: 131_072,
            thinkingOptions: [.off, .low, .medium, .high],
            defaultThinkingSelection: .medium
        )

        #expect(updated.id == model.id)
        #expect(updated.title == model.title)
        #expect(updated.llmID == model.llmID)
        #expect(updated.modelID == model.modelID)
        #expect(updated.providerID == model.providerID)
        #expect(updated.provider == model.provider)
        #expect(updated.configuredContextWindowLimit == 131_072)
        #expect(updated.thinkingOptions == [.off, .low, .medium, .high])
        #expect(updated.defaultThinkingSelection == .medium)
    }

    @Test
    func setupThinkingSupportDefaultsPreserveExistingSelections() {
        let availableOptions: [AgentThinkingSelection] = [.off, .enabled, .low, .medium, .high]

        let indexes = ZenCODESetupRunner.thinkingSupportDefaultMenuSelection(
            availableOptions: availableOptions,
            existingOptions: [.enabled, .high]
        )
        let preservedDefault = ZenCODESetupRunner.defaultThinkingSelection(
            existingDefaultSelection: .high,
            selectedOptions: [.off, .low, .high]
        )
        let fallbackDefault = ZenCODESetupRunner.defaultThinkingSelection(
            existingDefaultSelection: .xhigh,
            selectedOptions: [.off, .low, .medium, .high]
        )

        #expect(indexes == Set([1, 4]))
        #expect(preservedDefault == .high)
        #expect(fallbackDefault == .medium)
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
