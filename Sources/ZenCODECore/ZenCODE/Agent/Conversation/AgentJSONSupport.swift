//
//  AgentJSONSupport.swift
//  ZenCODE
//

import Foundation
import ToolCore

public enum AgentJSONSupport {
    public static func jsonString(from value: Any) -> String {
        JSONValue(jsonObject: value).compactString(sortedKeys: true)
    }

    public static func object(from json: String) -> [String: Any]? {
        let trimmedJSON = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJSON.isEmpty,
              let data = trimmedJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            return nil
        }

        return object.mapValues(\.jsonObject)
    }

    public static func jsonCompatible(_ value: Any) -> Any {
        JSONValue(jsonObject: value).jsonObject
    }
}
