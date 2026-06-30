//
//  ZenCODESetupRunner+Types.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//
import Foundation
import ZenCODECore

struct SetupSectionOption {
    let section: SetupSection
    let detail: String?
}

enum SetupSectionCategory {
    case required
    case recommended
    case optional
    case finish
}

struct SetupSectionConfigurationResult {
    var manifest: AgentSettingsManifest?
    var additionalResult: ZenCODESetupAdditionalSectionResult = .unchanged
}

enum SetupSection: Equatable, Hashable {
    case providersAndModels
    case defaultModelSettings
    case defaultModel
    case defaultThinking
    case telegram
    case voice
    case features
    case agents
    case additionalGroup(Int, title: String, aliases: Set<String>)
    case finish
    case cancel

    var title: String {
        switch self {
        case .providersAndModels:
            return "Providers and models"
        case .defaultModelSettings:
            return "Default model & thinking"
        case .defaultModel:
            return "Default model"
        case .defaultThinking:
            return "Default thinking"
        case .telegram:
            return "Telegram remote control"
        case .voice:
            return "Local voice tools"
        case .features:
            return "Features"
        case .agents:
            return "Agents"
        case .additionalGroup(_, let title, _):
            return title
        case .finish:
            return "Finish setup"
        case .cancel:
            return "Cancel without saving"
        }
    }

    var category: SetupSectionCategory {
        switch self {
        case .providersAndModels:
            return .required
        case .defaultModelSettings, .agents:
            return .recommended
        case .telegram, .voice, .features, .additionalGroup:
            return .optional
        case .defaultModel, .defaultThinking:
            return .recommended
        case .finish, .cancel:
            return .finish
        }
    }

    var requiresConfiguredModels: Bool {
        switch self {
        case .providersAndModels, .agents, .features, .additionalGroup, .finish, .cancel:
            return false
        case .defaultModelSettings, .defaultModel, .defaultThinking, .telegram, .voice:
            return true
        }
    }

    var isAdditional: Bool {
        if case .additionalGroup = self {
            return true
        }
        return false
    }

    func matches(_ value: String) -> Bool {
        aliases.contains(value)
    }

    private var aliases: Set<String> {
        switch self {
        case .providersAndModels:
            return ["providers", "provider", "models", "model", "providers and models", "providers/models", "remote"]
        case .defaultModelSettings:
            return ["default", "default model", "selected model", "model default", "thinking", "default thinking"]
        case .defaultModel:
            return ["default", "default model", "selected model", "model default"]
        case .defaultThinking:
            return ["thinking", "default thinking", "reasoning", "thinking default"]
        case .telegram:
            return ["telegram", "remote control", "bot"]
        case .voice:
            return ["voice", "local voice", "voice tools", "speech"]
        case .features:
            return ["features", "feature", "tools", "swift features", "enable features", "disable features"]
        case .agents:
            return ["agents", "agent", "profiles", "agent profiles"]
        case .additionalGroup(_, _, let aliases):
            return aliases
        case .finish:
            return ["finish", "done", "exit", "quit", "end", "stop"]
        case .cancel:
            return ["cancel", "abort", "discard", "quit without saving"]
        }
    }
}

struct VoiceSetupOption {
    let value: String
    let title: String
    let detail: String?
    let aliases: [String]

    init(
        value: String,
        title: String,
        detail: String? = nil,
        aliases: [String] = []
    ) {
        self.value = value
        self.title = title
        self.detail = detail
        self.aliases = aliases
    }

    func matches(_ rawValue: String?) -> Bool {
        guard let value = rawValue?.nilIfBlank?.lowercased() else {
            return false
        }
        return self.value.lowercased() == value
            || title.lowercased() == value
            || aliases.contains { $0.lowercased() == value }
    }
}

struct SetupProviderInput {
    let id: UUID
    let name: String
    let baseURL: String
    let chatEndpoint: AgentRemoteChatEndpoint
    let apiKey: String?
    let models: [AgentSettingsModelManifest]
}

enum SetupProviderKind: Hashable {
    case remoteAPI
    case chatGPTSubscription
    case anthropicSubscription
}


enum ZenCODESetupError: LocalizedError {
    case nonInteractiveTerminal
    case cancelled
    case emptyRequiredValue(String)
    case invalidChoice(String)
    case noModelsConfigured
    case noRemoteModelsReturned
    case chatGPTSubscriptionUnsupported
    case anthropicSubscriptionUnsupported

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "Setup requires an interactive terminal."
        case .cancelled:
            return "Setup cancelled."
        case let .emptyRequiredValue(label):
            return "\(label) is required."
        case let .invalidChoice(value):
            return "Invalid setup choice: \(value)"
        case .noModelsConfigured:
            return "At least one provider model is required."
        case .noRemoteModelsReturned:
            return "The server did not return any models from /models."
        case .chatGPTSubscriptionUnsupported:
            return "ChatGPT Subscription setup is available on macOS."
        case .anthropicSubscriptionUnsupported:
            return "Claude Subscription setup is available on macOS."
        }
    }
}
