//
//  ZenCODESetupRunner+RemoteModelManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension ZenCODESetupRunner {
    static func remoteModelManifest(
        from model: OpenRouterModelInfo,
        providerID: String,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> AgentSettingsModelManifest {
        AgentSettingsModelManifestFactory.remoteAPIModel(
            title: model.name == model.id ? nil : model.name,
            modelID: model.id,
            providerID: providerID,
            providerName: providerName,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            configuredContextWindowLimit: model.contextLength.map {
                kimiCodeContextWindowLimit($0, providerID: providerID)
            },
            generationParameterOverrides: model.generationParameterOverrides,
            thinkingSupport: directDeepSeekThinkingSupport(modelID: model.id, baseURL: baseURL)
                ?? model.thinkingSupport
        )
    }

    /// The `/models` catalog of Kimi Code advertises the full 1M context of
    /// `k3.1-pro`, but a standard Kimi Code plan rejects requests above 256K
    /// with an HTTP 400 before the model can reply. Newly configured Kimi Code
    /// models therefore start at 256K; the setup metadata prompt can raise the
    /// limit for plans that support 1M. Every other provider keeps the
    /// advertised context window unchanged.
    static func kimiCodeContextWindowLimit(
        _ contextLength: Int,
        providerID: String
    ) -> Int {
        guard AgentRemoteProvider.normalizedProviderID(providerID)
            == AgentRemoteProvider.kimiCodeProviderID else {
            return contextLength
        }
        return min(contextLength, 256_000)
    }

    /// Capability metadata only: /models remains authoritative for discovery.
    /// Match documented direct-API IDs, never vendor suffixes or future models.
    static func directDeepSeekThinkingSupport(
        modelID: String,
        baseURL: String
    ) -> ModelThinkingSupport? {
        guard AgentRemoteProvider.isDeepSeekBaseURL(baseURL) else { return nil }
        switch modelID {
        case "deepseek-flash", "deepseek-v4-pro",
             "deepseek-v4-flash", "deepseek-v4-flash-vision-exp":
            // https://api-docs.deepseek.com/guides/thinking_mode/
            return .effort(levels: [.low, .high, .max], defaultSelection: .high)
        default:
            return nil
        }
    }

    static func subscriptionModelManifest(
        candidate: SubscriptionModelCandidate,
        providerID: String,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> AgentSettingsModelManifest {
        let manifest = AgentSettingsModelManifestFactory.remoteAPIModel(
            manifestID: candidate.manifestID,
            title: candidate.title,
            modelID: candidate.modelID,
            providerID: providerID,
            providerName: providerName,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            configuredContextWindowLimit: candidate.contextWindowTokenLimit,
            generationParameterOverrides: AgentGenerationParameterOverrides(
                maxTokens: candidate.maxOutputTokens,
                subscriptionThinkingMode: candidate.anthropicThinkingMode,
                subscriptionReasoningLevels: candidate.subscriptionReasoningLevels
            ).nilIfEmpty,
            thinkingSupport: candidate.thinkingSupport
        )
        guard candidate.isDiscovered, candidate.thinkingSupport?.supportsThinking != true else { return manifest }
        return modelWithMetadata(manifest,
            configuredContextWindowLimit: candidate.contextWindowTokenLimit,
            thinkingOptions: [.off], defaultThinkingSelection: .off)
    }

    static func readModelMetadata(
        for model: AgentSettingsModelManifest,
        promptContextWindow: (String, Int?) throws -> Int? = {
            try promptOptionalContextWindow(forModel: $0, defaultValue: $1)
        },
        confirmThinkingSupport: (Bool) throws -> Bool = {
            try promptYesNo("This model supports thinking?", defaultValue: $0)
        },
        selectThinkingLevels: (String, [TerminalCheckboxMenuItem<Int>], Set<Int>) throws -> Set<Int> = {
            try promptMenuSelection(title: $0, items: $1, selected: $2)
        }
    ) throws -> AgentSettingsModelManifest {
        AgentOutput.standardError.writeString("\nModel metadata for \(model.displayTitle)\n")
        let configuredContextWindowLimit = try promptContextWindow(
            model.modelID, model.configuredContextWindowLimit
        )
        let thinkingConfiguration = try promptThinkingSupport(
            forModel: model.modelID,
            existingOptions: model.thinkingOptions,
            existingDefaultSelection: model.defaultThinkingSelection,
            fallbackSupport: model.provider.flatMap {
                directDeepSeekThinkingSupport(modelID: model.modelID, baseURL: $0.baseURL)
            },
            confirmSupport: confirmThinkingSupport,
            selectLevels: selectThinkingLevels
        )
        return modelWithMetadata(
            model,
            configuredContextWindowLimit: configuredContextWindowLimit,
            thinkingOptions: thinkingConfiguration.options,
            defaultThinkingSelection: thinkingConfiguration.defaultSelection
        )
    }

    static func modelWithMetadata(
        _ model: AgentSettingsModelManifest,
        configuredContextWindowLimit: Int?,
        thinkingOptions: [AgentThinkingSelection]?,
        defaultThinkingSelection: AgentThinkingSelection?
    ) -> AgentSettingsModelManifest {
        AgentSettingsModelManifest(
            id: model.id,
            kind: model.kind,
            title: model.title,
            llmID: model.llmID,
            modelID: model.modelID,
            providerID: model.providerID,
            provider: model.provider,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: model.generationParameterOverrides,
            apiKey: model.apiKey,
            thinkingOptions: thinkingOptions,
            defaultThinkingSelection: defaultThinkingSelection
        )
    }

    static func remoteModelListTitle(
        _ model: OpenRouterModelInfo
    ) -> String {
        var details: [String] = []
        if let contextLength = model.contextLength {
            details.append("ctx \(contextLength)")
        }
        if model.thinkingSupport?.supportsThinking == true {
            details.append("thinking")
        }
        if model.generationParameterOverrides != nil {
            details.append("params")
        }
        if let status = remoteModelStatus(model) {
            details.append(status)
        }

        let suffix = details.isEmpty ? "" : " [\(details.joined(separator: ", "))]"
        return "\(model.name) (\(model.id))\(suffix)"
    }

    static func remoteModelStatus(
        _ model: OpenRouterModelInfo
    ) -> String? {
        if model.serverLoaded == true || model.loaded == true {
            return "loaded"
        }
        if model.installed == true {
            return "installed"
        }
        if model.installed == false {
            return "non installato"
        }
        return nil
    }

    static func remoteModelSort(
        lhs: OpenRouterModelInfo,
        rhs: OpenRouterModelInfo
    ) -> Bool {
        let lhsRank = remoteModelRank(lhs)
        let rhsRank = remoteModelRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }

    static func remoteModelRank(
        _ model: OpenRouterModelInfo
    ) -> Int {
        if model.serverLoaded == true || model.loaded == true {
            return 0
        }
        if model.installed == true {
            return 1
        }
        if model.installed == false {
            return 3
        }
        return 2
    }

    static func readModel(
        providerID: String,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        modelIndex: Int
    ) throws -> AgentSettingsModelManifest {
        AgentOutput.standardError.writeString("\nModel\n")
        let defaultModelID = modelIndex == 0 ? AgentRemoteProvider.defaultOpenRouterModelID : nil
        let modelID = try promptString(
            "Model ID",
            defaultValue: defaultModelID,
            allowEmpty: false
        )
        let provider = AgentRemoteProvider(
            id: providerID,
            name: providerName,
            baseURL: baseURL,
            modelID: modelID,
            chatEndpoint: chatEndpoint
        )

        let configuredContextWindowLimit = try promptOptionalContextWindow(forModel: modelID)
        let knownThinkingSupport = directDeepSeekThinkingSupport(modelID: modelID, baseURL: baseURL)
        let thinkingConfiguration = try promptThinkingSupport(
            forModel: modelID,
            existingOptions: AgentSettingsModelManifestFactory.agentThinkingOptions(from: knownThinkingSupport),
            existingDefaultSelection: knownThinkingSupport?.defaultSelection
        )
        let manifestID = AgentRemoteProvider.modelManifestID(providerID: providerID, modelID: modelID)
        return AgentSettingsModelManifest(
            id: manifestID,
            kind: .remoteAPI,
            title: nil,
            llmID: manifestID,
            modelID: modelID,
            providerID: providerID,
            provider: provider,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: nil,
            thinkingOptions: thinkingConfiguration.options,
            defaultThinkingSelection: thinkingConfiguration.defaultSelection
        )
    }

    static func promptOptionalContextWindow(
        forModel modelID: String,
        defaultValue: Int? = nil
    ) throws -> Int? {
        while true {
            let help = defaultValue.map {
                "Enter a positive integer (for example 131072), or press return to keep \($0)."
            } ?? "Enter a positive integer (for example 131072), or leave blank to skip."
            let prompt = try promptString(
                "Context window tokens (optional for \(modelID))",
                defaultValue: defaultValue.map { String($0) },
                allowEmpty: true,
                help: help
            )
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmedNonEmpty = trimmed.nilIfBlank else {
                return nil
            }
            guard let value = Int(trimmedNonEmpty), value > 0 else {
                AgentOutput.standardError.writeString("Context window must be a positive integer.\n")
                continue
            }
            return value
        }
    }

    static func promptThinkingSupport(
        forModel modelID: String,
        existingOptions: [AgentThinkingSelection]? = nil,
        existingDefaultSelection: AgentThinkingSelection? = nil,
        fallbackSupport: ModelThinkingSupport? = nil,
        confirmSupport: (Bool) throws -> Bool = {
            try promptYesNo("This model supports thinking?", defaultValue: $0)
        },
        selectLevels: (String, [TerminalCheckboxMenuItem<Int>], Set<Int>) throws -> Set<Int> = {
            try promptMenuSelection(title: $0, items: $1, selected: $2)
        }
    ) throws -> (options: [AgentThinkingSelection]?, defaultSelection: AgentThinkingSelection?) {
        guard try confirmSupport(existingOptions?.isEmpty == false) else {
            return (nil, nil)
        }

        // Saved absence also represents an earlier opt-out: never use provider
        // capabilities to change the support confirmation's default.
        let useFallback = existingOptions?.isEmpty != false
        let suggestedOptions = useFallback
            ? AgentSettingsModelManifestFactory.agentThinkingOptions(from: fallbackSupport)
            : existingOptions
        let suggestedDefault = existingDefaultSelection ?? (useFallback
            ? fallbackSupport?.defaultSelection
            : nil)

        let availableOptions = AgentThinkingSelection.allCases
        let menuItems = availableOptions.enumerated().map { index, option in
            TerminalCheckboxMenuItem(
                value: index,
                title: option.menuTitle,
                detail: option.rawValue
            )
        }
        let defaultMenuSelection = thinkingSupportDefaultMenuSelection(
            availableOptions: availableOptions,
            existingOptions: suggestedOptions
        )

        while true {
            let selectedIndexes = try selectLevels(
                "Select supported thinking levels for \(modelID)",
                menuItems,
                defaultMenuSelection
            )
            let selectedOptions = selectedIndexes
                .sorted()
                .compactMap { index in
                    availableOptions.indices.contains(index) ? availableOptions[index] : nil
                }

            guard !selectedOptions.isEmpty else {
                AgentOutput.standardError.writeString(
                    "Select at least one thinking level or disable thinking support.\n"
                )
                continue
            }

            let defaultSelection = defaultThinkingSelection(
                existingDefaultSelection: suggestedDefault,
                selectedOptions: selectedOptions
            )
            return (selectedOptions, defaultSelection)
        }
    }

    static func thinkingSupportDefaultMenuSelection(
        availableOptions: [AgentThinkingSelection] = AgentThinkingSelection.allCases,
        existingOptions: [AgentThinkingSelection]?
    ) -> Set<Int> {
        if let existingOptions,
           !existingOptions.isEmpty {
            return Set(
                existingOptions.compactMap { existingOption in
                    availableOptions.firstIndex(of: existingOption)
                }
            )
        }

        return Set(
            availableOptions.enumerated().compactMap { index, option in
                if option == .off || option == .low || option == .medium || option == .high {
                    index
                } else {
                    nil
                }
            }
        )
    }

    static func defaultThinkingSelection(
        existingDefaultSelection: AgentThinkingSelection?,
        selectedOptions: [AgentThinkingSelection]
    ) -> AgentThinkingSelection? {
        if let existingDefaultSelection,
           selectedOptions.contains(existingDefaultSelection) {
            return existingDefaultSelection
        }
        if selectedOptions.contains(.medium) {
            return .medium
        }
        return selectedOptions.first { $0 != .off } ?? selectedOptions.first
    }

    static func promptEndpoint(
        defaultValue: AgentRemoteChatEndpoint = .chatCompletions
    ) throws -> AgentRemoteChatEndpoint {
        let defaultChoice: Int
        switch defaultValue {
        case .chatCompletions:
            defaultChoice = 0
        case .responses:
            defaultChoice = 1
        @unknown default:
            defaultChoice = 0
        }
        let choice = try promptMenuChoice(
            title: "Endpoint",
            items: [
                TerminalCheckboxMenuItem(
                    value: 0,
                    title: "chat/completions",
                    detail: "best for OpenAI-compatible APIs, OpenRouter, and local servers"
                ),
                TerminalCheckboxMenuItem(
                    value: 1,
                    title: "responses",
                    detail: "best for OpenAI Responses-compatible providers"
                )
            ],
            selected: defaultChoice
        )
        return choice == 0 ? .chatCompletions : .responses
    }

    /// Items of "Provider family": one per `SetupProviderFamily`, in display
    /// order. Every family opens a submenu, which marks the configured choices.
    static func providerFamilyMenuItems() -> [TerminalCheckboxMenuItem<SetupProviderFamily>] {
        SetupProviderFamily.allCases.map { family in
            TerminalCheckboxMenuItem(
                value: family,
                title: family.title,
                detail: family.detail
            )
        }
    }

    /// Items of the submenu of `family`: one per provider choice, in family
    /// order. A choice whose provider key is in `configuredProviderIDs` stays
    /// visible with `alreadyConfiguredProviderDetail`.
    static func providerKindMenuItems(
        for family: SetupProviderFamily,
        configuredProviderIDs: Set<String>
    ) -> [TerminalCheckboxMenuItem<SetupProviderKind>] {
        family.kinds.map { kind in
            TerminalCheckboxMenuItem(
                value: kind,
                title: providerKindTitle(kind),
                detail: configuredProviderIDs.contains(kind.providerID)
                    ? alreadyConfiguredProviderDetail
                    : kind.menuDetail
            )
        }
    }

    /// The preselected choice of the submenu of `family`: the first one that
    /// is not configured yet, otherwise the first one.
    static func preferredProviderKind(
        in family: SetupProviderFamily,
        configuredProviderIDs: Set<String>
    ) -> SetupProviderKind {
        let kinds = family.kinds
        return kinds.first { !configuredProviderIDs.contains($0.providerID) } ?? kinds[0]
    }

    /// Asks for the kind of provider to add. "Provider family" lists every
    /// `SetupProviderFamily` (see `providerFamilyMenuItems`); each family
    /// opens a submenu titled after the family ("API provider preset" for
    /// Other API providers, see `providerKindMenuItems`). Choices whose
    /// provider key is in `configuredProviderIDs` stay visible but are marked
    /// as already configured; the caller refuses them (see `readProvider`).
    ///
    /// Esc on a family submenu returns to "Provider family"; Esc there throws
    /// `ZenCODESetupError.cancelled`. `selectFamily` and `promptKind` (the
    /// submenu of a family) replace the menus in tests.
    static func promptProviderKind(
        configuredProviderIDs: Set<String> = [],
        selectFamily: (
            String,
            [TerminalCheckboxMenuItem<SetupProviderFamily>],
            SetupProviderFamily
        ) -> SetupProviderFamily? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        },
        promptKind promptKindInFamily: ((SetupProviderFamily) throws -> SetupProviderKind)? = nil
    ) throws -> SetupProviderKind {
        func promptFamily() throws -> SetupProviderFamily {
            let selected = selectFamily(
                "Provider family",
                providerFamilyMenuItems(),
                .openAI
            )
            guard let selected else {
                throw ZenCODESetupError.cancelled
            }
            return selected
        }

        func promptKind(in family: SetupProviderFamily) throws -> SetupProviderKind {
            if let promptKindInFamily {
                return try promptKindInFamily(family)
            }
            return try promptMenuChoice(
                title: family.submenuTitle,
                items: providerKindMenuItems(
                    for: family,
                    configuredProviderIDs: configuredProviderIDs
                ),
                selected: preferredProviderKind(
                    in: family,
                    configuredProviderIDs: configuredProviderIDs
                )
            )
        }

        // Esc on a family submenu comes back here, never to the submenu
        // itself, so a closed input still reaches the Esc of this menu.
        while true {
            let family = try promptFamily()
            let kind = try returningToMenuOnCancel(nil) { () throws -> SetupProviderKind in
                try promptKind(in: family)
            }
            if let kind {
                return kind
            }
        }
    }


}
