//
//  ZenCODESetupRunner+DS4ProviderStaging.swift
//  ZenCODE
//
//  Staging of the DS4 provider: folder scan, the "DS4 models" menu (configure,
//  add or delete one model at a time), the questions of one model, then the
//  engine build.
//

import Foundation
import ZenCODERuntime

/// What every step of one DS4 stage shares: the scanned folder, the provider
/// the models belong to and the questions.
struct DS4SetupStage {
    /// Canonical DS4 folder.
    let rootDirectory: String
    /// GGUFs that can be a model (shards of split models excluded).
    let candidates: [DS4SetupModelCandidate]
    /// Every GGUF of the folder, offered as vision projector or DSpark support model.
    let auxiliaryCandidates: [DS4SetupModelCandidate]
    let providerBase: AgentSettingsProviderManifest
    /// The DS4 models saved before this setup: the defaults of a GGUF that is
    /// added again.
    let existingModels: [AgentSettingsModelManifest]
    /// Ids of the models of the other providers.
    let reservedModelIDs: Set<String>
    let prompts: DS4SetupPrompts
}

/// The answers for one model: everything its manifest needs but its id.
struct DS4SetupModelAnswers {
    let runtime: AgentDS4RuntimeManifest
    let apiModelID: String
}

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
        prompts: DS4SetupPrompts = DS4SetupPrompts(),
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
                prompts: prompts,
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

    /// Core DS4 flow: folder → models → engine build.
    ///
    /// With no saved model in the folder, the flow goes straight to the GGUF
    /// selection and asks the questions of every file selected. Otherwise it
    /// opens the "DS4 models" menu, where each model is configured or deleted
    /// on its own and new GGUFs are added, until Done (see
    /// ``manageDS4Models(_:stage:)``).
    ///
    /// Every model gets its own launch parameters; defaults come from that
    /// model's previously saved runtime, never from another model. Each model
    /// also gets the `/think` levels of its family (no question is asked, see
    /// ``ds4ThinkingOptions(forAPIModelID:)``); the levels already saved for
    /// the same GGUF are kept unchanged.
    ///
    /// Saved models whose GGUF is not in the folder are dropped; the others
    /// move to the folder when it changed.
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
        prompts: DS4SetupPrompts = DS4SetupPrompts(),
        engine: DS4SetupEngineOptions = DS4SetupEngineOptions()
    ) async throws -> SetupProviderInput? {
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
        // The vision and DSpark GGUFs are offered from the complete list,
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
        let stage = DS4SetupStage(
            rootDirectory: installation.rootDirectory,
            candidates: candidates,
            auxiliaryCandidates: auxiliaryCandidates,
            providerBase: providerBase,
            existingModels: existingModels,
            reservedModelIDs: reservedModelIDs,
            prompts: prompts
        )

        let savedModels = try ds4ModelsInFolder(existingModels, stage: stage)
        let models: [AgentSettingsModelManifest]
        if savedModels.isEmpty {
            guard let added = try addDS4Models(to: [], stage: stage) else {
                return nil
            }
            guard !added.isEmpty else {
                AgentOutput.standardError.writeString("No DS4 model selected. Nothing was changed.\n")
                return nil
            }
            models = added
        } else {
            guard let managed = try manageDS4Models(savedModels, stage: stage) else {
                return nil
            }
            models = managed
        }

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
            ds4Runtime: models[0].ds4Runtime,
            apiKey: existingAPIKey,
            models: models
        )
    }

    /// The "DS4 models" menu, until Done: each choice changes the models and
    /// shows the menu again. Configure asks the questions of one model, Delete
    /// removes one, Add models adds GGUFs of the folder that no model uses.
    ///
    /// Returns the models at Done, or `nil` when the menu is left with Esc:
    /// every change of this visit is then discarded. Esc or an error inside a
    /// step discards only that step. Done needs at least one model: DS4 itself
    /// is removed by deleting its provider in Providers and models.
    private static func manageDS4Models(
        _ initialModels: [AgentSettingsModelManifest],
        stage: DS4SetupStage
    ) throws -> [AgentSettingsModelManifest]? {
        var models = initialModels
        while true {
            let usedPaths = Set(models.compactMap { $0.ds4Runtime?.modelRelativePath })
            let canAdd = stage.candidates.contains { !usedPaths.contains($0.relativePath) }
            let choice: DS4SetupModelMenuChoice
            do {
                choice = try stage.prompts.modelMenu(models, canAdd)
            } catch ZenCODESetupError.cancelled {
                AgentOutput.standardError.writeString("DS4 models cancelled; changes not saved.\n")
                return nil
            }

            switch choice {
            case .done:
                guard !models.isEmpty else {
                    AgentOutput.standardError.writeString(
                        "Keep at least one DS4 model. To remove DS4, delete its provider in Providers and models.\n"
                    )
                    continue
                }
                return models

            case .add:
                guard canAdd else { continue }
                let current = models
                if let added = ds4ModelMenuStep("Add models", {
                    try addDS4Models(to: current, stage: stage)
                }) ?? nil {
                    models += added
                }

            case let .configure(id):
                guard let index = models.firstIndex(where: { $0.id == id }),
                      let candidate = ds4Candidate(for: models[index], stage: stage) else {
                    continue
                }
                let model = models[index]
                if let answers = ds4ModelMenuStep("Configure \(model.displayTitle)", {
                    try promptDS4Model(candidate, previousModel: model, stage: stage)
                }) ?? nil {
                    models[index] = ds4ModelManifest(
                        candidate: candidate,
                        previousModel: model,
                        runtime: answers.runtime,
                        providerBase: stage.providerBase,
                        modelID: model.id,
                        apiModelID: answers.apiModelID
                    )
                }

            case let .delete(id):
                models.removeAll { $0.id == id }
            }
        }
    }

    /// Runs one step of the "DS4 models" menu. Esc discards the step; any
    /// other error is printed and discards it as well. Both return `nil`, and
    /// the menu, whose own Esc leaves the section, opens again.
    private static func ds4ModelMenuStep<Value>(
        _ title: String,
        _ body: () throws -> Value
    ) -> Value? {
        do {
            return try body()
        } catch ZenCODESetupError.cancelled {
            AgentOutput.standardError.writeString("\(title) cancelled.\n")
        } catch {
            AgentOutput.standardError.writeString("\(title) failed: \(error.localizedDescription)\n")
        }
        return nil
    }

    /// The saved models whose GGUF is in the scanned folder, in their saved
    /// order and moved to that folder when it changed, each rebuilt with the
    /// current provider (and the thinking levels of its family when it has
    /// none). The other saved models are dropped, with a note.
    private static func ds4ModelsInFolder(
        _ existingModels: [AgentSettingsModelManifest],
        stage: DS4SetupStage
    ) throws -> [AgentSettingsModelManifest] {
        let auxiliaryPaths = Set(stage.auxiliaryCandidates.map(\.relativePath))
        var models: [AgentSettingsModelManifest] = []
        for model in existingModels {
            guard let runtime = model.ds4Runtime,
                  let candidate = ds4Candidate(for: model, stage: stage) else {
                AgentOutput.standardError.writeString(
                    "  \(model.displayTitle) is not in the DS4 folder and will be removed.\n"
                )
                continue
            }
            models.append(
                ds4ModelManifest(
                    candidate: candidate,
                    previousModel: model,
                    runtime: try ds4Runtime(
                        runtime,
                        movedTo: stage.rootDirectory,
                        auxiliaryPaths: auxiliaryPaths
                    ),
                    providerBase: stage.providerBase,
                    modelID: model.id,
                    apiModelID: ds4KnownAPIModelID(for: candidate, previousModel: model) ?? model.modelID
                )
            )
        }
        return models
    }

    /// The candidate of the GGUF of a model, when the folder holds it.
    private static func ds4Candidate(
        for model: AgentSettingsModelManifest,
        stage: DS4SetupStage
    ) -> DS4SetupModelCandidate? {
        guard let path = model.ds4Runtime?.modelRelativePath else {
            return nil
        }
        return stage.candidates.first { $0.relativePath == path }
    }

    /// Add models: the GGUF selection, offering only the files no model of
    /// `models` uses, then the questions of each file selected, in the order
    /// of the folder. A file that had a model before this setup starts from
    /// that model's values and keeps its id when it is free.
    ///
    /// Returns the models added (empty when nothing is selected), or `nil`
    /// when the selection is cancelled. Esc in the questions of a model throws
    /// `ZenCODESetupError.cancelled`.
    private static func addDS4Models(
        to models: [AgentSettingsModelManifest],
        stage: DS4SetupStage
    ) throws -> [AgentSettingsModelManifest]? {
        let usedPaths = Set(models.compactMap { $0.ds4Runtime?.modelRelativePath })
        let available = stage.candidates.filter { !usedPaths.contains($0.relativePath) }
        guard let selectedPaths = try stage.prompts.files(available, []) else {
            return nil
        }

        var usedIDs = stage.reservedModelIDs.union(models.map(\.id))
        var added: [AgentSettingsModelManifest] = []
        for candidate in available where selectedPaths.contains(candidate.relativePath) {
            let previousModel = ds4PreviousModel(for: candidate, in: stage.existingModels)
            guard let answers = try promptDS4Model(
                candidate,
                previousModel: previousModel,
                stage: stage
            ) else {
                continue
            }
            // The id is taken here, once the model is certain to be kept, so a
            // skipped GGUF never uses one up.
            let modelID: String
            if let previousID = previousModel?.id, !usedIDs.contains(previousID) {
                modelID = previousID
                usedIDs.insert(previousID)
            } else {
                let base = "ds4:" + (candidate.catalogID ?? candidate.fileStem.lowercased())
                modelID = uniqueDS4ModelID(base, used: &usedIDs)
            }
            added.append(
                ds4ModelManifest(
                    candidate: candidate,
                    previousModel: previousModel,
                    runtime: answers.runtime,
                    providerBase: stage.providerBase,
                    modelID: modelID,
                    apiModelID: answers.apiModelID
                )
            )
        }
        return added
    }

    /// The questions of one model, starting from the values of `previousModel`
    /// (the standard defaults without one): the API id (only when nothing else
    /// gives it), the backend, the tuning, the optional vision projector and,
    /// for a DeepSeek model, the DSpark support model, which turns DSpark on.
    /// Returns `nil` when the file is not a GGUF.
    private static func promptDS4Model(
        _ candidate: DS4SetupModelCandidate,
        previousModel: AgentSettingsModelManifest?,
        stage: DS4SetupStage
    ) throws -> DS4SetupModelAnswers? {
        let prompts = stage.prompts
        // Launch parameters belong to this model only.
        let previousRuntime = previousModel?.ds4Runtime
        let apiModelID = try ds4KnownAPIModelID(for: candidate, previousModel: previousModel)
            ?? prompts.apiModelID(candidate)
        let usesDSpark = ds4UsesDSpark(apiModelID: apiModelID)

        let backend = try prompts.backend(candidate, previousRuntime?.backend ?? defaultDS4Backend)
        let tuning = try prompts.tuning(
            candidate,
            ds4TuningDefaults(from: previousRuntime),
            DS4SetupTuningContext(backend: backend, usesDSpark: usesDSpark)
        )

        // Optional paired GGUFs: vision projector and DSpark support model.
        let pairable = stage.auxiliaryCandidates.filter { $0.relativePath != candidate.relativePath }
        let visionRelativePath = try selectDS4AuxiliaryFile(
            kind: .vision,
            model: candidate,
            pairable: pairable,
            saved: previousRuntime?.visionRelativePath,
            select: prompts.auxiliaryFile
        )
        var dsparkRelativePath: String?
        if usesDSpark {
            // Only a support model that DSpark used is proposed again.
            dsparkRelativePath = try selectDS4AuxiliaryFile(
                kind: .dspark,
                model: candidate,
                pairable: pairable,
                saved: previousRuntime?.dspark == true ? previousRuntime?.mtpRelativePath : nil,
                select: prompts.auxiliaryFile
            )
        }

        let runtime = try ds4RuntimeManifest(
            rootDirectory: stage.rootDirectory,
            candidate: candidate,
            previousRuntime: previousRuntime,
            backend: backend,
            visionRelativePath: visionRelativePath,
            dsparkRelativePath: dsparkRelativePath,
            usesDSpark: usesDSpark,
            tuning: tuning
        )
        let modelURL = try AgentDS4PathGuard.resolveModelURL(
            rootDirectory: stage.rootDirectory,
            modelRelativePath: candidate.relativePath
        )
        guard modelURL.pathExtension.lowercased() == "gguf" else { return nil }
        return DS4SetupModelAnswers(runtime: runtime, apiModelID: apiModelID)
    }

    /// The API id that the catalog, the name of the GGUF or the served id
    /// saved for it gives, in this order; `nil` when none of them does.
    private static func ds4KnownAPIModelID(
        for candidate: DS4SetupModelCandidate,
        previousModel: AgentSettingsModelManifest?
    ) -> String? {
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
        return nil
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

    /// Asks for the optional vision / DSpark file of one model. With no other
    /// GGUF in the folder there is nothing to choose and nothing is asked.
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
