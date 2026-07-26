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

        let rendered = TerminalChat.renderAgentModelBindingsCard(
            agents: [developer, minimal],
            selectedAgent: developer,
            columns: 120,
            colorsEnabled: false
        )

        #expect(rendered.contains("Agent model bindings"))
        #expect(rendered.contains("Developer ✱"))
        #expect(rendered.contains("· RemoteAPI / fast-model · capability: 5/10"))
        #expect(rendered.contains("★ Claude / deep-model · capability: 8/10 · thinking: High"))
        #expect(rendered.contains("(no dedicated model bindings)"))
        #expect(rendered.contains("★ default binding"))
        #expect(rendered.contains("✱ active agent"))
    }

    /// The card is width-aligned on visible columns, so every row must render the
    /// same length once ANSI sequences are stripped.
    @Test
    func bindingCardRowsShareTheSameVisibleWidth() {
        let developer = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(
                    id: "deep",
                    modelID: "remoteapi:d3eea8e9-eccf-499e-9697-298ede7af8d5:glm-5.2",
                    modelProvider: "Z.ai",
                    thinkingSelection: .max,
                    capability: 6
                )
            ],
            defaultModelBindingID: "deep"
        )

        for columns in [40, 80, 120] {
            let rendered = TerminalChat.renderAgentModelBindingsCard(
                agents: [developer],
                selectedAgent: developer,
                columns: columns,
                colorsEnabled: true
            )
            let widths = Set(
                rendered
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { TerminalANSIText.visibleWidth(String($0)) }
            )
            #expect(widths.count == 1, "columns: \(columns) produced widths \(widths)")
            #expect((widths.first ?? 0) <= columns)
        }
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

        let rendered = TerminalChat.renderAgentModelBindingsCard(
            agents: [developer],
            selectedAgent: developer,
            columns: 120,
            colorsEnabled: false
        )

        // The bare model name is shown alongside the provider.
        #expect(rendered.contains("Z.ai / glm-5.2"))
        #expect(rendered.contains("ChatGPT / gpt-5.6-terra"))
        // The provider prefix must not leak into the model field.
        #expect(!rendered.contains("Z.ai / remoteapi:"))
        #expect(!rendered.contains("ChatGPT / chatgpt:"))

        // The plain summary line used by the setup shares the same behavior.
        let line = TerminalChat.renderModelBindingLine(
            AgentModelBinding(
                id: "remoteapi:abc:claude-opus-5",
                modelID: "remoteapi:abc:claude-opus-5",
                modelProvider: "Anthropic",
                capability: 8
            ),
            defaultBindingID: "remoteapi:abc:claude-opus-5"
        )
        #expect(line.contains("Anthropic / claude-opus-5"))
        #expect(!line.contains("Anthropic / remoteapi:"))
    }

    /// The orange border and the graded capability color are the visual contract
    /// of the card; keep them anchored to the shared identity palette.
    @Test
    func bindingCardUsesOrangeBorderAndGradedCapabilityColors() {
        let agent = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(id: "low", modelID: "low", capability: 2),
                AgentModelBinding(id: "mid", modelID: "mid", capability: 5),
                AgentModelBinding(id: "high", modelID: "high", capability: 9)
            ],
            defaultModelBindingID: "high"
        )

        let rendered = TerminalChat.renderAgentModelBindingsCard(
            agents: [agent],
            selectedAgent: agent,
            columns: 120,
            colorsEnabled: true
        )

        #expect(rendered.contains("\u{1B}[38;5;208m╭─ "))
        #expect(rendered.contains(TerminalChat.BindingsCardPalette.capabilityLow + "2/10"))
        #expect(rendered.contains(TerminalChat.BindingsCardPalette.capabilityMedium + "5/10"))
        #expect(rendered.contains(TerminalChat.BindingsCardPalette.capabilityHigh + "9/10"))
    }

    @Test
    func bindingRenderingWithoutAgentsReportsEmptyConfiguration() {
        #expect(
            TerminalChat.renderAgentModelBindings(agents: [], selectedAgent: nil)
                == "No agent model bindings configured.\n"
        )
    }
}
