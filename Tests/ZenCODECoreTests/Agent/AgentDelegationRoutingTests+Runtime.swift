//
//  AgentDelegationRoutingTests+Runtime.swift
//  ZenCODE
//
//  Delegation routing tests that drive DirectSubAgentRuntime through a probe
//  backend: stale bindings, ambiguous profiles and qualified model
//  identities.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension AgentDelegationRoutingTests {
    @Test
    func liveSnapshotExcludesProviderThatRequiresAMissingAPIKey() async throws {
        let keyedModel = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: nil,
            modelID: Self.sharedSlug,
            providerID: Self.betaProviderID,
            providerName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            chatEndpoint: .chatCompletions,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(id: "beta", modelID: keyedModel.id, capability: 7)
            ]
        )
        let liveSnapshot = AgentDelegationCatalogSnapshot.available(
            AgentSettingsManifest(models: [keyedModel])
        )
        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            snapshot: liveSnapshot
        )

        #expect(resolved.bindings.isEmpty)
        let stale = try #require(resolved.staleBindings.first)
        #expect(stale.diagnostic.contains("no API key"))
        let section = try #require(
            SystemPromptBuilder.delegatableAgentsSection(
                agents: [profile],
                allowedToolNames: nil,
                snapshot: liveSnapshot
            )
        )
        #expect(section.contains("No configured profile currently has a routable model binding"))

        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.resolvingModelBinding(
                for: DirectSubAgentRuntime.RequestedAgentPayload(
                    name: "worker",
                    profileReference: "Developer",
                    modelID: "binding:beta"
                ),
                profile: profile,
                snapshot: liveSnapshot
            )
        }

        let catalogOnly = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            snapshot: .available(models: [keyedModel])
        )
        #expect(catalogOnly.bindings.map(\.bindingID) == ["beta"])

        let backend = RoutingProbeBackend()
        let factoryCalls = Mutex<Int>(0)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in
                factoryCalls.withLock { $0 += 1 }
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [profile])
            },
            modelCatalogProvider: { liveSnapshot }
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "missing-key-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-key", title: "Work", complexity: 5)]
        )
        await runtime.installTaskOrchestrator(orchestrator)

        await #expect(throws: DirectSubAgentRuntimeError.self) {
            try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object([
                            "profile": .string("Developer"),
                            "model": .string("binding:beta"),
                            "taskID": .string("task-key"),
                        ]),
                    ]),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
        }
        let task = try await orchestrator.task(sessionID: "root", taskID: "task-key")
        #expect(task.task.attempts.isEmpty)
        #expect(factoryCalls.withLock { $0 } == 0)
        #expect(await backend.createdSessionCount() == 0)
        await runtime.shutdown()
    }

    @Test
    func staleBindingIsRejectedBeforeTaskClaimAndBackendCreation() async throws {
        let staleModelID = "nvidia:removed-model"
        let profile = Self.profile(
            bindings: [AgentModelBinding(id: "ghost", modelID: staleModelID, capability: 9)]
        )
        let backend = RoutingProbeBackend()
        let factoryCallCount = Mutex<Int>(0)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in
                factoryCallCount.withLock { $0 += 1 }
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [profile])
            },
            modelCatalogProvider: { .available(models: [Self.betaModel]) }
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "Work", complexity: 5)]
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("worker"),
                    "profile": .string("Developer"),
                    "model": .string(staleModelID),
                    "taskID": .string("task-a")
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-delegation-routing-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
            Issue.record("Expected a stale model binding to be rejected.")
        } catch let DirectSubAgentRuntimeError.modelBindingUnavailable(modelID, profileName, reason) {
            #expect(modelID == staleModelID)
            #expect(profileName == "Developer")
            #expect(reason.contains("no longer configured"))
        }

        #expect(factoryCallCount.withLock { $0 } == 0)
        #expect(await backend.createdSessionCount() == 0)
        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a")
        #expect(task.task.attempts.isEmpty)
        #expect(task.task.status == .pending)
        await runtime.shutdown()
    }

    @Test
    func ambiguousProfileNameOrCrossIDNameCollisionFailsClosed() async throws {
        let duplicateNameProfiles = [
            AgentProfile(
                id: "first",
                name: "Shared",
                role: .developer,
                tools: ["files"],
                modelBindings: [
                    AgentModelBinding(id: "alpha", modelID: Self.alphaModelID, capability: 4)
                ]
            ),
            AgentProfile(
                id: "second",
                name: "Shared",
                role: .developer,
                tools: ["shell"],
                modelBindings: [
                    AgentModelBinding(id: "beta", modelID: Self.betaModelID, capability: 7)
                ]
            ),
        ]
        let crossCollisionProfiles = [
            AgentProfile(id: "Reviewer", name: "Developer", role: .developer),
            AgentProfile(id: "second", name: "Reviewer", role: .reviewer),
        ]

        #expect(AgentProfileStore.ambiguousProfileReferences(in: duplicateNameProfiles) == ["shared"])
        #expect(AgentProfileStore.agent(matching: "Shared", in: duplicateNameProfiles) == nil)
        #expect(AgentProfileStore.agent(matching: "Reviewer", in: crossCollisionProfiles) == nil)
        #expect(
            AgentDelegationCatalog.roster(
                agents: duplicateNameProfiles,
                snapshot: .available(models: [Self.alphaModel, Self.betaModel])
            ).isEmpty
        )

        let backend = RoutingProbeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(
                    matching: payload,
                    in: duplicateNameProfiles
                )
            },
            modelCatalogProvider: {
                .available(models: [Self.alphaModel, Self.betaModel])
            }
        )
        await #expect(throws: DirectSubAgentRuntimeError.self) {
            try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object([
                            "profile": .string("Shared"),
                            "model": .string("binding:alpha"),
                        ]),
                    ]),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                parentAllowedToolNames: nil
            )
        }
        #expect(await backend.createdSessionCount() == 0)
        await runtime.shutdown()
    }

    @Test
    func qualifiedModelIDKeepsProviderIdentityUpToTheBackendContext() async throws {
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(id: "alpha", modelID: Self.alphaModelID, capability: 4),
                AgentModelBinding(id: "beta", modelID: Self.betaModelID, capability: 7)
            ],
            defaultBindingID: "alpha"
        )
        let backend = RoutingProbeBackend()
        let contexts = Mutex<[DirectSubAgentRuntime.BackendContext]>([])
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                contexts.withLock { $0.append(context) }
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [profile])
            },
            modelCatalogProvider: { .available(models: [Self.alphaModel, Self.betaModel]) }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "model": .string(Self.betaModelID)
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-delegation-routing-tests"),
            parentAllowedToolNames: nil
        )

        let context = try #require(contexts.withLock { $0.first })
        #expect(context.modelID == Self.betaModelID)
        #expect(context.modelID != Self.sharedSlug)
        #expect(context.modelBinding?.id == "beta")
        #expect(context.modelBinding?.modelProvider == "Beta")
        await runtime.shutdown()
    }

    @Test
    func rawModelReferenceSharedByTwoAuthorizedBindingsIsRejected() async throws {
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(id: "alpha", modelID: Self.alphaModelID, capability: 4),
                AgentModelBinding(id: "beta", modelID: Self.betaModelID, capability: 7)
            ],
            defaultBindingID: "alpha"
        )
        let backend = RoutingProbeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [profile])
            },
            modelCatalogProvider: { .available(models: [Self.alphaModel, Self.betaModel]) }
        )

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("worker"),
                    "profile": .string("Developer"),
                    "model": .string(Self.sharedSlug)
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-delegation-routing-tests"),
                parentAllowedToolNames: nil
            )
            Issue.record("Expected an ambiguous raw model reference to be rejected.")
        } catch let DirectSubAgentRuntimeError.ambiguousModelReference(modelID, profileName, candidates) {
            #expect(modelID == Self.sharedSlug)
            #expect(profileName == "Developer")
            #expect(candidates == ["binding:alpha", "binding:beta"])
        }

        #expect(await backend.createdSessionCount() == 0)
        await runtime.shutdown()
    }
}

/// Minimal backend double owned by this suite so the regressions stay isolated
/// from the shared sub-agent runtime test fixtures.
private actor RoutingProbeBackend: AgentRuntimeBackend {
    private var createdSessions = 0

    func installTaskOrchestrator(_ orchestrator: SessionTaskOrchestrator) async {}

    func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String?
    ) async {}

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        createdSessions += 1
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createdSessions += 1
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "routing-probe"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "done", stopReason: "stop", modelID: "routing-probe")
    }

    func snapshotSession(id _: String) -> AgentRuntimeSessionSnapshot? {
        nil
    }

    func createdSessionCount() -> Int {
        createdSessions
    }
}
