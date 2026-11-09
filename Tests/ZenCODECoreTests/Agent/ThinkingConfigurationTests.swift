//
//  ThinkingConfigurationTests.swift
//  ZenCODECoreTests
//

import Foundation
@testable import ZenCODECore
import Testing

struct ThinkingConfigurationTests {
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
        #expect(AgentThinkingSelection.ultra.openRouterReasoningPayload["effort"] as? String == "ultra")
    }
}
