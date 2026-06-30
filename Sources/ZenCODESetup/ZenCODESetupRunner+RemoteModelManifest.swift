//
//  ZenCODESetupRunner+RemoteModelManifest.swift
//  ZenCODE
//

import Foundation
import ZenCODECore

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

    static func chatGPTSubscriptionModelManifest(
        option: CodexAgentModel.ModelOption,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> AgentSettingsModelManifest {
        let manifestID = CodexAgentModel.selectionID(forModelID: option.modelID)
        return AgentSettingsModelManifestFactory.remoteAPIModel(
            manifestID: manifestID,
            title: option.title,
            modelID: option.modelID,
            providerID: providerID,
            providerName: providerName,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            configuredContextWindowLimit: option.contextWindowTokenLimit,
            generationParameterOverrides: nil,
            thinkingSupport: CodexAgentModel.thinkingSupport
        )
    }

    static func anthropicSubscriptionModelManifest(
        option: AnthropicSubscriptionModel.ModelOption,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> AgentSettingsModelManifest {
        let manifestID = AnthropicSubscriptionModel.selectionID(forModelID: option.modelID)
        return AgentSettingsModelManifestFactory.remoteAPIModel(
            manifestID: manifestID,
            title: option.title,
            modelID: option.modelID,
            providerID: providerID,
            providerName: providerName,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            configuredContextWindowLimit: option.contextWindowTokenLimit,
            generationParameterOverrides: nil,
            thinkingSupport: option.thinkingSupport
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
        let manifestID = "remoteapi:\(providerID.uuidString.lowercased()):\(modelID)"
        return AgentSettingsModelManifest(
            id: manifestID,
            kind: .remoteAPI,
            title: nil,
            llmID: manifestID,
            modelID: modelID,
            providerID: providerID,
            provider: provider,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingOptions: nil,
            defaultThinkingSelection: nil
        )
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
        try promptMenuChoice(
            title: "Provider",
            items: [
                TerminalCheckboxMenuItem(
                    value: .remoteAPI,
                    title: "OpenAI-compatible",
                    detail: "OpenRouter, local servers, or any /v1 compatible provider"
                ),
                TerminalCheckboxMenuItem(
                    value: .chatGPTSubscription,
                    title: "ChatGPT Subscription",
                    detail: "sign in through the browser"
                ),
                TerminalCheckboxMenuItem(
                    value: .anthropicSubscription,
                    title: "Claude Subscription",
                    detail: "sign in through the browser"
                )
            ],
            selected: .remoteAPI
        )
    }


}
