//
//  ZenCODESetupRunner+MemoryEmbedding.swift
//  ZenCODE
//

import Foundation

extension ZenCODESetupRunner {
    private enum MemoryEmbeddingSetupChoice: Hashable {
        case bm25Only
        case configureEndpoint
        case removeConfiguration
    }

    /// Configures optional semantic embeddings for memory retrieval.
    ///
    /// The prompt deliberately asks for only an endpoint. It validates the URL
    /// locally and does not contact the endpoint, enumerate models, or ask for
    /// credentials. Choosing no endpoint leaves retrieval on pure BM25.
    static func configureMemoryEmbedding(
        in manifest: AgentSettingsManifest?
    ) throws -> AgentSettingsManifest {
        let endpoint = try promptMemoryEmbeddingEndpoint(
            existingSettings: manifest?.memoryEmbedding
        )
        return try manifestByUpdatingMemoryEmbedding(
            manifest,
            endpoint: endpoint
        )
    }

    static func promptMemoryEmbeddingEndpoint(
        existingSettings: AgentMemoryEmbeddingSettingsManifest?
    ) throws -> String? {
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
        let choice = try promptMenuChoice(
            title: "Memory embeddings",
            items: choices,
            selected: defaultChoice
        )
        switch choice {
        case .bm25Only, .removeConfiguration:
            return nil
        case .configureEndpoint:
            return try promptValidatedMemoryEmbeddingEndpoint(
                defaultValue: existingSettings?.endpoint
            )
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
    /// fallback. A non-nil endpoint enables the provider. No I/O or network work.
    static func manifestByUpdatingMemoryEmbedding(
        _ manifest: AgentSettingsManifest?,
        endpoint: String?
    ) throws -> AgentSettingsManifest {
        let memoryEmbedding: AgentMemoryEmbeddingSettingsManifest
        if let endpoint {
            guard let settings = AgentMemoryEmbeddingSettingsManifest.validated(endpoint: endpoint) else {
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
            return settings.endpoint ?? "BM25 only"
        }
        return "not configured"
    }
}
