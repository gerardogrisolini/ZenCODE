//
//  ThinkingConfigurationTests.swift
//  ZenCODECoreTests
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

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
        let selection = ThinkingSelection.openRouterReasoningSelection(
            from: .object(["effort": .string("ultra")])
        )

        #expect(selection == .ultra)
        #expect(selection?.openRouterReasoningPayload["effort"] as? String == "ultra")
        #expect(AgentThinkingSelection.ultra.openRouterReasoningPayload["effort"] as? String == "ultra")
    }
}
