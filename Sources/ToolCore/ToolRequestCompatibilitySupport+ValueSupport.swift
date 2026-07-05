//
//  ToolRequestCompatibilitySupport+ValueSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

nonisolated func firstStringArrayValue(
    _ keys: [String],
    in arguments: [String: JSONValue]
) -> [String]? {
    for key in keys {
        guard let value = arguments[key] else {
            continue
        }

        switch value {
        case let .string(string):
            let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let decodedValue = decodedStructuredJSONStringToolValue(trimmedString),
               case let .array(items) = decodedValue {
                let strings = items.compactMap { item in
                    item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                if !strings.isEmpty {
                    return strings
                }
            }

            let commaSeparatedValues = trimmedString
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !commaSeparatedValues.isEmpty {
                return commaSeparatedValues
            }

            guard !trimmedString.isEmpty else {
                return nil
            }
            return [trimmedString]
        case let .array(items):
            let strings = items.compactMap { item in
                item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if !strings.isEmpty {
                return strings
            }
        default:
            continue
        }
    }

    return nil
}

nonisolated func decodedStructuredJSONStringToolValue(
    _ rawValue: String
) -> JSONValue? {
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstCharacter = trimmedValue.first,
          firstCharacter == "[" || firstCharacter == "{",
          let data = trimmedValue.data(using: .utf8) else {
        return nil
    }

    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

nonisolated func firstNumberValue(
    _ keys: [String],
    in arguments: [String: JSONValue]
) -> Double? {
    for key in keys {
        guard let value = arguments[key] else {
            continue
        }

        switch value {
        case let .number(number):
            return number
        case let .string(string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(trimmed) {
                return number
            }
        default:
            continue
        }
    }

    return nil
}

nonisolated func firstBoolValue(
    _ keys: [String],
    in arguments: [String: JSONValue]
) -> Bool? {
    for key in keys {
        guard let value = arguments[key] else {
            continue
        }

        switch value {
        case let .bool(bool):
            return bool
        case let .string(string):
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                continue
            }
        default:
            continue
        }
    }

    return nil
}

nonisolated func firstJSONValue(
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
