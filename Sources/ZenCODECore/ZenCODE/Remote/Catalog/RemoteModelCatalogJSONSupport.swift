//
//  RemoteModelCatalogJSONSupport.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Dictionary where Key == String, Value == Any {
    func removingSparseIdentifierKeys() -> [String: Any] {
        let sparseIdentifierKeys = Set([
            "id",
            "model",
            "modelid",
            "name",
            "modeltype",
            "architectures",
            "architecture"
        ])
        return filter { key, _ in
            !sparseIdentifierKeys.contains(normalizedMetadataKey(key))
        }
        .reduce(into: [:]) { result, element in
            result[element.key] = element.value
        }
    }
}

extension JSONValue {
    var anyValueDictionary: [String: Any] {
        guard case let .object(object) = self else {
            return [:]
        }
        return object.mapValues(\.anyValue)
    }

    var anyValue: Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .object(value):
            var object: [String: Any] = [:]
            for (key, nestedValue) in value {
                object[key] = nestedValue.anyValue
            }
            return object
        case let .array(value):
            return value.map(\.anyValue)
        case let .bool(value):
            return value
        case .null:
            return JSONValue.null
        }
    }
}
