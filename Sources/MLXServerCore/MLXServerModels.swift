//
//  MLXServerModels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Foundation
import MLXLLM
import MLXLMCommon

public struct MLXServerModelDescriptor: Sendable {
    public var id: String
    public var displayName: String
    public var runtimeKind: MLXServerModelRuntimeKind
    public var configuration: ModelConfiguration
    public var generationDefaults: MLXServerModelGenerationDefaults
    public var thinking: MLXServerModelThinkingConfiguration

    public init(
        id: String,
        displayName: String,
        runtimeKind: MLXServerModelRuntimeKind = .llm,
        configuration: ModelConfiguration,
        generationDefaults: MLXServerModelGenerationDefaults = .init(),
        thinking: MLXServerModelThinkingConfiguration = .disabled
    ) {
        self.id = id
        self.displayName = displayName
        self.runtimeKind = runtimeKind
        self.configuration = configuration
        self.generationDefaults = generationDefaults
        self.thinking = thinking.validated()
    }
}

public struct MLXServerModelsManifest: Codable, Equatable, Sendable {
    public var defaultModelID: String?
    public var models: [MLXServerModelRecord]

    public init(
        defaultModelID: String? = nil,
        models: [MLXServerModelRecord] = []
    ) {
        self.defaultModelID = defaultModelID
        self.models = models
    }

    public func validated() throws -> Self {
        var seenIDs = Set<String>()
        let normalizedModels = try models.map { record in
            let normalized = try record.validated()
            guard seenIDs.insert(normalized.id).inserted else {
                throw MLXServerModelsManifestError.duplicateModel(normalized.id)
            }
            return normalized
        }

        let normalizedDefaultModelID = defaultModelID?.trimmedNonEmpty
        if let normalizedDefaultModelID,
           !normalizedModels.contains(where: { $0.id == normalizedDefaultModelID }) {
            throw MLXServerModelsManifestError.defaultModelNotFound(normalizedDefaultModelID)
        }

        return Self(
            defaultModelID: normalizedDefaultModelID ?? normalizedModels.first?.id,
            models: normalizedModels
        )
    }

    public var catalog: MLXServerModelCatalog {
        get throws {
            try MLXServerModelCatalog(manifest: validated())
        }
    }
}

public struct MLXServerModelRecord: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var repositoryID: String
    public var revision: String
    public var runtimeKind: MLXServerModelRuntimeKind
    public var enabled: Bool
    public var generationDefaults: MLXServerModelGenerationDefaults
    public var thinking: MLXServerModelThinkingConfiguration

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case repositoryID = "repository_id"
        case revision
        case runtimeKind = "runtime_kind"
        case enabled
        case generationDefaults = "generation_defaults"
        case thinking
    }

    public init(
        id: String,
        displayName: String,
        repositoryID: String,
        revision: String = "main",
        runtimeKind: MLXServerModelRuntimeKind = .llm,
        enabled: Bool = true,
        generationDefaults: MLXServerModelGenerationDefaults = .init(),
        thinking: MLXServerModelThinkingConfiguration = .disabled
    ) {
        self.id = id
        self.displayName = displayName
        self.repositoryID = repositoryID
        self.revision = revision
        self.runtimeKind = runtimeKind
        self.enabled = enabled
        self.generationDefaults = generationDefaults
        self.thinking = thinking.validated()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        repositoryID = try container.decode(String.self, forKey: .repositoryID)
        revision = try container.decodeIfPresent(String.self, forKey: .revision) ?? "main"
        runtimeKind = try container.decodeIfPresent(MLXServerModelRuntimeKind.self, forKey: .runtimeKind) ?? .llm
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        generationDefaults = try container.decodeIfPresent(
            MLXServerModelGenerationDefaults.self,
            forKey: .generationDefaults
        ) ?? .init()
        thinking = try container.decodeIfPresent(
            MLXServerModelThinkingConfiguration.self,
            forKey: .thinking
        ) ?? .disabled
    }

    public func validated() throws -> Self {
        guard let normalizedID = id.trimmedNonEmpty else {
            throw MLXServerModelsManifestError.emptyModelID
        }
        guard let normalizedRepositoryID = repositoryID.trimmedNonEmpty else {
            throw MLXServerModelsManifestError.emptyRepositoryID
        }
        let normalizedDisplayName = displayName.trimmedNonEmpty ?? normalizedID
        let normalizedRevision = revision.trimmedNonEmpty ?? "main"
        return Self(
            id: normalizedID,
            displayName: normalizedDisplayName,
            repositoryID: normalizedRepositoryID,
            revision: normalizedRevision,
            runtimeKind: runtimeKind,
            enabled: enabled,
            generationDefaults: generationDefaults.validated(),
            thinking: thinking.validated()
        )
    }

    public var descriptor: MLXServerModelDescriptor {
        MLXServerModelDescriptor(
            id: id,
            displayName: displayName,
            runtimeKind: runtimeKind,
            configuration: ModelConfiguration(
                id: repositoryID,
                revision: revision
            ),
            generationDefaults: generationDefaults,
            thinking: thinking
        )
    }
}

public enum MLXServerThinkingSelection: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case off
    case enabled
    case minimal
    case low
    case medium
    case high
    case xhigh

    public var isEnabled: Bool {
        self != .off
    }

    public var isEffortLevel: Bool {
        switch self {
        case .minimal, .low, .medium, .high, .xhigh:
            true
        case .off, .enabled:
            false
        }
    }

    public init?(protocolValue: String?) {
        guard let protocolValue else {
            return nil
        }
        let normalized = protocolValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "off", "none", "false", "disabled", "disable":
            self = .off
        case "on", "enabled", "enable", "true", "auto":
            self = .enabled
        case "minimal":
            self = .minimal
        case "low":
            self = .low
        case "medium":
            self = .medium
        case "high":
            self = .high
        case "xhigh", "max":
            self = .xhigh
        default:
            return nil
        }
    }
}

public struct MLXServerModelThinkingConfiguration: Codable, Equatable, Sendable {
    public var supportsThinking: Bool
    public var supportsReasoningEffort: Bool
    public var supportsPreserveThinking: Bool
    public var availableSelections: [MLXServerThinkingSelection]
    public var defaultSelection: MLXServerThinkingSelection

    private enum CodingKeys: String, CodingKey {
        case supportsThinking = "supports_thinking"
        case supportsReasoningEffort = "supports_reasoning_effort"
        case supportsPreserveThinking = "supports_preserve_thinking"
        case availableSelections = "available_selections"
        case defaultSelection = "default_selection"
    }

    public static let disabled = MLXServerModelThinkingConfiguration(
        supportsThinking: false,
        supportsReasoningEffort: false,
        supportsPreserveThinking: false,
        availableSelections: [.off],
        defaultSelection: .off
    )

    public static let generic = MLXServerModelThinkingConfiguration(
        supportsThinking: true,
        supportsReasoningEffort: false,
        supportsPreserveThinking: false,
        availableSelections: [.off, .enabled],
        defaultSelection: .enabled
    )

    public static func effort(
        levels: [MLXServerThinkingSelection] = [.minimal, .low, .medium, .high, .xhigh],
        supportsPreserveThinking: Bool = false
    ) -> MLXServerModelThinkingConfiguration {
        let normalizedLevels = normalizedEffortLevels(from: levels)
        let resolvedLevels = normalizedLevels.isEmpty
            ? [.minimal, .low, .medium, .high, .xhigh]
            : normalizedLevels
        return MLXServerModelThinkingConfiguration(
            supportsThinking: true,
            supportsReasoningEffort: true,
            supportsPreserveThinking: supportsPreserveThinking,
            availableSelections: [.off] + resolvedLevels,
            defaultSelection: resolvedLevels.contains(.medium) ? .medium : resolvedLevels[0]
        )
    }

    public init(
        supportsThinking: Bool,
        supportsReasoningEffort: Bool,
        supportsPreserveThinking: Bool,
        availableSelections: [MLXServerThinkingSelection],
        defaultSelection: MLXServerThinkingSelection
    ) {
        self.supportsThinking = supportsThinking
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsPreserveThinking = supportsPreserveThinking
        self.availableSelections = availableSelections
        self.defaultSelection = defaultSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let supportsThinking = try container.decodeIfPresent(Bool.self, forKey: .supportsThinking) ?? false
        let supportsReasoningEffort = try container.decodeIfPresent(
            Bool.self,
            forKey: .supportsReasoningEffort
        ) ?? false
        let supportsPreserveThinking = try container.decodeIfPresent(
            Bool.self,
            forKey: .supportsPreserveThinking
        ) ?? false
        let availableSelections = try container.decodeIfPresent(
            [MLXServerThinkingSelection].self,
            forKey: .availableSelections
        ) ?? []
        let defaultSelection = try container.decodeIfPresent(
            MLXServerThinkingSelection.self,
            forKey: .defaultSelection
        ) ?? .off

        self = Self(
            supportsThinking: supportsThinking,
            supportsReasoningEffort: supportsReasoningEffort,
            supportsPreserveThinking: supportsPreserveThinking,
            availableSelections: availableSelections,
            defaultSelection: defaultSelection
        ).validated()
    }

    public func validated() -> Self {
        guard supportsThinking else {
            return .disabled
        }

        if supportsReasoningEffort {
            let levels = Self.normalizedEffortLevels(from: availableSelections)
            let resolvedLevels = levels.isEmpty
                ? [.minimal, .low, .medium, .high, .xhigh]
                : levels
            let defaultEffort = defaultSelection.isEffortLevel && resolvedLevels.contains(defaultSelection)
                ? defaultSelection
                : (resolvedLevels.contains(.medium) ? .medium : resolvedLevels[0])
            return Self(
                supportsThinking: true,
                supportsReasoningEffort: true,
                supportsPreserveThinking: supportsPreserveThinking,
                availableSelections: [.off] + resolvedLevels,
                defaultSelection: defaultEffort
            )
        }

        return Self(
            supportsThinking: true,
            supportsReasoningEffort: false,
            supportsPreserveThinking: supportsPreserveThinking,
            availableSelections: [.off, .enabled],
            defaultSelection: .enabled
        )
    }

    public func selection(for protocolValue: String?) -> MLXServerThinkingSelection {
        let normalized = validated()
        guard normalized.supportsThinking,
              let requested = MLXServerThinkingSelection(protocolValue: protocolValue) else {
            return .off
        }

        if requested == .off {
            return .off
        }

        if normalized.availableSelections.contains(requested) {
            return requested
        }

        if requested.isEffortLevel,
           !normalized.supportsReasoningEffort,
           normalized.availableSelections.contains(.enabled) {
            return .enabled
        }

        return normalized.defaultSelection.isEnabled
            ? normalized.defaultSelection
            : (normalized.availableSelections.first(where: \.isEnabled) ?? .off)
    }

    public func defaultEnabledSelection() -> MLXServerThinkingSelection {
        let normalized = validated()
        guard normalized.supportsThinking else {
            return .off
        }
        return normalized.defaultSelection.isEnabled
            ? normalized.defaultSelection
            : (normalized.availableSelections.first(where: \.isEnabled) ?? .off)
    }

    public func additionalContext(
        for selection: MLXServerThinkingSelection
    ) -> [String: any Sendable] {
        var context: [String: any Sendable] = [
            "enable_thinking": selection.isEnabled,
            "preserve_thinking": supportsPreserveThinking && selection.isEnabled,
            "thinking_selection": selection.rawValue
        ]
        if selection.isEffortLevel {
            context["reasoning_effort"] = selection.rawValue
            context["thinking_level"] = selection.rawValue
        }
        return context
    }

    public static func normalizedEffortLevels(
        from selections: [MLXServerThinkingSelection]
    ) -> [MLXServerThinkingSelection] {
        let requestedLevels = Set(selections)
        return [.minimal, .low, .medium, .high, .xhigh].filter {
            requestedLevels.contains($0)
        }
    }
}

public struct MLXServerModelGenerationDefaults: Codable, Equatable, Sendable {
    public static let defaultPrefillStepSize = 4_096

    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var temperature: Float?
    public var topP: Float?
    public var topK: Int?
    public var repetitionPenalty: Float?
    public var presencePenalty: Float?
    public var frequencyPenalty: Float?
    public var prefillStepSize: Int?

    private enum CodingKeys: String, CodingKey {
        case contextWindow = "context_window"
        case maxOutputTokens = "max_output_tokens"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case repetitionPenalty = "repetition_penalty"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case prefillStepSize = "prefill_step_size"
    }

    public init(
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        topK: Int? = nil,
        repetitionPenalty: Float? = nil,
        presencePenalty: Float? = nil,
        frequencyPenalty: Float? = nil,
        prefillStepSize: Int? = nil
    ) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.prefillStepSize = prefillStepSize
    }

    public func validated() -> Self {
        Self(
            contextWindow: contextWindow.map { max(1, $0) },
            maxOutputTokens: maxOutputTokens.map { max(1, $0) },
            temperature: temperature.map { max(0, $0) },
            topP: topP.map { min(max($0, 0), 1) },
            topK: topK.map { max(0, $0) },
            repetitionPenalty: repetitionPenalty.map { max(0, $0) },
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            prefillStepSize: prefillStepSize.map { max(1, $0) }
        )
    }

    public func generateParameters(
        maxTokens: Int? = nil,
        kvCacheSettings: MLXServerKVCacheSettings = .init()
    ) -> GenerateParameters {
        var parameters = GenerateParameters(
            maxTokens: maxTokens ?? maxOutputTokens,
            temperature: temperature ?? 0.6,
            topP: topP ?? 1.0,
            topK: topK ?? 0,
            repetitionPenalty: Self.runtimeRepetitionPenalty(repetitionPenalty),
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            prefillStepSize: prefillStepSize ?? Self.defaultPrefillStepSize
        )
        kvCacheSettings.apply(to: &parameters)
        return parameters
    }

    private static func runtimeRepetitionPenalty(_ value: Float?) -> Float? {
        guard let value, value != 0, value != 1 else {
            return nil
        }
        return value
    }
}

public extension MLXServerKVCacheSettings {
    func apply(to parameters: inout GenerateParameters) {
        let settings = validated()
        guard settings.mode == .quantized else {
            return
        }
        parameters.kvBits = settings.quantizedBits
        parameters.kvGroupSize = settings.quantizedGroupSize
        parameters.quantizedKVStart = settings.quantizedStart
    }
}

public struct MLXServerModelCatalog: Sendable {
    public let defaultModelID: String
    public let models: [MLXServerModelDescriptor]

    public init(manifest: MLXServerModelsManifest) throws {
        let validated = try manifest.validated()
        let enabledModels = validated.models
            .filter(\.enabled)
            .map(\.descriptor)

        guard !enabledModels.isEmpty else {
            throw MLXServerModelsManifestError.noEnabledModels
        }

        let defaultModelID = validated.defaultModelID ?? enabledModels[0].id
        guard enabledModels.contains(where: { $0.id == defaultModelID }) else {
            throw MLXServerModelsManifestError.defaultModelNotFound(defaultModelID)
        }

        self.defaultModelID = defaultModelID
        self.models = enabledModels
    }

    public func resolve(id: String?) throws -> MLXServerModelDescriptor {
        let requestedID = id?.trimmedNonEmpty ?? defaultModelID
        guard let model = models.first(where: { $0.id == requestedID || $0.configuration.name == requestedID }) else {
            throw MLXServerModelsManifestError.modelNotConfigured(requestedID)
        }
        return model
    }
}


private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
