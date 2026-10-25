//
//  ProjectAgentSelectionPromptTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct ProjectAgentSelectionPromptTests {
    private typealias Support = ProjectAgentSelectionTestSupport

    private static func roster(
        _ profiles: [AgentProfile],
        allowedToolNames: Set<String>? = nil
    ) -> String? {
        SystemPromptBuilder.delegatableAgentsSection(
            agents: profiles,
            allowedToolNames: allowedToolNames,
            models: []
        )
    }

    @Test
    func rosterBuiltFromTheFilteredProfilesListsOnlyAssociatedOnes() throws {
        let associated = ProjectAgentSelectionStore.filter(
            Support.profiles,
            selection: Set([Support.developer, Support.reporter].map(ProjectAgentSelectionStore.selectionKey(for:)))
        )
        let section = try #require(Self.roster(associated))
        #expect(section.contains("- Developer ["))
        #expect(section.contains("- Reporter ["))
        #expect(!section.contains("Reviewer"))
    }

    @Test
    func rosterWithoutASavedSelectionListsOnlyTheSystemProfiles() throws {
        let section = try #require(Self.roster(
            ProjectAgentSelectionStore.filter(Support.profiles, selection: nil)
        ))
        #expect(section.contains("- Developer ["))
        #expect(!section.contains("- Reviewer ["))
        #expect(!section.contains("- Reporter ["))
    }

    @Test
    func noProjectAgentsSectionTellsTheModelNotToDelegate() throws {
        let section = try #require(SystemPromptBuilder.noProjectAgentsSection(allowedToolNames: nil))
        #expect(section.contains("Delegatable agent profiles and model bindings:"))
        #expect(section.contains("No agent profile is associated with this project"))
        #expect(section.contains("Do not call agent.create"))
        #expect(section.contains("/agents"))
        // The misleading provider/binding notice must not be reused.
        #expect(!section.contains("routable model binding"))
        #expect(!section.contains("reconfigured"))

        #expect(SystemPromptBuilder.noProjectAgentsSection(allowedToolNames: ["agent.create"]) != nil)
        #expect(SystemPromptBuilder.noProjectAgentsSection(allowedToolNames: ["tasks.create"]) == nil)
        #expect(SystemPromptBuilder.noProjectAgentsSection(allowedToolNames: []) == nil)
    }

    @Test
    func standalonePromptWithoutASavedSelectionListsOnlyTheSystemProfiles() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles)

            let prompt = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil
            ).combinedPrompt

            #expect(prompt.contains("Delegatable agent profiles and model bindings:"))
            #expect(prompt.contains("- Developer [read-write; role: developer;"))
            #expect(!prompt.contains("- Reviewer ["))
            #expect(!prompt.contains("- Reporter ["))
            #expect(!prompt.contains("No agent profile is associated with this project"))
        }
    }

    @Test
    func standalonePromptWithoutASavedSelectionAndWithoutSystemProfilesDelegatesToNone() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save([Support.reviewer, Support.reporter])

            let prompt = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil
            ).combinedPrompt

            #expect(prompt.contains("No agent profile is associated with this project"))
            #expect(prompt.contains("Do not call agent.create"))
            #expect(!prompt.contains("- Reviewer ["))
            #expect(!prompt.contains("- Reporter ["))
        }
    }

    @Test
    func standalonePromptListsOnlyTheProfilesAssociatedWithTheProject() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles)
            try ProjectAgentSelectionStore.save(
                agentIDs: [Support.reviewer.id],
                workspaceRootURL: workspace
            )

            let prompt = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil
            ).combinedPrompt

            #expect(prompt.contains("- Reviewer ["))
            #expect(!prompt.contains("- Developer ["))
            #expect(!prompt.contains("- Reporter ["))
            #expect(!prompt.contains("No agent profile is associated with this project"))
        }
    }

    @Test
    func standalonePromptReportsNoAssociatedProfileForAnEmptySelection() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles)
            try ProjectAgentSelectionStore.save(agentIDs: [String](), workspaceRootURL: workspace)

            let prompt = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil
            ).combinedPrompt

            #expect(prompt.contains("No agent profile is associated with this project"))
            #expect(prompt.contains("Do not call agent.create"))
            #expect(!prompt.contains("routable model binding"))
            for profile in Support.profiles {
                #expect(!prompt.contains("- \(profile.name) ["))
            }

            // Without agent.create the delegation section is absent altogether.
            let withoutDelegation = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: ["local.readFile"]
            ).combinedPrompt
            #expect(!withoutDelegation.contains("No agent profile is associated with this project"))
            #expect(!withoutDelegation.contains("Delegatable agent profiles"))
        }
    }

    @Test
    func standalonePromptTreatsASavedSelectionOfDeletedProfilesAsEmpty() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles)
            try ProjectAgentSelectionStore.save(
                agentIDs: ["00000000-dead-beef-0000-000000000000"],
                workspaceRootURL: workspace
            )

            let prompt = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil
            ).combinedPrompt

            #expect(prompt.contains("No agent profile is associated with this project"))
        }
    }

    @Test
    func anotherProjectKeepsItsOwnRoster() throws {
        try Support.withTemporaryProject { support, workspace in
            let other = support.deletingLastPathComponent()
                .appendingPathComponent("other-workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try AgentProfileStore.save(Support.profiles)
            try ProjectAgentSelectionStore.save(agentIDs: [String](), workspaceRootURL: workspace)

            let prompt = AgentStandaloneSystemPrompt.promptSections(
                cwd: other.path,
                allowedToolNames: nil
            ).combinedPrompt

            #expect(prompt.contains("- Developer ["))
            #expect(!prompt.contains("No agent profile is associated with this project"))
        }
    }
}
