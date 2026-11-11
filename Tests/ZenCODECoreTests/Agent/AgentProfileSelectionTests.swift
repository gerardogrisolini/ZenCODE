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
        let gitKey = TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools")
        let webKey = TerminalToolSelectionCatalog.featurePackageKey(id: "web-tools")
        let featureBuilderKey = TerminalToolSelectionCatalog.featureBuilderKey
        let unavailableOptionalFeatureStatuses = [
            featureStatus(
                id: "git-tools",
                source: .bundled,
                tools: [],
                enabled: false,
                available: false
            ),
            featureStatus(
                id: "web-tools",
                source: .bundled,
                tools: [],
                enabled: false,
                available: false
            )
        ]
        let toolSelectionItems = ChatSessionController.toolSelectionItems(
            featureStatuses: unavailableOptionalFeatureStatuses
        )
        let developerProfile = try #require(profiles["Developer"])
        let builderProfile = try #require(profiles["Builder"])
        let reviewerProfile = try #require(profiles["Reviewer"])
        let reporterProfile = try #require(profiles["Reporter"])
        let testerProfile = try #require(profiles["Tester"])
        let plannerProfile = try #require(profiles["Planner"])
        #if os(macOS)
        let organizerProfile = try #require(profiles["Organizer"])
        #expect(profiles.count == 7)
        #else
        #expect(profiles["Organizer"] == nil)
        #expect(profiles.count == 6)
        #endif
        #expect(profiles["Xcode"] == nil)
        #expect(reviewerProfile.tools == AgentProfileStore.reviewerToolNames)
        #expect(reviewerProfile.instructions?.contains("Reviewer agent") == true)
        #expect(reviewerProfile.instructions?.contains("simplify the implementation") == true)
        #expect(reviewerProfile.instructions?.contains("reduce lines of code") == true)
        #expect(reviewerProfile.instructions?.contains("eliminate duplicated code") == true)
        #expect(reviewerProfile.readOnly)
        #expect(!reviewerProfile.tools.contains("sub-agents"))
        #expect(!reviewerProfile.tools.contains("shell"))
        #expect(reporterProfile.tools == AgentProfileStore.reporterToolNames)
        #expect(reporterProfile.tools == ["files", "search", "text", gitKey])
        #expect(reporterProfile.instructions?.contains("Reporter agent") == true)
        #expect(reporterProfile.readOnly)
        let reporterAllowedToolNames = reporterProfile.allowedToolNames(
            featureStatuses: unavailableOptionalFeatureStatuses
        )
        #expect(reporterAllowedToolNames.contains("local.readFile"))
        #expect(!reporterAllowedToolNames.contains("local.writeFile"))
        #expect(!reporterAllowedToolNames.contains("local.editFile"))
        // Search is a core group: it expands to the in-process `search.*`
        // tools without any installed feature package.
        #expect(reporterAllowedToolNames.contains("search.glob"))
        #expect(reporterAllowedToolNames.contains("search.grep"))
        #expect(reporterAllowedToolNames.contains("search.locate"))
        // Package selections remain in the profile allowlist, but an
        // uninstalled optional feature contributes no executable tool prefix.
        #expect(reporterAllowedToolNames.contains(gitKey))
        #expect(!reporterAllowedToolNames.contains("git."))
        #expect(!reporterAllowedToolNames.contains("git.push"))
        #expect(!reporterAllowedToolNames.contains("local.exec"))
        #expect(!reporterAllowedToolNames.contains("memory.read"))
        #expect(!reporterAllowedToolNames.contains("web.fetch"))
        #expect(!reporterAllowedToolNames.contains("agent.create"))
        #expect(testerProfile.id == AgentProfileRole.tester.rawValue)
        #expect(testerProfile.name == AgentProfileStore.testerAgentName)
        #expect(testerProfile.role == .tester)
        #expect(testerProfile.isSystemProfile)
        // The tester runs builds and tests through the shell, so it must not
        // be read-only: that would strip `local.exec`.
        #expect(!testerProfile.readOnly)
        #expect(testerProfile.modelBindings.isEmpty)
        #expect(testerProfile.defaultModelBindingID == nil)
        #expect(testerProfile.tools == AgentProfileStore.testerToolNames)
        #expect(testerProfile.tools == ["shell", "files", "search", "text", gitKey])
        #expect(testerProfile.tools.contains("shell"))
        #expect(testerProfile.tools.contains(gitKey))
        #expect(!testerProfile.tools.contains("memory"))
        #expect(!testerProfile.tools.contains("sub-agents"))
        #expect(!testerProfile.tools.contains(webKey))
        #expect(testerProfile.instructions?.contains("Tester agent") == true)
        #expect(testerProfile.instructions?.contains("Do not edit, create, or delete files") == true)
        #expect(testerProfile.instructions?.contains("Do not fix failures") == true)
        let testerAllowedToolNames = testerProfile.allowedToolNames(
            featureStatuses: unavailableOptionalFeatureStatuses
        )
        #expect(testerAllowedToolNames.contains("local.exec"))
        #expect(!testerAllowedToolNames.contains("memory.write"))
        #expect(!testerAllowedToolNames.contains("agent.create"))
        #expect(plannerProfile.tools == AgentProfileStore.plannerToolNames)
        #expect(plannerProfile.tools == ["files", "search", "text", gitKey, "memory", webKey])
        #expect(plannerProfile.instructions?.contains("Planner agent") == true)
        #expect(plannerProfile.readOnly)
        #expect(!plannerProfile.tools.contains("sub-agents"))
        #expect(!plannerProfile.tools.contains("shell"))
        #expect(!plannerProfile.tools.contains("local.exec"))
        #expect(!plannerProfile.tools.contains("local.readFile"))
        #expect(!plannerProfile.tools.contains("local.writeFile"))
        let optionalFeatureKeys = Set([gitKey, webKey])
        #expect(plannerProfile.tools.filter { !optionalFeatureKeys.contains($0) }.allSatisfy {
            !TerminalToolSelectionCatalog.selectionKeys(for: $0, items: toolSelectionItems).isEmpty
        })
        #expect(optionalFeatureKeys.isSubset(of: Set(plannerProfile.tools)))
        #expect(optionalFeatureKeys.allSatisfy { key in
            !toolSelectionItems.contains { $0.key == key }
        })
        let mutatingCoreNames = Set(DirectToolCatalog.coreMutatingDescriptors.map(\.name))
        #expect(
            reviewerProfile.allowedToolNames(
                featureStatuses: unavailableOptionalFeatureStatuses
            ).isDisjoint(with: mutatingCoreNames)
        )
        #expect(reporterAllowedToolNames.isDisjoint(with: mutatingCoreNames))
        #expect(
            plannerProfile.allowedToolNames(
                featureStatuses: unavailableOptionalFeatureStatuses
            ).isDisjoint(with: mutatingCoreNames)
        )

        for profile in profiles.values where !["Planner", "Organizer"].contains(profile.name) {
            #expect(!profile.tools.contains(xcodeKey))
            #expect(!profile.tools.contains(figmaKey))
            #expect(profile.tools.contains("files"))
            #expect(profile.tools.contains("text"))
        }

        for profile in profiles.values {
            #expect(!profile.tools.contains(featureBuilderKey))
        }

        #expect(developerProfile.tools.contains(webKey))
        let legacySearchKey = TerminalToolSelectionCatalog.featurePackageKey(id: "search-tools")
        for name in ["Developer", "Builder", "Reviewer", "Reporter", "Tester", "Planner"] {
            let profile = try #require(profiles[name])
            #expect(profile.tools.contains("search"))
            #expect(!profile.tools.contains(legacySearchKey))
        }
        #expect(developerProfile.instructions?.contains("Developer agent") == true)
        #expect(developerProfile.instructions?.contains("Do not take initiative") == true)
        #expect(developerProfile.instructions?.contains("Ask only when a decision is really needed") == true)
        #expect(developerProfile.instructions?.contains("proceed with the most conservative option") == true)
        #expect(developerProfile.instructions?.contains("always stop and ask the user") == false)
        #expect(developerProfile.instructions?.contains("coordinated workflow") == false)
        #expect(developerProfile.instructions?.contains("implementation tasks in parallel") == false)
        #expect(developerProfile.instructions?.contains("mutable scopes do not overlap") == false)
        #expect(builderProfile.tools.contains(webKey))
        #expect(!builderProfile.tools.contains("sub-agents"))
        #expect(builderProfile.instructions?.contains("Builder agent") == true)
        #if os(macOS)
        let macOSKey = TerminalToolSelectionCatalog.featurePackageKey(id: "macOS")
        #expect(organizerProfile.id == AgentProfileRole.organizer.rawValue)
        #expect(organizerProfile.tools == AgentProfileStore.organizerToolNames)
        #expect(organizerProfile.tools == [macOSKey, "memory", "sub-agents"])
        #expect(!organizerProfile.readOnly)
        #expect(organizerProfile.modelBindings.isEmpty)
        #expect(organizerProfile.defaultModelBindingID == nil)
        #expect(organizerProfile.instructions?.contains("Organizer agent") == true)
        #expect(organizerProfile.instructions?.contains("Daily briefing") == true)
        #expect(organizerProfile.instructions?.contains("Planning") == true)
        #expect(organizerProfile.instructions?.contains("Drafts") == true)
        #expect(organizerProfile.instructions?.contains("Preferences") == true)
        #expect(organizerProfile.instructions?.contains("unvalidated") == true)
        #expect(organizerProfile.instructions?.contains("profileRole") == true)
        #expect(organizerProfile.instructions?.contains("workingDirectory") == true)
        let organizerAllowedToolNames = organizerProfile.allowedToolNames(
            featureStatuses: unavailableOptionalFeatureStatuses
        )
        #expect(organizerAllowedToolNames.contains("memory.write"))
        #expect(organizerAllowedToolNames.contains("agent.create"))
        #expect(!organizerAllowedToolNames.contains("local.readFile"))
        #expect(!organizerAllowedToolNames.contains("local.writeFile"))
        #expect(!organizerAllowedToolNames.contains("local.exec"))
        #endif
    }

    @Test
    func recommendedWorkflowInstructionsArePersistedInAgentsManifest() throws {
        let data = try AgentProfileStore.encodedData(for: AgentProfileStore.defaultProfiles())
        let manifest = try JSONDecoder().decode(AgentProfileManifest.self, from: data)
        let builder = try #require(AgentProfileStore.agent(
            matching: AgentProfileStore.builderAgentName,
            in: manifest.agents
        ))
        let planner = try #require(AgentProfileStore.agent(
            matching: AgentProfileStore.plannerAgentName,
            in: manifest.agents
        ))

        #expect(builder.instructions?.contains("Builder workflow policy:") == true)
        #expect(builder.instructions?.contains("Never embed credentials") == true)
        #expect(planner.instructions?.contains("Planner workflow policy:") == true)
        #expect(planner.instructions?.contains("mandatory brainstorming phase") == true)
    }

    @Test
    func agentProfileRoundTripsThinkingSelection() throws {
        let profile = AgentProfile(
            id: "custom",
            name: "Custom",
            role: .developer,
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
    func agentProfileReadOnlyFlagRoundTripsAndDefaultsForLegacyManifests() throws {
        let profile = AgentProfile(
            id: "read-only",
            name: "Read Only",
            readOnly: true,
            role: .developer,
            tools: ["files"]
        )
        let normalized = AgentProfileStore.normalizedAgentForSave(profile)
        let decoded = try JSONDecoder().decode(
            AgentProfileManifest.self,
            from: JSONEncoder().encode(AgentProfileManifest(agents: [normalized]))
        )
        let legacyProfile = try JSONDecoder().decode(
            AgentProfile.self,
            from: #"{"id":"legacy","name":"Legacy","role":"developer","tools":[]}"#.data(using: .utf8)!
        )

        #expect(normalized.readOnly)
        #expect(decoded.agents.first?.readOnly == true)
        #expect(legacyProfile.readOnly == false)
    }

    @Test
    func readOnlyProfileKeepsOnlyCoreReadDescriptorsAndPreservesNonCoreGrants() {
        let profile = AgentProfile(
            id: "read-only",
            name: "Read Only",
            readOnly: true,
            role: .developer
        )
        let coreNames = Set(DirectToolCatalog.coreDescriptors.map(\.name))
        let coreReadNames = Set(DirectToolCatalog.coreReadDescriptors.map(\.name))
        let nonCoreNames: Set<String> = ["linear.", "external.inspect"]
        let searchNames: Set<String> = ["search.glob", "search.grep", "search.locate"]

        let resolved = profile.resolvedAllowedToolNames(coreNames.union(nonCoreNames))
        let broadGrantResolved = profile.resolvedAllowedToolNames(["local.", "linear."])
        let searchGrantResolved = profile.resolvedAllowedToolNames(["search."])
        let mutableLocalNames = Set(
            DirectToolCatalog.coreMutatingLocalFileAndTextDescriptors.map(\.name)
        )

        #expect(searchNames.isSubset(of: coreReadNames))
        #expect(resolved == coreReadNames.union(nonCoreNames))
        #expect(
            AgentProfile(id: "writable", name: "Writable", role: .developer).resolvedAllowedToolNames(coreNames)
                == coreNames
        )
        #expect(broadGrantResolved.contains("linear."))
        #expect(broadGrantResolved.isDisjoint(with: mutableLocalNames))
        #expect(broadGrantResolved.contains("local.readFile"))
        // `search.` covers only core read tools: a read-only profile keeps them.
        #expect(searchGrantResolved == searchNames)
    }

    @Test
    @ChatSessionActor
    func manualModelOverridePrefersExactProviderBindingOverSharedModelID() {
        let modelID = "deepseek-v4-flash"
        let remoteProviderID = "deepseek"
        let localProviderID = "ds4"
        let remote = AgentSettingsModelManifest(
            id: "\(remoteProviderID):\(modelID)",
            kind: .remoteAPI,
            modelID: modelID,
            providerID: remoteProviderID,
            provider: AgentRemoteProvider(
                id: remoteProviderID,
                name: "DeepSeek",
                baseURL: "https://api.deepseek.com",
                modelID: modelID
            )
        )
        let local = AgentSettingsModelManifest(
            id: "\(localProviderID):\(modelID)",
            kind: .remoteAPI,
            modelID: modelID,
            providerID: localProviderID,
            provider: AgentRemoteProvider(
                id: localProviderID,
                name: "ds4",
                baseURL: "http://127.0.0.1:8000/v1",
                modelID: modelID
            )
        )
        let manifest = AgentSettingsManifest(
            models: [remote, local],
            selectedModelID: remote.id
        )

        let resolved = TerminalChat.effectiveModelID(
            selectedAgent: nil,
            manualModelIDOverride: local.id,
            manifest: manifest
        )

        #expect(resolved == local.id)
    }

    @Test
    func featureBuilderIsIntrinsicToBuilderAgentAndNotSelectable() throws {
        let items = ChatSessionController.toolSelectionItems(
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
            _ = try TerminalToolSelectionCatalog.parseSelection("feature-builder", items: items)
            Issue.record("Expected feature-builder to be unavailable in /tools.")
        } catch TerminalToolSelectionError.unknownToken(let token) {
            #expect(token == "feature-builder")
        } catch {
            Issue.record("Expected unknown token error, got \(error).")
        }

        let builderAgent = AgentProfile(
            id: AgentProfileRole.builder.rawValue,
            name: AgentProfileStore.builderAgentName,
            role: .builder,
            tools: []
        )
        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            role: .developer,
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
    func appSessionToolOverridesCannotRestoreReadOnlyCoreMutators() {
        let profile = AgentProfile(
            id: "read-only",
            name: "Read Only",
            readOnly: true,
            role: .developer
        )
        let rawCompatibilityAlias = "agent.spawn"
        let requestedToolNames = Set(DirectToolCatalog.coreDescriptors.map(\.name))
            .union(["external.inspect", rawCompatibilityAlias])

        let allowedToolNames = AgentCoreAppSessionFactory.resolvedAllowedToolNames(
            selectedToolKeys: nil,
            explicitAllowedToolNames: requestedToolNames,
            selectedAgent: profile
        )

        let expectedToolNames = Set(DirectToolCatalog.coreReadDescriptors.map(\.name))
            .union(["external.inspect", rawCompatibilityAlias])
            .union(PromptSkillToolProvider.toolNames)
        #expect(allowedToolNames == expectedToolNames)
        #expect(
            !DirectToolExecutor.isCoreCoordinationToolAllowed(
                rawCompatibilityAlias,
                allowedToolNames: allowedToolNames
            )
        )
    }

    @Test
    func agentProfileSaveRemovesFeatureBuilderToolReferences() {
        let builderAgent = AgentProfile(
            id: AgentProfileRole.builder.rawValue,
            name: AgentProfileStore.builderAgentName,
            role: .builder,
            tools: ["shell", "feature.list", "feature-builder", "shell"]
        )
        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            role: .developer,
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
}

@Suite
struct AgentProfileCapabilityTests {
    @Test
    func capabilityDecodesWithBackwardCompat() throws {
        let json = """
        {"id":"a","name":"Test","role":"developer","tools":[]}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AgentProfile.self, from: json)
        #expect(profile.capability == nil)
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
            models: [Self.model("gpt-4"), Self.model("claude")]
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
                tools: ["local.readFile"]
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
            #expect(section.contains("Reviewer [read-only; role: reviewer; tools: local.readFile]: Review only; do not edit files."))
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
            models: [Self.model("opus"), Self.model("mini"), Self.model("sonnet")]
        )
        let rendered = try #require(section)
        let lowIndex = try #require(rendered.range(of: "pass model: binding:low"))
        let midIndex = try #require(rendered.range(of: "pass model: binding:mid"))
        let highIndex = try #require(rendered.range(of: "pass model: binding:high"))
        #expect(lowIndex.lowerBound < midIndex.lowerBound)
        #expect(midIndex.lowerBound < highIndex.lowerBound)
    }
}
