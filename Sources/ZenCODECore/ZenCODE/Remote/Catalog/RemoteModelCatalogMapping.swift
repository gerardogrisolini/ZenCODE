//
//  RemoteModelCatalogMapping.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func modelMetadata(
    from entry: RemoteModelCatalogEntry
) -> [String: Any] {
    var metadata: [String: Any] = [:]
    for (key, value) in entry.values {
        metadata[key] = value.anyValue
    }
    return metadata
}

func pricing(
    from object: [String: JSONValue]
) -> OpenRouterModelPricing? {
    guard let pricing = value(object, "pricing"),
          case let .object(pricingObject) = pricing else {
        return nil
    }
    return OpenRouterModelPricing(
        prompt: doubleValue(pricingObject, "prompt"),
        completion: doubleValue(pricingObject, "completion")
    )
}

func generationParameterOverrides(
    from object: [String: JSONValue]
) -> AgentGenerationParameterOverrides? {
    guard let overrides = value(object, "generation_parameter_overrides"),
          case let .object(overridesObject) = overrides else {
        return nil
    }

    return AgentGenerationParameterOverrides(
        maxTokens: intValue(overridesObject, "max_tokens"),
        maxKVSize: intValue(overridesObject, "max_kv_size"),
        temperature: doubleValue(overridesObject, "temperature"),
        topP: doubleValue(overridesObject, "top_p"),
        topK: intValue(overridesObject, "top_k"),
        minP: doubleValue(overridesObject, "min_p"),
        repetitionPenalty: doubleValue(overridesObject, "repetition_penalty"),
        repetitionContextSize: intValue(overridesObject, "repetition_context_size"),
        presencePenalty: doubleValue(overridesObject, "presence_penalty"),
        presenceContextSize: intValue(overridesObject, "presence_context_size"),
        frequencyPenalty: doubleValue(overridesObject, "frequency_penalty"),
        frequencyContextSize: intValue(overridesObject, "frequency_context_size"),
        prefillStepSize: intValue(overridesObject, "prefill_step_size"),
        kvBits: intValue(overridesObject, "kv_bits"),
        kvGroupSize: intValue(overridesObject, "kv_group_size"),
        quantizedKVStart: intValue(overridesObject, "quantized_kv_start")
    ).normalized().nilIfEmpty
}

func contextLength(
    from object: [String: JSONValue]
) -> Int? {
    contextLengthValue(.object(object))
}

func contextLengthValue(
    _ value: JSONValue
) -> Int? {
    switch value {
    case let .object(object):
        for preferredKey in preferredContextLengthMetadataKeys {
            if let nestedValue = object.first(where: {
                normalizedMetadataKey($0.key) == preferredKey
            })?.value,
               let integer = contextLengthIntegerValue(nestedValue) {
                return integer
            }
        }

        for (key, nestedValue) in object where isContextLengthMetadataKey(key) {
            if let integer = contextLengthIntegerValue(nestedValue) {
                return integer
            }
        }

        for nestedValue in object.values {
            if let integer = contextLengthValue(nestedValue) {
                return integer
            }
        }
    case let .array(array):
        for item in array {
            if let integer = contextLengthValue(item) {
                return integer
            }
        }
    default:
        break
    }

    return nil
}

var preferredContextLengthMetadataKeys: [String] {
    [
        "effectivecontextlength",
        "configuredcontextlength",
        "loadedcontextlength",
        "contextlength",
        "contextwindow",
        "maxcontextwindow",
        "samplingmaxcontextwindow",
        "maxcontextlength",
        "modelmaxlength",
        "modelmaxlen",
        "inputtokenlimit",
        "maxinputtokens",
        "maxmodellen",
        "maxmodellength",
        "maxsequencelength",
        "maxseqlen",
        "maxpositionembeddings",
        "npositions",
        "nctx"
    ]
}

func contextLengthIntegerValue(
    _ value: JSONValue
) -> Int? {
    guard let integer = integerValue(value),
          integer >= 1024 else {
        return nil
    }
    return integer
}

func isContextLengthMetadataKey(
    _ key: String
) -> Bool {
    preferredContextLengthMetadataKeys.contains(normalizedMetadataKey(key))
}

private let contextLengthRegexes: [NSRegularExpression] = [
    #"(?i)context\s+(?:length|window)[^\n\n\d]{0,40}(\d+(?:\.\d+)?)\s*([km])?\b"#,
    #"(?i)(\d+(?:\.\d+)?)\s*([km])?\s*(?:-|\s)?token\s+context\b"#,
    #"(?i)context\s+(?:length|window)[^\n\n\d]{0,40}(\d+)\b"#
].compactMap { try? NSRegularExpression(pattern: $0) }

func contextLength(
    fromText text: String
) -> Int? {
    let normalizedText = text.replacingOccurrences(of: ",", with: "")
    for regex in contextLengthRegexes {
        let range = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        let matches = regex.matches(in: normalizedText, range: range)
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let numberRange = Range(match.range(at: 1), in: normalizedText),
                  let number = Double(normalizedText[numberRange]) else {
                continue
            }
            let suffix: String?
            if match.numberOfRanges >= 3,
               let suffixRange = Range(match.range(at: 2), in: normalizedText) {
                suffix = String(normalizedText[suffixRange]).lowercased()
            } else {
                suffix = nil
            }
            let multiplier: Double
            switch suffix {
            case "m":
                multiplier = 1_000_000
            case "k":
                multiplier = 1_024
            default:
                multiplier = 1
            }
            let integer = Int(number * multiplier)
            if integer >= 1024 {
                return integer
            }
        }
    }
    return nil
}

func normalizedMetadataKey(
    _ key: String
) -> String {
    key
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: " ", with: "")
}

func value(
    _ object: [String: JSONValue],
    _ key: String
) -> JSONValue? {
    let normalizedKey = normalizedMetadataKey(key)
    return object.first { normalizedMetadataKey($0.key) == normalizedKey }?.value
}

func stringValue(
    _ object: [String: JSONValue],
    _ key: String
) -> String? {
    value(object, key)?.stringValue?.nilIfBlank
}

func boolValue(
    _ object: [String: JSONValue],
    _ key: String
) -> Bool? {
    value(object, key)?.boolValue
}

func intValue(
    _ object: [String: JSONValue],
    _ key: String
) -> Int? {
    value(object, key).flatMap(integerValue)
}

func doubleValue(
    _ object: [String: JSONValue],
    _ key: String
) -> Double? {
    value(object, key).flatMap(doubleValue)
}

func integerValue(
    _ value: JSONValue
) -> Int? {
    switch value {
    case let .number(number):
        guard number.isFinite else {
            return nil
        }
        return Int(number)
    case let .string(string):
        let trimmedValue = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let integer = Int(trimmedValue) {
            return integer
        }

        let sanitizedValue = trimmedValue
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let integer = Int(sanitizedValue) {
            return integer
        }
        if let double = Double(sanitizedValue) {
            return Int(double)
        }
        return nil
    default:
        return nil
    }
}

func doubleValue(
    _ value: JSONValue
) -> Double? {
    switch value {
    case let .number(number):
        return number.isFinite ? number : nil
    case let .string(string):
        return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

