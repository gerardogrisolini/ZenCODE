//
//  ZenCODESetupRunner+MemoryEmbedding.swift
//  ZenCODE
//

import Foundation

extension ZenCODESetupRunner {
    enum MemoryEmbeddingSetupChoice: Hashable {
        case bm25Only
        case configureEndpoint
        case removeConfiguration
        case openRouter
    }

    /// The precompiled OpenRouter embedding proposal produced only when at least
    /// one configured provider in `settings.json` is OpenRouter. `providerID`
    /// pins the provider whose API key the resolver reuses at runtime; it is a
    /// non-secret UUID reference, never a duplicated credential.
    struct MemoryEmbeddingOpenRouterProposal: Equatable, Sendable {
        let endpoint: String
        let model: String
        let providerID: UUID
    }

    /// The endpoint/model/provider reference chosen by setup. `nil` endpoint
    /// disables embeddings (BM25 only).
    struct MemoryEmbeddingSetupSelection: Equatable, Sendable {
        var endpoint: String?
        var model: String?
        var providerID: UUID?

        init(endpoint: String?, model: String? = nil, providerID: UUID? = nil) {
            self.endpoint = endpoint
            self.model = model
            self.providerID = providerID
        }
    }

    /// Configures optional semantic embeddings for memory retrieval.
    ///
    /// The prompt deliberately asks for only an endpoint (plus an optional
    /// model when a provider preset applies). It validates the URL locally and
    /// does not contact the endpoint, enumerate models, or ask for credentials.
    /// Choosing no endpoint leaves retrieval on pure BM25.
    static func configureMemoryEmbedding(
        in manifest: AgentSettingsManifest?
    ) throws -> AgentSettingsManifest {
        let selection = try promptMemoryEmbeddingSettings(
            existingSettings: manifest?.memoryEmbedding,
            openRouterProposal: openRouterEmbeddingProposal(in: manifest)
        )
        return try manifestByUpdatingMemoryEmbedding(
            manifest,
            endpoint: selection.endpoint,
            model: selection.model,
            providerID: selection.providerID
        )
    }

    /// Pure, I/O-free detection of the OpenRouter embedding preset. Returns a
    /// precompiled proposal (endpoint, model, referenced provider ID) only when
    /// a provider configured in `manifest.providers` is OpenRouter; `nil`
    /// otherwise. The first OpenRouter provider is the deterministic selection
    /// the user sees in the menu detail.
    static func openRouterEmbeddingProposal(
        in manifest: AgentSettingsManifest?
    ) -> MemoryEmbeddingOpenRouterProposal? {
        guard let manifest,
              let provider = manifest.providers.first(where: {
                  AgentRemoteProvider.isOpenRouterBaseURL($0.baseURL)
              }) else {
            return nil
        }
        return MemoryEmbeddingOpenRouterProposal(
            endpoint: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsEndpoint,
            model: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsModel,
            providerID: provider.id
        )
    }

    /// Pure menu construction used by the interactive prompt and by tests.
    /// The OpenRouter proposal appears as an immediately visible choice only
    /// when non-nil; default selections are unchanged (BM25-only when no
    /// endpoint, change endpoint when one exists) to preserve existing UX.
    static func memoryEmbeddingSetupMenu(
        existingSettings: AgentMemoryEmbeddingSettingsManifest?,
        openRouterProposal: MemoryEmbeddingOpenRouterProposal?
    ) -> (
        items: [TerminalCheckboxMenuItem<MemoryEmbeddingSetupChoice>],
        defaultChoice: MemoryEmbeddingSetupChoice
    ) {
        let hasEndpoint = existingSettings?.isConfigured == true
        var choices: [TerminalCheckboxMenuItem<MemoryEmbeddingSetupChoice>] = [
            TerminalCheckboxMenuItem(
                value: .bm25Only,
                title: "Use BM25 only",
                detail: hasEndpoint
                    ? "disable embeddings for memory retrieval"
                    : "memory retrieval stays keyword-only"
            ),
            TerminalCheckboxMenuItem(
                value: .configureEndpoint,
                title: hasEndpoint ? "Change embedding endpoint" : "Add embedding endpoint",
                detail: existingSettings?.endpoint ?? "enter an HTTP(S) endpoint URL"
            )
        ]
        if let openRouterProposal {
            choices.insert(
                TerminalCheckboxMenuItem(
                    value: .openRouter,
                    title: "Use OpenRouter embeddings",
                    detail: "\(openRouterProposal.endpoint) · \(openRouterProposal.model)"
                ),
                at: 1
            )
        }
        if hasEndpoint {
            choices.append(
                TerminalCheckboxMenuItem(
                    value: .removeConfiguration,
                    title: "Remove embedding configuration",
                    detail: "disable embeddings and use BM25 only"
                )
            )
        }

        let defaultChoice: MemoryEmbeddingSetupChoice = hasEndpoint
            ? .configureEndpoint
            : .bm25Only
        return (choices, defaultChoice)
    }

    static func promptMemoryEmbeddingSettings(
        existingSettings: AgentMemoryEmbeddingSettingsManifest?,
        openRouterProposal: MemoryEmbeddingOpenRouterProposal?
    ) throws -> MemoryEmbeddingSetupSelection {
        let menu = memoryEmbeddingSetupMenu(
            existingSettings: existingSettings,
            openRouterProposal: openRouterProposal
        )
        let choice = try promptMenuChoice(
            title: "Memory embeddings",
            items: menu.items,
            selected: menu.defaultChoice
        )
        switch choice {
        case .bm25Only, .removeConfiguration:
            return MemoryEmbeddingSetupSelection(endpoint: nil)
        case .openRouter:
            guard let openRouterProposal else {
                throw ZenCODESetupError.invalidMemoryEmbeddingEndpoint
            }
            return MemoryEmbeddingSetupSelection(
                endpoint: openRouterProposal.endpoint,
                model: openRouterProposal.model,
                providerID: openRouterProposal.providerID
            )
        case .configureEndpoint:
            let endpoint = try promptValidatedMemoryEmbeddingEndpoint(
                defaultValue: existingSettings?.endpoint
            )
            // The manual endpoint flow is deliberately endpoint-only: provider
            // presets (model/providerID) are applied only through their
            // dedicated menu choice, so a manual endpoint edit never forwards
            // the referenced provider's API key to a different host. The
            // existing model/provider reference is therefore not carried over.
            return MemoryEmbeddingSetupSelection(endpoint: endpoint)
        }
    }

    static func promptValidatedMemoryEmbeddingEndpoint(
        defaultValue: String?
    ) throws -> String {
        while true {
            let endpoint = try promptString(
                "Embedding endpoint URL",
                defaultValue: defaultValue,
                allowEmpty: false,
                help: "Enter a non-empty absolute http:// or https:// endpoint URL. ZenCODE validates only the URL format here and does not connect to it."
            )
            if let normalized = AgentMemoryEmbeddingSettingsManifest.normalizedEndpoint(endpoint) {
                return normalized
            }
            AgentOutput.standardError.writeString(
                "Embedding endpoint must be a non-empty absolute http:// or https:// URL without embedded credentials.\n"
            )
        }
    }

    /// Pure manifest transition used by setup and tests. Passing `nil` disables
    /// embeddings (persists ``AgentMemoryEmbeddingSettingsManifest/disabled``),
    /// which forces BM25-only retrieval and suppresses the legacy environment
    /// fallback. A non-nil endpoint enables the provider, optionally carrying a
    /// model identifier and a provider ID reference for API-key reuse. No I/O or
    /// network work.
    static func manifestByUpdatingMemoryEmbedding(
        _ manifest: AgentSettingsManifest?,
        endpoint: String?,
        model: String? = nil,
        providerID: UUID? = nil
    ) throws -> AgentSettingsManifest {
        let memoryEmbedding: AgentMemoryEmbeddingSettingsManifest
        if let endpoint {
            guard let settings = AgentMemoryEmbeddingSettingsManifest.validated(
                endpoint: endpoint,
                model: model,
                providerID: providerID
            ) else {
                throw ZenCODESetupError.invalidMemoryEmbeddingEndpoint
            }
            memoryEmbedding = settings
        } else {
            memoryEmbedding = .disabled
        }

        return AgentSettingsManifest(
            version: manifest?.version ?? AgentSettingsManifest.currentVersion,
            providers: manifest?.providers ?? [],
            models: manifest?.models ?? [],
            selectedModelID: manifest?.selectedModelID,
            selectedThinkingSelection: manifest?.selectedThinkingSelection,
            telegram: manifest?.telegram,
            voice: manifest?.voice,
            remoteAPIKeysByProviderID: manifest?.remoteAPIKeysByProviderID ?? [:],
            localExecAllowedCommands: manifest?.localExecAllowedCommands ?? [],
            chatGPTSubscriptionCredentials: manifest?.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: manifest?.anthropicSubscriptionCredentials,
            responseLanguage: manifest?.responseLanguage,
            memoryEmbedding: memoryEmbedding
        )
    }

    static func memoryEmbeddingSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        if let settings = manifest?.memoryEmbedding {
            if settings.isExplicitlyDisabled {
                return "BM25 only"
            }
            if let endpoint = settings.endpoint {
                if let model = settings.model {
                    return "\(endpoint) · \(model)"
                }
                return endpoint
            }
            return "BM25 only"
        }
        return "not configured"
    }
}
