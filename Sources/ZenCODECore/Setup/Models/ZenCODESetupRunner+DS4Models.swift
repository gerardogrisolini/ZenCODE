//
//  ZenCODESetupRunner+DS4Models.swift
//  ZenCODE
//
//  Pure steps of the DS4 stage: the ids a new model cannot take, the next free
//  model id, the runtime manifest of one model and the model manifest built
//  from it. They ask nothing and touch no file.
//

import Foundation

extension ZenCODESetupRunner {
    /// The saved model of the same GGUF as `candidate`, if there is one.
    static func ds4PreviousModel(
        for candidate: DS4SetupModelCandidate,
        in existingModels: [AgentSettingsModelManifest]
    ) -> AgentSettingsModelManifest? {
        existingModels.first {
            $0.ds4Runtime?.modelRelativePath == candidate.relativePath
        }
    }

    /// The ids no new model can take: the `reservedModelIDs` plus the id of
    /// every saved model whose GGUF is among the `selected` ones, which keeps
    /// it. They are taken before any id is generated, so a kept id wins over a
    /// generated one whatever the order of the selection. A saved model that is
    /// not selected takes nothing.
    ///
    /// The flow then gives each new model its id one at a time, when it gets
    /// to it (see ``uniqueDS4ModelID(_:used:)``): a model the flow skips does
    /// not take one.
    static func ds4PreservedModelIDs(
        for selected: [DS4SetupModelCandidate],
        existingModels: [AgentSettingsModelManifest],
        reservedModelIDs: Set<String>
    ) -> Set<String> {
        var usedIDs = reservedModelIDs
        for candidate in selected {
            if let previous = ds4PreviousModel(for: candidate, in: existingModels) {
                usedIDs.insert(previous.id)
            }
        }
        return usedIDs
    }

    /// `base` when no id in `used` is `base`, otherwise `base-2`, `base-3`, …
    /// with the first suffix that is free; the id returned is added to `used`.
    static func uniqueDS4ModelID(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// Runtime of one model: the answers of the setup plus, from the previous
    /// runtime of the same GGUF, the SSD streaming cache values that setup
    /// does not ask. Throws when a value is not valid for the manifest.
    static func ds4RuntimeManifest(
        rootDirectory: String,
        candidate: DS4SetupModelCandidate,
        previousRuntime: AgentDS4RuntimeManifest?,
        backend: AgentDS4RuntimeBackend,
        visionRelativePath: String?,
        mtpRelativePath: String?,
        tuning: AgentDS4RuntimeTuning
    ) throws -> AgentDS4RuntimeManifest {
        try AgentDS4RuntimeManifest(
            rootDirectory: rootDirectory,
            modelRelativePath: candidate.relativePath,
            backend: backend,
            contextWindow: tuning.contextWindow,
            ssdStreaming: tuning.ssdStreaming,
            ssdStreamingCacheExperts: previousRuntime?.ssdStreamingCacheExperts,
            ssdStreamingCacheBytes: previousRuntime?.ssdStreamingCacheBytes,
            ssdStreamingPreloadExperts: previousRuntime?.ssdStreamingPreloadExperts,
            ssdStreamingCold: previousRuntime?.ssdStreamingCold ?? false,
            mtp: tuning.mtp,
            power: tuning.power,
            visionRelativePath: visionRelativePath,
            mtpRelativePath: mtpRelativePath,
            steeringRelativePath: tuning.steeringRelativePath,
            dspark: tuning.dspark,
            mtpDraftTokens: tuning.mtpDraftTokens,
            mtpMargin: tuning.mtpMargin,
            quality: tuning.quality,
            threads: tuning.threads,
            prefillChunk: tuning.prefillChunk,
            warmWeights: tuning.warmWeights,
            steeringFFN: tuning.steeringFFN,
            steeringAttn: tuning.steeringAttn,
            cudaArch: tuning.cudaArch,
            rocmArch: tuning.rocmArch,
            engineSessions: tuning.engineSessions,
            extraEngineArguments: tuning.extraEngineArguments
        )
    }

    /// Manifest of one DS4 model. A model saved for the same GGUF keeps its
    /// title, `llmID`, generation overrides and saved thinking levels; a new
    /// one gets the title of the candidate and the thinking levels of its
    /// family.
    static func ds4ModelManifest(
        candidate: DS4SetupModelCandidate,
        previousModel: AgentSettingsModelManifest?,
        runtime: AgentDS4RuntimeManifest,
        providerBase: AgentSettingsProviderManifest,
        modelID: String,
        apiModelID: String
    ) -> AgentSettingsModelManifest {
        let thinking = ds4ThinkingConfiguration(
            forAPIModelID: apiModelID,
            previousModel: previousModel
        )
        let provider = AgentSettingsProviderManifest(
            id: providerBase.id,
            name: providerBase.name,
            baseURL: providerBase.baseURL,
            chatEndpoint: providerBase.chatEndpoint,
            providerProfileID: providerBase.providerProfileID,
            protocolProfileID: providerBase.protocolProfileID,
            authPolicy: .noAuthentication,
            ds4Runtime: runtime
        )
        return AgentSettingsModelManifest(
            id: modelID,
            kind: .remoteAPI,
            title: previousModel?.title ?? candidate.title,
            llmID: previousModel?.llmID,
            modelID: apiModelID,
            providerID: providerBase.id,
            provider: provider.remoteProvider(modelID: apiModelID),
            configuredContextWindowLimit: runtime.contextWindow,
            generationParameterOverrides: previousModel?.generationParameterOverrides,
            thinkingOptions: thinking.options,
            defaultThinkingSelection: thinking.defaultSelection,
            ds4Runtime: runtime
        )
    }

    /// Thinking levels and default of a DS4 model. The saved levels of the model
    /// for the same GGUF are kept as they are; a model without any (never
    /// configured, or configured before setup assigned them) gets the levels of
    /// its family with the default ``ds4DefaultThinkingSelection``.
    private static func ds4ThinkingConfiguration(
        forAPIModelID apiModelID: String,
        previousModel: AgentSettingsModelManifest?
    ) -> (options: [AgentThinkingSelection], defaultSelection: AgentThinkingSelection?) {
        if let saved = previousModel?.thinkingOptions, !saved.isEmpty {
            return (saved, previousModel?.defaultThinkingSelection)
        }
        return (ds4ThinkingOptions(forAPIModelID: apiModelID), ds4DefaultThinkingSelection)
    }
}
