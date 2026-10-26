//
//  DS4ToolParameterKind.swift
//  ZenCODE
//
//  Declared JSON-schema type of a tool parameter, used to decide how a
//  generated argument value is interpreted (string vs JSON).
//

import Foundation

/// The JSON-schema type declared for a tool parameter.
///
/// Only `.string` changes parsing: a parameter declared as a string always
/// stays a string, even when its text looks like JSON (for example a file body
/// `123`). ds4_server.c does the same for Qwen through
/// `qwen_param_declared_string`; ds4-agent keeps every GLM value as text.
enum DS4ToolParameterKind: Sendable, Equatable, Hashable {
    case string
    case integer
    case number
    case boolean
    case array
    case object
    case null
    /// No single type is declared (missing `type`, unions, `anyOf`, …).
    case any

    /// tool name → parameter name → declared kind, from each descriptor's
    /// `inputSchema` top-level `properties`. Descriptors with an invalid schema
    /// are skipped; for duplicated tool names the first descriptor wins.
    static func map(from descriptors: [DirectToolDescriptor]) -> [String: [String: DS4ToolParameterKind]] {
        var result: [String: [String: DS4ToolParameterKind]] = [:]
        for descriptor in descriptors where result[descriptor.name] == nil {
            guard let data = descriptor.inputSchema.data(using: .utf8),
                  let schema = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else {
                continue
            }
            var kinds: [String: DS4ToolParameterKind] = [:]
            for (name, property) in properties {
                kinds[name] = DS4ToolParameterKind(schema: property as? [String: Any] ?? [:])
            }
            result[descriptor.name] = kinds
        }
        return result
    }

    /// The kind declared by one property schema.
    init(schema: [String: Any]) {
        if let type = schema["type"] as? String {
            self = Self(typeName: type)
            return
        }
        if let types = schema["type"] as? [String] {
            self = Self.combined(types.map(Self.init(typeName:)))
            return
        }
        if let values = schema["enum"] as? [Any], !values.isEmpty {
            self = values.allSatisfy { $0 is String } ? .string : .any
            return
        }
        if schema["const"] is String {
            self = .string
            return
        }
        for key in ["anyOf", "oneOf"] {
            if let variants = schema[key] as? [[String: Any]], !variants.isEmpty {
                self = Self.combined(variants.map(Self.init(schema:)))
                return
            }
        }
        self = .any
    }

    private init(typeName: String) {
        switch typeName {
        case "string":
            self = .string
        case "integer":
            self = .integer
        case "number":
            self = .number
        case "boolean":
            self = .boolean
        case "array":
            self = .array
        case "object":
            self = .object
        case "null":
            self = .null
        default:
            self = .any
        }
    }

    /// A union is a single kind only when it has one non-null member.
    private static func combined(_ kinds: [DS4ToolParameterKind]) -> DS4ToolParameterKind {
        let nonNull = Set(kinds.filter { $0 != .null })
        if nonNull.isEmpty {
            return kinds.isEmpty ? .any : .null
        }
        guard nonNull.count == 1, let only = nonNull.first else {
            return .any
        }
        return only
    }
}
