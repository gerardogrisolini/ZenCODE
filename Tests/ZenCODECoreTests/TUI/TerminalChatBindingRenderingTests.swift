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

        // The table itself carries no title: the "Agent model bindings" heading
        // belongs to the setup flow and the `/bindings` command wrapper, not to
        // the rendered table.
        #expect(rendered.contains("Profile"))
        #expect(rendered.contains("Capability"))
        #expect(rendered.contains("Developer ✱"))
        #expect(rendered.contains("RemoteAPI"))
        #expect(rendered.contains("fast-model"))
        #expect(rendered.contains("5/10"))
        #expect(rendered.contains("★"))
        #expect(rendered.contains("Claude"))
        #expect(rendered.contains("deep-model"))
        #expect(rendered.contains("8/10"))
        #expect(rendered.contains("High"))
        #expect(rendered.contains("no dedicated model bindings"))
        // Provider and Model are now in separate columns.
        #expect(!rendered.contains("RemoteAPI / fast-model"))
        #expect(!rendered.contains("Claude / deep-model"))
        // A horizontal separator is drawn between the two agents.
        #expect(rendered.components(separatedBy: "├").count >= 3)
    }

    /// The provider is shown separately, so the model name must be stripped of
    /// any provider prefix (`remoteapi:<uuid>:name` or `provider:name`).
    @Test
    func bindingRenderingShowsBareModelNameWithoutProviderPrefix() {
        let developer = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(
                    id: "remoteapi:d3eea8e9-eccf-499e-9697-298ede7af8d5:glm-5.2",
                    modelID: "remoteapi:d3eea8e9-eccf-499e-9697-298ede7af8d5:glm-5.2",
                    modelProvider: "Z.ai",
                    capability: 6
                ),
                AgentModelBinding(
                    id: "chatgpt:gpt-5.6-terra",
                    modelID: "chatgpt:gpt-5.6-terra",
                    modelProvider: "ChatGPT",
                    capability: 7
                )
            ],
            defaultModelBindingID: "chatgpt:gpt-5.6-terra"
        )

        let rendered = TerminalChat.renderAgentModelBindings(
            agents: [developer],
            selectedAgent: developer
        )

        // The bare model name is shown in its own Model column.
        #expect(rendered.contains("Z.ai"))
        #expect(rendered.contains("glm-5.2"))
        #expect(rendered.contains("ChatGPT"))
        #expect(rendered.contains("gpt-5.6-terra"))
        // The provider prefix must not leak into the model field.
        #expect(!rendered.contains("remoteapi:"))
        #expect(!rendered.contains("chatgpt:gpt"))
    }

    /// When an agent with no bindings is followed by another agent, a
    /// horizontal separator must still be drawn between the two groups.
    @Test
    func bindingRenderingDrawsSeparatorAfterBindinglessProfile() {
        let builder = AgentProfile(id: "builder", name: "Builder")
        let developer = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(
                    id: "fast",
                    modelID: "fast-model",
                    modelProvider: "RemoteAPI",
                    capability: 5
                )
            ]
        )

        let rendered = TerminalChat.renderAgentModelBindings(
            agents: [builder, developer],
            selectedAgent: developer
        )

        // The bindingless profile must still be separated from the next agent.
        #expect(rendered.components(separatedBy: "├").count >= 3)
    }

    @Test
    func bindingRenderingWithoutAgentsReportsEmptyConfiguration() {
        #expect(
            TerminalChat.renderAgentModelBindings(agents: [], selectedAgent: nil)
                == "No agent model bindings configured.\n"
        )
    }
}
