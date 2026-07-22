//
//  TerminalChatBindingRenderingTests.swift
//  ZenCODE
//

import Testing
@testable import ZenCODECore

@Suite
struct TerminalChatBindingRenderingTests {
    @Test
    func bindingsCommandIsVisibleAndKnown() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)

        #expect(commands.contains("/bindings"))
        #expect(TerminalChat.isKnownSlashCommand("/bindings"))
    }

    @Test
    func bindingRenderingShowsEveryModelAndItsMetadata() {
        let developer = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(
                    id: "fast",
                    modelID: "fast-model",
                    modelProvider: "RemoteAPI",
                    capability: 5
                ),
                AgentModelBinding(
                    id: "deep",
                    modelID: "deep-model",
                    modelProvider: "Claude",
                    thinkingSelection: .high,
                    capability: 8
                )
            ],
            defaultModelBindingID: "deep"
        )
        let minimal = AgentProfile(id: "minimal", name: "Minimal")

        let rendered = TerminalChat.renderAgentModelBindings(
            agents: [developer, minimal],
            selectedAgent: developer
        )

        #expect(rendered.contains("Developer *"))
        #expect(rendered.contains("- RemoteAPI / fast-model · capability: 5/10"))
        #expect(rendered.contains("[default] Claude / deep-model · capability: 8/10 · thinking: High"))
        #expect(rendered.contains("Minimal\n    (no dedicated model bindings)"))
    }
}
