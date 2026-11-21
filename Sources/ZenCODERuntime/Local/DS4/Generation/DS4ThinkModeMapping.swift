//
//  DS4ThinkModeMapping.swift
//  ZenCODE
//
//  Maps ZenCODE's `/think` selection to a DS4 think mode
//  (`DS4EngineABI.ThinkMode`), mirroring ds4-agent:
//  - `off` is `NONE`;
//  - DeepSeek V4.1 (tool syntax `dsml41`) uses explicit effort levels parsed by
//    `ds4_think_mode_parse_level` (`--think` is effort 75, ds4_help.c);
//  - the other families use the named modes LOW / MEDIUM / HIGH / MAX;
//  - the result always goes through `ds4_think_mode_for_context`
//    (`effective_think_mode`, ds4_agent.c:1016), which degrades MAX below the
//    model's minimum context.
//  No selection means ds4-agent's default, `--think` (HIGH).
//

import Foundation

enum DS4ThinkModeMapping {
    /// The think mode requested by `selection`, before `think_mode_for_context`.
    /// `parseLevel` is `DS4Engine.thinkMode(parseLevel:)`.
    static func requestedMode(
        for selection: AgentThinkingSelection?,
        syntax: DS4ToolSyntax,
        parseLevel: (String) -> Int32?
    ) -> Int32 {
        let selection = selection ?? .enabled
        if selection == .off {
            return DS4EngineABI.ThinkMode.none
        }
        if syntax == .dsml41, let level = deepSeek41EffortLevel(for: selection) {
            return parseLevel(String(level)) ?? DS4EngineABI.ThinkMode.high
        }
        switch selection {
        case .off:
            return DS4EngineABI.ThinkMode.none
        case .minimal, .low:
            return DS4EngineABI.ThinkMode.low
        case .medium:
            return DS4EngineABI.ThinkMode.medium
        case .enabled, .high, .xhigh:
            return DS4EngineABI.ThinkMode.high
        case .max, .ultra:
            return DS4EngineABI.ThinkMode.max
        }
    }

    /// DeepSeek V4.1 effort level for `selection` (`nil` for `off`).
    static func deepSeek41EffortLevel(for selection: AgentThinkingSelection) -> Int? {
        switch selection {
        case .off:
            nil
        case .minimal:
            10
        case .low:
            25
        case .medium:
            50
        case .enabled, .high:
            75
        case .xhigh:
            90
        case .max, .ultra:
            100
        }
    }

    /// The think mode used for a turn: `requestedMode` passed through
    /// `think_mode_for_context` for the session context size.
    static func effectiveMode(
        for selection: AgentThinkingSelection?,
        syntax: DS4ToolSyntax,
        engine: any DS4Engine,
        contextSize: Int
    ) async -> Int32 {
        let requested = requestedMode(for: selection, syntax: syntax) { engine.thinkMode(parseLevel: $0) }
        return await engine.thinkMode(forContext: requested, contextSize: contextSize)
    }

    /// `ds4_think_mode_enabled` (ds4.c): the named modes other than NONE and
    /// every explicit level above 0.
    static func isEnabled(_ mode: Int32) -> Bool {
        switch mode {
        case DS4EngineABI.ThinkMode.low, DS4EngineABI.ThinkMode.medium,
             DS4EngineABI.ThinkMode.high, DS4EngineABI.ThinkMode.max:
            return true
        default:
            let level = mode - DS4EngineABI.ThinkMode.levelBase
            return mode >= DS4EngineABI.ThinkMode.levelBase && level > 0
                && level <= DS4EngineABI.ThinkMode.levelMax
        }
    }

    // MARK: - Qwen reasoning effort

    /// Copy of `DS4_QWEN4_REASONING_XHIGH` (ds4.c:44422). The shim does not
    /// export `ds4_qwen4_reasoning_effort_text`, so the text is replicated
    /// here; keep it byte-identical to ds4.c.
    static let qwenReasoningEffortXHigh =
        "Reasoning effort is set to xhigh. Please think carefully through the task, "
        + "validate key assumptions, consider plausible alternatives, and prioritize "
        + "correctness, consistency, and clarity in the final answer."

    /// Copy of `DS4_QWEN4_REASONING_LOW` (ds4.c:44426).
    static let qwenReasoningEffortLow =
        "Reasoning effort is set to low. Keep your thinking brief and focused, "
        + "moving directly to the conclusion without unnecessary elaboration."

    /// `ds4_qwen4_reasoning_effort_text` (ds4.c:73220): the system text Qwen
    /// gets in place of the think prefix (ds4_agent.c:5126). The template's
    /// default effort is xhigh; medium and no thinking add no text.
    static func qwenReasoningEffortText(for mode: Int32) -> String? {
        switch mode {
        case DS4EngineABI.ThinkMode.high, DS4EngineABI.ThinkMode.max:
            qwenReasoningEffortXHigh
        case DS4EngineABI.ThinkMode.low:
            qwenReasoningEffortLow
        default:
            nil
        }
    }
}
