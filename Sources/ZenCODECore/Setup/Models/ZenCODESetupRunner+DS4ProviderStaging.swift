//
//  ZenCODESetupRunner+DS4ProviderStaging.swift
//  ZenCODE
//
//  Staging of the DS4 provider: GGUF selection, per-model backend, auxiliary
//  files, tuning and API id, then the engine build.
//

import Foundation

extension ZenCODESetupRunner {
    /// Non-throwing wrapper: a failed discovery, an invalid folder and an
    /// Esc/EOF cancellation all return `nil` ("unchanged") instead of crashing
    /// setup.
    static func stageDS4ProviderOrNil(
        existingProvider: AgentSettingsProviderManifest?,
        existingModels: [AgentSettingsModelManifest],
        existingAPIKey: String?,
        reservedModelIDs: Set<String> = [],
        scanner: DS4InstallationScanner = DS4InstallationScanner(),
        catalog: DS4ModelCatalog = .default,
        promptFolder: ((String?) throws -> String?)? = nil,
        selectFiles: (([DS4SetupModelCandidate], Set<String>) throws -> Set<String>?)? = nil,
        selectBackend: ((DS4SetupModelCandidate, AgentDS4RuntimeBackend) throws -> AgentDS4RuntimeBackend)? = nil,
        selectAPIModelID: ((DS4SetupModelCandidate) throws -> String)? = nil,
        selectAuxiliaryFile: DS4SetupAuxiliaryFileSelector? = nil,
        promptTuning: ((DS4SetupModelCandidate, AgentDS4RuntimeTuning) throws -> AgentDS4RuntimeTuning)? = nil,
        engine: DS4SetupEngineOptions = DS4SetupEngineOptions()
    ) async -> SetupProviderInput? {
        do {
            return try await stageDS4Provider(
                existingProvider: existingProvider,
                existingModels: existingModels,
                existingAPIKey: existingAPIKey,
                reservedModelIDs: reservedModelIDs,
                scanner: scanner,
                catalog: catalog,
                promptFolder: promptFolder,
                selectFiles: selectFiles,
                selectBackend: selectBackend,
                selectAPIModelID: selectAPIModelID,
                selectAuxiliaryFile: selectAuxiliaryFile,
                promptTuning: promptTuning,
                engine: engine
            )
        } catch {
            if !(error is ZenCODESetupError) {
                AgentOutput.standardError.writeString(
                    "DS4 setup did not change settings: \(error.localizedDescription)\n"
                )
            }
            return nil
        }
    }

    /// Core DS4 flow: folder → GGUF multi-select → per-model backend, optional
    /// vision and MTP/DSpark files, tuning and API id → engine build. Every
    /// model gets its own launch parameters; defaults come from that model's
    /// previously saved runtime, never from another model.
    ///
    /// Each model also gets the `/think` levels of its family (no question is
    /// asked, see ``ds4ThinkingOptions(forAPIModelID:)``); the levels already
    /// saved for the same GGUF are kept unchanged.
    ///
    /// The engine library is built last (when the user agrees), still before
    /// the caller commits anything: a failed build prints the error and the
    /// manual command but does not discard the staged configuration.
    /// Returns a staged provider input, or `nil` when nothing should change.
    static func stageDS4Provider(
        existingProvider: AgentSettingsProviderManifest?,
        existingModels: [AgentSettingsModelManifest],
        existingAPIKey: String? = nil,
        reservedModelIDs: Set<String> = [],
        scanner: DS4InstallationScanner = DS4InstallationScanner(),
        catalog: DS4ModelCatalog = .default,
        promptFolder: ((String?) throws -> String?)? = nil,
        selectFiles: (([DS4SetupModelCandidate], Set<String>) throws -> Set<String>?)? = nil,
        selectBackend: ((DS4SetupModelCandidate, AgentDS4RuntimeBackend) throws -> AgentDS4RuntimeBackend)? = nil,
        selectAPIModelID: ((DS4SetupModelCandidate) throws -> String)? = nil,
        selectAuxiliaryFile: DS4SetupAuxiliaryFileSelector? = nil,
        promptTuning: ((DS4SetupModelCandidate, AgentDS4RuntimeTuning) throws -> AgentDS4RuntimeTuning)? = nil,
        engine: DS4SetupEngineOptions = DS4SetupEngineOptions()
    ) async throws -> SetupProviderInput? {
        let prompts = DS4SetupPrompts(
            folder: promptFolder,
            files: selectFiles,
            backend: selectBackend,
            auxiliaryFile: selectAuxiliaryFile,
            tuning: promptTuning,
            apiModelID: selectAPIModelID
        )
        let previousRootDirectory = (existingProvider?.ds4Runtime
            ?? existingModels.compactMap(\.ds4Runtime).first
        )?.rootDirectory
        let folder = try prompts.folder(previousRootDirectory)
        guard let folder, !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let installation = try scanner.scan(rootDirectory: folder)
        for diagnostic in installation.diagnostics {
            AgentOutput.standardError.writeString("  scan note: \(diagnostic)\n")
        }
        let candidates = ds4SetupCandidates(installation: installation, catalog: catalog)
        // The vision and MTP/DSpark GGUFs are offered from the complete list,
        // including files the model list hides (shards of split models).
        let auxiliaryCandidates = ds4SetupAuxiliaryCandidates(
            installation: installation,
            catalog: catalog
        )
        guard !candidates.isEmpty else {
            AgentOutput.standardError.writeString(
                "No GGUF model was found in the DS4 folder. Nothing was changed.\n"
            )
            return nil
        }

        let preselected = Set(
            existingModels.compactMap { $0.ds4Runtime?.modelRelativePath }
        ).intersection(candidates.map(\.relativePath))
        guard let selectedPaths = try prompts.files(candidates, preselected) else { return nil }
        let selected = candidates.filter { selectedPaths.contains($0.relativePath) }
        guard !selected.isEmpty else {
            AgentOutput.standardError.writeString("No DS4 model selected. Nothing was changed.\n")
            return nil
        }

        let providerID = existingProvider?.id ?? ds4SetupProviderID
        let providerBase = AgentSettingsProviderManifest(
            id: providerID,
            name: existingProvider?.name ?? ds4SetupProviderName,
            baseURL: existingProvider?.baseURL ?? ds4SetupProviderBaseURL,
            chatEndpoint: existingProvider?.chatEndpoint ?? .chatCompletions,
            providerProfileID: .ds4,
            protocolProfileID: existingProvider?.protocolProfileID ?? .openAIChatCompletions,
            authPolicy: .noAuthentication
        )

        var usedIDs = ds4PreservedModelIDs(
            for: selected,
            existingModels: existingModels,
            reservedModelIDs: reservedModelIDs
        )

        var models: [AgentSettingsModelManifest] = []
        var firstRuntime: AgentDS4RuntimeManifest?
        for candidate in selected {
            let previousModel = ds4PreviousModel(for: candidate, in: existingModels)
            // Launch parameters belong to this model only.
            let previousRuntime = previousModel?.ds4Runtime
            let defaultBackend = previousRuntime?.backend ?? defaultDS4Backend
            let backend = try prompts.backend(candidate, defaultBackend)

            let tuningDefaults = ds4TuningDefaults(from: previousRuntime)

            // Optional paired GGUFs: vision projector and MTP/DSpark support model.
            let pairable = auxiliaryCandidates.filter { $0.relativePath != candidate.relativePath }
            let visionRelativePath = try selectDS4AuxiliaryFile(
                kind: .vision,
                model: candidate,
                pairable: pairable,
                saved: previousRuntime?.visionRelativePath,
                select: prompts.auxiliaryFile
            )
            let mtpRelativePath = try selectDS4AuxiliaryFile(
                kind: .mtp,
                model: candidate,
                pairable: pairable,
                saved: previousRuntime?.mtpRelativePath,
                select: prompts.auxiliaryFile
            )

            let tuning = try prompts.tuning(
                candidate,
                tuningDefaults,
                DS4SetupTuningContext(
                    backend: backend,
                    rootDirectory: installation.rootDirectory,
                    hasMTPModel: mtpRelativePath != nil
                )
            )

            let runtime = try ds4RuntimeManifest(
                rootDirectory: installation.rootDirectory,
                candidate: candidate,
                previousRuntime: previousRuntime,
                backend: backend,
                visionRelativePath: visionRelativePath,
                mtpRelativePath: mtpRelativePath,
                tuning: tuning
            )
            let modelURL = try AgentDS4PathGuard.resolveModelURL(
                rootDirectory: installation.rootDirectory,
                modelRelativePath: candidate.relativePath
            )
            guard modelURL.pathExtension.lowercased() == "gguf" else { continue }

            let apiModelID = try ds4APIModelID(
                for: candidate,
                previousModel: previousModel,
                select: prompts.apiModelID
            )
            // The id is taken here, once the model is certain to be kept, so a
            // skipped GGUF never uses one up.
            let modelID: String
            if let previousModel {
                modelID = previousModel.id
            } else {
                let base = "ds4:" + (candidate.catalogID ?? candidate.fileStem.lowercased())
                modelID = uniqueDS4ModelID(base, used: &usedIDs)
            }
            models.append(
                ds4ModelManifest(
                    candidate: candidate,
                    previousModel: previousModel,
                    runtime: runtime,
                    providerBase: providerBase,
                    modelID: modelID,
                    apiModelID: apiModelID
                )
            )
            firstRuntime = firstRuntime ?? runtime
        }
        guard let firstRuntime, !models.isEmpty else { return nil }

        // Still part of the staged (uncommitted) setup: whatever happens here,
        // the configuration above is kept.
        try await buildDS4EngineIfNeeded(
            runtimes: models.compactMap(\.ds4Runtime),
            engine: engine
        )

        return SetupProviderInput(
            id: providerID,
            name: providerBase.name,
            baseURL: providerBase.baseURL,
            chatEndpoint: providerBase.chatEndpoint,
            providerProfileID: providerBase.providerProfileID,
            protocolProfileID: providerBase.protocolProfileID,
            authPolicy: .noAuthentication,
            ds4Runtime: firstRuntime,
            apiKey: existingAPIKey,
            models: models
        )
    }

    private static func ds4APIModelID(
        for candidate: DS4SetupModelCandidate,
        previousModel: AgentSettingsModelManifest?,
        select: (DS4SetupModelCandidate) throws -> String
    ) throws -> String {
        if let id = candidate.catalogAPIModelID {
            return id
        }
        if let id = DS4ModelCatalog.inferredAPIModelID(fromFileName: candidate.fileName) {
            return id
        }
        if let previous = previousModel?.modelID,
           DS4ModelCatalog.servedAPIModelIDs.contains(previous) {
            return previous
        }
        return try select(candidate)
    }

    /// Setup defaults for one model: its own saved runtime, or the standard
    /// defaults for a model that was never configured.
    private static func ds4TuningDefaults(from runtime: AgentDS4RuntimeManifest?) -> AgentDS4RuntimeTuning {
        guard let runtime else {
            return AgentDS4RuntimeTuning()
        }
        return AgentDS4RuntimeTuning(
            contextWindow: runtime.contextWindow,
            ssdStreaming: runtime.ssdStreaming,
            mtp: runtime.mtp,
            power: runtime.power,
            dspark: runtime.dspark,
            mtpDraftTokens: runtime.mtpDraftTokens,
            mtpMargin: runtime.mtpMargin,
            quality: runtime.quality,
            threads: runtime.threads,
            prefillChunk: runtime.prefillChunk,
            warmWeights: runtime.warmWeights,
            steeringRelativePath: runtime.steeringRelativePath,
            steeringFFN: runtime.steeringFFN,
            steeringAttn: runtime.steeringAttn,
            cudaArch: runtime.cudaArch,
            rocmArch: runtime.rocmArch,
            engineSessions: runtime.engineSessions,
            extraEngineArguments: runtime.extraEngineArguments
        )
    }

    /// Asks for the optional vision / MTP file of one model. With no other GGUF
    /// in the folder there is nothing to choose and nothing is asked.
    private static func selectDS4AuxiliaryFile(
        kind: DS4SetupAuxiliaryKind,
        model: DS4SetupModelCandidate,
        pairable: [DS4SetupModelCandidate],
        saved: String?,
        select: DS4SetupAuxiliaryFileSelector
    ) throws -> String? {
        guard !pairable.isEmpty else {
            return nil
        }
        // A saved file that is no longer in the folder is dropped.
        let current = saved.flatMap { path in
            pairable.contains { $0.relativePath == path } ? path : nil
        }
        return try select(model, kind, pairable, current)
    }
}
