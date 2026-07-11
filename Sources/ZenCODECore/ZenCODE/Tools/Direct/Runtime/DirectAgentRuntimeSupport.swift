//
//  DirectAgentRuntimeSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

func jsonString(from value: Any) -> String {
    AgentJSONSupport.jsonString(from: value)
}

func jsonCompatible(_ value: Any) -> Any {
    AgentJSONSupport.jsonCompatible(value)
}

extension Dictionary where Key == String, Value == Any {
    public func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key] as? String {
                return value
            }
            if let value = self[key] {
                return String(describing: value)
            }
        }
        return nil
    }

    public func bool(_ keys: String...) -> Bool? {
        for key in keys {
            if let value = JSONValue(jsonObject: self[key]).flexibleBoolValue {
                return value
            }
        }
        return nil
    }

    public func int(_ keys: String...) -> Int? {
        for key in keys {
            if let value = JSONValue(jsonObject: self[key]).intValue {
                return value
            }
        }
        return nil
    }

    public func stringArray(_ keys: String...) -> [String]? {
        for key in keys {
            if let values = self[key] as? [String] {
                return values
            }
            if let values = self[key] as? [Any] {
                let strings = values.compactMap { value -> String? in
                    guard let string = value as? String else {
                        return nil
                    }
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                if !strings.isEmpty {
                    return strings
                }
            }
            if let value = self[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return [trimmed]
                }
            }
        }
        return nil
    }
}
