import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    private static let roleProviderID = UUID(
        uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )!

    private static func roleCatalogSnapshot(
        _ modelIDs: [String]
    ) -> AgentDelegationCatalogSnapshot {
        .available(
            models: modelIDs.map { modelID in
                AgentSettingsModelManifestFactory.remoteAPIModel(
                    title: nil,
                    modelID: modelID,
                    providerID: roleProviderID,
                    providerName: "Role Provider",
                    baseURL: "https://roles.example.com/v1",
                    chatEndpoint: .chatCompletions,
                    configuredContextWindowLimit: nil,
                    generationParameterOverrides: nil,
                    thinkingSupport: .effort()
                )
            }
        )
    }

    /// System developer profile with a low-capability binding.
    private static let systemDeveloper = AgentProfile(
        id: AgentProfileRole.developer.rawValue,
        name: "Developer",
        role: .developer,
        tools: [],
        modelBindings: [AgentModelBinding(id: "fast", modelID: "fast-model", capability: 3)]
    )

    /// Custom developer profile with a high-capability binding.
    private static let seniorDeveloper = AgentProfile(
        id: "BBBBBBBB-0000-0000-0000-000000000001",
        name: "Senior Developer",
        role: .developer,
        tools: [],
        modelBindings: [AgentModelBinding(id: "deep", modelID: "deep-model", capability: 7)]
    )

    private static let roleModels = ["fast-model", "deep-model"]

    private static func makeRoleRuntime(
        backend: CapturingSubAgentRuntimeBackend,
        profiles: [AgentProfile],
        models: [String] = roleModels,
        recorder: SubAgentFactoryRecorder? = nil
    ) -> DirectSubAgentRuntime {
        DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder?.append(context)
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: profiles)
            },
            modelCatalogProvider: { Self.roleCatalogSnapshot(models) },
            profileCatalogProvider: { profiles }
        )
    }

    private static func agentItem(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var item: [String: JSONValue] = ["name": .string("worker")]
        item.merge(fields) { $1 }
        return ["agents": .array([.object(item)])]
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Binding selection

    @Test
    func profileRoleSelectsTheLowestSufficientCapabilityOrTheHighestWithAGap() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let profiles = [Self.systemDeveloper, Self.seniorDeveloper]
            try ProjectAgentSelectionStore.save(
                agentIDs: profiles.map(\.id),
                workspaceRootURL: workspace
            )
            let cases: [(complexity: Int, profile: AgentProfile, binding: String, capability: Int)] = [
                (5, Self.seniorDeveloper, "deep", 7),
                (2, Self.systemDeveloper, "fast", 3),
                (9, Self.seniorDeveloper, "deep", 7),
            ]
            for testCase in cases {
                let backend = CapturingSubAgentRuntimeBackend()
                let recorder = SubAgentFactoryRecorder()
                let runtime = Self.makeRoleRuntime(
                    backend: backend,
                    profiles: profiles,
                    recorder: recorder
                )

                let output = try await runtime.createAgents(
                    arguments: Self.agentItem([
                        "profileRole": .string("developer"),
                        "complexity": .number(Double(testCase.complexity)),
                    ]),
                    workingDirectory: workspace,
                    parentAllowedToolNames: nil
                )

                let context = try #require(recorder.contexts.first)
                #expect(context.profile == testCase.profile)
                #expect(context.modelBinding?.id == testCase.binding)
                #expect(context.capability == testCase.capability)
                #expect(context.modelSelection != nil)
                #expect(output.contains(
                    "Resolved profileRole \"developer\" for agent \"worker\" "
                        + "(complexity \(testCase.complexity)) to profile "
                        + "\"\(testCase.profile.displayName)\" with model "
                        + "binding:\(testCase.binding) (capability \(testCase.capability)/10)."
                ))
                let gap = testCase.complexity - testCase.capability
                #expect(
                    output.contains("Warning: capability gap of \(gap);") == (gap > 0)
                )
                let snapshot = try #require(await runtime.snapshots().first)
                #expect(snapshot.profileID == testCase.profile.id)
                #expect(snapshot.profileRole == .developer)
                await runtime.shutdown()
            }
        }
    }

    @Test
    func profileRolePrefersTheSystemProfileAtEqualCapability() throws {
        let custom = AgentProfile(
            id: "BBBBBBBB-0000-0000-0000-000000000002",
            name: "Custom Developer",
            role: .developer,
            tools: [],
            modelBindings: [AgentModelBinding(id: "custom", modelID: "deep-model", capability: 7)]
        )
        let system = AgentProfile(
            id: AgentProfileRole.developer.rawValue,
            name: "Developer",
            role: .developer,
            tools: [],
            modelBindings: [AgentModelBinding(id: "system", modelID: "fast-model", capability: 7)]
        )
        // The custom profile comes first in the manifest; the system profile
        // still wins the tie, both when sufficient and when short of complexity.
        for complexity in [5, 9] {
            let resolution = try DirectSubAgentRuntime.resolvingProfileRole(
                for: DirectSubAgentRuntime.RequestedAgentPayload(name: "worker", role: "worker"),
                role: .developer,
                complexity: complexity,
                profiles: [custom, system],
                projectSelection: [custom.id, system.id],
                projectPath: "/tmp/project",
                snapshot: Self.roleCatalogSnapshot(Self.roleModels)
            )
            #expect(resolution.profile == system)
            #expect(resolution.payload.profileReference == system.id)
            #expect(resolution.payload.modelBinding?.id == "system")
        }
    }

    @Test
    func profileRoleWithoutRoutableBindingsInheritsTheSessionModelOrFails() throws {
        let unboundCustom = AgentProfile(
            id: "BBBBBBBB-0000-0000-0000-000000000003",
            name: "Unbound Developer",
            role: .developer
        )
        let unboundSystem = AgentProfile(
            id: AgentProfileRole.developer.rawValue,
            name: "Developer",
            role: .developer
        )
        let resolution = try DirectSubAgentRuntime.resolvingProfileRole(
            for: DirectSubAgentRuntime.RequestedAgentPayload(name: "worker", role: "worker"),
            role: .developer,
            complexity: 4,
            profiles: [unboundCustom, unboundSystem, Self.seniorDeveloper],
            projectSelection: [unboundCustom.id, unboundSystem.id, Self.seniorDeveloper.id],
            projectPath: "/tmp/project",
            // The senior binding's model is not configured, so no pair exists.
            snapshot: Self.roleCatalogSnapshot([])
        )
        #expect(resolution.profile == unboundSystem)
        #expect(resolution.payload.modelBinding == nil)
        #expect(resolution.payload.modelSelection == nil)
        #expect(resolution.note.hasSuffix(
            "to profile \"Developer\" inheriting the main session model (no configured bindings)."
        ))

        do {
            _ = try DirectSubAgentRuntime.resolvingProfileRole(
                for: DirectSubAgentRuntime.RequestedAgentPayload(name: "worker", role: "worker"),
                role: .developer,
                complexity: 4,
                profiles: [Self.seniorDeveloper],
                projectSelection: [Self.seniorDeveloper.id],
                projectPath: "/tmp/project",
                snapshot: Self.roleCatalogSnapshot([])
            )
            Issue.record("Expected a role without routable bindings to be rejected.")
        } catch let DirectSubAgentRuntimeError.agentProfileRoleHasNoRoutableBinding(role, names) {
            #expect(role == .developer)
            #expect(names == ["Senior Developer"])
            let message = DirectSubAgentRuntimeError
                .agentProfileRoleHasNoRoutableBinding(role, names)
                .errorDescription
            #expect(message?.contains("developer role") == true)
            #expect(message?.contains("(Senior Developer)") == true)
            #expect(message?.contains("/agents") == true)
        }
    }

    @Test
    func profileRoleBreaksCapabilityTiesByManifestOrderAmongCustomProfiles() throws {
        let first = AgentProfile(
            id: "BBBBBBBB-0000-0000-0000-000000000004",
            name: "First Custom",
            role: .developer,
            tools: [],
            modelBindings: [AgentModelBinding(id: "first", modelID: "fast-model", capability: 6)]
        )
        let second = AgentProfile(
            id: "BBBBBBBB-0000-0000-0000-000000000005",
            name: "Second Custom",
            role: .developer,
            tools: [],
            modelBindings: [AgentModelBinding(id: "second", modelID: "deep-model", capability: 6)]
        )
        // Neither is a system profile: the one listed first in the manifest wins
        // the tie, both when sufficient (5) and when short of complexity (9).
        for (profiles, expected) in [([first, second], first), ([second, first], second)] {
            for complexity in [5, 9] {
                let resolution = try DirectSubAgentRuntime.resolvingProfileRole(
                    for: DirectSubAgentRuntime.RequestedAgentPayload(name: "worker", role: "worker"),
                    role: .developer,
                    complexity: complexity,
                    profiles: profiles,
                    projectSelection: [first.id, second.id],
                    projectPath: "/tmp/project",
                    snapshot: Self.roleCatalogSnapshot(Self.roleModels)
                )
                #expect(resolution.profile == expected)
                #expect(resolution.payload.profileReference == expected.id)
            }
        }
    }

    @Test
    func profileRoleBreaksCapabilityTiesByBindingOrderWithinAProfile() throws {
        // Ties inside a profile follow the order of its delegatable bindings (the
        // roster order the prompt shows), here also the declaration order in the
        // first profile; the second declares the opposite model order.
        let variants: [(bindings: [AgentModelBinding], winner: String?)] = [
            (
                [
                    AgentModelBinding(id: "alpha", modelID: "deep-model", capability: 6),
                    AgentModelBinding(id: "beta", modelID: "fast-model", capability: 6),
                ],
                "alpha"
            ),
            (
                [
                    AgentModelBinding(id: "alpha", modelID: "fast-model", capability: 6),
                    AgentModelBinding(id: "beta", modelID: "deep-model", capability: 6),
                ],
                nil
            ),
        ]
        for (bindings, winner) in variants {
            let twin = AgentProfile(
                id: "BBBBBBBB-0000-0000-0000-000000000006",
                name: "Twin Developer",
                role: .developer,
                tools: [],
                modelBindings: bindings
            )
            let snapshot = Self.roleCatalogSnapshot(Self.roleModels)
            let rosterFirst = try #require(
                AgentDelegationCatalog.resolvedBindings(for: twin, snapshot: snapshot)
                    .delegatableBindings.first
            )
            for complexity in [5, 9] {
                let resolution = try DirectSubAgentRuntime.resolvingProfileRole(
                    for: DirectSubAgentRuntime.RequestedAgentPayload(name: "worker", role: "worker"),
                    role: .developer,
                    complexity: complexity,
                    profiles: [twin],
                    projectSelection: [twin.id],
                    projectPath: "/tmp/project",
                    snapshot: snapshot
                )
                #expect(resolution.profile == twin)
                #expect(resolution.payload.modelBinding?.id == rosterFirst.bindingID)
                if let winner {
                    #expect(resolution.payload.modelBinding?.id == winner)
                }
            }
        }
    }

    @Test
    func profileRoleWithoutRoutableBindingFailsBeforeAnySessionOrTaskClaim() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let senior = Self.seniorDeveloper
            try ProjectAgentSelectionStore.save(
                agentIDs: [senior.id],
                workspaceRootURL: workspace
            )
            let orchestrator = SessionTaskOrchestrator()
            _ = try await orchestrator.createGraph(
                sessionID: "root",
                id: "graph",
                source: .manual,
                state: .active,
                tasks: [TaskDefinition(id: "task-a", title: "Implement", complexity: 5)]
            )
            let backend = CapturingSubAgentRuntimeBackend()
            let recorder = SubAgentFactoryRecorder()
            // No model is configured, so the senior binding cannot be routed.
            let runtime = Self.makeRoleRuntime(
                backend: backend,
                profiles: [senior],
                models: [],
                recorder: recorder
            )
            await runtime.installTaskOrchestrator(orchestrator)

            do {
                _ = try await runtime.createAgents(
                    arguments: Self.agentItem([
                        "profileRole": .string("developer"),
                        "taskID": .string("task-a"),
                    ]),
                    workingDirectory: workspace,
                    parentAllowedToolNames: nil,
                    rootSessionID: "root"
                )
                Issue.record("Expected a role without routable bindings to be rejected.")
            } catch let DirectSubAgentRuntimeError.agentProfileRoleHasNoRoutableBinding(role, names) {
                #expect(role == .developer)
                #expect(names == ["Senior Developer"])
            }

            #expect(await backend.createdSessions().isEmpty)
            #expect(recorder.contexts.isEmpty)
            #expect(await runtime.snapshots().isEmpty)
            let task = try await orchestrator.task(sessionID: "root", taskID: "task-a").task
            #expect(task.status == .pending)
            #expect(task.activeAttemptID == nil)
            #expect(task.attempts.isEmpty)
            await runtime.shutdown()
        }
    }

    @Test
    func profileRoleCandidateWithoutBindingsInheritsTheMainSessionModelViaCreateAgents() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let unbound = AgentProfile(
                id: AgentProfileRole.developer.rawValue,
                name: "Developer",
                role: .developer
            )
            let backend = CapturingSubAgentRuntimeBackend()
            let recorder = SubAgentFactoryRecorder()
            let runtime = Self.makeRoleRuntime(
                backend: backend,
                profiles: [unbound],
                recorder: recorder
            )

            let output = try await runtime.createAgents(
                arguments: Self.agentItem([
                    "profileRole": .string("developer"),
                    "complexity": .number(4),
                ]),
                workingDirectory: workspace,
                parentAllowedToolNames: nil
            )

            let context = try #require(recorder.contexts.first)
            #expect(context.profile == unbound)
            #expect(context.modelBinding == nil)
            #expect(context.modelSelection == nil)
            #expect(await backend.createdSessions().count == 1)
            #expect(output.contains(
                "Resolved profileRole \"developer\" for agent \"worker\" (complexity 4) "
                    + "to profile \"Developer\" inheriting the main session model "
                    + "(no configured bindings)."
            ))
            let snapshot = try #require(await runtime.snapshots().first)
            #expect(snapshot.profileID == unbound.id)
            await runtime.shutdown()
        }
    }

    @Test
    func profileRoleNotVisibleToTheProjectIsRejected() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            // The saved selection excludes every developer profile.
            try ProjectAgentSelectionStore.save(
                agentIDs: [ProjectAgentSelectionTestSupport.reviewer.id],
                workspaceRootURL: workspace
            )
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeRoleRuntime(
                backend: backend,
                profiles: [Self.systemDeveloper, Self.seniorDeveloper, ProjectAgentSelectionTestSupport.reviewer]
            )

            do {
                _ = try await runtime.createAgents(
                    arguments: Self.agentItem([
                        "profileRole": .string("developer"),
                        "complexity": .number(5),
                    ]),
                    workingDirectory: workspace,
                    parentAllowedToolNames: nil
                )
                Issue.record("Expected a role outside the project selection to be rejected.")
            } catch let DirectSubAgentRuntimeError.agentProfileRoleNotAvailableForProject(role, path) {
                #expect(role == .developer)
                #expect(path == workspace.standardizedFileURL.path)
                let message = DirectSubAgentRuntimeError
                    .agentProfileRoleNotAvailableForProject(role, path)
                    .errorDescription
                // Addressed to the model, unlike the operator-facing TUI message.
                #expect(message == "No agent profile with the developer role is associated with "
                    + "this project (\(path)), so it cannot be delegated to; the operator can "
                    + "associate one using /agents.")
                #expect(message != AgentProfileStore.roleUnavailableForProjectMessage(.developer)
                    + " Project: \(path).")
            }
            #expect(await backend.createdSessions().isEmpty)
            await runtime.shutdown()
        }
    }

    // MARK: - Argument validation

    @Test
    func profileRoleRejectsExplicitProfileModelAndMissingComplexity() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeRoleRuntime(backend: backend, profiles: [Self.systemDeveloper])
            let invalidItems: [([String: JSONValue], DirectSubAgentRuntimeError)] = [
                (
                    [
                        "profile": .string("Developer"),
                        "profileRole": .string("developer"),
                        "complexity": .number(5),
                    ],
                    .invalidArgument("agent.create profile and profileRole are mutually exclusive")
                ),
                (
                    [
                        "profileRole": .string("developer"),
                        "model": .string("binding:fast"),
                        "complexity": .number(5),
                    ],
                    .invalidArgument("agent.create model cannot be combined with profileRole")
                ),
                (
                    ["profileRole": .string("developer")],
                    .missingArgument("complexity")
                ),
            ]
            for (fields, expected) in invalidItems {
                do {
                    _ = try await runtime.createAgents(
                        arguments: Self.agentItem(fields),
                        workingDirectory: workspace,
                        parentAllowedToolNames: nil
                    )
                    Issue.record("Expected \(fields) to be rejected.")
                } catch let error as DirectSubAgentRuntimeError {
                    #expect(error.errorDescription == expected.errorDescription)
                }
            }
            #expect(await backend.createdSessions().isEmpty)
            await runtime.shutdown()
        }
    }

    @Test
    func profileRoleBoundToATaskUsesTheTaskComplexity() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let profiles = [Self.systemDeveloper, Self.seniorDeveloper]
            try ProjectAgentSelectionStore.save(
                agentIDs: profiles.map(\.id),
                workspaceRootURL: workspace
            )
            let orchestrator = SessionTaskOrchestrator()
            _ = try await orchestrator.createGraph(
                sessionID: "root",
                id: "graph",
                source: .manual,
                state: .active,
                tasks: [TaskDefinition(id: "task-a", title: "Implement", complexity: 9)]
            )
            let backend = CapturingSubAgentRuntimeBackend()
            let recorder = SubAgentFactoryRecorder()
            let runtime = Self.makeRoleRuntime(
                backend: backend,
                profiles: profiles,
                recorder: recorder
            )
            await runtime.installTaskOrchestrator(orchestrator)

            // No complexity is needed: the task's own complexity (9) wins over
            // anything the item could provide.
            let output = try await runtime.createAgents(
                arguments: Self.agentItem([
                    "profileRole": .string("developer"),
                    "complexity": .number(2),
                    "taskID": .string("task-a"),
                ]),
                workingDirectory: workspace,
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )

            let context = try #require(recorder.contexts.first)
            #expect(context.modelBinding?.id == "deep")
            let modelID = try #require(context.modelBinding?.modelID)
            #expect(output.contains("(complexity 9) to profile \"Senior Developer\""))
            // The gap of a task-bound item is reported by the post-claim advisory,
            // worded for a profile the runtime (not the coordinator) chose.
            #expect(!output.contains("Warning: capability gap of"))
            #expect(output.contains(
                "Warning: task \"task-a\" has complexity 9 but profileRole \"developer\" "
                    + "for agent \"worker\" resolved to profile \"Senior Developer\" with model "
                    + "\"\(modelID)\" at capability 7/10, a capability gap of 2; no authorized "
                    + "binding with this role meets the complexity in this project."
            ))
            #expect(modelID.hasSuffix("deep-model"))
            #expect(!output.contains("Use this profile only when no role-compatible profile"))
            await runtime.shutdown()
        }
    }

    // MARK: - Working directory

    @Test
    func workingDirectoryOutsideTheCoordinatorDirectoryOrMissingIsRejected() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { support, workspace in
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeRoleRuntime(backend: backend, profiles: [Self.systemDeveloper])
            let file = workspace.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            // A symlink inside the coordinator directory that leads outside it.
            try FileManager.default.createSymbolicLink(
                atPath: workspace.appendingPathComponent("escape").path,
                withDestinationPath: support.path
            )
            for value in ["missing", "..", support.path, "/", "file.txt", "escape", "escape/"] {
                do {
                    _ = try await runtime.createAgents(
                        arguments: Self.agentItem([
                            "profile": .string("Developer"),
                            "model": .string("binding:fast"),
                            "workingDirectory": .string(value),
                        ]),
                        workingDirectory: workspace,
                        parentAllowedToolNames: nil
                    )
                    Issue.record("Expected workingDirectory \(value) to be rejected.")
                } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
                    // The root is the path the coordinator knows, not its resolved form.
                    #expect(message == "agent.create workingDirectory must be an existing "
                        + "directory inside \(workspace.standardizedFileURL.path): \(value)")
                }
            }
            #expect(await backend.createdSessions().isEmpty)
            await runtime.shutdown()
        }
    }

    @Test
    func workingDirectoryInsideTheCoordinatorDirectoryDrivesTheChildSession() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let subdirectory = workspace.appendingPathComponent("Sources/Module", isDirectory: true)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            // The child keeps the coordinator's own (unresolved) path prefix, the
            // one the project selection and the memory digest are keyed on.
            let expectedPath = subdirectory.standardizedFileURL.path
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeRoleRuntime(backend: backend, profiles: [Self.systemDeveloper])

            for value in ["Sources/Module", "./Sources/../Sources/Module", subdirectory.path] {
                _ = try await runtime.createAgents(
                    arguments: Self.agentItem([
                        "profile": .string("Developer"),
                        "model": .string("binding:fast"),
                        "workingDirectory": .string(value),
                    ]),
                    workingDirectory: workspace,
                    parentAllowedToolNames: nil
                )
            }
            // Without workingDirectory the coordinator directory is inherited
            // unchanged and the prompt carries no working-directory section.
            _ = try await runtime.createAgents(
                arguments: Self.agentItem([
                    "profile": .string("Developer"),
                    "model": .string("binding:fast"),
                ]),
                workingDirectory: workspace,
                parentAllowedToolNames: nil
            )

            let sessions = await backend.createdSessions()
            #expect(sessions.count == 4)
            for session in sessions.prefix(3) {
                #expect(session.cwd == expectedPath)
                #expect(session.systemPrompt?.contains("Working directory path: \(expectedPath)") == true)
            }
            let inherited = try #require(sessions.last)
            #expect(inherited.cwd == workspace.path)
            #expect(inherited.systemPrompt?.contains("Working directory path:") == false)
            await runtime.shutdown()
        }
    }

    @Test
    func dotAndTrailingSlashWorkingDirectoriesNormalizeToTheSamePath() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let subdirectory = workspace.appendingPathComponent("Sources/Module", isDirectory: true)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeRoleRuntime(backend: backend, profiles: [Self.systemDeveloper])

            let items: [[String: JSONValue]] = [
                [:],
                ["workingDirectory": .string(".")],
                ["workingDirectory": .string("Sources/Module")],
                ["workingDirectory": .string("Sources/Module/")],
            ]
            for item in items {
                var fields: [String: JSONValue] = [
                    "profile": .string("Developer"),
                    "model": .string("binding:fast"),
                ]
                fields.merge(item) { $1 }
                _ = try await runtime.createAgents(
                    arguments: Self.agentItem(fields),
                    workingDirectory: workspace,
                    parentAllowedToolNames: nil
                )
            }

            let sessions = await backend.createdSessions()
            #expect(sessions.count == 4)
            // "." is the inherited coordinator directory, unchanged.
            #expect(sessions[0].cwd == workspace.path)
            #expect(sessions[1].cwd == sessions[0].cwd)
            // A trailing slash does not change the result.
            #expect(sessions[2].cwd == subdirectory.standardizedFileURL.path)
            #expect(sessions[3].cwd == sessions[2].cwd)
            #expect(sessions[3].systemPrompt?.contains(
                "Working directory path: \(subdirectory.standardizedFileURL.path)\n"
            ) == true)
            await runtime.shutdown()
        }
    }

    @Test
    func coordinatorReachedThroughASymlinkKeepsItsOwnPathForTheChild() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            // `linked -> real`: the coordinator was started through the symlink.
            let real = workspace.appendingPathComponent("real", isDirectory: true)
            let linked = workspace.appendingPathComponent("linked", isDirectory: true)
            let realChild = real.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: realChild, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: linked.path,
                withDestinationPath: real.path
            )
            let linkedChild = linked.appendingPathComponent("sub", isDirectory: true)
            let expectedPath = linkedChild.standardizedFileURL.path
            #expect(Self.resolvedPath(linkedChild) != expectedPath)

            // Only the selection saved for the path the coordinator knows
            // (`linked/sub`) associates the custom profile and drops the system one.
            let senior = Self.seniorDeveloper
            try ProjectAgentSelectionStore.save(
                agentIDs: [senior.id],
                workspaceRootURL: linkedChild
            )
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: realChild) == nil)
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeRoleRuntime(
                backend: backend,
                profiles: [Self.systemDeveloper, senior]
            )

            let output = try await runtime.createAgents(
                arguments: Self.agentItem([
                    "profileRole": .string("developer"),
                    "complexity": .number(2),
                    "workingDirectory": .string("sub"),
                ]),
                workingDirectory: linked,
                parentAllowedToolNames: nil
            )

            // Complexity 2 would pick the system "fast" binding if the child saw
            // the (empty) selection of the resolved path.
            #expect(output.contains("to profile \"Senior Developer\""))
            let session = try #require(await backend.createdSessions().first)
            #expect(session.cwd == expectedPath)
            #expect(session.systemPrompt?.contains("Working directory path: \(expectedPath)") == true)
            await runtime.shutdown()
        }
    }

    @Test
    func projectSelectionIsEvaluatedOnTheResolvedWorkingDirectory() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let subdirectory = workspace.appendingPathComponent("package", isDirectory: true)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            let senior = Self.seniorDeveloper
            // Only the subdirectory's project associates the custom profile and
            // excludes the system one; the coordinator directory has no selection.
            try ProjectAgentSelectionStore.save(
                agentIDs: [senior.id],
                workspaceRootURL: subdirectory
            )
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = Self.makeRoleRuntime(
                backend: backend,
                profiles: [Self.systemDeveloper, senior]
            )

            _ = try await runtime.createAgents(
                arguments: Self.agentItem([
                    "profile": .string("Senior Developer"),
                    "model": .string("binding:deep"),
                    "workingDirectory": .string("package"),
                ]),
                workingDirectory: workspace,
                parentAllowedToolNames: nil
            )
            let roleOutput = try await runtime.createAgents(
                arguments: Self.agentItem([
                    "profileRole": .string("developer"),
                    "complexity": .number(2),
                    "workingDirectory": .string("package"),
                ]),
                workingDirectory: workspace,
                parentAllowedToolNames: nil
            )
            #expect(roleOutput.contains("to profile \"Senior Developer\""))

            do {
                _ = try await runtime.createAgents(
                    arguments: Self.agentItem([
                        "profile": .string("Senior Developer"),
                        "model": .string("binding:deep"),
                    ]),
                    workingDirectory: workspace,
                    parentAllowedToolNames: nil
                )
                Issue.record("Expected the coordinator directory to keep system-only visibility.")
            } catch let DirectSubAgentRuntimeError.agentProfileNotAssociatedWithProject(reference, path) {
                #expect(reference == "Senior Developer")
                #expect(path == workspace.standardizedFileURL.path)
            }
            do {
                _ = try await runtime.createAgents(
                    arguments: Self.agentItem([
                        "profile": .string("Developer"),
                        "model": .string("binding:fast"),
                        "workingDirectory": .string("package"),
                    ]),
                    workingDirectory: workspace,
                    parentAllowedToolNames: nil
                )
                Issue.record("Expected the subdirectory selection to exclude the system profile.")
            } catch let DirectSubAgentRuntimeError.agentProfileNotAssociatedWithProject(reference, path) {
                #expect(reference == "Developer")
                #expect(path == subdirectory.standardizedFileURL.path)
            }

            #expect(await backend.createdSessions().count == 2)
            await runtime.shutdown()
        }
    }
}
