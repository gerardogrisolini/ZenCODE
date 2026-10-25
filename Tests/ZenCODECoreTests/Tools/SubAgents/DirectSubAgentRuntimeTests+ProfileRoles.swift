import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    @Test
    func createdAgentSnapshotCarriesTheProfileRole() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let profiles = [
                AgentProfile(id: "pluto", name: "Pluto", role: .planner),
                AgentProfile(id: AgentProfileRole.reviewer.rawValue, name: "Renamed Reviewer", role: .reviewer),
                AgentProfile(id: "plain", name: "Planner", role: .reporter),
            ]
            try ProjectAgentSelectionStore.save(agentIDs: profiles.map(\.id), workspaceRootURL: workspace)
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = DirectSubAgentRuntime(
                contextualBackendFactory: { _ in backend },
                profileResolver: { payload in
                    DirectSubAgentRuntime.agentProfile(matching: payload, in: profiles)
                }
            )

            for profile in ["Pluto", "Renamed Reviewer", "plain"] {
                _ = try await runtime.createAgents(
                    arguments: ["name": .string("worker-\(profile)"), "profile": .string(profile)],
                    workingDirectory: workspace,
                    parentAllowedToolNames: nil
                )
            }

            let rolesByProfile = Dictionary(
                uniqueKeysWithValues: await runtime.snapshots().compactMap { snapshot in
                    snapshot.profileName.map { ($0, snapshot.profileRole) }
                }
            )
            #expect(rolesByProfile["Pluto"] == .some(.planner))
            #expect(rolesByProfile["Renamed Reviewer"] == .some(.reviewer))
            // The name carries no meaning: a profile named "Planner" keeps its role.
            #expect(rolesByProfile["Planner"] == .some(.reporter))
            await runtime.shutdown()
        }
    }
}
