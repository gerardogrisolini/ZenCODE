//
//  ZenCODESetupRunner+DS4.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Read-only DS4 GGUF discovery and staged setup integration.
//

import Foundation

/// A GGUF found in the DS4 folder that setup can offer as a model.
struct DS4SetupModelCandidate: Equatable, Hashable {
    let relativePath: String
    let title: String
    /// Catalog id when the file is a recognized single-file catalog artifact.
    let catalogID: String?
    /// Catalog API id (nil for files that are not in the catalog).
    let catalogAPIModelID: String?
    let diskBytes: UInt64

    var fileName: String { (relativePath as NSString).lastPathComponent }
    var fileStem: String { (fileName as NSString).deletingPathExtension }
}

/// The optional GGUF a model can be paired with.
enum DS4SetupAuxiliaryKind: Equatable, Hashable, Sendable {
    /// Vision projector (`vision_path`).
    case vision
    /// MTP / DSpark support model (`mtp_path`).
    case mtp

    var title: String {
        switch self {
        case .vision: return "vision projector"
        case .mtp: return "MTP / DSpark support model"
        }
    }
}

/// Test seam of the optional-file question. Receives the model, what the file
/// is for, the GGUFs offered (every `.gguf` of the DS4 folder except the model
/// itself) and the saved choice of that model (`nil` means none); returns the
/// relative path of the chosen file, or `nil` for none.
typealias DS4SetupAuxiliaryFileSelector = (
    DS4SetupModelCandidate,
    DS4SetupAuxiliaryKind,
    [DS4SetupModelCandidate],
    String?
) throws -> String?

/// How the setup builds the in-process engine library, with the seams tests use
/// to keep real processes, the real support folder and the terminal out of it.
struct DS4SetupEngineOptions {
    /// Builds the library. The default runs the real build script.
    var builder: any DS4EngineBuilding
    /// Where the library and the extracted sources live (`nil`: the app support folder).
    var supportDirectory: URL?
    /// Answers "Build the DS4 engine now?" for the pending builds (`nil`: asks in the terminal).
    var confirmBuild: (([DS4EngineBuildRequest]) throws -> Bool)?
    /// Receives every line the setup prints about the engine, including the
    /// build log (`nil`: standard error).
    var output: (@Sendable (String) -> Void)?

    init(
        builder: any DS4EngineBuilding = DS4EngineBuilder(),
        supportDirectory: URL? = nil,
        confirmBuild: (([DS4EngineBuildRequest]) throws -> Bool)? = nil,
        output: (@Sendable (String) -> Void)? = nil
    ) {
        self.builder = builder
        self.supportDirectory = supportDirectory
        self.confirmBuild = confirmBuild
        self.output = output
    }
}

/// What the DS4 setup section does when DS4 is already configured.
enum DS4SetupAction: Hashable, Sendable {
    /// The complete flow: folder, models, backend and tuning.
    case reconfigure
    /// Recompiles the engine library of the configured models and changes no
    /// setting.
    case rebuildEngine
}

extension ZenCODESetupRunner {
    /// Stable provider key of the optional local DS4 provider created by setup.
    /// The provider remains an OpenAI-compatible provider entry with the `ds4`
    /// provider profile; runtime metadata is what lets the backend open the
    /// in-process DS4 engine lazily later.
    static let ds4SetupProviderID = AgentRemoteProvider.ds4ProviderID

    /// Compatibility placeholder: the engine runs in-process, so this URL is
    /// never contacted. It only keeps the provider an ordinary OpenAI-compatible
    /// entry for the settings manifest.
    static let ds4SetupProviderBaseURL = "http://127.0.0.1:8000/v1"
    static let ds4SetupProviderName = "DS4 (local)"

    /// Configures the optional local DS4 provider without touching the DS4
    /// checkout or writing settings. The returned manifest is folded into the
    /// caller's ``SetupSession`` and is persisted only by the normal setup
    /// transaction at the end of the wizard.
    ///
    /// DS4 is never running during setup, so `/models` is never called: models
    /// come from the GGUF files found in the DS4 folder. Missing GGUFs, invalid
    /// paths, an empty selection and cancellation all return the input
    /// manifest unchanged.
    ///
    /// When DS4 is already configured the section first asks what to do
    /// (``DS4SetupAction``). Rebuilding the engine recompiles the libraries of
    /// the configured models and returns the input manifest unchanged; Esc at
    /// that question (or any error of `selectAction`) does the same without
    /// building. Without a DS4 configuration the question is not asked.
    static func configureDS4Runtime(
        existingManifest: AgentSettingsManifest?,
        scanner: DS4InstallationScanner = DS4InstallationScanner(),
        catalog: DS4ModelCatalog = .default,
        prompts: DS4SetupPrompts = DS4SetupPrompts(),
        selectAction: (() throws -> DS4SetupAction)? = nil,
        engine: DS4SetupEngineOptions = DS4SetupEngineOptions()
    ) async throws -> AgentSettingsManifest? {
        if let existingManifest, let configured = existingDS4Runtime(in: existingManifest) {
            let action: DS4SetupAction
            do {
                action = try selectDS4SetupAction(select: selectAction)
            } catch {
                return existingManifest
            }
            if action == .rebuildEngine {
                let runtimes = existingManifest.models.compactMap {
                    $0.ds4Runtime ?? $0.provider?.ds4Runtime
                }
                // Settings are never modified, and a failed or cancelled build
                // must not make the setup throw.
                try? await rebuildDS4Engines(
                    runtimes: runtimes.isEmpty ? [configured] : runtimes,
                    engine: engine
                )
                return existingManifest
            }
        }

        let previousProvider = existingManifest?.providers.first { $0.ds4Runtime != nil }
        let previousModels = previousProvider.map { provider in
            ds4Models(for: provider, in: existingManifest?.models ?? [])
        } ?? (existingManifest?.models.filter { $0.ds4Runtime != nil } ?? [])
        let providerID = previousProvider?.id ?? ds4SetupProviderID
        let previousModelIDs = Set(previousModels.map(\.id))
        let reserved = Set(
            (existingManifest?.models ?? []).map(\.id)
        ).subtracting(previousModelIDs)

        guard let input = await stageDS4ProviderOrNil(
            existingProvider: previousProvider,
            existingModels: previousModels,
            existingAPIKey: nil,
            reservedModelIDs: reserved,
            scanner: scanner,
            catalog: catalog,
            prompts: prompts,
            engine: engine
        ) else {
            return existingManifest
        }
        return manifestByApplyingDS4(
            existingManifest,
            input: input,
            replacingProviderID: providerID
        )
    }

    /// Asks whether to reconfigure DS4 or to rebuild its engine. Esc throws
    /// `ZenCODESetupError.cancelled`.
    private static func selectDS4SetupAction(
        select: (() throws -> DS4SetupAction)?
    ) throws -> DS4SetupAction {
        if let select {
            return try select()
        }
        return try promptMenuChoice(
            title: "DS4 local runtime",
            items: [
                TerminalCheckboxMenuItem(
                    value: DS4SetupAction.reconfigure,
                    title: "Reconfigure DS4 models",
                    detail: "folder, models, backend and tuning"
                ),
                TerminalCheckboxMenuItem(
                    value: DS4SetupAction.rebuildEngine,
                    title: "Rebuild the DS4 engine",
                    detail: "recompile libzencode-ds4 for the configured models, settings unchanged"
                )
            ],
            selected: .reconfigure
        )
    }

    /// Dispatch used by "Providers & models" when the provider being
    /// reconfigured is the DS4 provider: it never goes through
    /// `readRemoteAPIProvider`, so `/models` is never requested. A cancelled or
    /// unchanged flow keeps the existing input.
    static func reconfigureDS4ProviderInput(
        _ providerInput: SetupProviderInput,
        reservedModelIDs: Set<String> = [],
        scanner: DS4InstallationScanner = DS4InstallationScanner(),
        catalog: DS4ModelCatalog = .default,
        prompts: DS4SetupPrompts = DS4SetupPrompts(),
        engine: DS4SetupEngineOptions = DS4SetupEngineOptions()
    ) async -> SetupProviderInput {
        await stageDS4ProviderOrNil(
            existingProvider: providerManifest(from: providerInput),
            existingModels: providerInput.models,
            existingAPIKey: providerInput.apiKey,
            reservedModelIDs: reservedModelIDs,
            scanner: scanner,
            catalog: catalog,
            prompts: prompts,
            engine: engine
        ) ?? providerInput
    }

    static var defaultDS4Backend: AgentDS4RuntimeBackend {
        #if os(macOS)
        .metal
        #else
        .cpu
        #endif
    }

    /// Every regular GGUF in the DS4 folder, except files the catalog marks as
    /// shards of a multi-artifact entry (they cannot run on their own).
    static func ds4SetupCandidates(
        installation: DS4InstallationSnapshot,
        catalog: DS4ModelCatalog
    ) -> [DS4SetupModelCandidate] {
        installation.artifacts.compactMap { artifact in
            guard artifact.relativePath.lowercased().hasSuffix(".gguf") else { return nil }
            let entry = catalog.entry(forArtifactPath: artifact.relativePath)
            if let entry,
               entry.artifacts.count > 1,
               entry.artifacts.first(where: { $0.relativePath == artifact.relativePath })?.role == .modelShard {
                return nil
            }
            return ds4SetupCandidate(for: artifact, entry: entry)
        }
    }

    /// Every GGUF in the DS4 folder, shards of split models included: the
    /// vision projector and the MTP/DSpark support model are plain GGUFs that
    /// the model list does not necessarily show.
    static func ds4SetupAuxiliaryCandidates(
        installation: DS4InstallationSnapshot,
        catalog: DS4ModelCatalog
    ) -> [DS4SetupModelCandidate] {
        installation.artifacts.compactMap { artifact in
            guard artifact.relativePath.lowercased().hasSuffix(".gguf") else { return nil }
            return ds4SetupCandidate(
                for: artifact,
                entry: catalog.entry(forArtifactPath: artifact.relativePath)
            )
        }
    }

    private static func ds4SetupCandidate(
        for artifact: DS4InstalledArtifact,
        entry: DS4ModelCatalogEntry?
    ) -> DS4SetupModelCandidate {
        let stem = ((artifact.relativePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        return DS4SetupModelCandidate(
            relativePath: artifact.relativePath,
            title: entry?.displayName ?? stem,
            catalogID: entry?.id,
            catalogAPIModelID: entry?.apiModelID,
            diskBytes: artifact.diskBytes
        )
    }

    /// API id of DeepSeek V4.1 (DSML41 tool syntax), the only family whose
    /// effort levels `DS4ThinkModeMapping` keeps distinct.
    private static let ds4DeepSeek41APIModelID = "deepseek-v4.1-flash"

    /// Level `/think` starts on for a DS4 model that has no saved default: the
    /// default think mode of ds4-agent (HIGH).
    static let ds4DefaultThinkingSelection: AgentThinkingSelection = .high

    /// Thinking levels setup assigns to a DS4 model, by the family of its API
    /// model id, without asking. Only levels that `DS4ThinkModeMapping` maps to
    /// distinct think modes are offered: DeepSeek V4.1 has explicit effort levels
    /// for all of them, while the other families (DeepSeek V4, GLM, Qwen) have
    /// the named modes LOW, MEDIUM, HIGH and MAX only (`minimal` is `low`,
    /// `xhigh` is `high`, `ultra` is `max`).
    static func ds4ThinkingOptions(forAPIModelID apiModelID: String) -> [AgentThinkingSelection] {
        if apiModelID == ds4DeepSeek41APIModelID {
            return [.off, .minimal, .low, .medium, .high, .xhigh, .max]
        }
        return [.off, .low, .medium, .high, .max]
    }

    static func existingDS4Runtime(
        in manifest: AgentSettingsManifest?
    ) -> AgentDS4RuntimeManifest? {
        manifest?.providers.compactMap(\.ds4Runtime).first
            ?? manifest?.models.compactMap(\.ds4Runtime).first
    }

    private static func ds4Models(
        for provider: AgentSettingsProviderManifest,
        in models: [AgentSettingsModelManifest]
    ) -> [AgentSettingsModelManifest] {
        models.filter { model in
            model.ds4Runtime != nil
                || model.provider?.ds4Runtime != nil
                || model.providerID == provider.id
        }
    }

    /// Reconciles the staged DS4 provider/models while retaining every existing
    /// non-DS4 provider, model, key and optional setting at the value level. The
    /// normal manifest initializer performs its established normalization and
    /// provider/model linking afterward.
    static func manifestByApplyingDS4(
        _ existingManifest: AgentSettingsManifest?,
        input: SetupProviderInput,
        replacingProviderID: String
    ) -> AgentSettingsManifest {
        let provider = providerManifest(from: input)
        let providerIDs: Set<String> = [replacingProviderID, input.id]

        let providersWithoutDS4 = existingManifest?.providers.filter {
            !providerIDs.contains($0.id) && $0.ds4Runtime == nil
        } ?? []
        let modelsWithoutDS4 = existingManifest?.models.filter { existingModel in
            let modelProviderID = existingModel.providerID ?? existingModel.provider?.id
            return !(modelProviderID.map(providerIDs.contains) ?? false)
                && existingModel.ds4Runtime == nil
                && existingModel.provider?.ds4Runtime == nil
        } ?? []
        let models = modelsWithoutDS4 + input.models

        let existingSelection = existingManifest?.selectedModelID
        let selectionStillPresent = existingSelection.flatMap { id in
            models.first { $0.matches(id) }?.id
        }
        let selectedModelID = selectionStillPresent ?? input.models[0].id

        return AgentSettingsManifest(
            version: existingManifest?.version ?? AgentSettingsManifest.currentVersion,
            providers: providersWithoutDS4 + [provider],
            models: models,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectionStillPresent == nil
                ? nil
                : existingManifest?.selectedThinkingSelection,
            telegram: existingManifest?.telegram,
            voice: existingManifest?.voice,
            remoteAPIKeysByProviderID: existingManifest?.remoteAPIKeysByProviderID ?? [:],
            localExecAllowedCommands: existingManifest?.localExecAllowedCommands ?? [],
            chatGPTSubscriptionCredentials: existingManifest?.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: existingManifest?.anthropicSubscriptionCredentials,
            responseLanguage: existingManifest?.responseLanguage,
            memoryEmbedding: existingManifest?.memoryEmbedding
        )
    }

    /// Menu summary: each DS4 model with its own launch parameters (including
    /// the paired vision, MTP and steering files and the state of the engine
    /// library for its backend), then the shared DS4 folder.
    static func ds4RuntimeSetupDetail(
        _ manifest: AgentSettingsManifest?,
        supportDirectory: URL? = nil
    ) -> String {
        guard let runtime = existingDS4Runtime(in: manifest) else {
            return "not configured"
        }
        let supportDirectory = supportDirectory ?? AppStorageDirectory.appSupportDirectoryURL()
        var engineStates: [DS4EngineTarget: String] = [:]
        var parts: [String] = []
        for model in manifest?.models ?? [] {
            guard let modelRuntime = model.ds4Runtime ?? model.provider?.ds4Runtime else {
                continue
            }
            var settings = [modelRuntime.backend.rawValue]
            if modelRuntime.ssdStreaming {
                settings.append("SSD streaming")
            }
            if modelRuntime.mtp {
                settings.append("MTP")
            }
            if modelRuntime.dspark {
                settings.append("DSpark")
            }
            settings.append("power \(modelRuntime.power)")
            settings.append("ctx \(modelRuntime.contextWindow)")
            settings.append("vision \(ds4FileName(modelRuntime.visionRelativePath))")
            settings.append("MTP model \(ds4FileName(modelRuntime.mtpRelativePath))")
            settings.append("steer \(ds4FileName(modelRuntime.steeringRelativePath))")

            let target = DS4EngineTarget(runtime: modelRuntime)
            let engineState: String
            if let known = engineStates[target] {
                engineState = known
            } else {
                engineState = ds4EngineStateDescription(for: target, supportDirectory: supportDirectory)
                engineStates[target] = engineState
            }
            settings.append("engine \(engineState)")
            parts.append("\(model.id) (\(settings.joined(separator: ", ")))")
        }
        parts.append(runtime.rootDirectory)
        return parts.joined(separator: " · ")
    }

    /// File name of a stored relative path, or `none`.
    private static func ds4FileName(_ relativePath: String?) -> String {
        relativePath.map { ($0 as NSString).lastPathComponent } ?? "none"
    }
}
