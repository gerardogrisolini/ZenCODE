import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    private static let catalogProviderID = "custom"

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
            #expect(argument == "profile or profileRole")
        }
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
}
