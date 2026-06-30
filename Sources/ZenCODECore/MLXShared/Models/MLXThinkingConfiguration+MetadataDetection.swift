//
//  MLXThinkingConfiguration+MetadataDetection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

extension MLXModelThinkingSupport {
    public static func fromSparseRemoteModelIdentifier(
        _ modelID: String
    ) -> MLXModelThinkingSupport? {
        var detector = MetadataDetector()
        detector.scan(["id": modelID])
        return detector.support
    }

    public static func effortLevels(
        from selections: [MLXThinkingSelection]
    ) -> [MLXThinkingSelection] {
        let requestedLevels = Set(selections)
        return [.minimal, .low, .medium, .high, .xhigh].filter {
            requestedLevels.contains($0)
        }
    }

    public struct MetadataDetector {
        public var supportsThinking = false
        public var supportsEffort = false
        public var supportsPreserveThinking = false
        public var effortLevels: [MLXThinkingSelection] = []
        public var defaultSelection: MLXThinkingSelection?

        public var support: MLXModelThinkingSupport? {
            guard supportsThinking else {
                return nil
            }

            if supportsEffort {
                let normalizedLevels = MLXModelThinkingSupport.effortLevels(from: effortLevels)
                let resolvedLevels = normalizedLevels.isEmpty
                    ? [.minimal, .low, .medium, .high, .xhigh]
                    : normalizedLevels
                let availableSelections = [.off] + resolvedLevels
                let resolvedDefaultSelection = defaultSelection.flatMap {
                    availableSelections.contains($0) ? $0 : nil
                } ?? (resolvedLevels.contains(.medium) ? .medium : resolvedLevels[0])

                return MLXModelThinkingSupport(
                    supportsThinking: true,
                    supportsReasoningEffort: true,
                    supportsPreserveThinking: supportsPreserveThinking,
                    availableSelections: availableSelections,
                    defaultSelection: resolvedDefaultSelection
                )
            }

            let availableSelections: [MLXThinkingSelection] = [.enabled, .off]
            let resolvedDefaultSelection = defaultSelection.flatMap {
                availableSelections.contains($0) ? $0 : nil
            } ?? .enabled

            return MLXModelThinkingSupport(
                supportsThinking: true,
                supportsReasoningEffort: false,
                supportsPreserveThinking: supportsPreserveThinking,
                availableSelections: availableSelections,
                defaultSelection: resolvedDefaultSelection
            )
        }

        public mutating func scan(
            _ value: Any,
            keyPath: [String] = []
        ) {
            if case .null = JSONValue(jsonObject: value) {
                return
            }

            if let dictionary = value as? [String: Any] {
                for (key, nestedValue) in dictionary {
                    scanKey(key, value: nestedValue, keyPath: keyPath)
                    scan(nestedValue, keyPath: keyPath + [key])
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    scan(item, keyPath: keyPath)
                }
                return
            }

            if let string = value as? String {
                scanString(string, keyPath: keyPath)
                return
            }

            if JSONValue(jsonObject: value).flexibleBoolValue == true,
               keyPath.contains(where: isThinkingKey) {
                supportsThinking = true
            }
        }

        private mutating func scanKey(
            _ key: String,
            value: Any,
            keyPath: [String]
        ) {
            let normalizedKey = normalizedToken(key)

            if isThinkingKey(normalizedKey), truthy(value) {
                supportsThinking = true
            }

            if isEffortKey(normalizedKey), truthy(value) {
                supportsThinking = true
                supportsEffort = true
                appendEffortLevels(from: value)
            }

            if isPreserveThinkingKey(normalizedKey), truthy(value) {
                supportsThinking = true
                supportsPreserveThinking = true
            }

            if normalizedKey == "supportedparameters"
                || normalizedKey == "supportedparams"
                || normalizedKey == "capabilities"
                || normalizedKey == "features" {
                scanCapabilityList(value)
            }

            if keyPath.contains(where: isThinkingKey),
               isThinkingSelectionListKey(normalizedKey) {
                scanThinkingSelectionList(value)
            }

            if keyPath.contains(where: isThinkingKey),
               isDefaultThinkingSelectionKey(normalizedKey) {
                appendDefaultSelection(from: value)
            }

            if normalizedKey == "chattemplate",
               let template = value as? String,
               template.localizedCaseInsensitiveContains("enable_thinking") {
                supportsThinking = true
            }

            if normalizedKey == "chattemplate",
               let template = value as? String,
               containsPreserveThinkingReference(template) {
                supportsThinking = true
                supportsPreserveThinking = true
            }

            if isModelIdentifierKey(normalizedKey) {
                scanModelIdentifier(value)
            }

            if isThinkingKey(normalizedKey) {
                appendExplicitEffortLevels(from: value)
            }
        }

        private mutating func scanModelIdentifier(
            _ value: Any
        ) {
            if let string = value as? String {
                if isKnownThinkingModelIdentifier(string) {
                    supportsThinking = true
                }
                return
            }

            if let strings = value as? [String] {
                for string in strings where isKnownThinkingModelIdentifier(string) {
                    supportsThinking = true
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    scanModelIdentifier(item)
                }
            }
        }

        private mutating func scanCapabilityList(
            _ value: Any
        ) {
            if let strings = value as? [String] {
                for string in strings {
                    scanCapabilityString(string)
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    if let string = item as? String {
                        scanCapabilityString(string)
                    } else {
                        scan(item)
                    }
                }
                return
            }

            if let dictionary = value as? [String: Any] {
                for (key, nestedValue) in dictionary {
                    let normalizedKey = normalizedToken(key)
                    if isThinkingKey(normalizedKey), truthy(nestedValue) {
                        supportsThinking = true
                    }
                    if isEffortKey(normalizedKey), truthy(nestedValue) {
                        supportsThinking = true
                        supportsEffort = true
                        appendEffortLevels(from: nestedValue)
                    }
                    if isPreserveThinkingKey(normalizedKey), truthy(nestedValue) {
                        supportsThinking = true
                        supportsPreserveThinking = true
                    }
                    scan(nestedValue, keyPath: [key])
                }
            }
        }

        private mutating func scanThinkingSelectionList(
            _ value: Any
        ) {
            let selections = thinkingSelections(from: value)
            guard selections.contains(where: \.isEnabled) else {
                return
            }
            supportsThinking = true
            for selection in selections where isEffortSelection(selection) {
                appendEffortSelection(selection)
            }
        }

        private mutating func scanCapabilityString(
            _ string: String
        ) {
            let normalizedString = normalizedToken(string)
            if normalizedString == "reasoning" {
                supportsThinking = true
                supportsEffort = true
            } else if normalizedString.contains("reasoning")
                || normalizedString.contains("thinking")
                || normalizedString.contains("enablethinking") {
                supportsThinking = true
            }

            if normalizedString.contains("preservethinking") {
                supportsThinking = true
                supportsPreserveThinking = true
            }

            if normalizedString.contains("effort") {
                supportsThinking = true
                supportsEffort = true
            }

            appendEffortLevel(from: string)
        }

        private mutating func scanString(
            _ string: String,
            keyPath: [String]
        ) {
            if keyPath.contains(where: isEffortKey) {
                supportsThinking = true
                supportsEffort = true
                appendEffortLevel(from: string)
            }

            if keyPath.contains(where: isThinkingKey),
               truthy(string) {
                supportsThinking = true
            }

            if containsEnableThinkingReference(string) {
                supportsThinking = true
            }

            if containsPreserveThinkingReference(string) {
                supportsThinking = true
                supportsPreserveThinking = true
            }
        }

        private mutating func appendEffortLevels(
            from value: Any
        ) {
            if let string = value as? String {
                appendEffortLevel(from: string)
                return
            }

            if let strings = value as? [String] {
                for string in strings {
                    appendEffortLevel(from: string)
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    appendEffortLevels(from: item)
                }
                return
            }

            if truthy(value) {
                supportsEffort = true
            }
        }

        private mutating func appendExplicitEffortLevels(
            from value: Any
        ) {
            if let string = value as? String {
                appendEffortLevel(from: string)
                return
            }

            if let strings = value as? [String] {
                for string in strings {
                    appendEffortLevel(from: string)
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    appendExplicitEffortLevels(from: item)
                }
            }
        }

        private mutating func appendDefaultSelection(
            from value: Any
        ) {
            guard let selection = firstThinkingSelection(from: value),
                  selection.isEnabled else {
                return
            }
            supportsThinking = true
            defaultSelection = selection
            if isEffortSelection(selection) {
                appendEffortSelection(selection)
            }
        }

        private mutating func appendEffortLevel(
            from value: String
        ) {
            guard let selection = thinkingSelection(from: value),
                  isEffortSelection(selection) else {
                return
            }
            appendEffortSelection(selection)
        }

        private mutating func appendEffortSelection(
            _ selection: MLXThinkingSelection
        ) {
            guard !effortLevels.contains(selection) else {
                return
            }
            supportsThinking = true
            supportsEffort = true
            effortLevels.append(selection)
        }

        private func thinkingSelections(
            from value: Any
        ) -> [MLXThinkingSelection] {
            if let string = value as? String {
                return thinkingSelection(from: string).map { [$0] } ?? []
            }

            if let strings = value as? [String] {
                return strings.compactMap(thinkingSelection)
            }

            if let array = value as? [Any] {
                return array.flatMap(thinkingSelections)
            }

            return []
        }

        private func firstThinkingSelection(
            from value: Any
        ) -> MLXThinkingSelection? {
            thinkingSelections(from: value).first
        }

        private func thinkingSelection(
            from value: String
        ) -> MLXThinkingSelection? {
            let normalizedValue = normalizedToken(value)
            switch normalizedValue {
            case "on", "enabled", "enable", "true", "auto":
                return .enabled
            case "off", "none", "false", "disabled", "disable":
                return .off
            case "max":
                return .xhigh
            default:
                return MLXThinkingSelection(rawValue: normalizedValue)
            }
        }

        private func isEffortSelection(
            _ selection: MLXThinkingSelection
        ) -> Bool {
            switch selection {
            case .minimal, .low, .medium, .high, .xhigh:
                return true
            case .off, .enabled:
                return false
            }
        }

        private func isThinkingKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "reasoning"
                || normalizedKey == "thinking"
                || normalizedKey == "enablethinking"
                || normalizedKey == "supportsthinking"
                || normalizedKey == "reasoningcontent"
                || normalizedKey == "reasoningdetails"
        }

        private func isEffortKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "effort"
                || normalizedKey == "efforts"
                || normalizedKey == "reasoningeffort"
                || normalizedKey == "reasoningefforts"
                || normalizedKey == "thinkingeffort"
                || normalizedKey == "thinkingefforts"
                || normalizedKey == "effortlevels"
                || normalizedKey == "reasoningeffortlevels"
                || normalizedKey == "supportsreasoningeffort"
        }

        private func isPreserveThinkingKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "preservethinking"
                || normalizedKey == "supportspreservethinking"
        }

        private func isThinkingSelectionListKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "availableselections"
                || normalizedKey == "thinkingselections"
                || normalizedKey == "thinkingoptions"
                || normalizedKey == "options"
                || normalizedKey == "selections"
        }

        private func isDefaultThinkingSelectionKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "defaultselection"
                || normalizedKey == "defaultthinkingselection"
                || normalizedKey == "default"
        }

        private func isModelIdentifierKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "id"
                || normalizedKey == "model"
                || normalizedKey == "modelid"
                || normalizedKey == "name"
                || normalizedKey == "modeltype"
                || normalizedKey == "architectures"
                || normalizedKey == "architecture"
        }

        private func isKnownThinkingModelIdentifier(
            _ value: String
        ) -> Bool {
            let normalizedValue = normalizedToken(value)
            return normalizedValue.contains("qwen3")
                || normalizedValue.contains("qwq")
                || normalizedValue.contains("gemma4")
                || normalizedValue.contains("reasoning")
                || normalizedValue.contains("thinking")
                || normalizedValue.contains("deepseekr1")
                || normalizedValue.contains("cosmosreason")
                || normalizedValue.contains("gptoss")
                || normalizedValue.contains("nemotronreasoning")
                || normalizedValue.contains("nemotroncontentreasoning")
                || normalizedValue.contains("nemotronsuper")
                || normalizedValue.contains("nemotronultra")
                || normalizedValue.contains("nemotronnano")
                || normalizedValue.contains("nemotron3super")
                || normalizedValue.contains("nemotron3ultra")
                || normalizedValue.contains("nemotron3nano")
        }

        private func containsPreserveThinkingReference(
            _ value: String
        ) -> Bool {
            normalizedToken(value).contains("preservethinking")
        }

        private func containsEnableThinkingReference(
            _ value: String
        ) -> Bool {
            normalizedToken(value).contains("enablethinking")
        }

        private func truthy(
            _ value: Any
        ) -> Bool {
            let jsonValue = JSONValue(jsonObject: value)

            if let bool = jsonValue.flexibleBoolValue {
                return bool
            }

            if let string = jsonValue.stringValue {
                let normalizedString = normalizedToken(string)
                return normalizedString == "true"
                    || normalizedString == "enabled"
                    || normalizedString == "supported"
                    || normalizedString == "yes"
                    || normalizedString == "1"
                    || normalizedString.contains("reasoning")
                    || normalizedString.contains("thinking")
                    || normalizedString.contains("enablethinking")
            }

            if let array = value as? [Any] {
                return !array.isEmpty
            }

            if let dictionary = value as? [String: Any] {
                return !dictionary.isEmpty
            }

            return false
        }

        private func normalizedToken(
            _ value: String
        ) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "")
        }
    }
}
