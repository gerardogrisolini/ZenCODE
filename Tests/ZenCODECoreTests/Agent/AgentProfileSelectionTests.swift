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
        let defaultProfile = try #require(profiles["Default"])
        let minimalProfile = try #require(profiles["Minimal"])
        let builderProfile = try #require(profiles["Builder"])
                let xcodeProfile = try #require(profiles["Xcode"])
        let reviewerProfile = try #require(profiles["Reviewer"])
        let plannerProfile = try #require(profiles["Planner"])
        #expect(profiles.count == 6)
        #expect(reviewerProfile.tools == AgentProfileStore.reviewerToolNames)
        #expect(reviewerProfile.instructions?.contains("Reviewer agent") == true)
                #expect(!reviewerProfile.tools.contains("sub-agents"))
        #expect(!reviewerProfile.tools.contains("shell"))
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

        #expect(defaultProfile.tools.contains(webKey))
        #expect(defaultProfile.instructions?.contains("General coding agent") == true)
        #expect(defaultProfile.instructions?.contains("coordinated workflow") == true)
        #expect(defaultProfile.instructions?.contains("session task-workflow policy") == true)
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

        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Default"])).contains("General coding"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Minimal"])).contains("Minimal tools"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Builder"])).contains("Create, build"))
                #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Xcode"])).contains("ACP agent for Xcode"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Reviewer"])).contains("Read-only reviewer"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Planner"])).contains("Read-only planner"))
                #expect(profiles.count == 6)

        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: [
                "shell",
                TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools"),
                "custom.tool"
            ],
            modelID: "mlx-community/custom",
            thinkingSelection: .high
        )
        let customDetail = TerminalChat.agentSelectionDetail(customAgent)

        #expect(customDetail.contains("Tools: shell, git, 1 custom"))
        #expect(customDetail.contains("model: mlx-community/custom"))
        #expect(customDetail.contains("thinking: High"))
        #expect(!customDetail.contains("feature:git-tools"))
    }

    @Test
    func agentProfileRoundTripsThinkingSelection() throws {
        let profile = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: ["shell"],
            modelID: "mlx-community/custom",
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
