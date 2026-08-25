//
//  AgentDelegationRoutingTests.swift
//  ZenCODE
//
//  Created by ZenCODE on 02/07/26.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// Regressions for the canonical delegatable catalog: stale bindings and two
/// providers exposing the same raw model slug.
@Suite
struct AgentDelegationRoutingTests {
    // MARK: - Fixtures

    static let alphaProviderID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let betaProviderID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let sharedSlug = "glm-4.6"

    static var alphaModel: AgentSettingsModelManifest {
        remoteModel(providerID: alphaProviderID, providerName: "Alpha", modelID: sharedSlug)
    }

    static var betaModel: AgentSettingsModelManifest {
        remoteModel(providerID: betaProviderID, providerName: "Beta", modelID: sharedSlug)
    }

    static var alphaModelID: String {
        "remoteapi:\(alphaProviderID.uuidString.lowercased()):\(sharedSlug)"
    }

    static var betaModelID: String {
        "remoteapi:\(betaProviderID.uuidString.lowercased()):\(sharedSlug)"
    }

    static func remoteModel(
        providerID: UUID,
        providerName: String,
        modelID: String
    ) -> AgentSettingsModelManifest {
        AgentSettingsModelManifestFactory.remoteAPIModel(
            title: nil,
            modelID: modelID,
            providerID: providerID,
            providerName: providerName,
            baseURL: "https://\(providerName.lowercased()).example.com/v1",
            chatEndpoint: .chatCompletions,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )
    }

    static func profile(bindings: [AgentModelBinding], defaultBindingID: String? = nil) -> AgentProfile {
        AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: [],
            modelBindings: bindings,
            defaultModelBindingID: defaultBindingID
        )
    }

    // MARK: - Stale bindings

    @Test
    func bindingWhoseModelWasRemovedIsReportedStale() throws {
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(id: "live", modelID: Self.betaModelID, capability: 6),
                AgentModelBinding(
                    id: "ghost",
                    modelID: "remoteapi:99999999-9999-9999-9999-999999999999:removed-model",
                    capability: 9
                )
            ],
            defaultBindingID: "live"
        )

        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            models: [Self.betaModel]
        )

        #expect(resolved.isCatalogAvailable)
        #expect(resolved.bindings.map(\.bindingID) == ["live"])
        #expect(resolved.staleBindings.map(\.binding.id) == ["ghost"])
        let stale = try #require(resolved.staleBindings.first)
        #expect(stale.reason == .modelNotConfigured)
        #expect(stale.diagnostic.contains("no longer configured"))
    }

    @Test
    func staleBindingIsExcludedFromTheDelegatableRoster() throws {
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(id: "live", modelID: Self.betaModelID, capability: 6),
                AgentModelBinding(id: "ghost", modelID: "remoteapi:dead:removed-model", capability: 9)
            ],
            defaultBindingID: "ghost"
        )

        let section = try #require(
            SystemPromptBuilder.delegatableAgentsSection(
                agents: [profile],
                allowedToolNames: nil,
                models: [Self.betaModel]
            )
        )

        #expect(section.contains("pass model: binding:live"))
        #expect(!section.contains("removed-model"))
        #expect(section.contains("provider: Beta"))
        #expect(!section.contains("profile default"))
    }

    @Test
    func authoritativeEmptyCatalogMarksEveryBindingStale() throws {
        let profile = Self.profile(
            bindings: [AgentModelBinding(id: "any", modelID: "offline-model", capability: 4)]
        )

        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            snapshot: .available(models: [])
        )

        #expect(resolved.isCatalogAvailable)
        #expect(resolved.bindings.isEmpty)
        let stale = try #require(resolved.staleBindings.first)
        #expect(stale.reason == .modelNotConfigured)
    }

    @Test
    func unavailableCatalogFailsClosed() throws {
        let profile = Self.profile(
            bindings: [AgentModelBinding(id: "any", modelID: "offline-model", capability: 4)]
        )

        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            snapshot: .unavailable("invalid settings")
        )

        #expect(!resolved.isCatalogAvailable)
        #expect(resolved.bindings.isEmpty)
        let stale = try #require(resolved.staleBindings.first)
        #expect(stale.diagnostic.contains("invalid settings"))
    }

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
                    role: "worker",
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
        let staleModelID = "remoteapi:99999999-9999-9999-9999-999999999999:removed-model"
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

    // MARK: - Two providers sharing one raw model slug

    @Test
    func sameSlugFromTwoProvidersResolvesByCanonicalIdentity() throws {
        let models = [Self.alphaModel, Self.betaModel]
        let profile = Self.profile(
            bindings: [AgentModelBinding(id: "beta", modelID: Self.betaModelID, capability: 7)]
        )

        let resolved = AgentDelegationCatalog.resolvedBindings(for: profile, models: models)
        let binding = try #require(resolved.bindings.first)

        #expect(binding.canonicalModelID == Self.betaModelID)
        #expect(binding.providerModelID == Self.sharedSlug)
        #expect(binding.providerID == Self.betaProviderID)
        #expect(binding.providerTitle == "Beta")
        #expect(binding.routingBinding.modelID == Self.betaModelID)
    }

    @Test
    func rawSlugSharedByTwoProvidersIsNotResolvedWithoutAProviderHint() {
        let models = [Self.alphaModel, Self.betaModel]

        #expect(
            AgentDelegationCatalog.canonicalModelID(
                forReference: Self.sharedSlug,
                models: models
            ) == nil
        )
        #expect(
            AgentDelegationCatalog.canonicalModelID(
                forReference: Self.sharedSlug,
                providerHint: "Beta",
                models: models
            ) == Self.betaModelID
        )
        #expect(
            AgentDelegationCatalog.canonicalModelID(
                forReference: Self.betaModelID,
                models: models
            ) == Self.betaModelID
        )
    }

    @Test
    func bindingOnASharedSlugWithoutProviderIsReportedAmbiguous() throws {
        let profile = Self.profile(
            bindings: [AgentModelBinding(id: "shared", modelID: Self.sharedSlug, capability: 5)]
        )

        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            models: [Self.alphaModel, Self.betaModel]
        )

        #expect(resolved.bindings.isEmpty)
        let stale = try #require(resolved.staleBindings.first)
        #expect(
            stale.reason == .ambiguousModelReference([Self.alphaModelID, Self.betaModelID].sorted())
        )
    }

    @Test
    func duplicatedLLMIDAliasIsRejectedInsteadOfChoosingTheFirstModel() throws {
        let alphaProvider = try #require(Self.alphaModel.provider)
        let betaProvider = try #require(Self.betaModel.provider)
        let alpha = AgentSettingsModelManifest(
            id: Self.alphaModelID,
            kind: .remoteAPI,
            llmID: "shared-alias",
            modelID: "alpha-raw",
            providerID: Self.alphaProviderID,
            provider: alphaProvider
        )
        let beta = AgentSettingsModelManifest(
            id: Self.betaModelID,
            kind: .remoteAPI,
            llmID: "shared-alias",
            modelID: "beta-raw",
            providerID: Self.betaProviderID,
            provider: betaProvider
        )
        let binding = AgentModelBinding(id: "alias", modelID: "shared-alias", capability: 5)

        let result = AgentDelegationCatalog.catalogModel(for: binding, in: [alpha, beta])

        #expect(
            result == .failure(
                .ambiguousModelReference([Self.alphaModelID, Self.betaModelID].sorted())
            )
        )
    }

    @Test
    func legacyUnprefixedReferenceRejectsCrossNamespaceCollision() throws {
        let betaAliasModel = Self.remoteModel(
            providerID: Self.betaProviderID,
            providerName: "Beta",
            modelID: "alias-model"
        )
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(
                    id: "alias-model",
                    modelID: Self.alphaModelID,
                    capability: 4
                ),
                AgentModelBinding(
                    id: "beta",
                    modelID: betaAliasModel.id,
                    capability: 7
                ),
            ]
        )
        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            models: [Self.alphaModel, betaAliasModel]
        )

        if case let .ambiguous(candidates) = resolved.selection(for: "alias-model") {
            #expect(candidates == ["binding:alias-model", "binding:beta"])
        } else {
            Issue.record("Expected the unprefixed cross-namespace reference to be ambiguous.")
        }
        if case let .selected(binding) = resolved.selection(for: "binding:alias-model") {
            #expect(binding.bindingID == "alias-model")
        } else {
            Issue.record("Expected the namespaced binding reference to remain unambiguous.")
        }
    }

    @Test
    func multipleBindingsConvergingOnOneCanonicalModelFailClosed() throws {
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(id: "canonical", modelID: Self.betaModelID, capability: 7),
                AgentModelBinding(
                    id: "legacy",
                    modelID: Self.sharedSlug,
                    modelProvider: "Beta",
                    capability: 5
                ),
            ]
        )

        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            models: [Self.alphaModel, Self.betaModel]
        )

        #expect(resolved.bindings.isEmpty)
        #expect(Set(resolved.staleBindings.map(\.binding.id)) == ["canonical", "legacy"])
        #expect(resolved.staleBindings.allSatisfy {
            if case .duplicateCanonicalModel = $0.reason { return true }
            return false
        })
    }

    @Test
    func promptAndRuntimeShareCapabilityEligibilityExactly() throws {
        let alphaOnly = Self.remoteModel(
            providerID: Self.alphaProviderID,
            providerName: "Alpha",
            modelID: "alpha-only"
        )
        let betaOnly = Self.remoteModel(
            providerID: Self.betaProviderID,
            providerName: "Beta",
            modelID: "beta-only"
        )
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(id: "listed", modelID: alphaOnly.id, capability: 5),
                AgentModelBinding(id: "no-capability", modelID: betaOnly.id),
            ]
        )
        let models = [alphaOnly, betaOnly]
        let section = try #require(
            SystemPromptBuilder.delegatableAgentsSection(
                agents: [profile],
                allowedToolNames: nil,
                models: models
            )
        )
        #expect(section.contains("binding:listed"))
        #expect(!section.contains("binding:no-capability"))

        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.resolvingModelBinding(
                for: DirectSubAgentRuntime.RequestedAgentPayload(
                    name: "worker",
                    role: "worker",
                    profileReference: "Developer",
                    modelID: "binding:no-capability"
                ),
                profile: profile,
                snapshot: .available(models: models)
            )
        }
    }

    @Test
    func ambiguousProfileNameOrCrossIDNameCollisionFailsClosed() async throws {
        let duplicateNameProfiles = [
            AgentProfile(
                id: "first",
                name: "Shared",
                tools: ["files"],
                modelBindings: [
                    AgentModelBinding(id: "alpha", modelID: Self.alphaModelID, capability: 4)
                ]
            ),
            AgentProfile(
                id: "second",
                name: "Shared",
                tools: ["shell"],
                modelBindings: [
                    AgentModelBinding(id: "beta", modelID: Self.betaModelID, capability: 7)
                ]
            ),
        ]
        let crossCollisionProfiles = [
            AgentProfile(id: "Reviewer", name: "Developer"),
            AgentProfile(id: "second", name: "Reviewer"),
        ]

        #expect(AgentProfileStore.ambiguousProfileReferences(in: duplicateNameProfiles) == ["shared"])
        #expect(AgentProfileStore.agent(matching: "Shared", in: duplicateNameProfiles) == nil)
        #expect(AgentProfileStore.agent(matching: "Reviewer", in: crossCollisionProfiles) == nil)
        #expect(
            AgentDelegationCatalog.roster(
                agents: duplicateNameProfiles,
                models: [Self.alphaModel, Self.betaModel]
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
    func profileReferenceIdentityUsesPOSIXCaseFolding() {
        let latinUpper = AgentProfileStore.profileReferenceKey("I")
        let latinLower = AgentProfileStore.profileReferenceKey("i")
        let dottedUpper = AgentProfileStore.profileReferenceKey("İ")
        let dotlessLower = AgentProfileStore.profileReferenceKey("ı")

        #expect(latinUpper == latinLower)
        #expect(dottedUpper == latinLower)
        #expect(dotlessLower != latinLower)
    }

    @Test
    func subscriptionPreflightMatchesPersistedAndEnvironmentCredentialRules() {
        let blankChatGPT = CodexAgentCredentials(
            accessToken: " ",
            refreshToken: "refresh",
            expiresAt: Date(),
            accountID: "account"
        )
        let blankAnthropic = AnthropicSubscriptionCredentials(
            accessToken: "token",
            refreshToken: " ",
            expiresAt: Date(),
            scope: nil
        )

        #expect(
            !AgentDelegationCatalogSnapshot.hasUsableChatGPTCredentials(
                blankChatGPT,
                environment: [:]
            )
        )
        #expect(
            AgentDelegationCatalogSnapshot.hasUsableChatGPTCredentials(
                nil,
                environment: [
                    "CHATGPT_ACCESS_TOKEN": "environment-token",
                    "CHATGPT_ACCOUNT_ID": "environment-account",
                ]
            )
        )
        #expect(
            !AgentDelegationCatalogSnapshot.hasUsableAnthropicCredentials(
                blankAnthropic,
                environment: [:]
            )
        )
        #expect(
            AgentDelegationCatalogSnapshot.hasUsableAnthropicCredentials(
                nil,
                environment: ["ANTHROPIC_ACCESS_TOKEN": "environment-token"]
            )
        )
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
    func subAgentConfigurationKeepsTheCanonicalModelIDInsteadOfTheSharedSlug() throws {
        let parentConfiguration = AgentRuntimeConfiguration(
            modelID: Self.alphaModelID,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
        let profile = Self.profile(
            bindings: [AgentModelBinding(id: "beta", modelID: Self.betaModelID, capability: 7)]
        )
        let snapshot = AgentDelegationCatalogSnapshot.available(
            models: [Self.alphaModel, Self.betaModel]
        )
        let resolvedBinding = try #require(
            AgentDelegationCatalog.resolvedBindings(
                for: profile,
                snapshot: snapshot
            ).bindings.first
        )
        let modelSelection = try #require(snapshot.modelSelection(for: resolvedBinding))
        let context = DirectSubAgentRuntime.BackendContext(
            requestedName: "worker",
            requestedRole: "worker",
            profile: profile,
            modelBinding: resolvedBinding.routingBinding,
            modelSelection: modelSelection,
            modelID: "binding:beta"
        )

        let resolved = parentConfiguration.applyingSubAgentBackendContext(context)

        #expect(resolved.modelID == Self.betaModelID)
        #expect(resolved.modelID != Self.sharedSlug)
    }

    @Test
    func canonicalReferenceForLegacyRawBindingIsAcceptedEndToEnd() throws {
        let parentConfiguration = AgentRuntimeConfiguration(
            modelID: Self.alphaModelID,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(
                    id: "legacy",
                    modelID: Self.sharedSlug,
                    modelProvider: "Beta",
                    capability: 7
                )
            ]
        )
        let snapshot = AgentDelegationCatalogSnapshot.available(
            models: [Self.alphaModel, Self.betaModel]
        )
        let payload = DirectSubAgentRuntime.RequestedAgentPayload(
            name: "worker",
            role: "worker",
            profileReference: "Developer",
            modelID: Self.betaModelID
        )
        let routedPayload = try DirectSubAgentRuntime.resolvingModelBinding(
            for: payload,
            profile: profile,
            snapshot: snapshot
        )
        let context = DirectSubAgentRuntime.backendContext(
            for: routedPayload,
            profile: profile
        )

        let resolved = parentConfiguration.applyingSubAgentBackendContext(context)

        #expect(context.modelBinding?.id == "legacy")
        #expect(context.modelID == Self.betaModelID)
        #expect(context.modelSelection?.remoteProvider?.id == Self.betaProviderID)
        #expect(resolved.modelID == Self.betaModelID)
    }

    @Test
    func backendFactoryUsesTheSnapshotProviderInsteadOfFallbackOrGlobalSlugLookup() async throws {
        let profile = Self.profile(
            bindings: [
                AgentModelBinding(id: "beta", modelID: Self.betaModelID, capability: 7)
            ]
        )
        let manifest = AgentSettingsManifest(
            models: [Self.alphaModel, Self.betaModel],
            remoteAPIKeysByProviderID: [
                Self.alphaProviderID.uuidString.lowercased(): "alpha-key",
                Self.betaProviderID.uuidString.lowercased(): "beta-key",
            ]
        )
        let snapshot = AgentDelegationCatalogSnapshot.available(manifest)
        let routedPayload = try DirectSubAgentRuntime.resolvingModelBinding(
            for: DirectSubAgentRuntime.RequestedAgentPayload(
                name: "worker",
                role: "worker",
                profileReference: "Developer",
                modelID: "binding:beta"
            ),
            profile: profile,
            snapshot: snapshot
        )
        let context = DirectSubAgentRuntime.backendContext(
            for: routedPayload,
            profile: profile
        )
        let configuration = AgentRuntimeConfiguration(
            modelID: Self.alphaModelID,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        ).applyingSubAgentBackendContext(context)

        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: DirectMCPToolRuntime(),
            fallbackProvider: Self.alphaModel.provider,
            fallbackAPIKey: "alpha-key",
            resolvedModelSelection: context.modelSelection
        )
        let remote = try #require(backend as? RemoteGenerationClient)

        #expect(await remote.provider.id == Self.betaProviderID)
        #expect(await remote.provider.modelID == Self.sharedSlug)
        #expect(await remote.apiKey == "beta-key")
        await remote.shutdown()
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
