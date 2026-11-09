//
//  ThinkingConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated enum ThinkingSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case enabled
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    public var id: String { rawValue }

    public var isEnabled: Bool {
        self != .off
    }

    public var displayTitle: String {
        switch self {
        case .off:
            "Off"
        case .enabled:
            "On"
        case .minimal:
            "Minimal"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .xhigh:
            "XHigh"
        case .max:
            "Max"
        case .ultra:
            "Ultra"
        }
    }

    public var menuTitle: String {
        switch self {
        case .off:
            "Thinking off"
        case .enabled:
            "Thinking on"
        case .minimal:
            "Minimal thinking"
        case .low:
            "Low thinking"
        case .medium:
            "Medium thinking"
        case .high:
            "High thinking"
        case .xhigh:
            "XHigh thinking"
        case .max:
            "Max thinking"
        case .ultra:
            "Ultra thinking"
        }
    }
}

public nonisolated struct ModelThinkingSupport: Codable, Hashable, Sendable {
    public let supportsThinking: Bool
    public let supportsReasoningEffort: Bool
    public let supportsPreserveThinking: Bool
    public let availableSelections: [ThinkingSelection]
    public let defaultSelection: ThinkingSelection

    public init(
        supportsThinking: Bool,
        supportsReasoningEffort: Bool,
        supportsPreserveThinking: Bool,
        availableSelections: [ThinkingSelection],
        defaultSelection: ThinkingSelection
    ) {
        self.supportsThinking = supportsThinking
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsPreserveThinking = supportsPreserveThinking
        self.availableSelections = availableSelections
        self.defaultSelection = defaultSelection
    }

    public static let generic = ModelThinkingSupport(
        supportsThinking: true,
        supportsReasoningEffort: false,
        supportsPreserveThinking: false,
        availableSelections: [.enabled, .off],
        defaultSelection: .enabled
    )

    public static func effort(
        levels: [ThinkingSelection] = [.minimal, .low, .medium, .high, .xhigh],
        supportsPreserveThinking: Bool = false,
        defaultSelection: ThinkingSelection? = nil
    ) -> ModelThinkingSupport {
        let normalizedLevels = effortLevels(from: levels)
        let resolvedLevels = normalizedLevels.isEmpty
            ? [.minimal, .low, .medium, .high, .xhigh, .max]
            : normalizedLevels
        let resolvedDefaultSelection = defaultSelection.flatMap {
            resolvedLevels.contains($0) ? $0 : nil
        } ?? (resolvedLevels.contains(.medium)
            ? ThinkingSelection.medium
            : (resolvedLevels.first ?? .medium))

        return ModelThinkingSupport(
            supportsThinking: true,
            supportsReasoningEffort: true,
            supportsPreserveThinking: supportsPreserveThinking,
            availableSelections: [.off] + resolvedLevels,
            defaultSelection: resolvedDefaultSelection
        )
    }

    public static func fromModelMetadata(
        _ metadata: [String: Any]
    ) -> ModelThinkingSupport? {
        var detector = MetadataDetector()
        detector.scan(metadata)
        return detector.support
    }
}
