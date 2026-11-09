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
    func truncatedInlineCollapsesWhitespaceRunsBeforeTruncating() {
        let text = "  Review\n\n code \t\t and\r\nreport  "
        #expect(ZenCODEAgentProfileSetupRunner.truncatedInline(text, limit: 96) == "Review code and report")
        #expect(ZenCODEAgentProfileSetupRunner.truncatedInline(text, limit: 9) == "Review...")
        #expect(ZenCODEAgentProfileSetupRunner.truncatedInline(" \n\t ", limit: 4).isEmpty)
    }

    @Test
    func directDeepSeekSetupUsesDocumentedCapabilitiesWithoutRenamingIDs() {
        for modelID in ["deepseek-flash", "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            let manifest = ZenCODESetupRunner.remoteModelManifest(
                from: OpenRouterModelInfo(
                    id: modelID, name: modelID, contextLength: nil, pricing: nil,
                    thinkingSupport: .effort(levels: [.medium, .xhigh], defaultSelection: .medium)
                ),
                providerID: "deepseek", providerName: "DeepSeek",
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
                providerID: "custom", providerName: "Other", baseURL: baseURL,
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

    private func metadataPromptModel(
        modelID: String = "deepseek-flash",
        baseURL: String = "https://api.deepseek.com/v1",
        options: [AgentThinkingSelection]? = nil,
        defaultSelection: AgentThinkingSelection? = nil
    ) -> AgentSettingsModelManifest {
        let providerID = "deepseek"
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
    func setupPreparationPreservesCustomAgentsAndRestoresOnlyDeveloper() throws {
        let existingAgents = [
            AgentProfile(
                id: "11111111-1111-1111-1111-111111111111",
                name: "Custom",
                role: .reporter,
                tools: AgentProfileStore.developerToolNames
            )
        ]

        let prepared = ZenCODEAgentProfileSetupRunner.preparedAgentsForSave(existingAgents)
        let names = Set(prepared.map(\.name))
        let developer = try #require(
            prepared.first { $0.role == .developer }
        )

        #expect(names == ["Developer", "Custom"])
        #expect(developer.id == AgentProfileRole.developer.rawValue)
        #expect(developer.tools == AgentProfileStore.developerToolNames)
    }

    @Test
    func setupPreparationKeepsACustomDeveloperWithoutAddingTheSystemOne() {
        let custom = AgentProfile(
            id: "11111111-1111-1111-1111-111111111111",
            name: "Brutta merda",
            role: .developer,
            tools: ["files"]
        )

        let prepared = ZenCODEAgentProfileSetupRunner.preparedAgentsForSave([custom])

        #expect(prepared == [custom])
    }

    @Test
    func setupProfileReplacementPreservesMultipleBindingsAndDefault() {
        let original = AgentProfile(
            id: "developer",
            name: "Developer",
            readOnly: true,
            role: .developer,
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
    func setupDefaultThinkingSelectionFallsBackToModelDefault() {
        let model = setupThinkingModel()

        let selection = ZenCODESetupRunner.setupDefaultThinkingSelection(
            for: model,
            existingSelection: .xhigh
        )

        #expect(selection == .medium)
    }

    @Test
    func setupModelWithMetadataPreservesIdentityAndProvider() {
        let providerID = "deepseek"
        let provider = AgentRemoteProvider(
            id: providerID,
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            modelID: "deepseek-reasoner",
            chatEndpoint: .chatCompletions
        )
        let model = AgentSettingsModelManifest(
            id: "deepseek:deepseek-reasoner",
            kind: .remoteAPI,
            title: "DeepSeek Reasoner",
            llmID: "deepseek:deepseek-reasoner",
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

    private func setupThinkingModel() -> AgentSettingsModelManifest {
        AgentSettingsModelManifest(
            id: "thinking",
            kind: .remoteAPI,
            modelID: "thinking-model",
            providerID: "openrouter",
            provider: AgentRemoteProvider(modelID: "thinking-model"),
            thinkingOptions: [.off, .low, .medium, .high],
            defaultThinkingSelection: .medium
        )
    }
}
