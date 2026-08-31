//
//  DirectArgumentValues.swift
//  ZenCODE
//

import Foundation
import ToolCore

enum DirectArgumentValues {
    static func firstString(
        _ keys: [String],
        in arguments: [String: JSONValue],
        convert: (JSONValue) -> String?
    ) -> String? {
        for key in keys {
            if let value = arguments[key],
               let string = convert(value),
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }
        return nil
    }

    static func firstArray(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> [JSONValue]? {
        for key in keys {
            guard let value = arguments[key] else { continue }
            switch value {
            case let .array(values):
                guard !values.isEmpty else { continue }
                return values
            case let .object(object): return [.object(object)]
            default: continue
            }
        }
        return nil
    }

    static func firstStringList(
        _ keys: [String],
        in arguments: [String: JSONValue],
        convert: (JSONValue) -> String?
    ) -> [String]? {
        for key in keys {
            guard let value = arguments[key] else { continue }
            switch value {
            case let .array(values):
                let convertedValues = values
                    .compactMap(convert)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard !convertedValues.isEmpty else { continue }
                return convertedValues
            case let .string(string):
                guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                return [string]
            default:
                continue
            }
        }
        return nil
    }
}
