//
//  JSONValue.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case object([String: JSONValue])
    case array([JSONValue])
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: encoded())
    }

    public init(jsonObject value: Any?) {
        guard let value else {
            self = .null
            return
        }
        if let jsonValue = value as? JSONValue {
            self = jsonValue
        } else if let string = value as? String {
            self = .string(string)
        } else if let bool = value as? Bool {
            self = .bool(bool)
        } else if let int = value as? Int {
            self = .number(Double(int))
        } else if let int64 = value as? Int64 {
            self = .number(Double(int64))
        } else if let double = value as? Double {
            self = .number(double)
        } else if let float = value as? Float {
            self = .number(Double(float))
        } else if let object = value as? [String: Any] {
            self = .object(object.mapValues { JSONValue(jsonObject: $0) })
        } else if let array = value as? [Any] {
            self = .array(array.map { JSONValue(jsonObject: $0) })
        } else {
            self = .string(String(describing: value))
        }
    }

    public func prettyPrinted() -> String {
        guard let data = try? jsonData(outputFormatting: [
                  .withoutEscapingSlashes,
                  .prettyPrinted,
                  .sortedKeys
              ]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    public func compactString(sortedKeys: Bool = false) -> String {
        var formatting: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]
        if sortedKeys {
            formatting.insert(.sortedKeys)
        }
        guard let data = try? jsonData(outputFormatting: formatting) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func jsonData(
        outputFormatting: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        return try encoder.encode(self)
    }

    public var jsonObject: Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .object(value):
            return value.mapValues(\.jsonObject)
        case let .array(value):
            return value.map(\.jsonObject)
        case let .bool(value):
            return value
        case .null:
            return JSONValue.null
        }
    }

    public var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }

        return value
    }

    public var numberValue: Double? {
        guard case let .number(value) = self else {
            return nil
        }

        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }

        return value
    }

    public var intValue: Int? {
        switch self {
        case let .number(value):
            guard value.isFinite, value.rounded(.towardZero) == value else {
                return nil
            }
            return Int(value)
        case let .string(value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .number(value):
            return value.isFinite ? value : nil
        case let .string(value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    public var flexibleStringValue: String? {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            guard value.isFinite else {
                return nil
            }
            if value.rounded(.towardZero) == value {
                return String(Int(value))
            }
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    public var flexibleBoolValue: Bool? {
        switch self {
        case let .bool(value):
            return value
        case let .number(value):
            guard value.isFinite else {
                return nil
            }
            return value != 0
        case let .string(value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }
}
