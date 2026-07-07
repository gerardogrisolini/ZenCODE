//
//  ZenCODESetupRunner+RemoteModelSelection.swift
//  ZenCODE
//

import Foundation
import ZenCODECore

extension ZenCODESetupRunner {
    static func reconfigureModels(
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        apiKey: String?,
        existingModels: [AgentSettingsModelManifest]
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
        existingModels: [AgentSettingsModelManifest]
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
        return selectedModels.map {
            remoteModelManifest(
                from: $0,
                providerID: providerID,
                providerName: providerName,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint
            )
        }
    }

    static func normalizedRemoteModelID(_ modelID: String) -> String {
        AgentRemoteProvider.normalizedModelID(modelID).lowercased()
    }

    static func modelWithProvider(
        _ model: AgentSettingsModelManifest,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
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
                chatEndpoint: chatEndpoint
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

    static func ensureChatGPTSubscriptionCredentials() async throws {
#if os(macOS)
        do {
            _ = try await CodexAgentModel.loadValidCredentials()
            return
        } catch {
            AgentOutput.standardError.writeString(
                "ChatGPT Subscription is not connected. Opening ChatGPT login in the browser.\n"
            )
        }

        let session = try await ChatGPTSubscriptionAuthService.startSignIn()
        AgentOutput.standardError.writeString(
            """
            Complete ChatGPT login in the browser.

            If the browser does not open, open this URL:
            \(session.authorizationURL.absoluteString)

            Waiting for sign-in...

            """
        )
        let didOpen = await ChatGPTSubscriptionAuthService.openAuthorizationURL(
            session.authorizationURL
        )
        if !didOpen {
            throw ChatGPTSubscriptionAuthError.browserOpenFailed
        }
        _ = try await session.waitForCredentials()
        AgentOutput.standardError.writeString("ChatGPT Subscription connected.\n")
#else
        throw ZenCODESetupError.chatGPTSubscriptionUnsupported
#endif
    }

    static func ensureAnthropicSubscriptionCredentials() async throws {
#if os(macOS)
        do {
            _ = try await AnthropicSubscriptionAuthService.loadValidCredentials()
            return
        } catch {
            AgentOutput.standardError.writeString(
                "Claude Subscription is not connected. Opening Claude login in the browser.\n"
            )
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
        guard didOpen else {
            throw AnthropicSubscriptionAuthError.browserOpenFailed
        }

        let authorizationInput = try promptString(
            "Authorization code",
            defaultValue: nil,
            allowEmpty: false
        )
        try session.submitAuthorizationInput(authorizationInput)

        _ = try await session.waitForCredentials()
        AgentOutput.standardError.writeString("Claude Subscription connected.\n")
#else
        throw ZenCODESetupError.anthropicSubscriptionUnsupported
#endif
    }

    static func readModels(
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        apiKey: String?
    ) async throws -> [AgentSettingsModelManifest] {
        if try promptYesNo("Load the model list from the server /models endpoint?", defaultValue: true) {
            do {
                let catalogModels = try await RemoteModelCatalogClient()
                    .fetchModels(baseURL: baseURL, apiKey: apiKey)
                    .sorted(by: remoteModelSort)
                guard !catalogModels.isEmpty else {
                    throw ZenCODESetupError.noRemoteModelsReturned
                }

                let selectedModels = try selectRemoteModels(from: catalogModels)
                return selectedModels.map {
                    remoteModelManifest(
                        from: $0,
                        providerID: providerID,
                        providerName: providerName,
                        baseURL: baseURL,
                        chatEndpoint: chatEndpoint
                    )
                }
            } catch {
                AgentOutput.standardError.writeString(
                    "Unable to load /models: \(error.localizedDescription)\n"
                )
                guard try promptYesNo("Enter models manually?", defaultValue: true) else {
                    throw error
                }
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
        let selectedIndexes = promptMenuSelection(
            title: "Models available from /models",
            items: items,
            selected: models.isEmpty ? [] : [0]
        )
        return selectedIndexes.sorted().compactMap { index in
            models.indices.contains(index) ? models[index] : nil
        }
    }


    static func selectChatGPTSubscriptionModels(
        defaultModels: [AgentSettingsModelManifest] = []
    ) throws -> [CodexAgentModel.ModelOption] {
        let models = CodexAgentModel.availableModels
        let defaultSelection = chatGPTSubscriptionModelSelectionDefaultIndexes(
            models: models,
            defaultModels: defaultModels
        )
        let items = models.enumerated().map { index, model in
            let context = model.contextWindowTokenLimit.map { "ctx \($0)" } ?? "ctx default"
            return TerminalCheckboxMenuItem(
                value: index,
                title: model.title,
                detail: "\(model.modelID) [\(context), thinking]"
            )
        }
        let selectedIndexes = promptMenuSelection(
            title: "ChatGPT Subscription models",
            items: items,
            selected: defaultSelection
        )
        return selectedIndexes.sorted().compactMap { index in
            models.indices.contains(index) ? models[index] : nil
        }
    }


    static func chatGPTSubscriptionModelSelectionDefaultIndexes(
        models: [CodexAgentModel.ModelOption],
        defaultModels: [AgentSettingsModelManifest]
    ) -> Set<Int> {
        guard !defaultModels.isEmpty else {
            return models.isEmpty ? [] : [0]
        }
        let selectedIndexes = defaultModels.compactMap { defaultModel in
            models.firstIndex { option in
                option.modelID == defaultModel.modelID
                    || CodexAgentModel.selectionID(forModelID: option.modelID) == defaultModel.id
            }
        }
        guard !selectedIndexes.isEmpty else {
            return models.isEmpty ? [] : [0]
        }
        return Set(selectedIndexes)
    }


    static func selectAnthropicSubscriptionModels(
        defaultModels: [AgentSettingsModelManifest] = []
    ) throws -> [AnthropicSubscriptionModel.ModelOption] {
        let models = AnthropicSubscriptionModel.availableModels
        let defaultSelection = anthropicSubscriptionModelSelectionDefaultIndexes(
            models: models,
            defaultModels: defaultModels
        )
        let items = models.enumerated().map { index, model in
            let context = model.contextWindowTokenLimit.map { "ctx \($0)" } ?? "ctx default"
            let thinking = model.thinkingSupport?.supportsThinking == true ? ", thinking" : ""
            return TerminalCheckboxMenuItem(
                value: index,
                title: model.title,
                detail: "\(model.modelID) [\(context)\(thinking)]"
            )
        }
        let selectedIndexes = promptMenuSelection(
            title: "Claude Subscription models",
            items: items,
            selected: defaultSelection
        )
        return selectedIndexes.sorted().compactMap { index in
            models.indices.contains(index) ? models[index] : nil
        }
    }


    static func anthropicSubscriptionModelSelectionDefaultIndexes(
        models: [AnthropicSubscriptionModel.ModelOption],
        defaultModels: [AgentSettingsModelManifest]
    ) -> Set<Int> {
        guard !defaultModels.isEmpty else {
            return models.isEmpty ? [] : [0]
        }
        let selectedIndexes = defaultModels.compactMap { defaultModel in
            models.firstIndex { option in
                option.modelID == defaultModel.modelID
                    || AnthropicSubscriptionModel.selectionID(forModelID: option.modelID) == defaultModel.id
            }
        }
        guard !selectedIndexes.isEmpty else {
            return models.isEmpty ? [] : [0]
        }
        return Set(selectedIndexes)
    }


}
