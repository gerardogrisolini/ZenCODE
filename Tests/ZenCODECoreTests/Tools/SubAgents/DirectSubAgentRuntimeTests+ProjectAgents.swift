import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    private typealias ProjectSupport = ProjectAgentSelectionTestSupport

    /// Runs `body` with an isolated support directory in which
    /// `workingDirectory` has `profiles` as its saved agent selection, so
    /// custom (non-system) profiles can be delegated to.
    static func withProjectSelection<T>(
        _ profiles: [AgentProfile],
        workingDirectory: URL,
        _ body: () async throws -> T
    ) async throws -> T {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-sub-agent-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        return try await AppStorageDirectory.withSupportDirectoryURL(support) {
            try ProjectAgentSelectionStore.save(
                agentIDs: profiles.map(\.id),
                workspaceRootURL: workingDirectory
            )
            return try await body()
        }
    }

    private static func makeProjectRuntime(
        backend: CapturingSubAgentRuntimeBackend
    ) -> DirectSubAgentRuntime {
        DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(
                    matching: payload,
                    in: ProjectAgentSelectionTestSupport.profiles
                )
            }
        )
    }

    private static func createProjectAgent(
        profile: String,
        runtime: DirectSubAgentRuntime,
        workspace: URL
    ) async throws -> String {
        try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string(profile)
            ],
            workingDirectory: workspace,
            parentAllowedToolNames: nil
        )
    }

    @Test
    func profileNotAssociatedWithTheProjectIsRejected() async throws {
        try await ProjectSupport.withTemporaryProjectAsync { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [ProjectSupport.developer.id],
                workspaceRootURL: workspace
            )
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeProjectRuntime(backend: backend)

            do {
                _ = try await Self.createProjectAgent(profile: "Reviewer", runtime: runtime, workspace: workspace)
                Issue.record("Expected a profile outside the project selection to be rejected.")
            } catch let DirectSubAgentRuntimeError.agentProfileNotAssociatedWithProject(reference, path) {
                #expect(reference == "Reviewer")
                #expect(path == workspace.standardizedFileURL.path)
            }

            let message = DirectSubAgentRuntimeError
                .agentProfileNotAssociatedWithProject("Reviewer", workspace.path)
                .errorDescription
            #expect(message?.contains("Reviewer") == true)
            #expect(message?.contains("not associated with this project") == true)
            #expect(message?.contains("delegatable roster") == true)
            #expect(message?.contains("/agents") == true)

            #expect(await backend.createdSessions().isEmpty)
            await runtime.shutdown()
        }
    }

    @Test
    func profileAssociatedWithTheProjectIsAccepted() async throws {
        try await ProjectSupport.withTemporaryProjectAsync { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [ProjectSupport.reviewer.id],
                workspaceRootURL: workspace
            )
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeProjectRuntime(backend: backend)

            _ = try await Self.createProjectAgent(profile: "Reviewer", runtime: runtime, workspace: workspace)

            #expect(await backend.createdSessions().count == 1)
            await runtime.shutdown()
        }
    }

    @Test
    func projectWithoutASavedSelectionAcceptsOnlySystemProfiles() async throws {
        try await ProjectSupport.withTemporaryProjectAsync { _, workspace in
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeProjectRuntime(backend: backend)

            _ = try await Self.createProjectAgent(profile: "Developer", runtime: runtime, workspace: workspace)
            for profile in ["Reviewer", "Reporter"] {
                do {
                    _ = try await Self.createProjectAgent(profile: profile, runtime: runtime, workspace: workspace)
                    Issue.record("A custom profile must not be delegatable without a saved selection.")
                } catch let DirectSubAgentRuntimeError.agentProfileNotAssociatedWithProject(reference, _) {
                    #expect(reference == profile)
                }
            }

            #expect(await backend.createdSessions().count == 1)
            await runtime.shutdown()
        }
    }

    @Test
    func emptySavedSelectionRejectsEveryProfile() async throws {
        try await ProjectSupport.withTemporaryProjectAsync { _, workspace in
            try ProjectAgentSelectionStore.save(agentIDs: [String](), workspaceRootURL: workspace)
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeProjectRuntime(backend: backend)

            for profile in ["Developer", "Reviewer", "Reporter"] {
                await #expect(throws: DirectSubAgentRuntimeError.self) {
                    _ = try await Self.createProjectAgent(profile: profile, runtime: runtime, workspace: workspace)
                }
            }

            #expect(await backend.createdSessions().isEmpty)
            await runtime.shutdown()
        }
    }

    @Test
    func aBatchWithOneUnassociatedProfileCreatesNoAgentAtAll() async throws {
        try await ProjectSupport.withTemporaryProjectAsync { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [ProjectSupport.developer.id],
                workspaceRootURL: workspace
            )
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeProjectRuntime(backend: backend)

            await #expect(throws: DirectSubAgentRuntimeError.self) {
                _ = try await runtime.createAgents(
                    arguments: [
                        "agents": .array([
                            .object(["name": .string("first"), "profile": .string("Developer")]),
                            .object(["name": .string("second"), "profile": .string("Reporter")]),
                        ])
                    ],
                    workingDirectory: workspace,
                    parentAllowedToolNames: nil
                )
            }

            #expect(await backend.createdSessions().isEmpty)
            await runtime.shutdown()
        }
    }

    @Test
    func selectionOfAnotherProjectDoesNotRestrictThisOne() async throws {
        try await ProjectSupport.withTemporaryProjectAsync { support, workspace in
            let other = support.deletingLastPathComponent()
                .appendingPathComponent("other-workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try ProjectAgentSelectionStore.save(agentIDs: [String](), workspaceRootURL: other)

            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeProjectRuntime(backend: backend)

            _ = try await Self.createProjectAgent(profile: "Developer", runtime: runtime, workspace: workspace)

            #expect(await backend.createdSessions().count == 1)
            await runtime.shutdown()
        }
    }
}
