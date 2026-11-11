//
//  AnthropicModelCapabilities.swift
//  ZenCODE
//

import Foundation

/// Thinking and input capabilities advertised by an Anthropic `/v1/models`
/// entry (`capabilities`). Shared by the subscription catalog and by the
/// API-key provider setup so both persist the same wire thinking mode.
/// Setup-time only: nothing here changes the generation runtime.
struct AnthropicModelCapabilities: Equatable, Sendable {
    /// Effort levels in ascending order, as named by `capabilities.effort`.
    static let effortLevelNames = ["low", "medium", "high", "xhigh", "max"]

    /// Wire thinking mode: `adaptive`, `enabled` or `disabled`. Persisted as
    /// `AgentGenerationParameterOverrides.subscriptionThinkingMode`.
    let thinkingMode: String
    /// Supported effort levels. Empty unless the model exposes adaptive effort.
    let effortLevels: [String]
    /// `capabilities.thinking.types.disabled.supported`. Several adaptive
    /// models reject `thinking: {type: "disabled"}` with HTTP 400, so "off" is
    /// offered only when the catalog confirms it.
    let supportsDisabledThinking: Bool
    let supportsImageInput: Bool
    let supportsPDFInput: Bool

    init(entry: [String: Any]) {
        let capabilities = entry["capabilities"] as? [String: Any] ?? [:]
        let thinking = capabilities["thinking"] as? [String: Any] ?? [:]
        let types = thinking["types"] as? [String: Any] ?? [:]
        let effort = capabilities["effort"] as? [String: Any] ?? [:]
        var mode = "disabled"
        var levels: [String] = []
        if thinking["supported"] as? Bool == true {
            if Self.supported(types["adaptive"]), effort["supported"] as? Bool == true {
                levels = Self.effortLevelNames.filter { Self.supported(effort[$0]) }
                if !levels.isEmpty { mode = "adaptive" }
            } else if Self.supported(types["enabled"]) {
                mode = "enabled"
            }
        }
        thinkingMode = mode
        effortLevels = levels
        supportsDisabledThinking = Self.supported(types["disabled"])
        supportsImageInput = Self.supported(capabilities["image_input"])
        supportsPDFInput = Self.supported(capabilities["pdf_input"])
    }

    var thinkingSupport: ModelThinkingSupport? {
        Self.thinkingSupport(
            mode: thinkingMode,
            effortLevels: effortLevels,
            supportsDisabledThinking: supportsDisabledThinking
        )
    }

    /// `enabled` is the generic manual toggle; `adaptive` offers the catalog's
    /// effort levels (plus "off" only when the model accepts disabled thinking)
    /// and defaults to the first level; anything else carries no thinking.
    static func thinkingSupport(
        mode: String,
        effortLevels: [String],
        supportsDisabledThinking: Bool
    ) -> ModelThinkingSupport? {
        switch mode {
        case "enabled":
            return .generic
        case "adaptive":
            let levels = effortLevels.compactMap { ThinkingSelection(rawValue: $0) }
            guard !levels.isEmpty else { return nil }
            return ModelThinkingSupport(
                supportsThinking: true,
                supportsReasoningEffort: true,
                supportsPreserveThinking: false,
                availableSelections: (supportsDisabledThinking ? [.off] : []) + levels,
                defaultSelection: levels[0]
            )
        default:
            return nil
        }
    }

    /// `{"supported": true}` capability flag; any other shape is unsupported.
    static func supported(_ value: Any?) -> Bool {
        (value as? [String: Any])?["supported"] as? Bool == true
    }
}
