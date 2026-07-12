//
//  XcodeArgumentNormalizationSupport.swift
//  ZenCODE
//

import ToolCore

nonisolated func assignXcodeSnippetString(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstXcodeStringValue(sourceKeys, in: arguments) else {
        return
    }
    normalized[destinationKey] = .string(normalizedXcodeSnippetString(value))
}

nonisolated func assignNormalizedTextEditOperations(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstXcodeJSONValue(sourceKeys, in: arguments) else {
        return
    }
    normalized[destinationKey] = normalizedTextEditOperations(value)
}

nonisolated func assignNormalizedXcodeTestSpecifiers(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstXcodeJSONValue(sourceKeys, in: arguments),
          let normalizedValue = normalizedXcodeTestSpecifiers(value) else {
        return
    }
    normalized[destinationKey] = normalizedValue
}

private nonisolated func firstXcodeStringValue(
    _ keys: [String],
    in arguments: [String: JSONValue]
) -> String? {
    for key in keys {
        guard let value = arguments[key] else {
            continue
        }
        switch value {
        case let .string(string):
            return string
        case let .number(number):
            return number.rounded() == number ? String(Int(number)) : String(number)
        case let .bool(bool):
            return bool ? "true" : "false"
        default:
            continue
        }
    }
    return nil
}

private nonisolated func firstXcodeJSONValue(
    _ keys: [String],
    in arguments: [String: JSONValue]
) -> JSONValue? {
    for key in keys {
        if let value = arguments[key] {
            return value
        }
    }
    return nil
}
