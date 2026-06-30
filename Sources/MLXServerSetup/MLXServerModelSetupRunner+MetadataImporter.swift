//
//  MLXServerModelSetupRunner+MetadataImporter.swift
//  ZenCODE
//

import Foundation
import HuggingFace
import MLXServerCore

enum MLXServerModelParameterImporter {
    static func importDefaults(from snapshotURL: URL) -> MLXServerModelGenerationDefaults {
        let config = decode(ModelConfigProbe.self, from: snapshotURL.appendingPathComponent("config.json"))
        let generationConfig = decode(
            GenerationConfigProbe.self,
            from: snapshotURL.appendingPathComponent("generation_config.json")
        )

        return MLXServerModelGenerationDefaults(
            contextWindow: config?.contextWindow,
            maxOutputTokens: generationConfig?.maxOutputTokensValue,
            temperature: generationConfig?.temperature,
            topP: generationConfig?.topP,
            topK: generationConfig?.topK,
            repetitionPenalty: generationConfig?.repetitionPenalty,
            presencePenalty: generationConfig?.presencePenalty,
            frequencyPenalty: generationConfig?.frequencyPenalty,
            prefillStepSize: MLXServerModelGenerationDefaults.defaultPrefillStepSize
        )
    }

    static func importThinking(
        from snapshotURL: URL,
        repositoryID: String
    ) -> MLXServerModelThinkingConfiguration {
        var detector = ModelThinkingMetadataDetector()
        detector.scan(repositoryID)

        for filename in ["config.json", "generation_config.json", "tokenizer_config.json"] {
            let fileURL = snapshotURL.appendingPathComponent(filename)
            if let value = decode(ModelMetadataValue.self, from: fileURL) {
                detector.scan(value)
            }
        }

        let templateURL = snapshotURL.appendingPathComponent("chat_template.jinja")
        if let data = try? Data(contentsOf: templateURL),
           let template = String(data: data, encoding: .utf8) {
            detector.scan(template)
        }

        return detector.configuration.validated()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum ModelMetadataValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ModelMetadataValue])
    case object([String: ModelMetadataValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([ModelMetadataValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: ModelMetadataValue].self))
        }
    }
}

struct ModelThinkingMetadataDetector {
    var supportsThinking = false
    var supportsReasoningEffort = false
    var supportsPreserveThinking = false
    var effortLevels: [MLXServerThinkingSelection] = []

    var configuration: MLXServerModelThinkingConfiguration {
        guard supportsThinking else {
            return .disabled
        }
        if supportsReasoningEffort {
            return .effort(
                levels: effortLevels,
                supportsPreserveThinking: supportsPreserveThinking
            )
        }
        return MLXServerModelThinkingConfiguration(
            supportsThinking: true,
            supportsReasoningEffort: false,
            supportsPreserveThinking: supportsPreserveThinking,
            availableSelections: [.off, .enabled],
            defaultSelection: .enabled
        )
    }

    mutating func scan(_ value: ModelMetadataValue, keyPath: [String] = []) {
        switch value {
        case .null:
            return
        case .bool(let bool):
            if bool, keyPath.contains(where: isThinkingKey) {
                supportsThinking = true
            }
            if bool, keyPath.contains(where: isEffortKey) {
                supportsThinking = true
                supportsReasoningEffort = true
            }
            if bool, keyPath.contains(where: isPreserveThinkingKey) {
                supportsThinking = true
                supportsPreserveThinking = true
            }
        case .number(let number):
            if number != 0, keyPath.contains(where: isThinkingKey) {
                supportsThinking = true
            }
        case .string(let string):
            scan(string, keyPath: keyPath)
        case .array(let array):
            for item in array {
                scan(item, keyPath: keyPath)
            }
        case .object(let object):
            for (key, nestedValue) in object {
                scanKey(key, value: nestedValue)
                scan(nestedValue, keyPath: keyPath + [key])
            }
        }
    }

    mutating func scan(_ text: String, keyPath: [String] = []) {
        if keyPath.contains(where: isEffortKey) {
            supportsThinking = true
            supportsReasoningEffort = true
            appendEffortLevel(from: text)
        }

        if keyPath.contains(where: isThinkingKey), isTruthy(text) {
            supportsThinking = true
        }

        if containsEnableThinkingReference(text) || isKnownThinkingModelIdentifier(text) {
            supportsThinking = true
        }

        if containsPreserveThinkingReference(text) || isKnownPreserveThinkingModelIdentifier(text) {
            supportsThinking = true
            supportsPreserveThinking = true
        }

        appendEffortLevel(from: text)
    }

    private mutating func scanKey(_ key: String, value: ModelMetadataValue) {
        if isThinkingKey(key), value.isTruthy {
            supportsThinking = true
        }

        if isEffortKey(key), value.isTruthy {
            supportsThinking = true
            supportsReasoningEffort = true
            appendEffortLevels(from: value)
        }

        if isPreserveThinkingKey(key), value.isTruthy {
            supportsThinking = true
            supportsPreserveThinking = true
        }

        let normalizedKey = normalizedToken(key)
        if normalizedKey == "chattemplate",
           case .string(let template) = value {
            if containsEnableThinkingReference(template) {
                supportsThinking = true
            }
            if containsPreserveThinkingReference(template) {
                supportsThinking = true
                supportsPreserveThinking = true
            }
        }
    }

    private mutating func appendEffortLevels(from value: ModelMetadataValue) {
        switch value {
        case .string(let string):
            appendEffortLevel(from: string)
        case .array(let array):
            for item in array {
                appendEffortLevels(from: item)
            }
        case .object(let object):
            for nestedValue in object.values {
                appendEffortLevels(from: nestedValue)
            }
        case .bool(let bool):
            if bool {
                supportsReasoningEffort = true
            }
        case .number, .null:
            return
        }
    }

    private mutating func appendEffortLevel(from value: String) {
        guard let selection = MLXServerThinkingSelection(protocolValue: value),
              selection.isEffortLevel,
              !effortLevels.contains(selection) else {
            return
        }
        supportsThinking = true
        supportsReasoningEffort = true
        effortLevels.append(selection)
    }

    private func isThinkingKey(_ key: String) -> Bool {
        let normalizedKey = normalizedToken(key)
        return normalizedKey == "reasoning"
            || normalizedKey == "thinking"
            || normalizedKey == "enablethinking"
            || normalizedKey == "reasoningcontent"
            || normalizedKey == "reasoningdetails"
    }

    private func isEffortKey(_ key: String) -> Bool {
        let normalizedKey = normalizedToken(key)
        return normalizedKey == "effort"
            || normalizedKey == "efforts"
            || normalizedKey == "reasoningeffort"
            || normalizedKey == "reasoningefforts"
            || normalizedKey == "thinkingeffort"
            || normalizedKey == "thinkingefforts"
            || normalizedKey == "effortlevels"
            || normalizedKey == "reasoningeffortlevels"
            || normalizedKey == "thinkinglevels"
    }

    private func isPreserveThinkingKey(_ key: String) -> Bool {
        normalizedToken(key) == "preservethinking"
    }

    private func containsEnableThinkingReference(_ value: String) -> Bool {
        normalizedToken(value).contains("enablethinking")
    }

    private func containsPreserveThinkingReference(_ value: String) -> Bool {
        normalizedToken(value).contains("preservethinking")
    }

    private func isKnownThinkingModelIdentifier(_ value: String) -> Bool {
        let normalizedValue = normalizedToken(value)
        return normalizedValue.contains("qwen3")
            || normalizedValue.contains("qwq")
            || normalizedValue.contains("reasoning")
            || normalizedValue.contains("thinking")
            || normalizedValue.contains("deepseekr1")
            || normalizedValue.contains("gptoss")
    }

    private func isKnownPreserveThinkingModelIdentifier(_ value: String) -> Bool {
        let normalizedValue = normalizedToken(value)
        return normalizedValue.contains("qwen36")
    }

    private func isTruthy(_ value: String) -> Bool {
        let normalizedValue = normalizedToken(value)
        return normalizedValue == "true"
            || normalizedValue == "enabled"
            || normalizedValue == "supported"
            || normalizedValue == "yes"
            || normalizedValue == "1"
            || normalizedValue.contains("reasoning")
            || normalizedValue.contains("thinking")
            || normalizedValue.contains("enablethinking")
    }

    private func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension ModelMetadataValue {
    var isTruthy: Bool {
        switch self {
        case .null:
            false
        case .bool(let bool):
            bool
        case .number(let number):
            number != 0
        case .string(let string):
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let array):
            !array.isEmpty
        case .object(let object):
            !object.isEmpty
        }
    }
}

