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

    static let alphaProviderID = "openrouter"
    static let betaProviderID = "deepseek"
    static let sharedSlug = "glm-4.6"

    static var alphaModel: AgentSettingsModelManifest {
        remoteModel(providerID: alphaProviderID, providerName: "Alpha", modelID: sharedSlug)
    }

    static var betaModel: AgentSettingsModelManifest {
        remoteModel(providerID: betaProviderID, providerName: "Beta", modelID: sharedSlug)
    }

    static var alphaModelID: String {
        "\(alphaProviderID):\(sharedSlug)"
    }

    static var betaModelID: String {
        "\(betaProviderID):\(sharedSlug)"
    }

    static func remoteModel(
        providerID: String,
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

    /// The system developer profile, so a project without a saved agent
    /// selection may delegate to it.
    static func profile(bindings: [AgentModelBinding], defaultBindingID: String? = nil) -> AgentProfile {
        AgentProfile(
            id: AgentProfileRole.developer.rawValue,
            name: "Developer",
            role: .developer,
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
                    modelID: "nvidia:removed-model",
                    capability: 9
                )
            ],
            defaultBindingID: "live"
        )

        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            snapshot: .available(models: [Self.betaModel])
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
                AgentModelBinding(id: "ghost", modelID: "modal:removed-model", capability: 9)
            ],
            defaultBindingID: "ghost"
        )

        let section = try #require(
            SystemPromptBuilder.delegatableAgentsSection(
                agents: [profile],
                allowedToolNames: nil,
                snapshot: .available(models: [Self.betaModel])
            )
        )

        #expect(section.contains("pass model: binding:live"))
        #expect(!section.contains("removed-model"))
        #expect(section.contains("provider: Beta"))
        #expect(!section.contains("profile default"))
        // The roster keeps only its own format instructions; the tool-grant and
        // model-inheritance rules live once, in the agent.create contract and in
        // the per-profile "no configured bindings" line.
        #expect(section.contains("Give each sub-agent an explicit scope."))
        #expect(section.contains("Do not substitute provider names"))
        #expect(!section.contains("inherits the coordinator's effective session allowlist"))
        #expect(!section.contains("For profiles without bindings, omit `model`"))
    }

    @Test
    func profileWithoutBindingsCarriesTheModelInheritanceRuleOnItsOwnLine() throws {
        let section = try #require(
            SystemPromptBuilder.delegatableAgentsSection(
                agents: [Self.profile(bindings: [])],
                allowedToolNames: nil,
                snapshot: .available(models: [Self.betaModel])
            )
        )

        #expect(section.contains(
            "  - no configured bindings: inherits the main session model and provider; omit `model`."
        ))
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

    // MARK: - Two providers sharing one raw model slug

    @Test
    func sameSlugFromTwoProvidersResolvesByCanonicalIdentity() throws {
        let models = [Self.alphaModel, Self.betaModel]
        let profile = Self.profile(
            bindings: [AgentModelBinding(id: "beta", modelID: Self.betaModelID, capability: 7)]
        )

        let resolved = AgentDelegationCatalog.resolvedBindings(for: profile, snapshot: .available(models: models))
        let binding = try #require(resolved.bindings.first)

        #expect(binding.canonicalModelID == Self.betaModelID)
        #expect(binding.providerModelID == Self.sharedSlug)
        #expect(binding.providerTitle == "Beta")
        #expect(binding.routingBinding.modelID == Self.betaModelID)
    }

    @Test
    func bindingOnASharedSlugWithoutProviderIsReportedAmbiguous() throws {
        let profile = Self.profile(
            bindings: [AgentModelBinding(id: "shared", modelID: Self.sharedSlug, capability: 5)]
        )

        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            snapshot: .available(models: [Self.alphaModel, Self.betaModel])
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
            snapshot: .available(models: [Self.alphaModel, betaAliasModel])
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
                snapshot: .available(models: models)
            )
        )
        #expect(section.contains("binding:listed"))
        #expect(!section.contains("binding:no-capability"))

        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.resolvingModelBinding(
                for: DirectSubAgentRuntime.RequestedAgentPayload(
                    name: "worker",
                    profileReference: "Developer",
                    modelID: "binding:no-capability"
                ),
                profile: profile,
                snapshot: .available(models: models)
            )
        }
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
                Self.alphaProviderID: "alpha-key",
                Self.betaProviderID: "beta-key",
            ]
        )
        let snapshot = AgentDelegationCatalogSnapshot.available(manifest)
        let routedPayload = try DirectSubAgentRuntime.resolvingModelBinding(
            for: DirectSubAgentRuntime.RequestedAgentPayload(
                name: "worker",
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
}
