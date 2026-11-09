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
        let cases: [(input: String, expected: String?)] = [
            ("openrouter:model", "model"),
            ("OPENROUTER:vendor:model:v2", "vendor:model:v2"),
            // OpenRouter model names may contain ':' themselves: split on the
            // first colon only.
            ("openrouter:deepseek/deepseek-r1:free", "deepseek/deepseek-r1:free"),
            ("google.gemini:gemini-2.5-pro", "gemini-2.5-pro"),
            ("zai-coding-plan:glm-5.2", "glm-5.2"),
            ("custom:local-model", "local-model"),
            (" \topenai: model:v2 \n", " model:v2"),
            ("openai:model:", "model:"),
            ("openai::", ":"),
            ("openai:", nil),
            ("openai: \n", nil),
            ("openai", nil),
            ("not-a-provider:model", nil),
            (":model", nil),
            // Subscription and DS4 ids keep their own presentation.
            ("chatgpt:model", nil),
            ("claude:model", nil),
            ("ds4:model", nil),
            // Pre-v15 ids are no longer recognised.
            ("remoteapi:d3eea8e9-eccf-499e-9697-298ede7af8d5:model", nil),
            (" model ", nil),
            ("", nil),
            (" \n", nil),
        ]
        for item in cases {
            #expect(ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix(item.input) == item.expected)
        }
    }

    @Test
    func bindingModelNameCharacterization() {
        let cases: [(input: String, provider: String?, expected: String)] = [
            ("openrouter:vendor:model", nil, "vendor:model"),
            ("OPENROUTER:vendor:model:", "Remote", "vendor:model:"),
            ("openrouter:deepseek/deepseek-r1:free", "OpenRouter", "deepseek/deepseek-r1:free"),
            ("openrouter:deepseek/deepseek-r1:free", nil, "deepseek/deepseek-r1:free"),
            (" \topenai: model \n", nil, " model"),
            // Known non-remote-API keys are stripped on the first colon, and
            // only when the provider is shown separately.
            ("chatgpt:gpt-5.6-terra", "ChatGPT Subscription", "gpt-5.6-terra"),
            ("chatgpt:gpt-5.6-terra", nil, "chatgpt:gpt-5.6-terra"),
            ("ds4:vendor:model", "DS4 (local)", "vendor:model"),
            ("provider:vendor:model", nil, "provider:vendor:model"),
            ("provider:vendor:model", "Provider", "model"),
            ("provider:vendor:model", "", "model"),
            ("provider:vendor:model:", "Provider", "provider:vendor:model:"),
            ("provider:vendor:model:", nil, "provider:vendor:model:"),
            ("openai:", "Remote", "openai:"),
            ("openai: \n", "Remote", " \n"),
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
            #expect(ModelNamePresentation.strippedModelNameForBinding(item.input, modelProvider: item.provider) == item.expected)
        }
    }

    @Test
    func bindingTablePreservesModelNameColonSemantics() {
        let agent = AgentProfile(
            id: "developer",
            name: "Developer",
            role: .developer,
            modelBindings: [
                AgentModelBinding(id: "remote", modelID: "OPENROUTER:vendor:model:", modelProvider: "Remote"),
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
        #expect(!rendered.contains("OPENROUTER:"))
        #expect(!rendered.contains("provider:vendor:last"))
    }

    @Test
    func bindingRenderingShowsEveryModelAndItsMetadata() {
        let developer = AgentProfile(
            id: "developer",
            name: "Developer",
            role: .developer,
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
        let minimal = AgentProfile(id: "minimal", name: "Minimal", role: .minimal)

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
}
