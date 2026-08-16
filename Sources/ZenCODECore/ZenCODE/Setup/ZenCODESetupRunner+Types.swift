//
//  ZenCODESetupRunner+Types.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import ToolCore

struct SetupSectionOption {
    let section: SetupSection
    let detail: String?
}

enum SetupSectionCategory {
    case required
    case recommended
    case optional
    case finish

    /// Display order of the menu groups. The main setup menu prints a group
    /// heading whenever the category changes between consecutive items, so the
    /// options must be laid out in this order to avoid repeating a heading.
    var displayOrder: Int {
        switch self {
        case .required:
            return 0
        case .recommended:
            return 1
        case .optional:
            return 2
        case .finish:
            return 3
        }
    }
}

struct SetupSectionConfigurationResult {
    var manifest: AgentSettingsManifest?
    var agentProfiles: [AgentProfile]?

    init(
        manifest: AgentSettingsManifest?,
        agentProfiles: [AgentProfile]? = nil
    ) {
        self.manifest = manifest
        self.agentProfiles = agentProfiles
    }
}

/// Read-only compare-and-swap baseline for the two manifests setup may replace.
/// Unlike the removed rollback snapshot, it is never written back: a mismatch at
/// finalization aborts before mutation instead of overwriting a concurrent edit.
struct SetupManifestBaseline: Sendable {
    let settingsData: Data?
    let agentsData: Data?

    static func capture(
        fileManager: FileManager = .default
    ) throws -> SetupManifestBaseline {
        try SensitiveManifestCoordination.withExclusiveLock(
            fileManager: fileManager
        ) {
            func dataIfPresent(at url: URL) throws -> Data? {
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            }
            return try SetupManifestBaseline(
                settingsData: dataIfPresent(
                    at: AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
                ),
                agentsData: dataIfPresent(
                    at: AgentProfileStore.agentsManifestURL(fileManager: fileManager)
                )
            )
        }
    }
}

/// The terminal result of a setup run, reported to the caller so it can decide
/// whether to proceed.
///
/// Previously `run()` returned `Void`, so a cancellation or a reset was
/// indistinguishable from a completed configuration at the call site. The CLI
/// uses this to start the interactive runner only when setup actually produced a
/// usable configuration.
public enum SetupOutcome: Sendable, Equatable {
    /// Setup completed and support files were configured.
    case configured
    /// The operator cancelled before completing setup.
    case cancelled
    /// Remote configuration was reset to its defaults.
    case reset
}

/// Pure, terminal-free state machine for a setup run.
///
/// It owns the settings manifest and agent profiles as they evolve plus the
/// bookkeeping flag that decides whether settings must be written. Keeping these
/// transitions here (instead of inline mutable locals in `run()`) makes the
/// "when do we persist?" rule testable, and keeps cancel/error paths free of
/// manifest writes or compensating rollbacks.
struct SetupSession {
    private(set) var originalManifest: AgentSettingsManifest?
    private(set) var manifest: AgentSettingsManifest?
    private(set) var didChangeSettings = false
    private(set) var agentProfiles: [AgentProfile]?

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
    mutating func applyQuickSetup(
        _ manifest: AgentSettingsManifest,
        agentProfiles: [AgentProfile]? = nil
    ) {
        self.manifest = manifest
        self.agentProfiles = agentProfiles
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
        if let agentProfiles = result.agentProfiles {
            self.agentProfiles = agentProfiles
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
    case providersAndModels, defaultModelSettings, defaultModel, defaultThinking
    case telegram, voice, features, agents, agentModels, responseLanguage, memoryEmbedding
    case resetRemoteConfiguration, finish, cancel

    private struct Descriptor {
        let title: String
        let category: SetupSectionCategory
        let requiresConfiguredModels: Bool
        let aliases: Set<String>
    }

    private static let descriptors: [SetupSection: Descriptor] = [
        .providersAndModels: .init(title: "Providers and models", category: .required, requiresConfiguredModels: false, aliases: ["providers", "provider", "models", "model", "providers and models", "providers/models", "remote"]),
        .defaultModelSettings: .init(title: "Default model & thinking", category: .recommended, requiresConfiguredModels: true, aliases: ["default", "default model", "selected model", "model default", "thinking", "default thinking"]),
        .defaultModel: .init(title: "Default model", category: .recommended, requiresConfiguredModels: true, aliases: ["default", "default model", "selected model", "model default"]),
        .defaultThinking: .init(title: "Default thinking", category: .recommended, requiresConfiguredModels: true, aliases: ["thinking", "default thinking", "reasoning", "thinking default"]),
        .telegram: .init(title: "Telegram remote control", category: .optional, requiresConfiguredModels: true, aliases: ["telegram", "remote control", "bot"]),
        .voice: .init(title: "Voice tools", category: .optional, requiresConfiguredModels: true, aliases: ["voice", "voice transcription", "voice messages", "speech"]),
        .features: .init(title: "Features", category: .optional, requiresConfiguredModels: false, aliases: ["features", "feature", "tools", "swift features", "enable features", "disable features"]),
        .agents: .init(title: "Agents", category: .recommended, requiresConfiguredModels: false, aliases: ["agents", "agent", "profiles", "agent profiles"]),
        .agentModels: .init(title: "Agent model bindings", category: .recommended, requiresConfiguredModels: true, aliases: ["agent models", "agent model bindings", "agent bindings", "agent capability", "models", "capability", "agent models & capability"]),
        .responseLanguage: .init(title: "Response language", category: .recommended, requiresConfiguredModels: false, aliases: ["language", "response language", "locale", "response_language"]),
        .memoryEmbedding: .init(title: "Memory embeddings", category: .optional, requiresConfiguredModels: false, aliases: ["memory embeddings", "memory embedding", "embeddings", "embedding", "bm25"]),
        .resetRemoteConfiguration: .init(title: "Reset remote configuration", category: .optional, requiresConfiguredModels: false, aliases: ["reset", "reset remote configuration", "reset configuration"]),
        .finish: .init(title: "Finish setup", category: .finish, requiresConfiguredModels: false, aliases: ["finish", "done", "exit", "quit", "end", "stop"]),
        .cancel: .init(title: "Cancel without saving", category: .finish, requiresConfiguredModels: false, aliases: ["cancel", "abort", "discard", "quit without saving"])
    ]

    private var descriptor: Descriptor { Self.descriptors[self]! }
    var title: String { descriptor.title }
    var category: SetupSectionCategory { descriptor.category }
    var requiresConfiguredModels: Bool { descriptor.requiresConfiguredModels }
    func matches(_ value: String) -> Bool { descriptor.aliases.contains(value) }
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
    let providerProfileID: AgentProviderProfileID
    let protocolProfileID: AgentProtocolProfileID
    let authPolicy: AgentProviderAuthPolicy
    let apiKey: String?
    let models: [AgentSettingsModelManifest]
    let chatGPTSubscriptionCredentials: CodexAgentCredentials?
    let anthropicSubscriptionCredentials: AnthropicSubscriptionCredentials?

    init(
        id: UUID,
        name: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        providerProfileID: AgentProviderProfileID? = nil,
        protocolProfileID: AgentProtocolProfileID? = nil,
        authPolicy: AgentProviderAuthPolicy? = nil,
        apiKey: String?,
        models: [AgentSettingsModelManifest],
        chatGPTSubscriptionCredentials: CodexAgentCredentials? = nil,
        anthropicSubscriptionCredentials: AnthropicSubscriptionCredentials? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint
        let legacyProfiles = AgentRemoteProvider.legacyProfiles(
            id: id,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint
        )
        self.providerProfileID = providerProfileID ?? legacyProfiles.provider
        self.protocolProfileID = protocolProfileID ?? legacyProfiles.protocolProfile
        self.authPolicy = authPolicy ?? legacyProfiles.auth
        self.apiKey = apiKey
        self.models = models
        self.chatGPTSubscriptionCredentials = chatGPTSubscriptionCredentials
        self.anthropicSubscriptionCredentials = anthropicSubscriptionCredentials
    }
}

enum SetupProviderKind: Hashable {
    case remoteAPI(SetupProviderPreset)
    case chatGPTSubscription
    case anthropicSubscription
}

enum SetupProviderFamily: Hashable {
    case openAI
    case anthropic
    case otherAPI
}

enum SetupAnthropicProviderOption: Hashable {
    case api
    case subscription
}

/// Hosted API defaults exposed by setup. These are intentionally configuration
/// presets, not provider identities: every configured provider still receives a
/// fresh UUID, its own key and its own model records.
enum SetupProviderPreset: String, CaseIterable, Hashable {
    case openRouter
    case openAIAPI
    case anthropicAPI
    case zaiAPI
    case zaiCodingPlan
    case gemini
    case deepSeek
    case kimi
    case nvidiaAPI
    case modal
    case custom

    var title: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAIAPI: return "OpenAI API"
        case .anthropicAPI: return "Anthropic API"
        case .zaiAPI: return "Z.ai API"
        case .zaiCodingPlan: return "Z.ai Coding Plan"
        case .gemini: return "Gemini"
        case .deepSeek: return "DeepSeek"
        case .kimi: return "Kimi API (Moonshot AI)"
        case .nvidiaAPI: return "NVIDIA API"
        case .modal: return "Modal"
        case .custom: return "Custom"
        }
    }

    var baseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAIAPI: return "https://api.openai.com/v1"
        case .anthropicAPI: return "https://api.anthropic.com/v1"
        case .zaiAPI: return "https://api.z.ai/api/paas/v4"
        case .zaiCodingPlan: return "https://api.z.ai/api/coding/paas/v4"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .kimi: return "https://api.moonshot.ai/v1"
        case .nvidiaAPI: return "https://integrate.api.nvidia.com/v1"
        case .modal: return "https://api.us-west-2.modal.direct/v1"
        case .custom: return AgentRemoteProvider.defaultOpenRouterBaseURL
        }
    }

    var providerProfileID: AgentProviderProfileID {
        switch self {
        case .openRouter: return .openRouter
        case .openAIAPI: return .openAI
        case .anthropicAPI: return .anthropic
        case .zaiAPI, .zaiCodingPlan: return .zAI
        case .gemini: return .googleGemini
        case .deepSeek: return .deepSeek
        case .kimi: return .moonshot
        case .nvidiaAPI: return .nvidia
        case .modal: return .modal
        case .custom: return .custom
        }
    }

    var protocolProfileID: AgentProtocolProfileID {
        switch self {
        case .openAIAPI: return .openAIResponses
        case .anthropicAPI: return .anthropicMessages
        case .zaiCodingPlan: return .zaiCodingPlan
        case .openRouter, .zaiAPI, .gemini, .deepSeek, .kimi, .nvidiaAPI, .modal, .custom:
            return .openAIChatCompletions
        }
    }

    var authPolicy: AgentProviderAuthPolicy {
        self == .custom ? .apiKeyOptional : .apiKeyRequired
    }

    var isAdvanced: Bool { self == .custom }
}


enum ZenCODESetupError: LocalizedError {
    case nonInteractiveTerminal
    case cancelled
    case emptyRequiredValue(String)
    case invalidChoice(String)
    case noModelsConfigured
    case noRemoteModelsReturned
    case invalidMemoryEmbeddingEndpoint

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
        case .invalidMemoryEmbeddingEndpoint:
            return "Memory embedding endpoint must be a non-empty absolute http:// or https:// URL without embedded credentials."
        }
    }
}
