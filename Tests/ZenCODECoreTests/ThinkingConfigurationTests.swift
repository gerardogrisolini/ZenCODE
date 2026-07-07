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
}
