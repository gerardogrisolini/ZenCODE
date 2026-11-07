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

    /// System profile of the organizer role: it is visible to a project that
    /// has no saved selection.
    private static let organizer = AgentProfile(
        id: "organizer",
        name: "Organizer",
        role: .organizer
    )

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
    func organizerDelegatesByRoleInsteadOfListingTheProjectRoster() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])

            let prompt = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer
            ).combinedPrompt

            #expect(prompt.contains("Delegation by role:"))
            #expect(prompt.contains("profileRole"))
            // Without a saved selection the project sees its system profiles.
            #expect(prompt.contains("- organizer: "))
            #expect(prompt.contains("- developer: "))
            #expect(!prompt.contains("- reviewer: "))
            #expect(!prompt.contains("Delegatable agent profiles and model bindings:"))
            #expect(!prompt.contains("- Developer ["))
        }
    }

    @Test
    func organizerListsOnlyTheRolesOfTheProfilesAssociatedWithTheProject() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])
            try ProjectAgentSelectionStore.save(
                agentIDs: [Support.reviewer.id, Support.developer.id],
                workspaceRootURL: workspace
            )

            let prompt = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer
            ).combinedPrompt

            #expect(prompt.contains("Delegation by role:"))
            #expect(prompt.contains("- developer: "))
            #expect(prompt.contains("- reviewer: "))
            #expect(!prompt.contains("- planner: "))
            #expect(!prompt.contains("- reporter: "))
            #expect(!prompt.contains("- organizer: "))
            #expect(!prompt.contains("Delegatable agent profiles and model bindings:"))
        }
    }

    @Test
    func roleDelegationIsAbsentWithoutAgentCreateOrWhenTheModelIsLocked() throws {
        #expect(SystemPromptBuilder.roleDelegationSection(
            allowedToolNames: ["local.readFile"],
            roles: AgentProfileRole.allCases
        ) == nil)
        #expect(SystemPromptBuilder.roleDelegationSection(
            allowedToolNames: [],
            roles: AgentProfileRole.allCases
        ) == nil)
        #expect(SystemPromptBuilder.roleDelegationSection(
            allowedToolNames: nil,
            roles: []
        ) == nil)
        #expect(SystemPromptBuilder.roleDelegationSection(
            allowedToolNames: ["agent.create"],
            roles: [.developer]
        ) != nil)

        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])

            let locked = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                locksModelToSession: true,
                selectedAgentRole: .organizer
            ).combinedPrompt
            #expect(!locked.contains("Delegation by role:"))
            #expect(!locked.contains("Delegatable agent profiles and model bindings:"))

            let withoutAgentCreate = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: ["local.readFile"],
                selectedAgentRole: .organizer
            ).combinedPrompt
            #expect(!withoutAgentCreate.contains("Delegation by role:"))
        }
    }
}
