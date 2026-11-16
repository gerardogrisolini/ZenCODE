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
/// indistinguishable from a completed configuration at the call site.
/// `zen --setup` (`ZenCODESetupCommand`) uses this to open the setup again
/// after a reset or an imported backup, and otherwise to end with an exit
/// status that tells whether a usable configuration exists.
public enum SetupOutcome: Sendable, Equatable {
    /// Setup completed and support files were configured.
    case configured
    /// The operator cancelled before completing setup.
    case cancelled
    /// Remote configuration was reset to its defaults.
    case reset
    /// The support directory was replaced by an imported backup.
    case dataReplaced
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
    case providersAndModels
    case telegram, features, agents, agentModels, responseLanguage, memoryEmbedding
    case ds4Runtime
    case voiceMode
    case scheduledPrompts
    case dataManagement
    case finish, cancel

    private struct Descriptor {
        let title: String
        let category: SetupSectionCategory
        let requiresConfiguredModels: Bool
    }

    private static let descriptors: [SetupSection: Descriptor] = [
        .providersAndModels: .init(title: "Providers and models", category: .required, requiresConfiguredModels: false),
        .telegram: .init(title: "Telegram remote control", category: .optional, requiresConfiguredModels: true),
        .features: .init(title: "Features", category: .recommended, requiresConfiguredModels: false),
        .agents: .init(title: "Agents", category: .required, requiresConfiguredModels: false),
        .agentModels: .init(title: "Agent model bindings", category: .recommended, requiresConfiguredModels: true),
        .responseLanguage: .init(title: "Response language", category: .recommended, requiresConfiguredModels: false),
        .memoryEmbedding: .init(title: "Memory embeddings", category: .recommended, requiresConfiguredModels: false),
        .ds4Runtime: .init(title: "DS4 local runtime (in-process engine)", category: .optional, requiresConfiguredModels: false),
        .voiceMode: .init(title: "Voice mode", category: .optional, requiresConfiguredModels: false),
        .scheduledPrompts: .init(title: "Scheduled prompts (ZenCRON)", category: .optional, requiresConfiguredModels: false),
        .dataManagement: .init(title: "Data management", category: .optional, requiresConfiguredModels: false),
        .finish: .init(title: "Finish setup", category: .finish, requiresConfiguredModels: false),
        .cancel: .init(title: "Cancel without saving", category: .finish, requiresConfiguredModels: false)
    ]

    private var descriptor: Descriptor { Self.descriptors[self]! }
    var title: String { descriptor.title }
    var category: SetupSectionCategory { descriptor.category }
    var requiresConfiguredModels: Bool { descriptor.requiresConfiguredModels }

    /// Whether the section only stages its changes in the setup session, so
    /// that an error inside it discards all of them. Features and Scheduled
    /// prompts act as soon as an action is chosen (a feature installed or
    /// toggled, ZenCRON built and installed): an error there may come after
    /// some of those actions, which stay applied.
    var stagesSettings: Bool {
        switch self {
        case .features, .scheduledPrompts:
            return false
        case .providersAndModels, .telegram, .agents, .agentModels, .responseLanguage,
             .memoryEmbedding, .ds4Runtime, .voiceMode, .dataManagement, .finish, .cancel:
            return true
        }
    }
}

struct SetupProviderInput {
    /// Stable provider key (see `SetupProviderPreset.providerID`).
    let id: String
    let name: String
    let baseURL: String
    let chatEndpoint: AgentRemoteChatEndpoint
    let providerProfileID: AgentProviderProfileID
    let protocolProfileID: AgentProtocolProfileID
    let authPolicy: AgentProviderAuthPolicy
    let ds4Runtime: AgentDS4RuntimeConfiguration?
    let apiKey: String?
    let models: [AgentSettingsModelManifest]
    let chatGPTSubscriptionCredentials: CodexAgentCredentials?
    let anthropicSubscriptionCredentials: AnthropicSubscriptionCredentials?

    init(
        id: String,
        name: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        providerProfileID: AgentProviderProfileID? = nil,
        protocolProfileID: AgentProtocolProfileID? = nil,
        authPolicy: AgentProviderAuthPolicy? = nil,
        ds4Runtime: AgentDS4RuntimeConfiguration? = nil,
        apiKey: String?,
        models: [AgentSettingsModelManifest],
        chatGPTSubscriptionCredentials: CodexAgentCredentials? = nil,
        anthropicSubscriptionCredentials: AnthropicSubscriptionCredentials? = nil
    ) {
        self.id = AgentRemoteProvider.normalizedProviderID(id) ?? id
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
        self.ds4Runtime = ds4Runtime
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

    /// The stable key of the provider this choice configures. A provider is
    /// configured at most once, so a choice whose key is already configured
    /// must be reconfigured instead of added.
    var providerID: String {
        switch self {
        case let .remoteAPI(preset):
            return preset.providerID
        case .chatGPTSubscription:
            return AgentRemoteProvider.chatGPTSubscriptionProviderID
        case .anthropicSubscription:
            return AgentRemoteProvider.anthropicSubscriptionProviderID
        }
    }

    /// Menu detail of this choice in its family submenu, shown when the
    /// provider is not configured yet.
    var menuDetail: String {
        switch self {
        case .chatGPTSubscription, .anthropicSubscription:
            return "browser sign-in; separate credentials and provider key"
        case let .remoteAPI(preset):
            switch preset {
            case .openAIAPI:
                return "API key; OpenAI Responses protocol"
            case .anthropicAPI:
                return "API key; native Messages protocol"
            case .xaiAPI:
                return "API key; pay-as-you-go xAI API"
            case .kimi:
                return "pay-as-you-go API key from the Kimi platform"
            case .kimiCode:
                return "Kimi membership; API key from the Kimi Code console"
            case .zaiAPI:
                return "pay-as-you-go API key"
            case .zaiCodingPlan:
                return "Coding Plan subscription; plan API key"
            case .qwenAPI:
                return "pay-as-you-go API key; Singapore region"
            case .qwenTokenPlan:
                return "Token Plan subscription; plan API key (sk-sp-)"
            case .custom:
                return "advanced OpenAI-compatible setup; optional auth, fail-closed protocol selection"
            case .openRouter, .gemini, .deepSeek, .nvidiaAPI, .modal:
                return "hosted API preset; API key required"
            }
        }
    }
}

/// The first page of the provider menu, in display order: the providers that
/// offer a subscription or a coding plan, then "Other API providers" with the
/// API-only presets and Custom.
enum SetupProviderFamily: CaseIterable, Hashable {
    case openAI
    case anthropic
    case kimi
    case zAI
    case qwen
    case otherAPI

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .kimi: return "Kimi"
        case .zAI: return "Z.ai"
        case .qwen: return "Qwen"
        case .otherAPI: return "Other API providers"
        }
    }

    var detail: String {
        switch self {
        case .openAI: return "OpenAI API or ChatGPT Subscription"
        case .anthropic: return "Anthropic API status or Claude Subscription"
        case .kimi: return "Kimi API (Moonshot AI) or Kimi Code membership"
        case .zAI: return "Z.ai API or Z.ai Coding Plan"
        case .qwen: return "Qwen API (QwenCloud) or Qwen Token Plan"
        case .otherAPI: return "hosted presets and advanced Custom setup"
        }
    }

    /// Title of the family submenu.
    var submenuTitle: String {
        self == .otherAPI ? "API provider preset" : title
    }

    /// The provider choices of the family, in menu order.
    var kinds: [SetupProviderKind] {
        switch self {
        case .openAI:
            return [.remoteAPI(.openAIAPI), .chatGPTSubscription]
        case .anthropic:
            return [.remoteAPI(.anthropicAPI), .anthropicSubscription]
        case .kimi:
            return [.remoteAPI(.kimi), .remoteAPI(.kimiCode)]
        case .zAI:
            return [.remoteAPI(.zaiAPI), .remoteAPI(.zaiCodingPlan)]
        case .qwen:
            return [.remoteAPI(.qwenAPI), .remoteAPI(.qwenTokenPlan)]
        case .otherAPI:
            return SetupProviderPreset.allCases
                .filter { $0.family == .otherAPI }
                .map(SetupProviderKind.remoteAPI)
        }
    }
}

/// Hosted API defaults exposed by setup. Each preset configures exactly one
/// provider identified by its stable key (`providerID`); a provider that is
/// already configured cannot be added again and must be reconfigured.
enum SetupProviderPreset: String, CaseIterable, Hashable {
    case openRouter
    case openAIAPI
    case anthropicAPI
    case xaiAPI
    case kimi
    case kimiCode
    case zaiAPI
    case zaiCodingPlan
    case qwenAPI
    case qwenTokenPlan
    case gemini
    case deepSeek
    case nvidiaAPI
    case modal
    case custom

    var title: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAIAPI: return "OpenAI API"
        case .anthropicAPI: return "Anthropic API"
        case .xaiAPI: return "Grok API (xAI)"
        case .kimi: return "Kimi API (Moonshot AI)"
        case .kimiCode: return "Kimi Code"
        case .zaiAPI: return "Z.ai API"
        case .zaiCodingPlan: return "Z.ai Coding Plan"
        case .qwenAPI: return "Qwen API (QwenCloud)"
        case .qwenTokenPlan: return "Qwen Token Plan"
        case .gemini: return "Gemini"
        case .deepSeek: return "DeepSeek"
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
        case .xaiAPI: return "https://api.x.ai/v1"
        case .kimi: return "https://api.moonshot.ai/v1"
        case .kimiCode: return "https://api.kimi.ai/coding/v1"
        case .zaiAPI: return "https://api.z.ai/api/paas/v4"
        case .zaiCodingPlan: return "https://api.z.ai/api/coding/paas/v4"
        case .qwenAPI: return "https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1"
        case .qwenTokenPlan: return "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek: return "https://api.deepseek.com/v1"
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
        case .xaiAPI: return .xAI
        case .kimi, .kimiCode: return .moonshot
        case .zaiAPI, .zaiCodingPlan: return .zAI
        case .qwenAPI, .qwenTokenPlan: return .qwen
        case .gemini: return .googleGemini
        case .deepSeek: return .deepSeek
        case .nvidiaAPI: return .nvidia
        case .modal: return .modal
        case .custom: return .custom
        }
    }

    var protocolProfileID: AgentProtocolProfileID {
        switch self {
        case .openAIAPI: return .openAIResponses
        case .anthropicAPI: return .anthropicMessages
        case .kimiCode: return .kimiCode
        case .zaiCodingPlan: return .zaiCodingPlan
        case .qwenTokenPlan: return .qwenTokenPlan
        case .openRouter, .xaiAPI, .kimi, .zaiAPI, .qwenAPI, .gemini, .deepSeek, .nvidiaAPI,
             .modal, .custom:
            return .openAIChatCompletions
        }
    }

    var authPolicy: AgentProviderAuthPolicy {
        self == .custom ? .apiKeyOptional : .apiKeyRequired
    }

    /// Stable provider key, derived from the preset profiles through the single
    /// key table: `openrouter`, `openai`, `anthropic`, `xai`, `moonshot`,
    /// `kimi-code`, `zai`, `zai-coding-plan`, `qwen`, `qwen-token-plan`,
    /// `google.gemini`, `deepseek`, `nvidia`, `modal`, `custom`.
    var providerID: String {
        AgentRemoteProvider.providerKey(
            providerProfileID: providerProfileID,
            protocolProfileID: protocolProfileID
        )
    }

    /// The first-page family of the provider menu that lists this preset.
    var family: SetupProviderFamily {
        switch self {
        case .openAIAPI: return .openAI
        case .anthropicAPI: return .anthropic
        case .kimi, .kimiCode: return .kimi
        case .zaiAPI, .zaiCodingPlan: return .zAI
        case .qwenAPI, .qwenTokenPlan: return .qwen
        case .openRouter, .xaiAPI, .gemini, .deepSeek, .nvidiaAPI, .modal, .custom: return .otherAPI
        }
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
            return "zen --setup requires an interactive terminal."
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
