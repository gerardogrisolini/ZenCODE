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
}

/// Pure, terminal-free state machine for a setup run.
///
/// It owns the manifest as it evolves plus the two bookkeeping flags that decide
/// whether settings must be written. Keeping these transitions here (instead of
/// inline mutable locals in `run()`) makes the "when do we persist?" rule
/// testable without a real terminal and avoids silently dropping a
/// `didChangeSettings` update when a new section type is added.
struct SetupSession {
    private(set) var originalManifest: AgentSettingsManifest?
    private(set) var manifest: AgentSettingsManifest?
    private(set) var didChangeSettings = false

    /// The terminal outcome of a completed setup run.
    enum Outcome: Equatable {
        /// A usable manifest is present and should be finalized. When
        /// `settingsWillBeWritten` is false the existing settings.json is kept
        /// as-is (required files are still ensured).
        case write(manifest: AgentSettingsManifest, settingsWillBeWritten: Bool)
        /// No usable remote model is configured, so setup cannot complete.
        case noModels
    }

    init(originalManifest: AgentSettingsManifest?) {
        self.originalManifest = originalManifest
        self.manifest = originalManifest
    }

    /// Records the manifest produced by quick setup, which always counts as a
    /// settings change.
    mutating func applyQuickSetup(_ manifest: AgentSettingsManifest) {
        self.manifest = manifest
        didChangeSettings = true
    }

    /// Folds the result of a configured section into the session state. A
    /// changed manifest is persisted only after it contains at least one model.
    mutating func apply(_ result: SetupSectionConfigurationResult) {
        let previousManifest = manifest
        manifest = result.manifest
        if manifest != previousManifest {
            didChangeSettings = true
        }
    }

    /// Whether settings.json must be (re)written for the current manifest.
    var shouldWriteSettings: Bool {
        guard let manifest else {
            return false
        }
        return didChangeSettings
            || originalManifest == nil
            || manifest != originalManifest
    }

    var outcome: Outcome {
        guard let manifest, !manifest.models.isEmpty else {
            return .noModels
        }
        return .write(manifest: manifest, settingsWillBeWritten: shouldWriteSettings)
    }
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
    case agentModels
    case resetRemoteConfiguration
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
            return "Voice tools"
        case .features:
            return "Features"
        case .agents:
            return "Agents"
        case .agentModels:
            return "Agent model bindings"
        case .resetRemoteConfiguration:
            return "Reset remote configuration"
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
        case .defaultModelSettings, .agents, .agentModels:
            return .recommended
        case .telegram, .voice, .features, .resetRemoteConfiguration:
            return .optional
        case .defaultModel, .defaultThinking:
            return .recommended
        case .finish, .cancel:
            return .finish
        }
    }

    var requiresConfiguredModels: Bool {
        switch self {
        case .providersAndModels, .agents, .features, .resetRemoteConfiguration, .finish, .cancel:
            return false
        case .defaultModelSettings, .defaultModel, .defaultThinking, .telegram, .voice, .agentModels:
            return true
        }
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
            return ["voice", "voice tools", "speech"]
        case .features:
            return ["features", "feature", "tools", "swift features", "enable features", "disable features"]
        case .agents:
            return ["agents", "agent", "profiles", "agent profiles"]
        case .agentModels:
            return [
                "agent models",
                "agent model bindings",
                "agent bindings",
                "agent capability",
                "models",
                "capability",
                "agent models & capability"
            ]
        case .resetRemoteConfiguration:
            return ["reset", "reset remote configuration", "reset configuration"]
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
            return "Remote provider setup requires an interactive terminal."
        case .cancelled:
            return "Setup cancelled."
        case let .emptyRequiredValue(label):
            return "\(label) is required."
        case let .invalidChoice(value):
            return "Invalid setup choice: \(value)"
        case .noModelsConfigured:
            return "At least one remote provider model is required."
        case .noRemoteModelsReturned:
            return "The server did not return any models from /models."
        case .chatGPTSubscriptionUnsupported:
            return "ChatGPT Subscription setup is available on macOS."
        case .anthropicSubscriptionUnsupported:
            return "Claude Subscription setup is available on macOS."
        }
    }
}
