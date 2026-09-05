//
//  ZenCODESetupRunner+RemoteModelManifest.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension ZenCODESetupRunner {
    static func remoteModelManifest(
        from model: OpenRouterModelInfo,
        providerID: UUID,
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
            configuredContextWindowLimit: model.contextLength,
            generationParameterOverrides: model.generationParameterOverrides,
            thinkingSupport: model.thinkingSupport
        )
    }

    static func subscriptionModelManifest(
        candidate: SubscriptionModelCandidate,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> AgentSettingsModelManifest {
        return AgentSettingsModelManifestFactory.remoteAPIModel(
            manifestID: candidate.manifestID,
            title: candidate.title,
            modelID: candidate.modelID,
            providerID: providerID,
            providerName: providerName,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            configuredContextWindowLimit: candidate.contextWindowTokenLimit,
            generationParameterOverrides: nil,
            thinkingSupport: candidate.thinkingSupport
        )
    }

    static func readModelMetadata(
        for model: AgentSettingsModelManifest
    ) throws -> AgentSettingsModelManifest {
        AgentOutput.standardError.writeString("\nModel metadata for \(model.displayTitle)\n")
        let configuredContextWindowLimit = try promptOptionalContextWindow(
            forModel: model.modelID,
            defaultValue: model.configuredContextWindowLimit
        )
        let thinkingConfiguration = try promptThinkingSupport(
            forModel: model.modelID,
            existingOptions: model.thinkingOptions,
            existingDefaultSelection: model.defaultThinkingSelection
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
        providerID: UUID,
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
        let thinkingConfiguration = try promptThinkingSupport(forModel: modelID)
        let manifestID = "remoteapi:\(providerID.uuidString.lowercased()):\(modelID)"
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
        existingDefaultSelection: AgentThinkingSelection? = nil
    ) throws -> (options: [AgentThinkingSelection]?, defaultSelection: AgentThinkingSelection?) {
        guard try promptYesNo(
            "This model supports thinking?",
            defaultValue: existingOptions?.isEmpty == false
        ) else {
            return (nil, nil)
        }

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
            existingOptions: existingOptions
        )

        while true {
            let selectedIndexes = try promptMenuSelection(
                title: "Select supported thinking levels for \(modelID)",
                items: menuItems,
                selected: defaultMenuSelection
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
                existingDefaultSelection: existingDefaultSelection,
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

    static func promptProviderKind() throws -> SetupProviderKind {
        let family = try promptMenuChoice(
            title: "Provider family",
            items: [
                TerminalCheckboxMenuItem(
                    value: SetupProviderFamily.openAI,
                    title: "OpenAI",
                    detail: "OpenAI API or ChatGPT Subscription"
                ),
                TerminalCheckboxMenuItem(
                    value: SetupProviderFamily.anthropic,
                    title: "Anthropic",
                    detail: "Anthropic API status or Claude Subscription"
                ),
                TerminalCheckboxMenuItem(
                    value: SetupProviderFamily.otherAPI,
                    title: "Other API providers",
                    detail: "hosted presets and advanced Custom setup"
                )
            ],
            selected: .openAI
        )

        switch family {
        case .openAI:
            return try promptMenuChoice(
                title: "OpenAI",
                items: [
                    TerminalCheckboxMenuItem(
                        value: SetupProviderKind.remoteAPI(.openAIAPI),
                        title: SetupProviderPreset.openAIAPI.title,
                        detail: "API key; OpenAI Responses protocol"
                    ),
                    TerminalCheckboxMenuItem(
                        value: SetupProviderKind.chatGPTSubscription,
                        title: "ChatGPT Subscription",
                        detail: "browser sign-in; separate credentials and provider UUID"
                    )
                ],
                selected: .remoteAPI(.openAIAPI)
            )
        case .anthropic:
            let option = try promptMenuChoice(
                title: "Anthropic",
                items: [
                    TerminalCheckboxMenuItem(
                        value: SetupAnthropicProviderOption.api,
                        title: "Anthropic API",
                        detail: "API key; native Messages protocol"
                    ),
                    TerminalCheckboxMenuItem(
                        value: SetupAnthropicProviderOption.subscription,
                        title: "Claude Subscription",
                        detail: "browser sign-in; separate credentials and provider UUID"
                    )
                ],
                selected: .api
            )
            return option == .api ? .remoteAPI(.anthropicAPI) : .anthropicSubscription
        case .otherAPI:
            let presets = SetupProviderPreset.allCases.filter {
                $0 != .openAIAPI && $0 != .anthropicAPI
            }
            let items = presets.map { preset in
                TerminalCheckboxMenuItem(
                    value: preset,
                    title: preset.title,
                    detail: preset.isAdvanced
                        ? "advanced OpenAI-compatible setup; optional auth, fail-closed protocol selection"
                        : "hosted API preset; API key required"
                )
            }
            let preset = try promptMenuChoice(
                title: "API provider preset",
                items: items,
                selected: .openRouter
            )
            return .remoteAPI(preset)
        }
    }


}
