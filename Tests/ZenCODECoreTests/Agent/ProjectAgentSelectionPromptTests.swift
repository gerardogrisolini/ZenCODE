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
            snapshot: .available(models: [])
        )
    }

    private static let builder = AgentProfile(
        id: "builder",
        name: "Builder",
        role: .builder
    )

    /// The paragraph that offers a coordinator to have a missing tool built;
    /// `delegation` is the sentence naming how the Builder is selected.
    private static func missingToolParagraph(delegation: String) -> String {
        """
        Developing a missing tool:
        When the work needs a reusable tool that none of your available tools provides, you may have it built instead of stopping or asking the operator to run /feature. \(delegation) In the prompt state the capability, the tool name you expect in a namespace that no existing tool uses (for example `changelog.build`, not `git.changelog`), its inputs and outputs, and every constraint; never ask for credentials to be embedded. Then call agent.wait. A feature that sub-agent builds and enables is exposed to this session automatically: its tools are in your tool list from your next step, and the agent.wait or agent.get result names them, so call them directly without /tools. Do this only for a durable capability; do one-off work with the tools you already have. An installed feature that is merely not selected is not exposed this way: ask the operator to select it with /tools.
        """
    }

    private static let rosterParagraph = missingToolParagraph(
        delegation: "Delegate it with agent.create to a profile listed above whose role is `builder`."
    )

    private static let roleParagraph = missingToolParagraph(
        delegation: "Delegate it with agent.create using `profileRole: \"builder\"`."
    )

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

    @Test
    func rosterWithABuilderEndsWithTheMissingToolParagraph() throws {
        let section = try #require(Self.roster([Support.developer, Self.builder]))

        #expect(section.hasSuffix("an explicit scope.\n\n" + Self.rosterParagraph))
        // Said once, with no role-variant wording.
        #expect(section.components(separatedBy: "Developing a missing tool:").count == 2)
        #expect(!section.contains("profileRole"))
    }

    @Test
    func rosterWithoutABuilderHasNoMissingToolParagraph() throws {
        let section = try #require(Self.roster([Support.developer, Support.reviewer]))

        #expect(!section.contains("Developing a missing tool"))
        #expect(!section.contains("/feature"))
    }

    @Test
    func missingToolParagraphNeedsADelegatableBuilder() throws {
        // A builder whose only binding is not configured is dropped from the
        // roster, so there is nobody to build the tool.
        let unroutableBuilder = AgentProfile(
            id: "builder",
            name: "Builder",
            role: .builder,
            modelID: "missing",
            capability: 5
        )
        let section = try #require(Self.roster([Support.developer, unroutableBuilder]))
        #expect(section.contains("- Developer ["))
        #expect(!section.contains("- Builder ["))
        #expect(!section.contains("Developing a missing tool"))

        let nothingRoutable = try #require(Self.roster([unroutableBuilder]))
        #expect(nothingRoutable.contains("No configured profile currently has a routable model binding"))
        #expect(!nothingRoutable.contains("Developing a missing tool"))

        // Without agent.create there is no roster at all.
        #expect(Self.roster([Self.builder], allowedToolNames: ["local.readFile"]) == nil)
    }

    @Test
    func roleDelegationWithABuilderEndsWithTheRoleVariantOfTheParagraph() throws {
        let section = try #require(SystemPromptBuilder.roleDelegationSection(
            allowedToolNames: nil,
            roles: [.developer, .builder]
        ))

        #expect(section.hasSuffix("and the agent.create result names the chosen profile and model.\n\n" + Self.roleParagraph))
        #expect(section.components(separatedBy: "Developing a missing tool:").count == 2)
        #expect(!section.contains("to a profile listed above"))
    }

    @Test
    func roleDelegationWithoutABuilderHasNoMissingToolParagraph() throws {
        let section = try #require(SystemPromptBuilder.roleDelegationSection(
            allowedToolNames: ["agent.create"],
            roles: [.developer, .reviewer]
        ))

        #expect(!section.contains("Developing a missing tool"))
        #expect(SystemPromptBuilder.roleDelegationSection(
            allowedToolNames: ["local.readFile"],
            roles: [.builder]
        ) == nil)
    }

    @Test
    func standalonePromptOffersTheMissingToolParagraphOnlyWithABuilderInTheProject() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer, Self.builder])

            let roster = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil
            ).combinedPrompt
            #expect(roster.contains(Self.rosterParagraph))

            let byRole = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer
            ).combinedPrompt
            #expect(byRole.contains(Self.roleParagraph))

            // A project associated with no builder never sees the paragraph.
            try ProjectAgentSelectionStore.save(
                agentIDs: [Support.reviewer.id, Support.developer.id],
                workspaceRootURL: workspace
            )
            for role in [nil, AgentProfileRole.organizer] {
                let prompt = AgentStandaloneSystemPrompt.promptSections(
                    cwd: workspace.path,
                    allowedToolNames: nil,
                    selectedAgentRole: role
                ).combinedPrompt
                #expect(prompt.contains("- Reviewer [") || prompt.contains("- reviewer: "))
                #expect(!prompt.contains("Developing a missing tool"))
            }
        }
    }
}
