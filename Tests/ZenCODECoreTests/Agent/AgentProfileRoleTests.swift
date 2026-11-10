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
                    + "developer, builder, generic, planner, reviewer, reporter, organizer, tester)."
            ))
        }
    }

    @Test
    func unknownBlankOrNonStringRoleMakesTheManifestInvalid() throws {
        let values: [(json: String, value: String?)] = [
            (#""architect""#, "architect"),
            (#""promoter""#, "promoter"),
            (#""minimal""#, "minimal"),
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
            .developer, .builder, .reviewer, .reporter, .tester, .planner, .organizer,
        ])
        #else
        #expect(!defaults.contains { $0.role == .organizer })
        #expect(defaults.count == AgentProfileRole.allCases.count - 2)
        #endif
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
        #expect(!AgentProfileStore.isBuilderAgent(AgentProfile(id: "builder", name: "Builder", role: .generic)))
        #expect(!AgentProfileStore.isBuilderAgent(nil))
    }

    @Test
    func genericIsTheNeutralRoleWithoutARecommendedProfileOrRuntimeSemantics() throws {
        let profiles = try Roles.loadManifest(Roles.manifest(
            profile: #"{"id": "scribe", "name": "Scribe", "role": "generic", "tools": []}"#
        ))
        let scribe = try #require(profiles.last)
        let generic = AgentProfile(id: "scribe", name: "Scribe", role: .generic)
        let coreNames = Set(DirectToolCatalog.coreDescriptors.map(\.name))

        #expect(scribe.role == .generic)
        #expect(AgentProfileRole.generic.rawValue == "generic")
        #expect(!AgentProfileStore.defaultProfiles().contains { $0.role == .generic })
        #expect(!AgentProfileRole.generic.usesGlobalMemory)
        #expect(!AgentProfileRole.generic.delegatesByRole)
        #expect(!AgentProfileStore.isPlannerAgent(generic))
        #expect(!AgentProfileStore.isBuilderAgent(generic))
        #expect(!AgentProfileStore.isReviewerAgent(generic))
        #expect(coreNames.contains("local.writeFile"))
        #expect(generic.resolvedAllowedToolNames(coreNames) == coreNames)
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
    func projectDefaultDeveloperIsTheFirstAssociatedDeveloperInManifestOrder() throws {
        let first = AgentProfile(id: "first-dev", name: "First Dev", role: .developer)
        let second = AgentProfile(id: "second-dev", name: "Second Dev", role: .developer)
        // The system developer exists but the project does not associate it.
        let agents = [Roles.developer, second, Roles.pluto, first]

        #expect(
            try AgentProfileStore.developerProfile(
                in: agents,
                projectSelection: [first.id, second.id, Roles.pluto.id]
            ) == second
        )
        #expect(try AgentProfileStore.developerProfile(in: agents, projectSelection: [first.id]) == first)
        // Selection keys are case-insensitive, like every profile reference.
        #expect(try AgentProfileStore.developerProfile(in: agents, projectSelection: ["FIRST-DEV"]) == first)
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
}
