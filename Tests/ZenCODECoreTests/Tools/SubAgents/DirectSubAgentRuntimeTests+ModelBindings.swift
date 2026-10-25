import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    private static let catalogProviderID = UUID(
        uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )!

    private static func catalogSnapshot(
        _ modelIDs: [String]
    ) -> AgentDelegationCatalogSnapshot {
        .available(
            models: modelIDs.map { modelID in
                AgentSettingsModelManifestFactory.remoteAPIModel(
                    title: nil,
                    modelID: modelID,
                    providerID: catalogProviderID,
                    providerName: "Test Provider",
                    baseURL: "https://tests.example.com/v1",
                    chatEndpoint: .chatCompletions,
                    configuredContextWindowLimit: nil,
                    generationParameterOverrides: nil,
                    thinkingSupport: .effort()
                )
            }
        )
    }

    @Test
    func createAgentsUsesExplicitProfileModel() async throws {
        let planner = AgentProfile(
            id: AgentProfileRole.planner.rawValue,
            name: "Planner",
            role: .planner,
            tools: [],
            modelID: "planner-model",
            thinkingSelection: .high,
            capability: 7
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(
                    matching: payload,
                    in: [planner]
                )
            },
            modelCatalogProvider: { Self.catalogSnapshot(["planner-model"]) }
        )

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("planning-pass"),
                "role": .string("Planner"),
                "profile": .string("Planner"),
                "model": .string("planner-model"),
                "prompt": .string("Create the plan")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.profile == planner)
        #expect(context.modelID?.hasSuffix(":planner-model") == true)
        #expect(context.thinkingSelection == .high)
        #expect(await backend.createdThinkingSelection() == .high)

        await runtime.waitForDirectSubAgentTestWorkLoops()
        let snapshot = try #require(await runtime.snapshots().first)
        #expect(snapshot.profileID == planner.id)
        #expect(snapshot.profileName == planner.name)
        #expect(snapshot.configuredModelID == context.modelID)
        #expect(snapshot.modelID == "test-model")
        #expect(output.contains("planner-model"))
    }

    @Test
    func legacyCustomResolverMayReadSettingsWithoutReentrantFileLock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-legacy-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = AgentProfile(id: AgentProfileRole.developer.rawValue, name: "Custom", role: .developer)
        let backend = CapturingSubAgentRuntimeBackend()

        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [])
            )
            let runtime = DirectSubAgentRuntime(
                contextualBackendFactory: { _ in backend },
                profileResolver: { _ in
                    _ = AgentSettingsManifestStore.load()
                    return profile
                }
            )

            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object([
                            "profile": .string("Custom"),
                            "name": .string("child"),
                            "role": .string("role"),
                            "prompt": .string("work"),
                        ])
                    ])
                ],
                workingDirectory: directory,
                parentAllowedToolNames: nil
            )
            #expect(await backend.createdSessions().count == 1)
            await runtime.shutdown()
        }
    }

    @Test
    func createAgentsUsesExplicitModelBindingAuthorizedByProfile() async throws {
        let developer = AgentProfile(
            id: AgentProfileRole.developer.rawValue,
            name: "Developer",
            role: .developer,
            tools: [],
            modelBindings: [
                AgentModelBinding(
                    id: "balanced",
                    modelID: "balanced-model",
                    thinkingSelection: .low,
                    capability: 5
                ),
                AgentModelBinding(
                    id: "deep",
                    modelID: "deep-model",
                    thinkingSelection: .high,
                    capability: 9
                )
            ],
            defaultModelBindingID: "balanced"
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [developer])
            },
            modelCatalogProvider: {
                Self.catalogSnapshot(["balanced-model", "deep-model"])
            }
        )

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("architecture-pass"),
                "profile": .string("Developer"),
                "model": .string("deep")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.modelBinding?.id == "deep")
        #expect(context.modelID?.hasSuffix(":deep-model") == true)
        #expect(context.thinkingSelection == .high)
        #expect(context.capability == 9)
        #expect(await backend.createdThinkingSelection() == .high)
        #expect(output.contains("deep-model"))
    }

    @Test
    func createAgentsRejectsModelOutsideProfileBindings() async throws {
        let developer = AgentProfile(
            id: AgentProfileRole.developer.rawValue,
            name: "Developer",
            role: .developer,
            tools: [],
            modelBindings: [
                AgentModelBinding(modelID: "allowed-model", capability: 5)
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [developer])
            }
        )

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("unauthorized"),
                    "profile": .string("Developer"),
                    "modelID": .string("other-model")
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
                parentAllowedToolNames: nil
            )
            Issue.record("Expected an unauthorized model binding to be rejected.")
        } catch DirectSubAgentRuntimeError.modelNotAllowedForProfile(let modelID, let profile) {
            #expect(modelID == "other-model")
            #expect(profile == "Developer")
        }
    }

    @Test
    func createAgentsRejectsMissingProfileEvenWithExplicitModel() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in nil }
        )

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("unbound"),
                    "model": .string("other-model")
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
                parentAllowedToolNames: nil
            )
            Issue.record("Expected an explicit model without a profile to be rejected.")
        } catch DirectSubAgentRuntimeError.missingArgument(let argument) {
            #expect(argument == "profile or agent")
        }
    }

    @Test
    func createAgentsRejectsUnknownProfile() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in nil }
        )

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("review-pass"),
                    "profile": .string("Rewiever")
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
                parentAllowedToolNames: nil
            )
            Issue.record("Expected an unknown profile to be rejected.")
        } catch DirectSubAgentRuntimeError.agentProfileNotFound(let profile) {
            #expect(profile == "Rewiever")
        }
    }

    @Test
    func createAgentsWarnsWhenTaskComplexityExceedsProfileCapability() async throws {
        let minimal = AgentProfile(
            id: AgentProfileRole.minimal.rawValue,
            name: "Minimal",
            role: .minimal,
            tools: [],
            modelID: "minimal-model",
            capability: 5
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [minimal])
            },
            modelCatalogProvider: { Self.catalogSnapshot(["minimal-model"]) }
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "default", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "hard-task", title: "Hard work", complexity: 9)]
        )
        await runtime.installTaskOrchestrator(orchestrator)

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Minimal"),
                "model": .string("minimal-model"),
                "taskID": .string("hard-task")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        #expect(output.contains("Warning: task \"hard-task\" has complexity 9"))
        #expect(output.contains("capability 5/10"))
        #expect(output.contains("capability gap of 4"))
        #expect(output.contains("role-compatible profile"))
    }

    @Test
    func capabilityAdvisoryUsesTheSelectedBinding() async throws {
        let developer = AgentProfile(
            id: AgentProfileRole.developer.rawValue,
            name: "Developer",
            role: .developer,
            tools: [],
            modelBindings: [
                AgentModelBinding(id: "light", modelID: "light-model", capability: 3),
                AgentModelBinding(id: "power", modelID: "power-model", capability: 8)
            ],
            defaultModelBindingID: "light"
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [developer])
            },
            modelCatalogProvider: {
                Self.catalogSnapshot(["light-model", "power-model"])
            }
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "default", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "hard-task", title: "Hard work", complexity: 9)]
        )
        await runtime.installTaskOrchestrator(orchestrator)

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "model": .string("power"),
                "taskID": .string("hard-task")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        #expect(output.contains("power-model"))
        #expect(output.contains("at capability 8/10"))
        #expect(output.contains("capability gap of 1"))
        #expect(!output.contains("capability gap of 6"))
    }

    @Test
    func agentCreateRequiresModelWhenTheProfileHasBindings() async throws {
        let developer = AgentProfile(
            id: AgentProfileRole.developer.rawValue,
            name: "Developer",
            role: .developer,
            tools: [],
            modelBindings: [AgentModelBinding(modelID: "balanced-model")]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [developer])
            }
        )

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("worker"),
                    "profile": .string("Developer"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
                parentAllowedToolNames: nil
            )
            Issue.record("Expected a profile with bindings to require model.")
        } catch DirectSubAgentRuntimeError.missingArgument(let argument) {
            #expect(argument == "model")
        }

        #expect(await backend.createdSessions().isEmpty)
        await runtime.shutdown()
    }

    @Test(arguments: [false, true])
    func createAgentWithoutModelProfileInheritsParentConfiguration(catalogAvailable: Bool) async throws {
        let minimal = AgentProfile(
            id: AgentProfileRole.minimal.rawValue,
            name: "Minimal",
            role: .minimal,
            tools: []
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(
                    matching: payload,
                    in: [minimal]
                )
            },
            modelCatalogProvider: {
                catalogAvailable ? .available(models: []) : .unavailable("test catalog unavailable")
            }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object([
                        "name": .string("quick-task"),
                        "role": .string("Minimal"),
                        "profile": .string("Minimal"),
                    ]),
                ]),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.profile == minimal)
        #expect(context.modelID == nil)
        #expect(context.modelBinding == nil)
        #expect(context.modelSelection == nil)
        #expect(context.thinkingSelection == nil)
        #expect(await backend.createdSessions().count == 1)
        await runtime.shutdown()
    }

    @Test
    func applyingSubAgentBackendContextUsesOnlyAnExplicitlyResolvedBinding() {
        let parentConfig = AgentRuntimeConfiguration(
            modelID: "parent-model",
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
        let profile = AgentProfile(
            id: "builder",
            name: "Builder",
            role: .builder,
            modelID: "builder-model"
        )
        let context = DirectSubAgentRuntime.BackendContext(
            requestedName: "Builder",
            requestedRole: "worker",
            profile: profile,
            modelBinding: AgentModelBinding(
                id: "builder-model",
                modelID: "builder-model",
                capability: 5
            ),
            modelID: "binding:builder-model"
        )
        let result = parentConfig.applyingSubAgentBackendContext(context)
        #expect(result.modelID == "builder-model")
    }

    @Test
    func applyingSubAgentBackendContextPreservesModelWhenProfileHasNoModel() {
        let parentConfig = AgentRuntimeConfiguration(
            modelID: "parent-model",
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
        let profile = AgentProfile(
            id: "minimal",
            name: "Minimal",
            role: .minimal
        )
        let context = DirectSubAgentRuntime.BackendContext(
            requestedName: "Minimal",
            requestedRole: "worker",
            profile: profile
        )
        let result = parentConfig.applyingSubAgentBackendContext(context)
        #expect(result.modelID == "parent-model")
    }

    @Test
    func applyingSubAgentBackendContextPreservesModelWhenLockedToSession() {
        let parentConfig = AgentRuntimeConfiguration(
            modelID: "local-model",
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            locksModelToSession: true,
            toolAuthorizationHandler: nil
        )
        let profile = AgentProfile(
            id: "builder",
            name: "Builder",
            role: .builder,
            modelID: "some-other-model"
        )
        let context = DirectSubAgentRuntime.BackendContext(
            requestedName: "Builder",
            requestedRole: "worker",
            profile: profile
        )
        let result = parentConfig.applyingSubAgentBackendContext(context)
        #expect(result.modelID == "local-model")
    }
}
