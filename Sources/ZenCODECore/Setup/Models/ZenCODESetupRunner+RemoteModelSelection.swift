//
//  ZenCODESetupRunner+RemoteModelSelection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension ZenCODESetupRunner {
    struct SubscriptionModelCandidate {
        let manifestID: String
        let modelID: String
        let title: String
        let detail: String
        let contextWindowTokenLimit: Int?
        let thinkingSupport: ModelThinkingSupport?
        var maxOutputTokens: Int? = nil
        var anthropicThinkingMode: String? = nil
        var subscriptionReasoningLevels: [String]? = nil
        var isDiscovered = false
    }

    static func reconfigureModels(
        providerID: String,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        apiKey: String?,
        existingModels: [AgentSettingsModelManifest],
    ) async throws -> [AgentSettingsModelManifest] {
        var models: [AgentSettingsModelManifest] = existingModels.map { model in
            modelWithProvider(
                model,
                providerID: providerID,
                providerName: providerName,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint
            )
        }
        models = try reconfigureExistingModelMetadata(
            providerName: providerName,
            models: models
        )

        while try promptYesNo(
            "Add another model for \(providerName)?",
            defaultValue: false
        ) {
            let selectedModels = try await readAdditionalModelsFromCatalog(
                providerID: providerID,
                providerName: providerName,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                apiKey: apiKey,
                existingModels: models
            )
            guard !selectedModels.isEmpty else {
                break
            }
            models.append(contentsOf: selectedModels)
        }

        let deletedModelIndexes = try promptModelIndexes(
            providerName: providerName,
            models: models
        )
        if !deletedModelIndexes.isEmpty {
            models = models.enumerated()
                .filter { !deletedModelIndexes.contains($0.offset) }
                .map(\.element)
        }

        return models

    }

    static func completeModelMetadataIfNeeded(
        providerName: String,
        models: [AgentSettingsModelManifest]
    ) throws -> [AgentSettingsModelManifest] {
        let hasIncompleteModels = models.contains { model in
            model.configuredContextWindowLimit == nil
                && (model.thinkingOptions?.isEmpty ?? true)
        }
        guard hasIncompleteModels else {
            return models
        }
        return try reconfigureExistingModelMetadata(
            providerName: providerName,
            models: models
        )
    }

    static func reconfigureExistingModelMetadata(
        providerName: String,
        models: [AgentSettingsModelManifest]
    ) throws -> [AgentSettingsModelManifest] {
        let selectedModelIndexes = try promptModelMetadataIndexes(
            providerName: providerName,
            models: models
        )
        guard !selectedModelIndexes.isEmpty else {
            return models
        }

        var updatedModels = models
        for index in selectedModelIndexes.sorted() where updatedModels.indices.contains(index) {
            updatedModels[index] = try readModelMetadata(for: updatedModels[index])
        }
        return updatedModels
    }

    /// The models whose context window and thinking options the operator
    /// configures next; the incomplete ones start checked. Enter with nothing
    /// checked configures none; Esc throws `ZenCODESetupError.cancelled`.
    static func promptModelMetadataIndexes(
        providerName: String,
        models: [AgentSettingsModelManifest],
        select: (String, [TerminalCheckboxMenuItem<Int>], Set<Int>) -> Set<Int>? = {
            TerminalCheckboxMenu.select(title: $0, items: $1, selected: $2)
        }
    ) throws -> Set<Int> {
        guard !models.isEmpty else {
            return []
        }

        let items = models.enumerated().map { index, model in
            TerminalCheckboxMenuItem(
                value: index,
                title: model.displayTitle,
                detail: modelMetadataDetail(model)
            )
        }
        return try promptMenuSelection(
            title: "Configure context window / thinking for \(providerName)",
            items: items,
            selected: defaultModelMetadataIndexes(models),
            select: select
        )
    }

    static func defaultModelMetadataIndexes(
        _ models: [AgentSettingsModelManifest]
    ) -> Set<Int> {
        Set(
            models.enumerated().compactMap { index, model in
                model.configuredContextWindowLimit == nil
                    && (model.thinkingOptions?.isEmpty ?? true)
                    ? index
                    : nil
            }
        )
    }

    static func modelMetadataDetail(
        _ model: AgentSettingsModelManifest
    ) -> String {
        var details: [String] = []
        if let contextWindow = model.configuredContextWindowLimit {
            details.append("ctx \(contextWindow)")
        } else {
            details.append("ctx not set")
        }

        if let thinkingOptions = model.thinkingOptions,
           !thinkingOptions.isEmpty {
            let options = thinkingOptions.map(\.rawValue).joined(separator: "/")
            if let defaultThinkingSelection = model.defaultThinkingSelection {
                details.append("thinking \(options), default \(defaultThinkingSelection.rawValue)")
            } else {
                details.append("thinking \(options)")
            }
        } else {
            details.append("thinking not set")
        }
        return details.joined(separator: ", ")
    }

    static func promptModelIndexes(
        providerName: String,
        models: [AgentSettingsModelManifest]
    ) throws -> Set<Int> {
        let items = models.enumerated().map { index, model in
            TerminalCheckboxMenuItem(
                value: index,
                title: model.displayTitle,
                detail: model.modelID
            )
        }
        return try promptSelectionIndexes(
            title: "Delete configured models for \(providerName)",
            items: items
        )
    }

    static func readAdditionalModelsFromCatalog(
        providerID: String,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        apiKey: String?,
        existingModels: [AgentSettingsModelManifest],
    ) async throws -> [AgentSettingsModelManifest] {
        let existingModelIDs = Set(
            existingModels.map { normalizedRemoteModelID($0.modelID) }
        )
        let catalogModels: [OpenRouterModelInfo]
        do {
            catalogModels = try await RemoteModelCatalogClient()
                .fetchModels(baseURL: baseURL, apiKey: apiKey)
                .sorted(by: remoteModelSort)
                .filter { model in
                    !existingModelIDs.contains(normalizedRemoteModelID(model.id))
                }
        } catch {
            AgentOutput.standardError.writeString(
                "Unable to load /models: \(error.localizedDescription)\n"
            )
            throw error
        }
        guard !catalogModels.isEmpty else {
            AgentOutput.standardError.writeString(
                "No additional models available from /models for \(providerName).\n"
            )
            guard try promptYesNo(
                "Enter another model manually?",
                defaultValue: false
            ) else {
                return []
            }
            return [
                try readModel(
                    providerID: providerID,
                    providerName: providerName,
                    baseURL: baseURL,
                    chatEndpoint: chatEndpoint,
                    modelIndex: existingModels.count
                )
            ]
        }

        let selectedModels = try selectRemoteModels(from: catalogModels)
        let enrichedModels = try await enrichModelsWithOpenRouterMetadata(
            selectedModels,
            providerBaseURL: baseURL,
            apiKey: apiKey
        )
        let manifests = enrichedModels.map {
            remoteModelManifest(
                from: $0,
                providerID: providerID,
                providerName: providerName,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint
            )
        }
        return try completeModelMetadataIfNeeded(
            providerName: providerName,
            models: manifests
        )
    }

    static func normalizedRemoteModelID(_ modelID: String) -> String {
        AgentRemoteProvider.normalizedModelID(modelID).lowercased()
    }

    static func enrichModelsWithOpenRouterMetadata(
        _ models: [OpenRouterModelInfo],
        providerBaseURL: String,
        apiKey: String?
    ) async throws -> [OpenRouterModelInfo] {
        try await enrichModelsWithOpenRouterMetadata(
            models,
            providerBaseURL: providerBaseURL,
            apiKey: apiKey
        ) {
            try await RemoteModelCatalogClient().fetchModels(
                apiKey: RemoteModelCatalogClient.openRouterAPIKey(
                    providerBaseURL: providerBaseURL,
                    apiKey: apiKey
                )
            )
        }
    }

    static func enrichModelsWithOpenRouterMetadata(
        _ models: [OpenRouterModelInfo],
        providerBaseURL: String,
        apiKey: String?,
        catalogLoader: @escaping @Sendable () async throws -> [OpenRouterModelInfo]
    ) async throws -> [OpenRouterModelInfo] {
        guard !models.isEmpty else {
            return models
        }

        do {
            let catalog = try await catalogLoader()
            return models.map { model in
                guard let metadata = openRouterMetadata(
                    matching: model.id,
                    in: catalog
                ) else {
                    return model
                }
                return modelMergingOpenRouterMetadata(
                    model,
                    metadata: metadata,
                    // DeepSeek and Anthropic API models carry authoritative
                    // thinking metadata (direct API / `capabilities`) that
                    // OpenRouter's routed catalog must not replace.
                    includeThinkingSupport: !AgentRemoteProvider.isDeepSeekBaseURL(providerBaseURL)
                        && model.generationParameterOverrides?.subscriptionThinkingMode == nil
                )
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            AgentOutput.standardError.writeString(
                "Unable to load OpenRouter model metadata: \(error.localizedDescription)\n"
            )
            return models
        }
    }

    /// Resolves a catalog model while retaining the provider's configured ID.
    /// A namespace-free ID can only use a catalog suffix when that suffix maps
    /// to exactly one catalog entry; this avoids silently selecting variants
    /// such as `model` versus `model:batch` or a model offered by two vendors.
    static func openRouterMetadata(
        matching modelID: String,
        in catalog: [OpenRouterModelInfo]
    ) -> OpenRouterModelInfo? {
        let normalizedModelID = normalizedRemoteModelID(modelID)
        if let exactMatch = catalog.first(where: {
            normalizedRemoteModelID($0.id) == normalizedModelID
        }) {
            return exactMatch
        }

        guard !normalizedModelID.contains("/") else {
            return nil
        }

        let suffixMatches = catalog.filter { catalogModel in
            let normalizedCatalogID = normalizedRemoteModelID(catalogModel.id)
            guard let separator = normalizedCatalogID.lastIndex(of: "/") else {
                return false
            }
            return normalizedCatalogID[
                normalizedCatalogID.index(after: separator)...
            ] == normalizedModelID
        }
        return suffixMatches.count == 1 ? suffixMatches[0] : nil
    }

    static func modelMergingOpenRouterMetadata(
        _ model: OpenRouterModelInfo,
        metadata: OpenRouterModelInfo,
        includeThinkingSupport: Bool = true
    ) -> OpenRouterModelInfo {
        OpenRouterModelInfo(
            id: model.id,
            name: model.name,
            contextLength: metadata.contextLength ?? model.contextLength,
            pricing: model.pricing,
            thinkingSupport: includeThinkingSupport
                ? (metadata.thinkingSupport ?? model.thinkingSupport)
                : model.thinkingSupport,
            generationParameterOverrides: model.generationParameterOverrides,
            installed: model.installed,
            loaded: model.loaded,
            serverLoaded: model.serverLoaded
        )
    }

    static func modelWithProvider(
        _ model: AgentSettingsModelManifest,
        providerID: String,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        providerProfileID: AgentProviderProfileID? = nil,
        protocolProfileID: AgentProtocolProfileID? = nil,
        authPolicy: AgentProviderAuthPolicy? = nil,
        ds4Runtime: AgentDS4RuntimeConfiguration? = nil
    ) -> AgentSettingsModelManifest {
        AgentSettingsModelManifest(
            id: model.id,
            kind: model.kind,
            title: model.title,
            llmID: model.llmID,
            modelID: model.modelID,
            providerID: providerID,
            provider: AgentRemoteProvider(
                id: providerID,
                name: providerName,
                baseURL: baseURL,
                modelID: model.modelID,
                chatEndpoint: chatEndpoint,
                providerProfileID: providerProfileID,
                protocolProfileID: protocolProfileID,
                authPolicy: authPolicy,
                ds4Runtime: ds4Runtime ?? model.ds4Runtime
            ),
            configuredContextWindowLimit: model.configuredContextWindowLimit,
            generationParameterOverrides: model.generationParameterOverrides,
            thinkingOptions: model.thinkingOptions,
            defaultThinkingSelection: model.defaultThinkingSelection
        )
    }

    static func readModels(
        providerID: String,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        apiKey: String?
    ) async throws -> [AgentSettingsModelManifest] {
        if try promptYesNo("Load the model list from the server /models endpoint?", defaultValue: true) {
            // Narrow the recoverable catch to the remote request only: a
            // cancellation or an error raised later (model selection, metadata
            // prompts) must not be swallowed as "could not load models".
            let catalogModels: [OpenRouterModelInfo]
            do {
                catalogModels = try await RemoteModelCatalogClient()
                    .fetchModels(baseURL: baseURL, apiKey: apiKey)
                    .sorted(by: remoteModelSort)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AgentOutput.standardError.writeString(
                    "Unable to load /models: \(error.localizedDescription)\n"
                )
                guard try promptYesNo("Enter models manually?", defaultValue: true) else {
                    throw error
                }
                catalogModels = []
            }

            if !catalogModels.isEmpty {
                let selectedModels = try selectRemoteModels(from: catalogModels)
                let enrichedModels = try await enrichModelsWithOpenRouterMetadata(
                    selectedModels,
                    providerBaseURL: baseURL,
                    apiKey: apiKey
                )
                let manifests = enrichedModels.map {
                    remoteModelManifest(
                        from: $0,
                        providerID: providerID,
                        providerName: providerName,
                        baseURL: baseURL,
                        chatEndpoint: chatEndpoint
                    )
                }
                return try completeModelMetadataIfNeeded(
                    providerName: providerName,
                    models: manifests
                )
            }
        }

        var models: [AgentSettingsModelManifest] = []
        repeat {
            models.append(
                try readModel(
                    providerID: providerID,
                    providerName: providerName,
                    baseURL: baseURL,
                    chatEndpoint: chatEndpoint,
                    modelIndex: models.count
                )
            )
        } while try promptYesNo("Add another model for \(providerName)?", defaultValue: false)

        return models
    }

    static func selectRemoteModels(
        from models: [OpenRouterModelInfo]
    ) throws -> [OpenRouterModelInfo] {
        let items = models.enumerated().map { index, model in
            TerminalCheckboxMenuItem(
                value: index,
                title: remoteModelListTitle(model),
                detail: nil
            )
        }
        let selectedIndexes = try promptMenuSelection(
            title: "Models available from /models",
            items: items,
            selected: models.isEmpty ? [] : [0]
        )
        return selectedIndexes.sorted().compactMap { index in
            models.indices.contains(index) ? models[index] : nil
        }
    }


    static func selectSubscriptionModelCandidates(
        _ candidates: [SubscriptionModelCandidate],
        title: String,
        defaultModels: [AgentSettingsModelManifest] = []
    ) throws -> [SubscriptionModelCandidate] {
        let items = candidates.enumerated().map { index, candidate in
            TerminalCheckboxMenuItem(
                value: index,
                title: candidate.title,
                detail: candidate.detail
            )
        }
        let selectedIndexes = try promptMenuSelection(
            title: title,
            items: items,
            selected: subscriptionModelSelectionDefaultIndexes(
                candidates: candidates,
                defaultModels: defaultModels
            )
        )
        return selectedIndexes.sorted().compactMap { index in
            candidates.indices.contains(index) ? candidates[index] : nil
        }
    }

    static func subscriptionModelSelectionDefaultIndexes(
        candidates: [SubscriptionModelCandidate],
        defaultModels: [AgentSettingsModelManifest]
    ) -> Set<Int> {
        guard !defaultModels.isEmpty else {
            return candidates.isEmpty ? [] : [0]
        }
        let selectedIndexes = defaultModels.compactMap { defaultModel in
            candidates.firstIndex { candidate in
                candidate.modelID == defaultModel.modelID
                    || candidate.manifestID == defaultModel.id
            }
        }
        guard !selectedIndexes.isEmpty else {
            return candidates.isEmpty ? [] : [0]
        }
        return Set(selectedIndexes)
    }


}
