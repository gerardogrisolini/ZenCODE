//
//  AgentProfileSelectionTests+Bindings.swift
//  ZenCODE
//
//  Suites covering agent profile model bindings and capabilities, and the
//  delegatable agents section rendered into the system prompt.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct AgentProfileCapabilityTests {
    @Test
    func capabilityDecodesWithBackwardCompat() throws {
        let json = """
        {"id":"a","name":"Test","role":"developer","tools":[]}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AgentProfile.self, from: json)
        #expect(profile.name == "Test")
    }

    @Test
    func modelBindingsKeepCapabilityAndThinkingPerBinding() throws {
        let profile = AgentProfile(
            id: "developer",
            name: "Developer",
            role: .developer,
            modelBindings: [
                AgentModelBinding(
                    id: "balanced",
                    modelID: "model-balanced",
                    modelProvider: "Example",
                    thinkingSelection: .low,
                    capability: 5
                ),
                AgentModelBinding(
                    id: "deep",
                    modelID: "model-deep",
                    modelProvider: "Example",
                    thinkingSelection: .high,
                    capability: 9
                )
            ],
            defaultModelBindingID: "deep"
        )

        #expect(profile.modelBindings.count == 2)
        #expect(profile.defaultModelBinding?.id == "deep")
        #expect(profile.modelID == "model-deep")
        #expect(profile.thinkingSelection == .high)
        #expect(profile.modelBinding(matching: "balanced")?.capability == 5)
        #expect(profile.modelBinding(matching: "model-balanced")?.thinkingSelection == .low)

        let reloaded = try JSONDecoder().decode(
            AgentProfile.self,
            from: JSONEncoder().encode(profile)
        )
        #expect(reloaded == profile)
    }

    @Test
    func bindingIdentifierTakesPrecedenceOverAnotherBindingsModelIdentifier() {
        let profile = AgentProfile(
            id: "developer",
            name: "Developer",
            role: .developer,
            modelBindings: [
                AgentModelBinding(id: "alpha", modelID: "shared-reference", capability: 4),
                AgentModelBinding(id: "shared-reference", modelID: "beta", capability: 8)
            ]
        )

        let resolved = profile.modelBinding(matching: "shared-reference")

        #expect(resolved?.id == "shared-reference")
        #expect(resolved?.modelID == "beta")
    }

    @Test
    func legacySingleModelDecodesAsOneDefaultBinding() throws {
        let data = #"""
        {
          "id": "legacy",
          "name": "Legacy",
          "role": "developer",
          "tools": [],
          "modelID": "legacy-model",
          "modelProvider": "Legacy Provider",
          "thinkingSelection": "high",
          "capability": 8
        }
        """#.data(using: .utf8)!

        let profile = try JSONDecoder().decode(AgentProfile.self, from: data)

        #expect(profile.modelBindings.count == 1)
        #expect(profile.defaultModelBindingID == "legacy-model")
        #expect(profile.defaultModelBinding?.modelID == "legacy-model")
        #expect(profile.defaultModelBinding?.modelProvider == "Legacy Provider")
        #expect(profile.defaultModelBinding?.thinkingSelection == .high)
        #expect(profile.defaultModelBinding?.capability == 8)
    }
}

@Suite
struct DelegatableAgentsSectionTests {
    private static let providerID = "custom"

    private static func model(_ modelID: String) -> AgentSettingsModelManifest {
        AgentSettingsModelManifestFactory.remoteAPIModel(
            title: nil,
            modelID: modelID,
            providerID: providerID,
            providerName: "Test Provider",
            baseURL: "https://tests.example.com/v1",
            chatEndpoint: .chatCompletions,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )
    }

    @Test
    func includesAgentsWithoutBindingsButExcludesBindingsWithoutCapability() {
        let agents = [
            AgentProfile(id: "1", name: "WithModel", role: .developer, modelID: "gpt-4", capability: 5),
            AgentProfile(id: "2", name: "NoModel", role: .developer),
            AgentProfile(id: "3", name: "ModelNoCapability", role: .developer, modelID: "claude"),
        ]
        let section = SystemPromptBuilder.delegatableAgentsSection(
            agents: agents,
            allowedToolNames: nil,
            snapshot: .available(models: [Self.model("gpt-4"), Self.model("claude")])
        )
        #expect(section != nil)
        #expect(section?.contains("WithModel") == true)
        #expect(section?.contains("NoModel") == true)
        #expect(section?.contains("inherits the main session model") == true)
        #expect(section?.contains("ModelNoCapability") == false)
    }

    @Test
    func unboundProfilesRemainDelegatableWithoutACatalog() throws {
        let agents = [
            AgentProfile(
                id: "reviewer",
                name: "Reviewer",
                instructions: "Review only; do not edit files.",
                readOnly: true,
                role: .reviewer,
                tools: ["local.read"]
            ),
            AgentProfile(id: "bound", name: "Unavailable", role: .developer, modelID: "missing", capability: 5),
        ]
        for snapshot: AgentDelegationCatalogSnapshot in [
            .available(models: []),
            .unavailable("settings unavailable"),
        ] {
            let section = try #require(SystemPromptBuilder.delegatableAgentsSection(
                agents: agents,
                allowedToolNames: ["agent.create"],
                snapshot: snapshot
            ))
            #expect(section.contains("Reviewer [read-only; role: reviewer; tools: local.read]: Review only; do not edit files."))
            #expect(section.contains("inherits the main session model"))
            #expect(section.contains("omit `model`"))
            #expect(!section.contains("Unavailable"))
            #expect(!section.contains("Do not call agent.create"))
        }
    }

    @Test
    func rendersAuthorizedBindingsSortedByCapability() throws {
        let agents = [
            AgentProfile(
                id: "developer",
                name: "Developer",
                role: .developer,
                modelBindings: [
                    AgentModelBinding(id: "high", modelID: "opus", capability: 9),
                    AgentModelBinding(id: "low", modelID: "mini", capability: 2),
                    AgentModelBinding(id: "mid", modelID: "sonnet", capability: 5)
                ],
                defaultModelBindingID: "mid"
            ),
        ]
        let section = SystemPromptBuilder.delegatableAgentsSection(
            agents: agents,
            allowedToolNames: nil,
            snapshot: .available(models: [Self.model("opus"), Self.model("mini"), Self.model("sonnet")])
        )
        let rendered = try #require(section)
        let lowIndex = try #require(rendered.range(of: "pass model: binding:low"))
        let midIndex = try #require(rendered.range(of: "pass model: binding:mid"))
        let highIndex = try #require(rendered.range(of: "pass model: binding:high"))
        #expect(lowIndex.lowerBound < midIndex.lowerBound)
        #expect(midIndex.lowerBound < highIndex.lowerBound)
    }
}
