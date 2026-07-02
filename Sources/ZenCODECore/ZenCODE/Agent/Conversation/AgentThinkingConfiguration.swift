//
//  AgentThinkingConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum AgentThinkingSelection: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case off
    case enabled
    case minimal
    case low
    case medium
    case high
    case xhigh

    public var id: String { rawValue }

    public var isEnabled: Bool {
        self != .off
    }

    public var displayTitle: String {
        switch self {
        case .off:
            return "Off"
        case .enabled:
            return "On"
        case .minimal:
            return "Minimal"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "XHigh"
        }
    }

    public var menuTitle: String {
        switch self {
        case .off:
            return "Thinking off"
        case .enabled:
            return "Thinking on"
        case .minimal:
            return "Minimal thinking"
        case .low:
            return "Low thinking"
        case .medium:
            return "Medium thinking"
        case .high:
            return "High thinking"
        case .xhigh:
            return "XHigh thinking"
        }
    }

    public var openRouterReasoningPayload: [String: Any] {
        switch self {
        case .off:
            [
                "effort": "none",
                "exclude": false
            ]
        case .enabled:
            [
                "enabled": true,
                "exclude": false
            ]
        case .minimal, .low, .medium, .high, .xhigh:
            [
                "effort": rawValue,
                "exclude": false
            ]
        }
    }

    public var chatTemplateReasoningEffort: String? {
        switch self {
        case .off, .enabled:
            nil
        case .minimal, .low, .medium, .high:
            rawValue
        case .xhigh:
            "max"
        }
    }

}

public enum AgentThinkingPayloadStyle {
    case openRouterReasoning
    case chatTemplateKwargs
}
