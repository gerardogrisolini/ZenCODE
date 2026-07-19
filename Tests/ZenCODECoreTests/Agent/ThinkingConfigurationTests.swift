//
//  ThinkingConfigurationTests.swift
//  ZenCODECoreTests
//

import Foundation
@testable import ZenCODECore
import Testing

struct ThinkingConfigurationTests {
    @Test
    func thinkingSelectionMaxAndXHighRemainDistinct() throws {
        let support = ModelThinkingSupport.fromModelMetadata(["reasoning_effort": "max"])?.availableSelections
        let selections = try #require(support)

        #expect(selections == [.off, .max])
        #expect(!selections.contains(.xhigh))
    }

    @Test
    func modelThinkingSupportEffortIncludesMaxInExpectedOrder() {
        let support = ModelThinkingSupport.effort(levels: [.max, .low, .high, .xhigh, .medium])

        #expect(support.availableSelections == [.off, .low, .medium, .high, .xhigh, .max])
    }

    @Test
    func openRouterReasoningPayloadUsesMaxWhenEffortIsMax() {
        let selection = ThinkingSelection.openRouterReasoningSelection(from: .object(["effort": .string("max")]))

        #expect(selection == .max)
        #expect(selection?.openRouterReasoningPayload["effort"] as? String == "max")
    }

    @Test
    func agentSelectionPayloadMapsMaxAndXHighSeparately() {
        let selectionXHigh = AgentThinkingSelection.xhigh
        let selectionMax = AgentThinkingSelection.max

        #expect(selectionXHigh.openRouterReasoningPayload["effort"] as? String == "xhigh")
        #expect(selectionMax.openRouterReasoningPayload["effort"] as? String == "max")
        #expect(selectionXHigh.chatTemplateReasoningEffort == "max")
        #expect(selectionMax.chatTemplateReasoningEffort == "max")
    }

    @Test
    func ultraThinkingSelectionRemainsDistinctOnTheWire() {
        let selection = ThinkingSelection.openRouterReasoningSelection(
            from: .object(["effort": .string("ultra")])
        )

        #expect(selection == .ultra)
        #expect(selection?.openRouterReasoningPayload["effort"] as? String == "ultra")
        #expect(AgentThinkingSelection.ultra.openRouterReasoningPayload["effort"] as? String == "ultra")
    }

    @Test
    func codexGPT56ModelsExposeTheirOwnThinkingLevelsAndDefaults() throws {
        let sol = try #require(CodexAgentModel.availableModels.first { $0.modelID == "gpt-5.6-sol" })
        let terra = try #require(CodexAgentModel.availableModels.first { $0.modelID == "gpt-5.6-terra" })
        let luna = try #require(CodexAgentModel.availableModels.first { $0.modelID == "gpt-5.6-luna" })

        #expect(CodexAgentModel.defaultModelID == "gpt-5.6-terra")
        #expect(sol.contextWindowTokenLimit == 372_000)
        #expect(sol.thinkingSupport.availableSelections == [.off, .low, .medium, .high, .xhigh, .max, .ultra])
        #expect(sol.thinkingSupport.defaultSelection == .low)
        #expect(terra.thinkingSupport.availableSelections == [.off, .low, .medium, .high, .xhigh, .max, .ultra])
        #expect(terra.thinkingSupport.defaultSelection == .medium)
        #expect(luna.thinkingSupport.availableSelections == [.off, .low, .medium, .high, .xhigh, .max])
        #expect(luna.thinkingSupport.defaultSelection == .medium)
    }
}
