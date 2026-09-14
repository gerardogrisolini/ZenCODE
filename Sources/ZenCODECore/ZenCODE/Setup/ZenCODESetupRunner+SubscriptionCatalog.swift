import Foundation

extension ZenCODESetupRunner {
    static func discoveredSubscriptionCandidates(
        provider: SubscriptionModelCatalogClient.Provider,
        accessToken: String,
        accountID: String? = nil,
        catalogScopeID: UUID? = nil,
        existingModels: [AgentSettingsModelManifest],
        client: SubscriptionModelCatalogClient = SubscriptionModelCatalogClient()
    ) async throws -> [SubscriptionModelCandidate] {
        let result = try await client.load(provider: provider, accessToken: accessToken,
                                          accountID: accountID, catalogScopeID: catalogScopeID)
        try Task.checkCancellation()
        if result.isCached {
            AgentOutput.standardError.writeString("Catalog refresh failed; using account catalog from \(result.fetchedAt.formatted()). This does not confirm current model access.\n")
        }
        if result.cacheWriteFailed {
            AgentOutput.standardError.writeString("Catalog loaded, but its cache could not be saved.\n")
        }
        if provider == .anthropic {
            AgentOutput.standardError.writeString("Anthropic subscription catalog OAuth compatibility has not been live-validated. Thinking capabilities not representable by this client are not enabled.\n")
        }
        return mergeSubscriptionCandidates(result.models.map { model in
            SubscriptionModelCandidate(
                manifestID: provider == .chatGPT
                    ? RemoteSubscriptionModelID.selectionID(forModelID: model.id, prefix: "chatgpt")
                    : RemoteSubscriptionModelID.selectionID(forModelID: model.id, prefix: "claude"),
                modelID: model.id, title: model.title,
                detail: model.id + (model.contextWindow.map { " [ctx \($0)]" } ?? " [context unknown]"),
                contextWindowTokenLimit: model.contextWindow,
                thinkingSupport: model.thinkingSupport,
                maxOutputTokens: model.maxOutputTokens,
                anthropicThinkingMode: model.anthropicThinkingMode,
                subscriptionReasoningLevels: provider == .chatGPT ? model.reasoningLevels : nil,
                isDiscovered: true
            )
        }, existingModels: existingModels)
    }

    static func mergeSubscriptionCandidates(
        _ candidates: [SubscriptionModelCandidate],
        existingModels: [AgentSettingsModelManifest]
    ) -> [SubscriptionModelCandidate] {
        // Saved entries are selectable even when absent from the current catalog.
        // Their manifests are reused verbatim by the caller, including persisted IDs.
        candidates + existingModels.filter { saved in
            !candidates.contains { $0.modelID == saved.modelID }
        }.map { saved in
            SubscriptionModelCandidate(manifestID: saved.id, modelID: saved.modelID,
                title: saved.displayTitle, detail: "\(saved.modelID) [configured; not in current catalog]",
                contextWindowTokenLimit: saved.configuredContextWindowLimit, thinkingSupport: nil)
        }
    }
}
