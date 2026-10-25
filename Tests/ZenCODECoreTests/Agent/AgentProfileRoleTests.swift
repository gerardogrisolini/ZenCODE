//
//  AgentProfileRoleTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

enum AgentProfileRoleTestSupport {
    static var developer: AgentProfile {
        system(.developer)
    }

    static var systemReviewer: AgentProfile {
        system(.reviewer)
    }

    static var systemPlanner: AgentProfile {
        system(.planner)
    }

    /// Custom profile with the reviewer role and an arbitrary name.
    static let customReviewer = AgentProfile(
        id: "BBBBBBBB-0000-0000-0000-000000000001",
        name: "Brutta merda",
        instructions: "Review the requested change.",
        readOnly: true,
        role: .reviewer,
        tools: ["files"]
    )

    /// Custom profile with the planner role and an unrelated name.
    static let pluto = AgentProfile(
        id: "BBBBBBBB-0000-0000-0000-000000000002",
        name: "Pluto",
        role: .planner,
        tools: ["files"]
    )

    static func system(_ role: AgentProfileRole) -> AgentProfile {
        AgentProfileStore.defaultProfiles().first { $0.id == role.rawValue }!
    }

    /// Writes `json` as the `agents.json` of a throwaway directory and loads it.
    static func loadManifest(_ json: String) throws -> [AgentProfile] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-agent-roles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(AgentProfileStore.manifestFilename)
        try Data(json.utf8).write(to: url)
        return try AgentProfileStore.loadRequiredUnlocked(from: url)
    }

    static func manifest(profile: String) -> String {
        """
        {
          "version": 1,
          "agents": [
            {"id": "developer", "name": "Developer", "role": "developer", "tools": []},
            \(profile)
          ]
        }
        """
    }
}

@Suite
struct AgentProfileRoleTests {
    private typealias Roles = AgentProfileRoleTestSupport
    private typealias ProjectSupport = ProjectAgentSelectionTestSupport

    // MARK: - Roles

    @Test
    func theRoleListIsFixed() {
        #expect(AgentProfileRole.allCases.map(\.rawValue) == [
            "developer", "builder", "minimal", "planner",
            "reviewer", "reporter", "organizer", "promoter",
        ])
        #expect(AgentProfileRole.allCases.map(\.title) == [
            "Developer", "Builder", "Minimal", "Planner",
            "Reviewer", "Reporter", "Organizer", "Promoter",
        ])
        #expect(AgentProfileRole.allCases.allSatisfy { !$0.summary.isEmpty })
        #expect(Set(AgentProfileRole.allCases.map(\.summary)).count == AgentProfileRole.allCases.count)
    }

    @Test
    func onlyTheOrganizerRoleUsesGlobalMemoryAndDelegatesByRole() {
        for role in AgentProfileRole.allCases {
            #expect(role.usesGlobalMemory == (role == .organizer))
            #expect(role.delegatesByRole == (role == .organizer))
        }
    }

    @Test
    func memoryGraphTargetResolvesFromTheProfileRole() {
        let workingDirectory = URL(fileURLWithPath: "/tmp/role-memory", isDirectory: true)

        #expect(
            MemoryGraphTarget.resolved(profileRole: .organizer, workingDirectory: workingDirectory)
                == .global
        )
        #expect(
            MemoryGraphTarget.resolved(profileRole: nil, workingDirectory: workingDirectory)
                == .workspace(workingDirectory)
        )
        for role in AgentProfileRole.allCases where role != .organizer {
            #expect(
                MemoryGraphTarget.resolved(profileRole: role, workingDirectory: workingDirectory)
                    == .workspace(workingDirectory)
            )
        }
    }

    // MARK: - Strict decoding

    @Test
    func profileWithoutARoleMakesTheManifestInvalid() throws {
        let json = Roles.manifest(profile: #"{"id": "custom", "name": "No Role", "tools": []}"#)

        do {
            _ = try Roles.loadManifest(json)
            Issue.record("A profile without a role must make agents.json invalid.")
        } catch let error as AgentProfileStoreError {
            guard case let .invalidFile(_, underlying) = error else {
                Issue.record("Expected invalidFile, got \(error).")
                return
            }
            #expect(underlying as? AgentProfileRoleDecodingError == .missing(profile: "No Role"))
            let message = try #require(error.errorDescription)
            #expect(message.contains(
                "profile 'No Role' is missing the required \"role\" field (one of: "
                    + "developer, builder, minimal, planner, reviewer, reporter, organizer, promoter)."
            ))
        }
    }

    @Test
    func unknownBlankOrNonStringRoleMakesTheManifestInvalid() throws {
        let values: [(json: String, value: String?)] = [
            (#""architect""#, "architect"),
            (#"" Reviewer ""#, " Reviewer "),
            (#""Reviewer""#, "Reviewer"),
            (#""""#, ""),
            ("42", nil),
            ("null", nil),
        ]
        for item in values {
            let json = Roles.manifest(
                profile: #"{"id": "custom", "name": "Custom", "role": \#(item.json), "tools": []}"#
            )
            do {
                _ = try Roles.loadManifest(json)
                Issue.record("role \(item.json) must make agents.json invalid.")
            } catch let error as AgentProfileStoreError {
                guard case let .invalidFile(_, underlying) = error else {
                    Issue.record("Expected invalidFile for role \(item.json), got \(error).")
                    continue
                }
                #expect(
                    underlying as? AgentProfileRoleDecodingError
                        == .invalid(profile: "Custom", value: item.value)
                )
                #expect(error.errorDescription?.contains("has an invalid \"role\" value") == true)
                #expect(error.errorDescription?.contains("one of: developer, builder") == true)
            }
        }
    }

    @Test
    func agentsJSONWithoutRolesIsReportedAsInvalidSoSetupOffersTheRewrite() throws {
        try ProjectSupport.withTemporaryProject { _, _ in
            let url = AgentProfileStore.agentsManifestURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(#"{"version":1,"agents":[{"id":"x","name":"Developer","tools":[]}]}"#.utf8)
                .write(to: url)

            let status = ZenInspector.status(ensureBaseFiles: false)
            guard case let .invalidAgents(_, message) = status else {
                Issue.record("Expected invalidAgents, got \(status).")
                return
            }
            #expect(status.requiresSetup)
            #expect(message.contains("profile 'Developer' is missing the required \"role\" field"))
        }
    }

    @Test
    func everyRoleRoundTripsAndIsAlwaysEncoded() throws {
        let profiles = AgentProfileRole.allCases.map { role in
            AgentProfile(id: "custom-\(role.rawValue)", name: "Custom \(role.title)", role: role)
        }

        let data = try JSONEncoder().encode(
            AgentProfileManifest(agents: AgentProfileStore.normalizedAgentsForSave(profiles))
        )
        let decoded = try JSONDecoder().decode(AgentProfileManifest.self, from: data)

        #expect(decoded.agents == profiles)
        let raw = try #require(String(data: data, encoding: .utf8))
        for role in AgentProfileRole.allCases {
            #expect(raw.contains(#""role":"\#(role.rawValue)""#))
        }
    }

    // MARK: - System profiles

    @Test
    func systemProfilesHaveTheirRoleAsID() {
        let defaults = AgentProfileStore.defaultProfiles()

        for profile in defaults {
            #expect(profile.id == profile.role.rawValue)
            #expect(profile.isSystemProfile)
        }
        #expect(defaults.allSatisfy { !$0.id.hasPrefix("00000000-") })
        #if os(macOS)
        #expect(defaults.map(\.role) == [
            .developer, .builder, .minimal, .reviewer, .reporter, .planner, .organizer, .promoter,
        ])
        #else
        #expect(!defaults.contains { $0.role == .organizer })
        #expect(defaults.count == AgentProfileRole.allCases.count - 1)
        #endif
    }

    @Test
    func aProfileIsASystemProfileExactlyWhenItsIDIsItsRole() {
        #expect(AgentProfile(id: "reviewer", name: "Anything", role: .reviewer).isSystemProfile)
        #expect(AgentProfile(id: " Reviewer ", name: "Anything", role: .reviewer).isSystemProfile)
        #expect(!AgentProfile(id: "reviewer", name: "Reviewer", role: .planner).isSystemProfile)
        #expect(!AgentProfile(id: UUID().uuidString, name: "Developer", role: .developer).isSystemProfile)
        #expect(!Roles.customReviewer.isSystemProfile)
    }

    // MARK: - Role semantics

    @Test
    func onlyTheRoleDeterminesTheKindOfAgent() {
        let namedPlanner = AgentProfile(id: "custom", name: "Planner", role: .developer)
        let plannerIDWithAnotherRole = AgentProfile(id: "planner", name: "Planner", role: .reviewer)

        #expect(!AgentProfileStore.isPlannerAgent(namedPlanner))
        #expect(!AgentProfileStore.isPlannerAgent(plannerIDWithAnotherRole))
        #expect(AgentProfileStore.isReviewerAgent(plannerIDWithAnotherRole))
        #expect(AgentProfileStore.isReviewerAgent(Roles.customReviewer))
        #expect(TerminalChat.isReviewerProfile(Roles.customReviewer))
        #expect(!TerminalChat.isReviewerProfile(namedPlanner))
        #expect(AgentProfileStore.isPlannerAgent(Roles.pluto))
        #expect(AgentProfileStore.isBuilderAgent(AgentProfile(id: "forge", name: "Forge", role: .builder)))
        #expect(!AgentProfileStore.isBuilderAgent(AgentProfile(id: "builder", name: "Builder", role: .minimal)))
        #expect(!AgentProfileStore.isBuilderAgent(nil))
    }

    @Test
    func customPlannerForcesReadOnlyCoreToolsAndCustomBuilderGetsFeatureTools() {
        let coreNames = Set(DirectToolCatalog.coreDescriptors.map(\.name))
        let coreReadNames = Set(DirectToolCatalog.coreReadDescriptors.map(\.name))
        let customPlanner = AgentProfile(id: "pluto", name: "Pluto", role: .planner)
        let customBuilder = AgentProfile(id: "forge", name: "Forge", role: .builder, tools: [])
        let namedBuilder = AgentProfile(id: "custom", name: "Builder", role: .developer, tools: [])
        let namedPlanner = AgentProfile(id: "custom", name: "Planner", role: .developer)

        #expect(customPlanner.resolvedAllowedToolNames(coreNames) == coreReadNames)
        #expect(namedPlanner.resolvedAllowedToolNames(coreNames) == coreNames)

        let builderTools = customBuilder.allowedToolNames()
        #expect(AgentProfileStore.featureManagementToolNames.isSubset(of: builderTools))
        #expect(builderTools.contains("feature.scaffold"))
        #expect(namedBuilder.allowedToolNames().isDisjoint(with: AgentProfileStore.featureManagementToolNames))
    }

    // MARK: - Preservation

    @Test
    func profileReconstructionsPreserveTheRole() {
        let planner = AgentProfile(
            id: "pluto",
            name: "Pluto",
            readOnly: true,
            role: .planner,
            tools: ["files"],
            modelBindings: [AgentModelBinding(id: "fast", modelID: "fast-model", capability: 4)]
        )
        let promoter = AgentProfile(id: "herald", name: "Herald", role: .promoter)

        let normalized = AgentProfileStore.normalizedAgentForSave(planner)
        let reconciled = AgentProfileBindingReconciler.reconciledAgents(
            [planner, promoter],
            models: []
        )
        let replaced = ZenCODEAgentProfileSetupRunner.profile(
            basedOn: planner,
            modelBindings: [],
            defaultModelBindingID: nil
        )

        #expect(normalized.role == .planner)
        #expect(reconciled.map(\.role) == [.planner, .promoter])
        #expect(replaced.role == .planner)
        #expect(
            ZenCODEAgentProfileSetupRunner.preparedAgentsForSave([planner, promoter]).map(\.role)
                == [.developer, .planner, .promoter]
        )
    }

    // MARK: - Default developer

    @Test
    func defaultDeveloperIsTheSystemDeveloperThenTheFirstDeveloperInManifestOrder() throws {
        let first = AgentProfile(id: "first", name: "First", role: .developer)
        let second = AgentProfile(id: "second", name: "Second", role: .developer)
        let namedDeveloper = AgentProfile(id: "named", name: "Developer", role: .reviewer)

        #expect(
            try AgentProfileStore.developerProfile(in: [namedDeveloper, first, Roles.developer, second])
                == Roles.developer
        )
        #expect(try AgentProfileStore.developerProfile(in: [namedDeveloper, second, first]) == second)

        do {
            _ = try AgentProfileStore.developerProfile(in: [namedDeveloper, Roles.systemReviewer])
            Issue.record("A manifest without the developer role has no default developer.")
        } catch let error as AgentProfileStoreError {
            #expect(error.errorDescription?.contains("does not contain an agent with the developer role") == true)
        }
    }

    @Test
    func setupRestoresTheSystemDeveloperOnlyWithoutADeveloperRoleAndProtectsTheDefaultOne() {
        let first = AgentProfile(id: "first", name: "First", role: .developer)
        let second = AgentProfile(id: "second", name: "Second", role: .developer)

        #expect(ZenCODEAgentProfileSetupRunner.ensureDeveloperAgent(in: [first, second]) == [first, second])
        #expect(
            ZenCODEAgentProfileSetupRunner.ensureDeveloperAgent(in: [Roles.pluto]).map(\.id)
                == ["developer", Roles.pluto.id]
        )

        // The default developer cannot be deleted; other developers can.
        let agents = [first, second, Roles.developer, Roles.pluto]
        #expect(ZenCODEAgentProfileSetupRunner.agentDeletionItems(agents).map(\.value) == [0, 1, 3])
        #expect(ZenCODEAgentProfileSetupRunner.agentDeletionItems([first, second]).map(\.value) == [1])
    }

    // MARK: - Candidate resolution

    @Test
    func roleProfilesListEveryProfileWithTheRoleInOrder() {
        let profiles = [Roles.developer, Roles.systemReviewer, Roles.customReviewer, Roles.pluto]

        #expect(AgentProfileStore.roleProfiles(.reviewer, in: profiles) == [Roles.systemReviewer, Roles.customReviewer])
        #expect(AgentProfileStore.roleProfiles(.planner, in: profiles) == [Roles.pluto])
        #expect(AgentProfileStore.roleProfiles(.builder, in: profiles).isEmpty)
    }

    @Test
    func roleDelegationCandidatesAreTheVisibleProfilesWithTheRole() {
        let profiles = [Roles.developer, Roles.systemReviewer, Roles.customReviewer, Roles.pluto]

        // No saved selection: only the system profiles are visible.
        #expect(
            AgentProfileStore.roleDelegationCandidates(.reviewer, in: profiles, projectSelection: nil)
                == [Roles.systemReviewer]
        )
        // Saved selection: exactly the saved profiles.
        #expect(
            AgentProfileStore.roleDelegationCandidates(
                .reviewer,
                in: profiles,
                projectSelection: [Roles.developer.id, Roles.customReviewer.id.lowercased()]
            ) == [Roles.customReviewer]
        )
        #expect(
            AgentProfileStore.roleDelegationCandidates(
                .reviewer,
                in: profiles,
                projectSelection: [Roles.systemReviewer.id, Roles.customReviewer.id]
            ) == [Roles.systemReviewer, Roles.customReviewer]
        )
        // No candidate: empty, with or without a saved selection, and never a
        // fallback to the recommended profiles.
        #expect(
            AgentProfileStore.roleDelegationCandidates(
                .reviewer,
                in: profiles,
                projectSelection: [Roles.developer.id]
            ).isEmpty
        )
        #expect(AgentProfileStore.roleDelegationCandidates(.reviewer, in: profiles, projectSelection: []).isEmpty)
        #expect(AgentProfileStore.roleDelegationCandidates(.planner, in: profiles, projectSelection: nil).isEmpty)
        #expect(AgentProfileStore.roleDelegationCandidates(.reviewer, in: [], projectSelection: nil).isEmpty)
    }

    @Test
    func roleDelegationCandidatesReadTheSavedProjectSelection() throws {
        try ProjectSupport.withTemporaryProject { _, workspace in
            let profiles = [Roles.developer, Roles.systemPlanner, Roles.pluto]

            #expect(
                AgentProfileStore.roleDelegationCandidates(.planner, in: profiles, workspaceRootURL: workspace)
                    == [Roles.systemPlanner]
            )

            try ProjectAgentSelectionStore.save(agentIDs: [Roles.pluto.id], workspaceRootURL: workspace)
            #expect(
                AgentProfileStore.roleDelegationCandidates(.planner, in: profiles, workspaceRootURL: workspace)
                    == [Roles.pluto]
            )

            try ProjectAgentSelectionStore.save(agentIDs: [Roles.developer.id], workspaceRootURL: workspace)
            #expect(
                AgentProfileStore.roleDelegationCandidates(.planner, in: profiles, workspaceRootURL: workspace)
                    .isEmpty
            )
        }
    }

    @Test
    func unavailableRoleMessageNamesTheRoleAndTheFix() {
        #expect(
            AgentProfileStore.roleUnavailableForProjectMessage(.reviewer)
                == "ZenCODE: no agent profile with the reviewer role is available for this project. "
                + "Tick one with /agents."
        )
        #expect(AgentProfileStore.roleUnavailableForProjectMessage(.planner).contains("planner role"))
    }

    // MARK: - Prompts

    @Test
    func delegationProfileClauseKeepsTheSingleProfileWordingAndListsSeveral() {
        #expect(
            AgentProfileStore.delegationProfileClause([Roles.customReviewer])
                == "profile \"\(Roles.customReviewer.id)\""
        )
        #expect(
            AgentProfileStore.delegationProfileClause([Roles.systemReviewer, Roles.customReviewer])
                == "one of these profiles (any of them is acceptable): "
                + "\"reviewer\" (Reviewer), "
                + "\"\(Roles.customReviewer.id)\" (Brutta merda)"
        )
    }

    @Test
    func planPromptsKeepTheSingleCandidateTextAndOfferEveryCandidate() {
        let single = PlanningCommandKernel.planStartPrompt(goal: "ship roles", planners: [Roles.pluto])
        #expect(single == PlanningCommandKernel.planStartPrompt(goal: "ship roles", planner: Roles.pluto))
        #expect(single.contains("role \"Planner\", and profile \"\(Roles.pluto.id)\"."))
        #expect(!single.contains("any of them is acceptable"))

        let multiple = PlanningCommandKernel.planStartPrompt(
            goal: "ship roles",
            planners: [Roles.systemPlanner, Roles.pluto]
        )
        #expect(multiple.contains("role \"Planner\", and one of these profiles (any of them is acceptable): "))
        #expect(multiple.contains("\"planner\" (Planner)"))
        #expect(multiple.contains("\"\(Roles.pluto.id)\" (Pluto)"))
        #expect(multiple.contains("Create exactly one sub-agent"))

        var state = PlanningCommandRuntimeState(goal: "ship roles")
        state.recordPlannerOutput("Planner questions\n1. Which roles?", agentID: "planner-1", revision: 1)
        let recordedReply = state.recordReply("All three.")
        #expect(recordedReply)
        var recreated = state
        recreated.plannerAgentID = nil
        for candidateState in [state, recreated] {
            let singleContinuation = PlanningCommandKernel.planContinuationPrompt(
                state: candidateState,
                planners: [Roles.pluto]
            )
            #expect(
                singleContinuation
                    == PlanningCommandKernel.planContinuationPrompt(state: candidateState, planner: Roles.pluto)
            )
            #expect(singleContinuation.contains("role \"Planner\" and profile \"\(Roles.pluto.id)\", give it"))

            let multipleContinuation = PlanningCommandKernel.planContinuationPrompt(
                state: candidateState,
                planners: [Roles.systemPlanner, Roles.pluto]
            )
            #expect(multipleContinuation.contains(
                "role \"Planner\" and one of these profiles (any of them is acceptable): "
            ))
            #expect(multipleContinuation.contains("\"\(Roles.pluto.id)\" (Pluto), give it"))
        }
    }

    @Test
    func reviewPromptsKeepTheSingleCandidateTextAndOfferEveryCandidate() {
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "Sources/Example.swift",
                additions: 1,
                deletions: 0,
                status: .modified,
                isBinary: false,
                existedBefore: true,
                beforeDataBase64: nil,
                patch: "+line"
            )
        ])
        let plan = TerminalSessionPlan(originalGoal: "goal", consolidatedText: "plan", isApproved: true)

        for approvedPlan in [nil, plan] {
            let single = TerminalChat.reviewDelegationPrompt(
                scope: "",
                reviewers: [Roles.customReviewer],
                changeSummary: summary,
                approvedPlan: approvedPlan
            )
            #expect(single == TerminalChat.reviewDelegationPrompt(
                scope: "",
                reviewer: Roles.customReviewer,
                changeSummary: summary,
                approvedPlan: approvedPlan
            ))
            #expect(single.contains(
                "role \"Reviewer\" and profile \"\(Roles.customReviewer.id)\"; Reviewers must not edit files."
            ))
            #expect(!single.contains("any of them is acceptable"))

            let multiple = TerminalChat.reviewDelegationPrompt(
                scope: "",
                reviewers: [Roles.systemReviewer, Roles.customReviewer],
                changeSummary: summary,
                approvedPlan: approvedPlan
            )
            #expect(multiple.contains(
                "role \"Reviewer\" and one of these profiles (any of them is acceptable): "
                    + "\"reviewer\" (Reviewer), "
                    + "\"\(Roles.customReviewer.id)\" (Brutta merda); Reviewers must not edit files."
            ))
        }
    }

    // MARK: - Planner snapshots

    @Test
    func plannerSnapshotIsRecognizedOnlyByItsProfileRole() {
        let customPlanner = Self.snapshot(profileID: Roles.pluto.id, profileName: "Pluto", profileRole: .planner)
        let customDeveloper = Self.snapshot(profileID: "custom", profileName: "Planner", profileRole: .developer)
        let withoutRole = Self.snapshot(profileID: "planner", profileName: "Planner")
        let systemIDWithAnotherRole = Self.snapshot(
            profileID: "planner",
            profileName: "Planner",
            profileRole: .reviewer
        )

        #expect(PlanningCommandKernel.isPlannerSnapshotProfile(customPlanner))
        #expect(!PlanningCommandKernel.isPlannerSnapshotProfile(customDeveloper))
        #expect(!PlanningCommandKernel.isPlannerSnapshotProfile(withoutRole))
        #expect(!PlanningCommandKernel.isPlannerSnapshotProfile(systemIDWithAnotherRole))
        #expect(
            PlanningCommandKernel.plannerSnapshots(
                [customPlanner, customDeveloper, withoutRole],
                rootSessionID: "root"
            ).map(\.profileRole) == [.planner]
        )
    }

    private static func snapshot(
        profileID: String,
        profileName: String,
        profileRole: AgentProfileRole? = nil
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: UUID().uuidString,
            rootSessionID: "root",
            name: PlanningCommandKernel.planAuthorAgentName,
            role: "Planner",
            profileID: profileID,
            profileName: profileName,
            profileRole: profileRole,
            status: .idle,
            pending: false,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - Presentation

    @Test
    func delegatableRosterLineShowsTheRoleOfEveryProfile() throws {
        let section = try #require(SystemPromptBuilder.delegatableAgentsSection(
            agents: [
                Roles.customReviewer,
                AgentProfile(id: "plain", name: "Plain", role: .reporter, tools: ["files"]),
            ],
            allowedToolNames: ["agent.create"],
            snapshot: .available(models: [])
        ))

        #expect(section.contains("- Brutta merda [read-only; role: reviewer; tools: files]: Review the requested change."))
        #expect(section.contains("- Plain [read-write; role: reporter; tools: files]: No role constraints declared."))
    }

    @Test
    func agentSelectionDetailDescribesTheRoleOfEveryProfile() {
        for profile in AgentProfileStore.defaultProfiles() + [Roles.customReviewer, Roles.pluto] {
            let detail = TerminalChat.agentSelectionDetail(profile)
            #expect(detail.hasPrefix(profile.role.summary))
            #expect(!detail.contains("role:"))
        }
        #expect(TerminalChat.agentSelectionDetail(Roles.customReviewer) == "/review delegates to it")
        #expect(
            TerminalChat.agentSelectionDetail(AgentProfile(id: "x", name: "Planner", role: .minimal))
                == AgentProfileRole.minimal.summary
        )
    }

    @Test
    func setupRoleChoiceOffersEveryRoleAndNoNone() {
        let items = ZenCODEAgentProfileSetupRunner.roleSelectionItems()

        #expect(items.map(\.value) == AgentProfileRole.allCases)
        #expect(items.map(\.title) == AgentProfileRole.allCases.map(\.title))
        #expect(!items.map(\.title).contains("None"))
        #expect(items.map(\.detail) == AgentProfileRole.allCases.map(\.summary))
    }
}
