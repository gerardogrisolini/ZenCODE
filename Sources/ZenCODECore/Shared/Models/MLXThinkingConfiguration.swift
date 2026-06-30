//
//  MLXThinkingConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public nonisolated enum MLXThinkingSelection: String, Codable, CaseIterable, Identifiable, Sendable {
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

    public static func openRouterReasoningSelection(from value: JSONValue?) -> MLXThinkingSelection? {
        guard let value else {
            return nil
        }

        guard case let .object(object) = value else {
            return nil
        }

        if let effort = object["effort"]?.stringValue?.lowercased() {
            switch effort {
            case "none":
                return .off
            case "minimal":
                return .minimal
            case "low":
                return .low
            case "medium":
                return .medium
            case "high":
                return .high
            case "xhigh":
                return .xhigh
            default:
                break
            }
        }

        if let enabled = object["enabled"]?.boolValue {
            return enabled ? .enabled : .off
        }

        if object["max_tokens"]?.numberValue != nil {
            return .enabled
        }

        return nil
    }
}

public nonisolated struct MLXModelThinkingSupport: Codable, Hashable, Sendable {
    public let supportsThinking: Bool
    public let supportsReasoningEffort: Bool
    public let supportsPreserveThinking: Bool
    public let availableSelections: [MLXThinkingSelection]
    public let defaultSelection: MLXThinkingSelection

    public init(
        supportsThinking: Bool,
        supportsReasoningEffort: Bool,
        supportsPreserveThinking: Bool,
        availableSelections: [MLXThinkingSelection],
        defaultSelection: MLXThinkingSelection
    ) {
        self.supportsThinking = supportsThinking
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsPreserveThinking = supportsPreserveThinking
        self.availableSelections = availableSelections
        self.defaultSelection = defaultSelection
    }

    public static let generic = MLXModelThinkingSupport(
        supportsThinking: true,
        supportsReasoningEffort: false,
        supportsPreserveThinking: false,
        availableSelections: [.enabled, .off],
        defaultSelection: .enabled
    )

    public static func effort(
        levels: [MLXThinkingSelection] = [.minimal, .low, .medium, .high, .xhigh],
        supportsPreserveThinking: Bool = false
    ) -> MLXModelThinkingSupport {
        let normalizedLevels = effortLevels(from: levels)
        let resolvedLevels = normalizedLevels.isEmpty
            ? [.minimal, .low, .medium, .high, .xhigh]
            : normalizedLevels
        let defaultSelection = resolvedLevels.contains(.medium)
            ? MLXThinkingSelection.medium
            : (resolvedLevels.first ?? .medium)

        return MLXModelThinkingSupport(
            supportsThinking: true,
            supportsReasoningEffort: true,
            supportsPreserveThinking: supportsPreserveThinking,
            availableSelections: [.off] + resolvedLevels,
            defaultSelection: defaultSelection
        )
    }

    public static func fromModelMetadata(
        _ metadata: [String: Any]
    ) -> MLXModelThinkingSupport? {
        var detector = MetadataDetector()
        detector.scan(metadata)
        return detector.support
    }

    public static func fromMetadataFiles(
        in directories: [URL]
    ) -> MLXModelThinkingSupport? {
        var detector = MetadataDetector()
        for directory in directories {
            for filename in ["config.json", "tokenizer_config.json", "chat_template.jinja"] {
                let fileURL = directory.appending(path: filename)
                guard FileManager.default.fileExists(atPath: fileURL.path),
                      let data = try? Data(contentsOf: fileURL) else {
                    continue
                }

                if filename.hasSuffix(".json"),
                   let object = try? JSONDecoder().decode(JSONValue.self, from: data).mlxObjectValue {
                    let metadata = object.mapValues(\.jsonObject)
                    detector.scan(metadata)
                } else if let text = String(data: data, encoding: .utf8) {
                    detector.scan(text)
                }
            }
        }

        return detector.support
    }

}
