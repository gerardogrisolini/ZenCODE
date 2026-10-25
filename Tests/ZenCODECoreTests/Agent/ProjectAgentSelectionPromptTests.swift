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
    func organizerWithAnEmptySelectionIsToldThatNoAgentIsAssociated() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])
            try ProjectAgentSelectionStore.save(agentIDs: [String](), workspaceRootURL: workspace)

            let prompt = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer
            ).combinedPrompt

            let notice = try #require(SystemPromptBuilder.noProjectAgentsSection(allowedToolNames: nil))
            #expect(prompt.contains(notice))
            #expect(!prompt.contains("Delegation by role:"))
            #expect(!prompt.contains("- developer: "))
        }
    }

    @Test
    func organizerTaskWorkflowPolicyDelegatesByRoleInsteadOfSelectingAProfile() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])

            let organizer = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer
            ).combinedPrompt
            #expect(organizer.contains("Task workflow policy:"))
            #expect(organizer.contains("Delegate by role: in each item set `profileRole`"))
            #expect(organizer.contains(
                "The runtime uses each task's complexity to select the model binding of the delegated role."
            ))
            #expect(!organizer.contains("Select the most suitable agent profile from the delegatable roster"))
            #expect(!organizer.contains("Agent selection policy:"))
            #expect(!organizer.contains(TaskRecord.agentSelectionPolicy))
            #expect(!organizer.contains(TaskRecord.delegationCostPolicy))

            // Any other coordinator keeps the profile-selection wording.
            let developer = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .developer
            ).combinedPrompt
            #expect(developer.contains("Select the most suitable agent profile from the delegatable roster"))
            #expect(developer.contains("Agent selection policy: \(TaskRecord.agentSelectionPolicy)"))
            #expect(developer.contains(TaskRecord.delegationCostPolicy))
            #expect(!developer.contains("Delegate by role:"))
        }
    }

    @Test
    func taskOrchestrationSectionIsUnchangedUnlessTheCoordinatorDelegatesByRole() throws {
        let withDelegation: Set<String> = ["tasks.create", "tasks.list", "tasks.update", "agent.create"]
        let withoutDelegation: Set<String> = ["tasks.create", "tasks.list", "tasks.update"]
        for allowedToolNames in [nil, withDelegation, withoutDelegation] {
            let defaulted = SystemPromptBuilder.taskOrchestrationSection(allowedToolNames: allowedToolNames)
            let explicit = SystemPromptBuilder.taskOrchestrationSection(
                allowedToolNames: allowedToolNames,
                delegatesByRole: false
            )
            #expect(defaulted != nil)
            #expect(defaulted == explicit)
        }
        #expect(SystemPromptBuilder.taskOrchestrationSection(allowedToolNames: ["agent.create"]) == nil)
        #expect(SystemPromptBuilder.taskOrchestrationSection(
            allowedToolNames: ["agent.create"],
            delegatesByRole: true
        ) == nil)

        let byProfile = try #require(SystemPromptBuilder.taskOrchestrationSection(
            allowedToolNames: withDelegation
        ))
        let byRole = try #require(SystemPromptBuilder.taskOrchestrationSection(
            allowedToolNames: withDelegation,
            delegatesByRole: true
        ))
        #expect(byProfile != byRole)
        #expect(byProfile.hasPrefix("Task workflow policy:\n"))
        #expect(byRole.hasPrefix("Task workflow policy:\n"))
        #expect(byProfile.contains("Select the most suitable agent profile from the delegatable roster"))
        #expect(byProfile.contains("Agent selection policy: \(TaskRecord.agentSelectionPolicy)"))
        #expect(byProfile.contains(TaskRecord.delegationCostPolicy))
        #expect(byRole.contains(
            "Delegate by role: in each item set `profileRole` to the role that fits the task type and "
                + "required tools, `workingDirectory` to the project folder, and `taskID`; omit `complexity`, "
                + "because the task's complexity applies, and never pass `profile` or `model`: the runtime "
                + "selects the profile associated with that project and the lowest-capability authorized "
                + "binding that meets the task complexity."
        ))
        #expect(!byRole.contains("Select the most suitable agent profile from the delegatable roster"))
        #expect(!byRole.contains("Agent selection policy:"))
        #expect(!byRole.contains(TaskRecord.delegationCostPolicy))

        // Without agent.create nothing is delegated, so the text is unchanged.
        #expect(
            SystemPromptBuilder.taskOrchestrationSection(
                allowedToolNames: withoutDelegation,
                delegatesByRole: true
            ) == SystemPromptBuilder.taskOrchestrationSection(allowedToolNames: withoutDelegation)
        )
    }

    @Test
    func organizerRolePropagatesToTheTaskWorkflowPolicyOfEveryPromptEntryPoint() throws {
        let allowedToolNames: Set<String> = ["tasks.create", "tasks.list", "tasks.update", "agent.create"]

        let sections = SystemPromptBuilder.standalonePromptSections(
            cwd: "/tmp/role-delegation",
            agentsSection: nil,
            memorySection: nil,
            memoryToolEnabled: false,
            allowedToolNames: allowedToolNames,
            delegatesByRole: true
        )
        #expect(sections.dynamicContext.contains("Delegate by role: in each item set `profileRole`"))
        let defaulted = SystemPromptBuilder.standalonePromptSections(
            cwd: "/tmp/role-delegation",
            agentsSection: nil,
            memorySection: nil,
            memoryToolEnabled: false,
            allowedToolNames: allowedToolNames
        )
        #expect(!defaulted.dynamicContext.contains("Delegate by role:"))
        #expect(defaulted.dynamicContext.contains("Agent selection policy:"))
        #expect(
            SystemPromptBuilder.standalonePrompt(
                cwd: "/tmp/role-delegation",
                agentsSection: nil,
                memorySection: nil,
                memoryToolEnabled: false,
                allowedToolNames: allowedToolNames,
                delegatesByRole: true
            ) == sections.combinedPrompt
        )

        for (selectedAgent, delegatesByRole) in [
            (Self.organizer, true),
            (Support.developer, false)
        ] {
            let withoutCwd = AgentSessionComposition.appProvidedPromptSections(
                "App instructions",
                allowedToolNames: allowedToolNames,
                selectedAgent: selectedAgent
            )
            #expect(
                withoutCwd.dynamicContext.contains("Delegate by role: in each item set `profileRole`")
                    == delegatesByRole
            )
            #expect(
                withoutCwd.dynamicContext.contains("Agent selection policy:") == !delegatesByRole
            )
        }
    }

    @Test
    func rolesWithoutRoleDelegationKeepThePromptUnchanged() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles)

            let omitted = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil
            )
            let developer = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .developer
            )
            let none = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: nil
            )

            #expect(developer == omitted)
            #expect(none == omitted)
            #expect(omitted.combinedPrompt.contains("Delegatable agent profiles and model bindings:"))
            #expect(!omitted.combinedPrompt.contains("Delegation by role:"))
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
    func roleDelegationSectionListsOnlyTheGivenRolesAndTheRequiredFields() throws {
        let section = try #require(SystemPromptBuilder.roleDelegationSection(
            allowedToolNames: nil,
            roles: [.reviewer, .developer]
        ))

        #expect(section.hasPrefix("Delegation by role:\n"))
        #expect(section.contains("You delegate by profile role, never by profile name"))
        #expect(section.contains(
            "\n- reviewer: \(AgentProfileRole.reviewer.summary)\n- developer: \(AgentProfileRole.developer.summary)\n"
        ))
        for role in AgentProfileRole.allCases where role != .reviewer && role != .developer {
            #expect(!section.contains("- \(role.rawValue): "))
        }
        #expect(section.contains("`profileRole`, `complexity` (1-10: \(TaskRecord.complexityRubric))"))
        #expect(section.contains("`workingDirectory`"))
        #expect(section.contains("Omit `complexity` when the item has `taskID`"))
        #expect(section.contains("Never pass `profile` or `model`"))

        let everyRole = try #require(SystemPromptBuilder.roleDelegationSection(
            allowedToolNames: nil,
            roles: AgentProfileRole.allCases
        ))
        for role in AgentProfileRole.allCases {
            #expect(everyRole.contains("- \(role.rawValue): \(role.summary)"))
        }
    }
}
