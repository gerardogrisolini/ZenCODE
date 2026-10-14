import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    @Test
    func agentWithoutProfileIsRejectedInsteadOfInheritingParentGrant() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in nil }
        )

        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.execute(
                rootSessionID: "root",
                toolCall: presentedToolCall(
                    id: "create-worker",
                    name: "agent.create",
                    argumentsObject: [
                        "name": "worker",
                        "role": "worker",
                        "prompt": "Do the delegated work"
                    ],
                    argumentsJSON: #"{"name":"worker","role":"worker","prompt":"Do the delegated work"}"#
                ),
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
                allowedToolNames: ["local.readFile", "local.writeFile"]
            )
        }
        #expect(await backend.createdSessions().isEmpty)
        await runtime.shutdown()
    }

    @Test
    func agentWithResolvedProfileWithoutCoordinatorIdentityUsesProfileGrant() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: ["local.readFile", "local.writeFile"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in developer }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("implementation-worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["git.status"]
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == [
            "local.readFile", "local.writeFile", "skills.list", "skills.read",
            "agent.list", "agent.get", "agent.message"
        ])
        await runtime.shutdown()
    }

    @Test
    func sameProfileInheritsEffectiveParentGrantAndKeepsOnlyChildIntrinsics() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: ["local.readFile", "local.writeFile"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in developer },
            parentProfileID: developer.id,
            parentProfileName: developer.name
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("implementation-worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: [
                "local.readFile", "external.sessionAddition", "skills.list"
            ]
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == [
            "local.readFile", "external.sessionAddition", "skills.list", "skills.read",
            "agent.list", "agent.get", "agent.message"
        ])
        #expect(!session.allowedToolNames!.contains("local.writeFile"))
        await runtime.shutdown()
    }

    @Test
    func sameProfilePreservesNilParentGrantAsUnrestricted() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: ["local.readFile", "local.writeFile"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in developer },
            parentProfileID: developer.id,
            parentProfileName: developer.name
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("unrestricted-worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: nil
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == nil)
        await runtime.shutdown()
    }

    @Test
    func profileIDDoesNotCollideWithCoordinatorName() async throws {
        let profile = AgentProfile(
            id: "child-profile",
            name: "coordinator-profile",
            tools: ["local.writeFile"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in profile },
            parentProfileID: "coordinator-profile",
            parentProfileName: "Developer"
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("isolated-worker"),
                "profile": .string(profile.name)
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["local.readFile"]
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames?.contains("local.writeFile") == true)
        #expect(session.allowedToolNames?.contains("local.readFile") == false)
        await runtime.shutdown()
    }

    @Test
    func profileNameDoesNotCollideWithCoordinatorID() async throws {
        let profile = AgentProfile(
            id: "coordinator-profile",
            name: "child-profile",
            tools: ["local.writeFile"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in profile },
            parentProfileID: "Developer",
            parentProfileName: "coordinator-profile"
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("isolated-worker"),
                "profile": .string(profile.id)
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["local.readFile"]
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames?.contains("local.writeFile") == true)
        #expect(session.allowedToolNames?.contains("local.readFile") == false)
        await runtime.shutdown()
    }

    @Test
    func profileNameIsFallbackWhenCoordinatorIDIsUnavailable() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: ["local.writeFile"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in developer },
            parentProfileName: developer.name
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("name-matched-worker"),
                "profile": .string(developer.id)
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["local.readFile"]
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames?.contains("local.readFile") == true)
        #expect(session.allowedToolNames?.contains("local.writeFile") == false)
        await runtime.shutdown()
    }
    @Test
    func resolvedPlannerProfileIsComposedIntoCreatedBackendSystemPrompt() async throws {
        let planner = AgentProfile(
            id: AgentProfileStore.plannerAgentID.uuidString,
            name: "Customized Planning Agent",
            instructions: "Preserve this authentic Planner customization.",
            readOnly: false,
            tools: ["local.readFile", "local.writeFile", "external.inspect"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in planner },
            parentProfileID: "developer-profile",
            parentProfileName: "Developer"
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string(PlanningCommandKernel.planAuthorAgentName),
                "role": .string(AgentProfileStore.plannerAgentName),
                "profile": .string(planner.id),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-planner-prompt-tests"),
            parentAllowedToolNames: ["local.writeFile"]
        )

        let session = try #require(await backend.createdSessions().first)
        let systemPrompt = try #require(session.systemPrompt)
        let allowedToolNames = try #require(session.allowedToolNames)
        #expect(systemPrompt.contains("Selected agent: Customized Planning Agent"))
        #expect(systemPrompt.contains("Preserve this authentic Planner customization."))
        #expect(!systemPrompt.contains("Planner workflow policy:"))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(!allowedToolNames.contains("local.writeFile"))
        #expect(allowedToolNames.contains("external.inspect"))
        await runtime.shutdown()
    }

    @Test
    func agentCreateRejectsToolOverrides() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: ["local.readFile", "local.writeFile"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in developer },
            parentProfileID: developer.id,
            parentProfileName: developer.name
        )

        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("implementation-worker"),
                    "profile": .string("Developer"),
                    "toolNames": .array([.string("local.writeFile")])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
                parentAllowedToolNames: ["git.status"]
            )
        }

        #expect(await backend.createdSessions().isEmpty)
        await runtime.shutdown()
    }

    @Test
    func emptyResolvedProfileGrantDoesNotFallBackToParentTools() async throws {
        let minimal = AgentProfile(
            id: "minimal-profile",
            name: "Minimal",
            tools: []
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in minimal },
            parentProfileID: "developer-profile",
            parentProfileName: "Developer"
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("minimal-worker"),
                "profile": .string("Minimal")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["local.readFile", "local.writeFile"]
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == [
            "skills.list", "skills.read", "agent.list", "agent.get", "agent.message"
        ])
        await runtime.shutdown()
    }

    @Test(arguments: [false, true])
    func taskBoundAgentKeepsIntrinsicReportingToolsAlongsideProfileGrant(isWorkflow: Bool) async throws {
        let reporter = AgentProfile(
            id: "reporter-profile",
            name: "Reporter",
            tools: ["local.readFile"]
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: isWorkflow ? .workflow : .manual,
            state: .active,
            tasks: [TaskDefinition(
                id: "report",
                title: "Report findings",
                execution: TaskExecutionSpec(executor: .subAgent)
            )]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in reporter }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object([
                        "name": .string("reporter"),
                        "profile": .string("Reporter"),
                        "taskID": .string("report"),
                    ]),
                ]),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["git.status"],
            rootSessionID: "root"
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == [
            "local.readFile", "tasks.list", "tasks.get", "tasks.update",
            "skills.list", "skills.read", "agent.list", "agent.get", "agent.message"
        ])
        await runtime.shutdown()
    }

    @Test
    func readOnlyTaskBoundAgentGrantRetainsTaskUpdateAndExcludesOtherMutableCoreTools() async throws {
        let rawCompatibilityAlias = "agent.spawn"
        let reviewer = AgentProfile(
            id: "reviewer-profile",
            name: "Reviewer",
            readOnly: true,
            tools: ["files", "memory", "sub-agents", rawCompatibilityAlias]
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "review", title: "Review findings")]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in reviewer },
            parentProfileID: "developer-profile",
            parentProfileName: "Developer"
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("reviewer"),
                "profile": .string("Reviewer"),
                "taskID": .string("review")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["local.writeFile"],
            rootSessionID: "root"
        )

        let session = try #require(await backend.createdSessions().first)
        let allowedToolNames = try #require(session.allowedToolNames)
        let mutatingCoreNames = Set(DirectToolCatalog.coreMutatingDescriptors.map(\.name))
            .subtracting(["agent.message"])

        #expect(allowedToolNames.isDisjoint(with: mutatingCoreNames))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("tasks.list"))
        #expect(allowedToolNames.contains("tasks.get"))
        #expect(allowedToolNames.contains("tasks.update"))
        #expect(allowedToolNames.contains("agent.list"))
        #expect(allowedToolNames.contains("agent.get"))
        #expect(allowedToolNames.contains("agent.message"))
        #expect(!allowedToolNames.contains("agent.create"))
        #expect(allowedToolNames.contains(rawCompatibilityAlias))
        #expect(
            !DirectToolExecutor.isCoreCoordinationToolAllowed(
                rawCompatibilityAlias,
                allowedToolNames: allowedToolNames
            )
        )
        await runtime.shutdown()
    }

    @Test
    func skillToolsAreAlwaysOnAndProviderPropagatesToSubAgentBackend() async throws {
        let skillProvider = PromptSkillSessionProvider(
            skills: [
                PromptSkill(
                    canonicalName: "release-review",
                    title: "Release Review",
                    summary: "Review release changes before publishing.",
                    promptBody: "Review the release carefully.",
                    sourceDirectoryPath: "/tmp/skills/release-review",
                    sourceHash: "release-review-hash"
                )
            ]
        ).asToolProvider()

        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in AgentProfile(id: "worker", name: "Worker", tools: []) }
        )
        await runtime.installPromptSkillToolProvider(skillProvider)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "role": .string("worker"),
                "profile": .string("Worker")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-skill-propagation-tests"),
            parentAllowedToolNames: ["local.readFile", "local.writeFile"]
        )

        // The intrinsic prompt-skill tools must be present in every
        // sub-agent allowlist, regardless of the profile grant.
        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames?.isSuperset(of: PromptSkillToolProvider.toolNames) == true)

        // The parent session's skill provider must be registered on the
        // sub-agent backend so skills.list / skills.read can execute.
        let updates = await backend.toolProviderUpdates
        #expect(updates.count == 1)
        let propagated = try #require(updates.first)
        #expect(propagated.providers.count == 1)
        #expect(propagated.sessionID == session.id)
        let propagatedToolNames = Set(propagated.providers.flatMap(\.tools).map(\.name))
        #expect(propagatedToolNames == PromptSkillToolProvider.toolNames)

        await runtime.shutdown()
    }

    @Test
    func skillProviderNotRegisteredWhenAbsent() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in AgentProfile(id: "worker", name: "Worker", tools: []) }
        )
        // No promptSkillToolProvider installed.

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "role": .string("worker"),
                "profile": .string("Worker")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-skill-absent-tests"),
            parentAllowedToolNames: ["local.readFile"]
        )

        let session = try #require(await backend.createdSessions().first)
        // Skill tools are still in the allowlist (always-on), but no
        // provider update is sent because there is no skill provider.
        #expect(session.allowedToolNames?.isSuperset(of: PromptSkillToolProvider.toolNames) == true)
        let updates = await backend.toolProviderUpdates
        #expect(updates.isEmpty)

        await runtime.shutdown()
    }
}
