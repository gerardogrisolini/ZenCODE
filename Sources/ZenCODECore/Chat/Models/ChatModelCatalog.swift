//
//  ChatModelCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The models a chat session can choose from, shared by every channel.
///
/// The models are the ones a host process (an app) supplies, or the user's
/// configured catalog otherwise. The configured catalog is read from the
/// settings on every call, so a change saved meanwhile is picked up. The
/// catalog lists, searches, and resolves models and thinking levels, and saves
/// a choice as the user's default only while ``persistsSelections`` is `true`.
struct ChatModelCatalog: Sendable {
    /// Models supplied by the host process; `nil` for the configured catalog.
    let hostedModels: [AgentSettingsModelManifest]?

    /// Whether model and thinking choices become the persisted defaults. A
    /// host that supplies its own models owns that choice.
    var persistsSelections: Bool {
        hostedModels == nil
    }

    init(hostedModels: [AgentSettingsModelManifest]?) {
        self.hostedModels = hostedModels
    }

    init(environment: ChatSessionEnvironment) {
        self.init(hostedModels: environment.hostedModels)
    }

    // MARK: - Listing

    /// Every available model, in configuration order.
    func availableModels() -> [AgentSettingsModelManifest] {
        hostedModels ?? AgentSettingsStore.availableModels()
    }

    /// Every available model, in presentation order
    /// (see ``AgentModelCatalogPresentation/sorted(_:)``).
    func sortedModels() -> [AgentSettingsModelManifest] {
        AgentModelCatalogPresentation.sorted(availableModels())
    }

    /// The available models grouped by provider, in presentation order.
    func providerGroups() -> [AgentModelProviderGroup] {
        Self.providerGroups(availableModels())
    }

    /// `models` grouped by provider, groups and models in presentation order.
    static func providerGroups(
        _ models: [AgentSettingsModelManifest]
    ) -> [AgentModelProviderGroup] {
        AgentModelCatalogPresentation.groupedByProvider(models)
    }

    // MARK: - Search

    /// The first available model that `modelID` names (its ID, LLM ID, or
    /// model ID). `nil` for a missing or blank reference.
    func model(matching modelID: String?) -> AgentSettingsModelManifest? {
        guard let modelID = modelID?.nilIfBlank else {
            return nil
        }
        return Self.model(matching: modelID, in: availableModels())
    }

    /// The first of `models` that `modelID` names. `nil` for a missing or
    /// blank reference.
    static func model(
        matching modelID: String?,
        in models: [AgentSettingsModelManifest]
    ) -> AgentSettingsModelManifest? {
        guard let modelID = modelID?.nilIfBlank else {
            return nil
        }
        return models.first { $0.matches(modelID) }
    }

    /// The first hosted model that `modelID` names; `nil` without hosted
    /// models.
    func hostedModel(matching modelID: String?) -> AgentSettingsModelManifest? {
        guard let hostedModels else {
            return nil
        }
        return Self.model(matching: modelID, in: hostedModels)
    }

    /// Whether `modelID` is exactly the ID of an available model, the value a
    /// model option carries.
    func containsModel(withID modelID: String) -> Bool {
        availableModels().contains { $0.id == modelID }
    }

    /// The references a model ID resolves through: the ID itself, plus the
    /// model component of a pre-v15 remote API identifier
    /// (`remoteapi:<provider>:<modelID>`), which saved sessions may still
    /// contain. The model component resolves the session against the migrated
    /// `<providerKey>:<modelID>` model by its model ID. The provider segment is
    /// deliberately not parsed (hosted transports may also use opaque provider
    /// segments).
    static func modelReferences(for rawModelID: String) -> [String] {
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            return []
        }
        var references = [modelID]
        let prefixes = ["remoteapi:", "remoteapimodel:"]
        if let prefix = prefixes.first(where: {
            modelID.lowercased().hasPrefix($0)
        }) {
            let remainder = modelID.dropFirst(prefix.count)
            if let separator = remainder.firstIndex(of: ":") {
                let modelComponent = String(remainder[remainder.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !modelComponent.isEmpty {
                    references.append(modelComponent)
                }
            }
        }
        var seen = Set<String>()
        return references.filter { reference in
            seen.insert(reference.lowercased()).inserted
        }
    }

    /// The binding of `agent` that names `model`, by binding ID or by model
    /// reference; `nil` without an agent or a matching binding.
    static func modelBinding(
        of agent: AgentProfile?,
        for model: AgentSettingsModelManifest
    ) -> AgentModelBinding? {
        guard let agent else {
            return nil
        }
        return agent.modelBindings.first { binding in
            let bindingReferences = [
                binding.id,
            ] + modelReferences(for: binding.modelID)
            return bindingReferences.contains { reference in
                model.matches(reference)
            }
        }
    }

    // MARK: - Resolution

    /// The manifest model references are resolved against: the hosted models
    /// with `selectedModelID` as their selection, or the user's settings read
    /// now.
    func resolutionManifest(selectedModelID: String?) -> AgentSettingsManifest? {
        guard let hostedModels else {
            return AgentSettingsManifestStore.load()
        }
        return AgentSettingsManifest(
            models: hostedModels,
            selectedModelID: selectedModelID
        )
    }

    /// The model a new session defaults to.
    ///
    /// With hosted models the host owns the choice and no choice is ever
    /// persisted, so the default is `launchModelID`, the model the process
    /// resolved at launch (`AgentConfiguration.effectiveModelID`), which
    /// already accounts for the explicit model. Otherwise
    /// the user's settings are read now, so a choice saved meanwhile becomes
    /// the default: the explicit model, the agent's model when it is
    /// configured, then the selected or only configured model.
    func defaultModelID(
        explicitModelID: String?,
        agentModelID: String?,
        launchModelID: String?
    ) -> String? {
        guard hostedModels == nil else {
            return launchModelID
        }
        return AgentSettingsStore.resolvedEffectiveModelID(
            explicitModelID: explicitModelID,
            agentModelID: agentModelID,
            manifest: AgentSettingsManifestStore.load()
        )
    }

    // MARK: - Thinking

    /// The thinking levels `model` offers, in menu order; empty when its
    /// thinking is not configurable.
    static func thinkingOptions(
        for model: AgentSettingsModelManifest
    ) -> [AgentThinkingSelection] {
        model.availableThinkingSelections
    }

    /// The thinking level `rawValue` names, when the model `modelID` names
    /// offers exactly that level; `nil` otherwise.
    func validatedThinkingSelection(
        _ rawValue: String,
        forModelID modelID: String?
    ) -> AgentThinkingSelection? {
        guard let model = model(matching: modelID),
              let requestedSelection = AgentThinkingSelection(rawValue: rawValue),
              let thinkingSelection = model.thinkingSelection(for: requestedSelection),
              thinkingSelection == requestedSelection else {
            return nil
        }
        return thinkingSelection
    }

    /// The thinking level `selection` becomes on the model `modelID` names:
    /// `selection` when the model offers it, otherwise the model's default.
    /// `nil` when the model is unknown or its thinking is not configurable.
    func thinkingSelection(
        _ selection: AgentThinkingSelection?,
        carriedTo modelID: String?
    ) -> AgentThinkingSelection? {
        model(matching: modelID)?.thinkingSelection(for: selection)
    }

    /// The thinking level a new session starts with: the requested level when
    /// the model offers it, else the agent's and the configured defaults
    /// (see ``AgentSettingsStore/thinkingSelection(requestedSelection:explicitModelID:agentModelID:agentThinkingSelection:manifest:)``),
    /// resolved against ``resolutionManifest(selectedModelID:)``.
    func resolvedThinkingSelection(
        requested requestedSelection: AgentThinkingSelection?,
        explicitModelID: String?,
        agentModelID: String?,
        agentThinkingSelection: AgentThinkingSelection?,
        selectedModelID: String?
    ) -> AgentThinkingSelection? {
        AgentSettingsStore.thinkingSelection(
            requestedSelection: requestedSelection,
            explicitModelID: explicitModelID,
            agentModelID: agentModelID,
            agentThinkingSelection: agentThinkingSelection,
            manifest: resolutionManifest(selectedModelID: selectedModelID)
        )
    }

    // MARK: - Persistence

    /// Saves `modelID` and `thinking` as the user's default model, when
    /// ``persistsSelections`` is `true`.
    func saveModelSelection(
        modelID: String,
        thinking: AgentThinkingSelection?
    ) throws {
        guard persistsSelections else {
            return
        }
        try AgentSettingsManifestStore.saveSelectedModel(
            modelID: modelID,
            thinkingSelection: thinking
        )
    }

    /// Saves `selection` as the user's default thinking level, when
    /// ``persistsSelections`` is `true`.
    func saveThinkingSelection(_ selection: AgentThinkingSelection?) throws {
        guard persistsSelections else {
            return
        }
        try AgentSettingsManifestStore.saveSelectedThinkingSelection(selection)
    }
}
