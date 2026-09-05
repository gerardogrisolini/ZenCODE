//
//  ZenCODESetupRunner+RemoteModelSelection.swift
//  ZenCODE
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
    }

    static func reconfigureModels(
        providerID: UUID,
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

        let deletedModelIndexes = promptModelIndexes(
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
        let selectedModelIndexes = promptModelMetadataIndexes(
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

    static func promptModelMetadataIndexes(
        providerName: String,
        models: [AgentSettingsModelManifest]
    ) -> Set<Int> {
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
        return TerminalCheckboxMenu.select(
            title: "Configure context window / thinking for \(providerName)",
            items: items,
            selected: defaultModelMetadataIndexes(models)
        ) ?? []
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
    ) -> Set<Int> {
        let items = models.enumerated().map { index, model in
            TerminalCheckboxMenuItem(
                value: index,
                title: model.displayTitle,
                detail: model.modelID
            )
        }
        return promptSelectionIndexes(
            title: "Delete configured models for \(providerName)",
            items: items
        )
    }

    static func readAdditionalModelsFromCatalog(
        providerID: UUID,
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
                return modelMergingOpenRouterMetadata(model, metadata: metadata)
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
        metadata: OpenRouterModelInfo
    ) -> OpenRouterModelInfo {
        OpenRouterModelInfo(
            id: model.id,
            name: model.name,
            contextLength: metadata.contextLength ?? model.contextLength,
            pricing: model.pricing,
            thinkingSupport: metadata.thinkingSupport ?? model.thinkingSupport,
            generationParameterOverrides: model.generationParameterOverrides,
            installed: model.installed,
            loaded: model.loaded,
            serverLoaded: model.serverLoaded
        )
    }

    static func modelWithProvider(
        _ model: AgentSettingsModelManifest,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        providerProfileID: AgentProviderProfileID? = nil,
        protocolProfileID: AgentProtocolProfileID? = nil,
        authPolicy: AgentProviderAuthPolicy? = nil
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
                authPolicy: authPolicy
            ),
            configuredContextWindowLimit: model.configuredContextWindowLimit,
            generationParameterOverrides: model.generationParameterOverrides,
            thinkingOptions: model.thinkingOptions,
            defaultThinkingSelection: model.defaultThinkingSelection
        )
    }

    static func isChatGPTSubscriptionProvider(
        _ provider: AgentSettingsProviderManifest
    ) -> Bool {
        provider.id == AgentRemoteProvider.chatGPTSubscriptionProviderID
            || provider.baseURL == AgentRemoteProvider.chatGPTSubscriptionBaseURL
    }

    static func isAnthropicSubscriptionProvider(
        _ provider: AgentSettingsProviderManifest
    ) -> Bool {
        provider.id == AgentRemoteProvider.anthropicSubscriptionProviderID
            || provider.baseURL == AgentRemoteProvider.anthropicSubscriptionBaseURL
    }

    static func ensureChatGPTSubscriptionCredentials() async throws -> CodexAgentCredentials {
        do {
            return try await CodexAgentModel.loadValidCredentials(
                persistRefresh: false
            )
        } catch is CancellationError {
            // A cooperative cancellation must not be mistaken for "not signed
            // in"; propagate it so the surrounding setup task unwinds.
            throw CancellationError()
        } catch {
            AgentOutput.standardError.writeString(
                "ChatGPT Subscription is not connected. Opening ChatGPT login in the browser.\n"
            )
        }

        #if os(macOS)
        let session = try await ChatGPTSubscriptionAuthService.startSignIn(
            promptAuthorizationInput: { label in
                try promptSecret(label, allowEmpty: false)
            }
        )
        if session.isCallbackServerAvailable {
            AgentOutput.standardError.writeString(
                """
                Complete ChatGPT login in the browser.

                If the browser does not open, open this URL:
                \(session.authorizationURL.absoluteString)

                Waiting for sign-in...

                """
            )
        } else {
            AgentOutput.standardError.writeString(
                """
                The local ChatGPT sign-in callback server could not start (the
                port may already be in use); the browser will not redirect back
                automatically.

                After completing the login, paste the authorization code below.

                If the browser does not open, open this URL:
                \(session.authorizationURL.absoluteString)

                """
            )
        }
        let didOpen = await ChatGPTSubscriptionAuthService.openAuthorizationURL(
            session.authorizationURL
        )
        if !didOpen {
            throw ChatGPTSubscriptionAuthError.browserOpenFailed
        }
        let credentials = try await session.waitForCredentials(persist: false)
        #else
        let credentials = try await ChatGPTSubscriptionAuthService.signInWithDeviceCode(
            persist: false
        ) {
            url,
            code in
            AgentOutput.standardError.writeString(
                """
                Complete ChatGPT login at:
                \(url.absoluteString)

                Enter this code: \(code)

                Waiting for sign-in...

                """
            )
            _ = await ChatGPTSubscriptionAuthService.openAuthorizationURL(url)
        }
        #endif
        AgentOutput.standardError.writeString("ChatGPT Subscription connected.\n")
        return credentials
    }

    static func ensureAnthropicSubscriptionCredentials() async throws -> AnthropicSubscriptionCredentials {
        do {
            return try await AnthropicSubscriptionAuthService.loadValidCredentials(
                persistRefresh: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AnthropicSubscriptionAuthError {
            // Only missing/invalid credentials are recoverable by starting a new
            // sign-in; structural or transport errors must surface unchanged.
            switch error {
            case .missingCredentials, .invalidCredentials:
                AgentOutput.standardError.writeString(
                    "Claude Subscription is not connected. Opening Claude login in the browser.\n"
                )
            default:
                throw error
            }
        } catch {
            throw error
        }

        let session = try await AnthropicSubscriptionAuthService.startSignIn()
        AgentOutput.standardError.writeString(
            """
            Complete Claude login in the browser.

            If the browser does not open automatically, open this URL:
            \(session.authorizationURL.absoluteString)

            """
        )
        let didOpen = await AnthropicSubscriptionAuthService.openAuthorizationURL(
            session.authorizationURL
        )
        if !didOpen {
            AgentOutput.standardError.writeString(
                "No browser launcher was found; open the URL above manually.\n"
            )
        }

        let authorizationInput = try promptSecret(
            "Authorization code",
            allowEmpty: false
        )
        try session.submitAuthorizationInput(authorizationInput)

        let credentials = try await session.waitForCredentials(persist: false)
        AgentOutput.standardError.writeString("Claude Subscription connected.\n")
        return credentials
    }

    static func readModels(
        providerID: UUID,
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


    static var chatGPTSubscriptionModelCandidates: [SubscriptionModelCandidate] {
        CodexAgentModel.availableModels.map { model in
            let context = model.contextWindowTokenLimit.map { "ctx \($0)" } ?? "ctx default"
            return SubscriptionModelCandidate(
                manifestID: CodexAgentModel.selectionID(forModelID: model.modelID),
                modelID: model.modelID,
                title: model.title,
                detail: "\(model.modelID) [\(context), thinking]",
                contextWindowTokenLimit: model.contextWindowTokenLimit,
                thinkingSupport: model.thinkingSupport
            )
        }
    }

    static var anthropicSubscriptionModelCandidates: [SubscriptionModelCandidate] {
        AnthropicSubscriptionModel.availableModels.map { model in
            let context = model.contextWindowTokenLimit.map { "ctx \($0)" } ?? "ctx default"
            let thinking = model.thinkingSupport?.supportsThinking == true ? ", thinking" : ""
            return SubscriptionModelCandidate(
                manifestID: AnthropicSubscriptionModel.selectionID(forModelID: model.modelID),
                modelID: model.modelID,
                title: model.title,
                detail: "\(model.modelID) [\(context)\(thinking)]",
                contextWindowTokenLimit: model.contextWindowTokenLimit,
                thinkingSupport: model.thinkingSupport
            )
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
