//
//  CommonInputs.swift
//  ZenCODE
//
//  Shared input protocols and a structured schema builder so tool authors
//  can reuse common parameter groups (path aliases, working-directory,
//  timeout, limits, pagination) without hand-writing JSON Schema strings.
//
//  The goal is to keep the Swift `Input` struct and the advertised
//  `inputSchema` in sync from a single declarative source, reducing the
//  mismatch risk that comes from maintaining hand-written JSON by hand.
//

import Foundation

// MARK: - Utility

/// Returns the first non-blank value from a variadic list of optional strings.
/// Used by common input protocols to resolve parameter aliases.
public func firstNonBlank(_ values: String?...) -> String? {
    firstNonBlank(values)
}

/// Array overload so callers can forward an already-built list of aliases.
public func firstNonBlank(_ values: [String?]) -> String? {
    for value in values {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
    }
    return nil
}

// MARK: - Common input protocols

/// Resolves the working directory from `workingDirectory`, `cwd`, or `path`.
public protocol WorkingDirectoryInput {
    var path: String? { get }
    var workingDirectory: String? { get }
    var cwd: String? { get }
}

public extension WorkingDirectoryInput {
    /// Returns the first non-blank value from `workingDirectory`, `cwd`, `path`.
    func resolvedWorkingDirectory() -> String? {
        firstNonBlank(workingDirectory, cwd, path)
    }
}

/// Resolves a file path from common aliases.
public protocol FilePathInput {
    var path: String? { get }
    var file_path: String? { get }
    var filePath: String? { get }
    var file: String? { get }
}

public extension FilePathInput {
    func resolvedPath() -> String? {
        firstNonBlank(path, file_path, filePath, file)
    }
}

/// Resolves a timeout in seconds from `timeoutSeconds` / `timeout` aliases.
public protocol TimeoutInput {
    var timeoutSeconds: Int? { get }
    var timeout: Int? { get }
}

public extension TimeoutInput {
    func resolvedTimeout(default: Int = 900, minimum: Int = 30, maximum: Int = 3600) -> TimeInterval {
        let raw = timeoutSeconds ?? timeout ?? `default`
        return TimeInterval(max(minimum, min(raw, maximum)))
    }
}

/// Resolves a pagination / result limit from `maxResults` / `max_results`.
public protocol LimitInput {
    var maxResults: Int? { get }
    var max_results: Int? { get }
}

public extension LimitInput {
    func resolvedLimit(default: Int = 100, minimum: Int = 1, maximum: Int = 500) -> Int {
        let raw = maxResults ?? max_results ?? `default`
        return max(minimum, min(raw, maximum))
    }
}

/// Resolves a symbol cap from `maxSymbols` / `max_symbols`.
public protocol SymbolLimitInput {
    var maxSymbols: Int? { get }
    var max_symbols: Int? { get }
}

public extension SymbolLimitInput {
    func resolvedMaxSymbols() -> Int? {
        maxSymbols ?? max_symbols
    }
}

/// Resolves a base revision from alias keys.
public protocol BaseRevisionInput {
    var baseRevision: String? { get }
    var base_revision: String? { get }
    var base: String? { get }
}

public extension BaseRevisionInput {
    func resolvedBaseRevision() -> String? {
        firstNonBlank(baseRevision, base_revision, base)
    }
}

// MARK: - Schema model

/// A JSON Schema node. `indirect` so arrays and objects can nest.
public indirect enum SchemaNode: Sendable {
    case string(enumValues: [String]?, description: String?)
    case number(description: String?)
    case boolean(description: String?)
    case array(items: SchemaNode, description: String?)
    case object(properties: [SchemaProperty], required: [String], description: String?)
}

/// Describes a single named JSON Schema property.
public struct SchemaProperty: Sendable {
    public let name: String
    public let node: SchemaNode

    public init(_ name: String, node: SchemaNode) {
        self.name = name
        self.node = node
    }

    // MARK: Factories

    public static func string(
        _ name: String,
        enumValues: [String]? = nil,
        description: String? = nil
    ) -> SchemaProperty {
        SchemaProperty(name, node: .string(enumValues: enumValues, description: description))
    }

    public static func number(_ name: String, description: String? = nil) -> SchemaProperty {
        SchemaProperty(name, node: .number(description: description))
    }

    public static func boolean(_ name: String, description: String? = nil) -> SchemaProperty {
        SchemaProperty(name, node: .boolean(description: description))
    }

    /// An array of a scalar item type (`string`, `number`, `boolean`).
    public static func array(
        _ name: String,
        of itemType: SchemaNode = .string(enumValues: nil, description: nil),
        description: String? = nil
    ) -> SchemaProperty {
        SchemaProperty(name, node: .array(items: itemType, description: description))
    }

    /// An array of objects with the given properties.
    public static func arrayOfObjects(
        _ name: String,
        properties: [SchemaProperty],
        required: [String] = [],
        description: String? = nil
    ) -> SchemaProperty {
        SchemaProperty(
            name,
            node: .array(
                items: .object(properties: properties, required: required, description: nil),
                description: description
            )
        )
    }
}

// MARK: - Schema rendering

/// Renders a top-level `object` JSON Schema string from properties.
///
/// The property order is preserved and `required` keys are emitted only when
/// non-empty, matching the shape tool consumers already expect.
public func buildInputSchema(
    _ properties: [SchemaProperty],
    required: [String] = []
) -> String {
    renderSchemaNode(.object(properties: properties, required: required, description: nil))
}

/// Convenience overload accepting the properties as a variadic list.
public func buildInputSchema(
    required: [String] = [],
    _ properties: SchemaProperty...
) -> String {
    buildInputSchema(properties, required: required)
}

private func renderSchemaNode(_ node: SchemaNode) -> String {
    switch node {
    case let .string(enumValues, description):
        var fields = ["\"type\":\"string\""]
        if let enumValues, !enumValues.isEmpty {
            let joined = enumValues.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            fields.append("\"enum\":[\(joined)]")
        }
        appendDescription(description, to: &fields)
        return "{\(fields.joined(separator: ","))}"

    case let .number(description):
        var fields = ["\"type\":\"number\""]
        appendDescription(description, to: &fields)
        return "{\(fields.joined(separator: ","))}"

    case let .boolean(description):
        var fields = ["\"type\":\"boolean\""]
        appendDescription(description, to: &fields)
        return "{\(fields.joined(separator: ","))}"

    case let .array(items, description):
        var fields = ["\"type\":\"array\"", "\"items\":\(renderSchemaNode(items))"]
        appendDescription(description, to: &fields)
        return "{\(fields.joined(separator: ","))}"

    case let .object(properties, required, description):
        let props = properties
            .map { "\"\(escapeJSONString($0.name))\":\(renderSchemaNode($0.node))" }
            .joined(separator: ",")
        var fields = ["\"type\":\"object\"", "\"properties\":{\(props)}"]
        if !required.isEmpty {
            let joined = required.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            fields.append("\"required\":[\(joined)]")
        }
        appendDescription(description, to: &fields)
        return "{\(fields.joined(separator: ","))}"
    }
}

private func appendDescription(_ description: String?, to fields: inout [String]) {
    guard let description, !description.isEmpty else {
        return
    }
    fields.append("\"description\":\"\(escapeJSONString(description))\"")
}

private func escapeJSONString(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.count)
    for character in value.unicodeScalars {
        switch character {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if character.value < 0x20 {
                result += String(format: "\\u%04x", character.value)
            } else {
                result.unicodeScalars.append(character)
            }
        }
    }
    return result
}

// MARK: - Legacy builder (retained for source compatibility)

/// Incrementally accumulates properties and renders an object schema.
/// Prefer `buildInputSchema(_:required:)` for new tools.
public struct InputSchemaBuilder {
    private var properties: [SchemaProperty] = []
    private var required: [String] = []

    public init() {}

    public mutating func add(_ property: SchemaProperty) {
        properties.append(property)
    }

    public mutating func add(contentsOf newProperties: [SchemaProperty]) {
        properties.append(contentsOf: newProperties)
    }

    public mutating func require(_ keys: String...) {
        required.append(contentsOf: keys)
    }

    public func build() -> String {
        buildInputSchema(properties, required: required)
    }
}

// MARK: - Convenience presets

/// Common property groups used across many tools. Reusing these keeps the
/// advertised alias set consistent everywhere and makes adding tools faster.
public enum CommonSchemaProperties {
    /// `path`, `workingDirectory`, `cwd` — filesystem / shell / git tools.
    public static let workingDirectory: [SchemaProperty] = [
        .string("path"),
        .string("workingDirectory"),
        .string("cwd"),
    ]

    /// `path`, `file_path` — the common two-alias file target.
    public static let pathAliases: [SchemaProperty] = [
        .string("path"),
        .string("file_path"),
    ]

    /// `path`, `file_path`, `file`, `filePath` — full file-target alias set.
    public static let filePath: [SchemaProperty] = [
        .string("path"),
        .string("file_path"),
        .string("file"),
        .string("filePath"),
    ]

    /// `timeoutSeconds`, `timeout` — long-running tools.
    public static let timeout: [SchemaProperty] = [
        .number("timeoutSeconds"),
        .number("timeout"),
    ]

    /// `maxResults`, `max_results` — search / listing tools.
    public static let limit: [SchemaProperty] = [
        .number("maxResults"),
        .number("max_results"),
    ]

    /// `offset`, `limit` — paged file reads.
    public static let offsetLimit: [SchemaProperty] = [
        .number("offset"),
        .number("limit"),
    ]

    /// `maxSymbols`, `max_symbols` — outline / inspection tools.
    public static let symbolLimit: [SchemaProperty] = [
        .number("maxSymbols"),
        .number("max_symbols"),
    ]

    /// `configuration` — SwiftPM tools.
    public static let configuration: [SchemaProperty] = [
        .string("configuration"),
    ]

    /// `baseRevision`, `base_revision`, `base` — git diff tools.
    public static let baseRevision: [SchemaProperty] = [
        .string("baseRevision"),
        .string("base_revision"),
        .string("base"),
    ]

    /// `staged`, `cached` — git diff flags.
    public static let staged: [SchemaProperty] = [
        .boolean("staged"),
        .boolean("cached"),
    ]

    /// `target`, `product` — SwiftPM build targets.
    public static let buildTarget: [SchemaProperty] = [
        .string("target"),
        .string("product"),
    ]

    /// `filter`, `target` — test / search filter.
    public static let filter: [SchemaProperty] = [
        .string("filter"),
        .string("target"),
    ]

    /// `oldString`, `old_string`, `newString`, `new_string` — text edit aliases.
    public static let editStrings: [SchemaProperty] = [
        .string("oldString"),
        .string("old_string"),
        .string("newString"),
        .string("new_string"),
    ]
}
