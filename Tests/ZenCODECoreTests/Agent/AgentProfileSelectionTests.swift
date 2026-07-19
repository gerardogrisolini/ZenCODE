//
//  AgentConfigurationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

extension AgentConfigurationTests {
    @Test
    func defaultAgentProfilesUseFocusedToolSelections() throws {
        let profiles = Dictionary(
            uniqueKeysWithValues: AgentProfileStore.defaultProfiles().map { ($0.name, $0) }
        )
        let xcodeKey = TerminalToolSelectionCatalog.featurePackageKey(id: "xcode-tools")
        let figmaKey = TerminalToolSelectionCatalog.featurePackageKey(id: "figma-tools")
        let searchKey = TerminalToolSelectionCatalog.featurePackageKey(id: "search-tools")
        let gitKey = TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools")
        let webKey = TerminalToolSelectionCatalog.featurePackageKey(id: "web-tools")
        let featureBuilderKey = TerminalToolSelectionCatalog.featureBuilderKey
        let toolSelectionItems = TerminalChat.toolSelectionItems(
            featureStatuses: SwiftFeatureRuntime.defaultFeatureStatuses()
        )
        let developerProfile = try #require(profiles["Developer"])
        let minimalProfile = try #require(profiles["Minimal"])
        let builderProfile = try #require(profiles["Builder"])
        let xcodeProfile = try #require(profiles["Xcode"])
        let reviewerProfile = try #require(profiles["Reviewer"])
        let reporterProfile = try #require(profiles["Reporter"])
        let plannerProfile = try #require(profiles["Planner"])
        #expect(profiles.count == 7)
        #expect(reviewerProfile.tools == AgentProfileStore.reviewerToolNames)
        #expect(reviewerProfile.instructions?.contains("Reviewer agent") == true)
        #expect(!reviewerProfile.tools.contains("sub-agents"))
        #expect(!reviewerProfile.tools.contains("shell"))
        #expect(reporterProfile.tools == AgentProfileStore.reporterToolNames)
        #expect(reporterProfile.tools == ["files", searchKey, "text", gitKey])
        #expect(reporterProfile.instructions?.contains("Reporter agent") == true)
        let reporterAllowedToolNames = reporterProfile.allowedToolNames()
        #expect(reporterAllowedToolNames.contains("local.writeFile"))
        #expect(reporterAllowedToolNames.contains("git.push"))
        #expect(!reporterAllowedToolNames.contains("local.exec"))
        #expect(!reporterAllowedToolNames.contains("memory.read"))
        #expect(!reporterAllowedToolNames.contains("web.fetch"))
        #expect(!reporterAllowedToolNames.contains("agent.create"))
        #expect(plannerProfile.tools == AgentProfileStore.plannerToolNames)
        #expect(plannerProfile.tools == ["files", searchKey, "text", gitKey, "memory", webKey])
        #expect(plannerProfile.instructions?.contains("Planner agent") == true)
        #expect(!plannerProfile.tools.contains("sub-agents"))
        #expect(!plannerProfile.tools.contains("shell"))
        #expect(!plannerProfile.tools.contains("local.exec"))
        #expect(!plannerProfile.tools.contains("local.readFile"))
        #expect(!plannerProfile.tools.contains("local.writeFile"))
        #expect(plannerProfile.tools.allSatisfy {
            !TerminalToolSelectionCatalog.selectionKeys(for: $0, items: toolSelectionItems).isEmpty
        })

        for profile in profiles.values where profile.name != "Xcode" && profile.name != "Planner" {
            #expect(!profile.tools.contains(xcodeKey))
            #expect(!profile.tools.contains(figmaKey))
            #expect(profile.tools.contains("files"))
            #expect(profile.tools.contains("text"))
        }

        for profile in profiles.values {
            #expect(!profile.tools.contains(featureBuilderKey))
        }

        #expect(developerProfile.tools.contains(webKey))
        #expect(developerProfile.instructions?.contains("Developer agent") == true)
        #expect(developerProfile.instructions?.contains("coordinated workflow") == true)
        #expect(developerProfile.instructions?.contains("session task-workflow policy") == true)
        #expect(developerProfile.instructions?.contains("implementation tasks in parallel") == true)
        #expect(developerProfile.instructions?.contains("mutable scopes do not overlap") == true)
        #expect(builderProfile.tools.contains(webKey))
        #expect(!builderProfile.tools.contains("sub-agents"))
        #expect(builderProfile.instructions?.contains("Builder agent") == true)
        #expect(!minimalProfile.tools.contains(webKey))
        #expect(!minimalProfile.tools.contains("memory"))
        #expect(!minimalProfile.tools.contains("sub-agents"))
        #expect(minimalProfile.tools == AgentProfileStore.minimalToolNames)
        #expect(minimalProfile.instructions?.contains("Minimal agent") == true)
        #expect(xcodeProfile.tools == AgentProfileStore.xcodeToolNames)
        #expect(xcodeProfile.tools == ["shell", "memory", webKey])
        #expect(xcodeProfile.instructions?.contains("Xcode agent") == true)
    }

    @Test
    func agentSelectionDetailsExplainProfileDifferences() throws {
        let profiles = Dictionary(
            uniqueKeysWithValues: AgentProfileStore.defaultProfiles().map { ($0.name, $0) }
        )

        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Developer"])).contains("General software development"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Minimal"])).contains("Minimal tools"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Builder"])).contains("Create, build"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Xcode"])).contains("ACP agent for Xcode"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Reviewer"])).contains("Read-only reviewer"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Reporter"])).contains("evidence-based reports"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Planner"])).contains("Read-only planner"))
        #expect(profiles.count == 7)

        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: [
                "shell",
                TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools"),
                "custom.tool"
            ],
            modelID: "remote-community/custom",
            thinkingSelection: .high
        )
        let customDetail = TerminalChat.agentSelectionDetail(customAgent)

        #expect(customDetail.contains("Tools: shell, git, 1 custom"))
        #expect(customDetail.contains("model: remote-community/custom"))
        #expect(customDetail.contains("thinking: High"))
        #expect(!customDetail.contains("feature:git-tools"))
    }

    @Test
    func agentProfileRoundTripsThinkingSelection() throws {
        let profile = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: ["shell"],
            modelID: "remote-community/custom",
            thinkingSelection: .high
        )
        let normalized = AgentProfileStore.normalizedAgentForSave(profile)
        let data = try JSONEncoder().encode(
            AgentProfileManifest(agents: [normalized])
        )
        let decoded = try JSONDecoder().decode(
            AgentProfileManifest.self,
            from: data
        )

        #expect(normalized.thinkingSelection == .high)
        #expect(decoded.agents.first?.thinkingSelection == .high)
    }

    @Test
    func agentProfileDetailRendersDefaultBindingAndBindingCount() {
        let agent = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(
                    id: "fast",
                    modelID: "fast-model",
                    thinkingSelection: .low,
                    capability: 4
                ),
                AgentModelBinding(
                    id: "deep",
                    modelID: "deep-model",
                    thinkingSelection: .high,
                    capability: 8
                )
            ],
            defaultModelBindingID: "deep"
        )

        let detail = TerminalChat.agentSelectionDetail(agent)

        #expect(detail.contains("default model: deep-model"))
        #expect(detail.contains("thinking: High"))
        #expect(detail.contains("bindings: 2"))
    }

    @Test
    func selectedProfileBindingUsesManualModelOverride() {
        let allowed = AgentSettingsModelManifest(
            id: "allowed",
            kind: .remoteAPI,
            modelID: "allowed-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "allowed-model")
        )
        let blocked = AgentSettingsModelManifest(
            id: "blocked",
            kind: .remoteAPI,
            modelID: "blocked-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "blocked-model")
        )
        let manifest = AgentSettingsManifest(
            models: [allowed, blocked],
            selectedModelID: blocked.id
        )
        let agent = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(modelID: allowed.id, capability: 5)
            ]
        )

        let resolved = TerminalChat.effectiveModelID(
            selectedAgent: agent,
            manualModelIDOverride: blocked.id,
            manifest: manifest
        )

        #expect(resolved == blocked.id)
    }

    @Test
    func modelPickerListsAllConfiguredModelsForBoundProfile() throws {
        let allowed = AgentSettingsModelManifest(
            id: "allowed",
            kind: .remoteAPI,
            modelID: "allowed-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "allowed-model")
        )
        let other = AgentSettingsModelManifest(
            id: "other",
            kind: .remoteAPI,
            modelID: "other-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "other-model")
        )
        let agent = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(modelID: allowed.id, capability: 5)
            ]
        )
        let configuration = try AgentConfiguration(
            hostedModelID: allowed.id,
            agentName: agent.name,
            availableAgents: [agent],
            availableModels: [allowed, other],
            cacheAgentProfiles: false,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let chat = TerminalChat(configuration: configuration, stdinIsTerminal: false)

        #expect(chat.selectableModelManifests().map(\.id) == [allowed.id, other.id])
    }

    @Test
    func selectedProfileBindingRemainsTheDefaultWithoutManualOverride() {
        let allowed = AgentSettingsModelManifest(
            id: "allowed",
            kind: .remoteAPI,
            modelID: "allowed-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "allowed-model")
        )
        let blocked = AgentSettingsModelManifest(
            id: "other",
            kind: .remoteAPI,
            modelID: "other-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "other-model")
        )
        let manifest = AgentSettingsManifest(
            models: [allowed, blocked],
            selectedModelID: blocked.id
        )
        let agent = AgentProfile(
            id: "developer",
            name: "Developer",
            modelBindings: [
                AgentModelBinding(modelID: allowed.id, capability: 5)
            ]
        )

        let resolved = TerminalChat.effectiveModelID(
            selectedAgent: agent,
            manualModelIDOverride: nil,
            manifest: manifest
        )

        #expect(resolved == allowed.id)
    }

    @Test
    func toolSelectionCatalogListsBundledAndGeneratedFeaturePackagesTogether() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "git-tools",
                    source: .bundled,
                    tools: ["git.status", "git.log"]
                ),
                featureStatus(
                    id: "live-git-branch",
                    displayName: "Live Git Branch",
                    source: .generated,
                    tools: ["live.git_current_branch"]
                )
            ]
        )

        #expect(!items.map(\.title).contains("Feature Builder"))
        #expect(items.map(\.title).contains("Git"))
        #expect(items.map(\.title).contains("Live Git Branch"))

        let selectedKeys = try TerminalChat.parseToolSelection(
            "git live-git-branch",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )

        #expect(selectedKeys.contains(TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools")))
        #expect(selectedKeys.contains(TerminalToolSelectionCatalog.featurePackageKey(id: "live-git-branch")))
        #expect(allowedToolNames.contains("git.status"))
        #expect(allowedToolNames.contains("live.git_current_branch"))
    }

    @Test
    func featureBuilderIsIntrinsicToBuilderAgentAndNotSelectable() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "web-tools",
                    source: .bundled,
                    tools: ["web.search"]
                ),
                featureStatus(
                    id: "generated-clock",
                    source: .generated,
                    tools: ["clock.now"]
                )
            ]
        )

        do {
            _ = try TerminalChat.parseToolSelection("feature-builder", items: items)
            Issue.record("Expected feature-builder to be unavailable in /tools.")
        } catch TerminalToolSelectionError.unknownToken(let token) {
            #expect(token == "feature-builder")
        } catch {
            Issue.record("Expected unknown token error, got \(error).")
        }

        let builderAgent = AgentProfile(
            id: AgentProfileStore.builderAgentID.uuidString,
            name: AgentProfileStore.builderAgentName,
            tools: []
        )
        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: ["feature.list", "feature-builder"]
        )
        let builderAllowedToolNames = builderAgent.allowedToolNames()
        let customAllowedToolNames = customAgent.allowedToolNames()

        #expect(builderAllowedToolNames.contains("feature.list"))
        #expect(builderAllowedToolNames.contains("feature.enable"))
        #expect(builderAllowedToolNames.contains("feature.disable"))
        #expect(builderAllowedToolNames.contains("feature.delete"))
        #expect(builderAllowedToolNames.contains("feature.scaffold"))
        #expect(!builderAllowedToolNames.contains("web.search"))
        #expect(!builderAllowedToolNames.contains("clock.now"))
        #expect(!builderAllowedToolNames.contains(SwiftFeatureRuntime.featurePackageToolsAllowedName))
        #expect(customAllowedToolNames.isEmpty)
    }

    @Test
    func appSessionToolOverridesKeepBuilderIntrinsicTools() {
        let builderAgent = AgentProfile(
            id: AgentProfileStore.builderAgentID.uuidString,
            name: AgentProfileStore.builderAgentName,
            tools: []
        )
        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: []
        )

        let builderAllowedToolNames = AgentCoreAppSessionFactory.resolvedAllowedToolNames(
            selectedToolKeys: ["shell"],
            explicitAllowedToolNames: nil,
            selectedAgent: builderAgent
        )
        let customAllowedToolNames = AgentCoreAppSessionFactory.resolvedAllowedToolNames(
            selectedToolKeys: ["shell"],
            explicitAllowedToolNames: nil,
            selectedAgent: customAgent
        )

        #expect(builderAllowedToolNames?.contains("local.exec") == true)
        #expect(builderAllowedToolNames?.contains("feature.list") == true)
        #expect(builderAllowedToolNames?.contains("feature.scaffold") == true)
        #expect(customAllowedToolNames?.contains("local.exec") == true)
        #expect(customAllowedToolNames?.contains("feature.list") == false)
    }

    @Test
    func agentProfileSaveRemovesFeatureBuilderToolReferences() {
        let builderAgent = AgentProfile(
            id: AgentProfileStore.builderAgentID.uuidString,
            name: AgentProfileStore.builderAgentName,
            tools: ["shell", "feature.list", "feature-builder", "shell"]
        )
        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: ["files", TerminalToolSelectionCatalog.featureBuilderKey, "feature.build"]
        )

        let normalizedAgents = AgentProfileStore.normalizedAgentsForSave([
            builderAgent,
            customAgent
        ])
        let normalizedBuilder = normalizedAgents[0]
        let normalizedCustom = normalizedAgents[1]

        #expect(normalizedBuilder.tools == ["shell"])
        #expect(normalizedCustom.tools == ["files"])
    }

    @Test
    func activeToolRenderingHidesIntrinsicFeatureManagementTools() {
        let items = TerminalChat.toolSelectionItems(featureStatuses: [])
        let rendered = TerminalChat.renderActiveTools(
            ["local.exec", "feature.list", "feature.build"],
            items: items,
            selectedKeys: ["shell"]
        )
        let hiddenOnly = TerminalChat.renderActiveTools(
            ["feature.list", "feature.build"],
            items: items,
            selectedKeys: []
        )

        #expect(rendered == "Active tools: Shell (1)\n")
        #expect(hiddenOnly == "Active tools: none\n")
    }
}

@Suite
struct AgentProfileCapabilityTests {
    @Test
    func defaultProfilesHaveNoCapability() {
        let profiles = AgentProfileStore.defaultProfiles()
        #expect(profiles.allSatisfy { $0.capability == nil })
    }

    @Test
    func capabilityClampsToRange() {
        let clamped = AgentProfile(id: "test", name: "Test", modelID: "test", capability: 50)
        #expect(clamped.capability == 10)

        let low = AgentProfile(id: "test", name: "Test", modelID: "test", capability: -3)
        #expect(low.capability == 1)

        let inRange = AgentProfile(id: "test", name: "Test", modelID: "test", capability: 7)
        #expect(inRange.capability == 7)
    }

    @Test
    func capabilityDecodesWithBackwardCompat() throws {
        let json = """
        {"id":"a","name":"Test","tools":[]}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AgentProfile.self, from: json)
        #expect(profile.capability == nil)
        #expect(profile.name == "Test")
    }

    @Test
    func capabilityRoundTripsThroughCodable() throws {
        let profile = AgentProfile(id: "x", name: "Test", modelID: "gpt-4", capability: 8)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: data)
        #expect(decoded.capability == 8)
        #expect(decoded.modelID == "gpt-4")
    }

    @Test
    func modelBindingsKeepCapabilityAndThinkingPerBinding() throws {
        let profile = AgentProfile(
            id: "developer",
            name: "Developer",
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
        #expect(profile.capability == 9)
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

    @Test
    func bindingCapabilityClampsToSharedRange() {
        let high = AgentModelBinding(modelID: "high", capability: 11)
        let low = AgentModelBinding(modelID: "low", capability: -2)

        #expect(high.capability == 10)
        #expect(low.capability == 1)
    }
}

@Suite
struct DelegatableAgentsSectionTests {
    @Test
    func excludesAgentsWithoutModelOrCapability() {
        let agents = [
            AgentProfile(id: "1", name: "WithModel", modelID: "gpt-4", capability: 5),
            AgentProfile(id: "2", name: "NoModel"),
            AgentProfile(id: "3", name: "ModelNoCapability", modelID: "claude"),
        ]
        let section = SystemPromptBuilder.delegatableAgentsSection(
            agents: agents,
            allowedToolNames: nil
        )
        #expect(section != nil)
        #expect(section?.contains("WithModel") == true)
        #expect(section?.contains("NoModel") == false)
        #expect(section?.contains("ModelNoCapability") == false)
    }

    @Test
    func returnsNilWhenNoAgentsHaveCapability() {
        let agents = [
            AgentProfile(id: "1", name: "Bare"),
            AgentProfile(id: "2", name: "ModelOnly", modelID: "gpt"),
        ]
        let section = SystemPromptBuilder.delegatableAgentsSection(
            agents: agents,
            allowedToolNames: nil
        )
        #expect(section == nil)
    }

    @Test
    func returnsNilWhenDelegationNotAvailable() {
        let agents = [
            AgentProfile(id: "1", name: "Capable", modelID: "gpt-4", capability: 5),
        ]
        let section = SystemPromptBuilder.delegatableAgentsSection(
            agents: agents,
            allowedToolNames: ["tasks.create"]
        )
        #expect(section == nil)
    }

    @Test
    func rendersAuthorizedBindingsSortedByCapability() throws {
        let agents = [
            AgentProfile(
                id: "developer",
                name: "Developer",
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
            allowedToolNames: nil
        )
        let rendered = try #require(section)
        let lowIndex = try #require(rendered.range(of: "mini [binding: low] (capability 2/10)"))
        let midIndex = try #require(rendered.range(of: "sonnet [binding: mid] (capability 5/10, default)"))
        let highIndex = try #require(rendered.range(of: "opus [binding: high] (capability 9/10)"))
        #expect(lowIndex.lowerBound < midIndex.lowerBound)
        #expect(midIndex.lowerBound < highIndex.lowerBound)
    }

    @Test
    func rendersEnglishRoleAwareSelectionPolicy() throws {
        let agents = [
            AgentProfile(
                id: "reviewer",
                name: "Reviewer",
                instructions: """
                Reviewer agent. Perform read-only code review. Do not edit files.

                Report findings with file and line references.
                """,
                modelID: "review-model",
                capability: 9
            ),
        ]

        let section = try #require(SystemPromptBuilder.delegatableAgentsSection(
            agents: agents,
            allowedToolNames: nil
        ))

        #expect(section.contains(
            "Delegatable agent profiles and authorized model bindings"
        ))
        #expect(section.contains(
            "Reviewer: Reviewer agent. Perform read-only code review. Do not edit files."
        ))
        #expect(section.contains("review-model (capability 9/10, default)"))
        #expect(!section.contains("Report findings with file and line references."))
        #expect(section.contains(TaskRecord.agentSelectionPolicy))
        #expect(section.contains("model id as `model` or `modelID`"))
        #expect(section.contains("effective tools come from the parent grant"))
        #expect(section.contains("`toolNames` can only narrow that grant"))
    }
}
