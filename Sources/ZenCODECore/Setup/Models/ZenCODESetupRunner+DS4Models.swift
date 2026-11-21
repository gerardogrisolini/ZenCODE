//
//  ZenCODESetupRunner+DS4Models.swift
//  ZenCODE
//
//  Pure steps of the DS4 stage: the next free model id, the runtime manifest
//  of one model, a saved runtime moved to another DS4 folder and the model
//  manifest built from a runtime. They ask nothing and touch no file.
//

import Foundation
import ZenCODERuntime

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

    /// Whether a model uses DSpark rather than MTP for speculative decoding.
    /// DSpark is the speculative decoding of the DeepSeek models and needs
    /// their support GGUF; the other families (GLM, Qwen) use the MTP block
    /// built into their own GGUF.
    static func ds4UsesDSpark(apiModelID: String) -> Bool {
        apiModelID.lowercased().hasPrefix("deepseek-")
    }

    /// Runtime of one model: the answers of the setup plus, from the previous
    /// runtime of the same GGUF, the SSD streaming cache values that setup
    /// does not ask. Throws when a value is not valid for the manifest.
    ///
    /// The speculative decoding follows the family of the model. A DeepSeek
    /// model (`usesDSpark`) gets DSpark on exactly when it has a support model
    /// (`dsparkRelativePath`), which is stored as its MTP file, and MTP off.
    /// Any other model gets the MTP of `tuning`, DSpark off and no MTP file.
    /// Every other value comes from `tuning`.
    static func ds4RuntimeManifest(
        rootDirectory: String,
        candidate: DS4SetupModelCandidate,
        previousRuntime: AgentDS4RuntimeManifest?,
        backend: AgentDS4RuntimeBackend,
        visionRelativePath: String?,
        dsparkRelativePath: String?,
        usesDSpark: Bool,
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
            mtp: !usesDSpark && tuning.mtp,
            power: tuning.power,
            visionRelativePath: visionRelativePath,
            mtpRelativePath: usesDSpark ? dsparkRelativePath : nil,
            steeringRelativePath: tuning.steeringRelativePath,
            dspark: usesDSpark && dsparkRelativePath != nil,
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

    /// `runtime` in the DS4 folder `rootDirectory`, with every other value
    /// unchanged. In the same folder the runtime is returned as it is. In
    /// another folder, the vision projector and the MTP / DSpark file that
    /// the new folder does not hold (`auxiliaryPaths`, its GGUFs) are dropped,
    /// and DSpark goes off without its support model.
    static func ds4Runtime(
        _ runtime: AgentDS4RuntimeManifest,
        movedTo rootDirectory: String,
        auxiliaryPaths: Set<String>
    ) throws -> AgentDS4RuntimeManifest {
        guard runtime.rootDirectory != rootDirectory else {
            return runtime
        }
        let visionRelativePath = runtime.visionRelativePath.flatMap {
            auxiliaryPaths.contains($0) ? $0 : nil
        }
        let mtpRelativePath = runtime.mtpRelativePath.flatMap {
            auxiliaryPaths.contains($0) ? $0 : nil
        }
        return try AgentDS4RuntimeManifest(
            rootDirectory: rootDirectory,
            modelRelativePath: runtime.modelRelativePath,
            backend: runtime.backend,
            contextWindow: runtime.contextWindow,
            ssdStreaming: runtime.ssdStreaming,
            ssdStreamingCacheExperts: runtime.ssdStreamingCacheExperts,
            ssdStreamingCacheBytes: runtime.ssdStreamingCacheBytes,
            ssdStreamingPreloadExperts: runtime.ssdStreamingPreloadExperts,
            ssdStreamingCold: runtime.ssdStreamingCold,
            mtp: runtime.mtp,
            power: runtime.power,
            visionRelativePath: visionRelativePath,
            mtpRelativePath: mtpRelativePath,
            steeringRelativePath: runtime.steeringRelativePath,
            dspark: runtime.dspark && mtpRelativePath != nil,
            mtpDraftTokens: runtime.mtpDraftTokens,
            mtpMargin: runtime.mtpMargin,
            quality: runtime.quality,
            threads: runtime.threads,
            prefillChunk: runtime.prefillChunk,
            warmWeights: runtime.warmWeights,
            steeringFFN: runtime.steeringFFN,
            steeringAttn: runtime.steeringAttn,
            cudaArch: runtime.cudaArch,
            rocmArch: runtime.rocmArch,
            engineSessions: runtime.engineSessions,
            extraEngineArguments: runtime.extraEngineArguments
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
