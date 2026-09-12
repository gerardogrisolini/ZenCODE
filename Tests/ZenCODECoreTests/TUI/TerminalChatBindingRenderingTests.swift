//
//  TerminalChatBindingRenderingTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalChatBindingRenderingTests {
    @Test
    func remoteAPIModelNameCharacterization() {
        let uuid = "d3eea8e9-eccf-499e-9697-298ede7af8d5"
        let cases: [(input: String, expected: String?)] = [
            ("remoteapi:\(uuid):model", "model"),
            ("REMOTEAPI:\(uuid.uppercased()):vendor:model:v2", "vendor:model:v2"),
            (" \tremoteapi:\(uuid): model:v2 \n", " model:v2"),
            ("remoteapi:\(uuid):model:", "model:"),
            ("remoteapi:\(uuid)::", ":"),
            ("remoteapi:\(uuid):", nil),
            ("remoteapi:\(uuid): \n", nil),
            ("remoteapi:\(uuid)", nil),
            ("remoteapi:not-a-uuid:model", nil),
            ("remoteapi::model", nil),
            ("remoteapi:", nil),
            ("chatgpt:model", nil),
            (" model ", nil),
            ("", nil),
            (" \n", nil),
        ]
        for item in cases {
            #expect(TerminalChat.subAgentModelNameStrippingRemoteAPIPrefix(item.input) == item.expected)
            #expect(ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix(item.input) == item.expected)
            #expect(TerminalChat.subAgentModelNameStrippingRemoteAPIPrefix(item.input)
                == ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix(item.input))
        }
    }

    @Test
    func bindingModelNameCharacterization() {
        let uuid = "d3eea8e9-eccf-499e-9697-298ede7af8d5"
        let cases: [(input: String, provider: String?, expected: String)] = [
            ("remoteapi:\(uuid):vendor:model", nil, "vendor:model"),
            ("REMOTEAPI:\(uuid):vendor:model:", "Remote", "vendor:model:"),
            (" \tremoteapi:\(uuid): model \n", nil, " model"),
            ("remoteapi:not-a-uuid:vendor:model", nil, "remoteapi:not-a-uuid:vendor:model"),
            ("remoteapi:not-a-uuid:vendor:model", "Remote", "model"),
            ("provider:vendor:model", nil, "provider:vendor:model"),
            ("provider:vendor:model", "Provider", "model"),
            ("provider:vendor:model", "", "model"),
            ("provider:vendor:model:", "Provider", "provider:vendor:model:"),
            ("provider:vendor:model:", nil, "provider:vendor:model:"),
            ("remoteapi:\(uuid):", "Remote", "remoteapi:\(uuid):"),
            ("remoteapi:\(uuid): \n", "Remote", " \n"),
            ("provider: model \n", "Provider", " model \n"),
            ("provider: model \n", nil, "provider: model \n"),
            (" model ", "Provider", " model "),
            (" model ", nil, " model "),
            ("", nil, ""),
            ("", "Provider", ""),
            (" \n", "Provider", " \n"),
            (":", "Provider", ":"),
        ]
        for item in cases {
            #expect(TerminalChat.strippedModelNameForBinding(item.input, modelProvider: item.provider) == item.expected)
            #expect(ModelNamePresentation.strippedModelNameForBinding(item.input, modelProvider: item.provider) == item.expected)
            #expect(TerminalChat.strippedModelNameForBinding(item.input, modelProvider: item.provider)
                == ModelNamePresentation.strippedModelNameForBinding(item.input, modelProvider: item.provider))
        }
    }

    @Test
    func bindingTablePreservesModelNameColonSemantics() {
        let agent = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(id: "remote", modelID: "REMOTEAPI:d3eea8e9-eccf-499e-9697-298ede7af8d5:vendor:model:", modelProvider: "Remote"),
                AgentModelBinding(id: "scoped", modelID: "provider:vendor:last", modelProvider: "Provider"),
                AgentModelBinding(id: "unscoped", modelID: "unscoped:vendor:whole", modelProvider: nil),
                AgentModelBinding(id: "trailing", modelID: "provider:trailing:", modelProvider: "Provider"),
            ]
        )
        let rendered = TerminalChat.renderAgentModelBindingsTable(
            agents: [agent], selectedAgent: nil, columns: 200, colorsEnabled: false
        )
        #expect(rendered.contains("vendor:model:"))
        #expect(rendered.contains("last"))
        #expect(rendered.contains("unscoped:vendor:whole"))
        #expect(rendered.contains("provider:trailing:"))
        #expect(!rendered.contains("REMOTEAPI:"))
        #expect(!rendered.contains("provider:vendor:last"))
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
        // belongs to the setup flow, not to the rendered table.
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
