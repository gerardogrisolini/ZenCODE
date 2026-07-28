//
//  ToolPresentationResolver.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Resolves serializable tool-owned metadata into unstyled semantic elements.
/// All returned strings remain untrusted and must be sanitized and bounded by
/// the presentation consumer.
public nonisolated enum ToolPresentationResolver {
    public static func resolve(
        _ definition: ToolPresentationDefinition,
        call: DirectAgentToolCall,
        result: DirectAgentToolResult? = nil,
        mode: ToolPresentationMode
    ) -> ResolvedToolPresentation {
        let definition = definition.validOrAutomatic
        guard !definition.isAutomatic else {
            return automaticPresentation(call: call, result: result, mode: mode)
        }

        let title = nonBlank(definition.title)
            ?? nonBlank(call.descriptorTitle)
            ?? call.name
        let action = nonBlank(definition.action)
        let target = definition.target.flatMap {
            nonBlank(displayString(for: $0, call: call, result: result))
        }
        let metadata = definition.metadata.compactMap { item -> ToolPresentationMetadata? in
            guard item.modes.contains(mode),
                  let value = nonBlank(displayString(for: item.value, call: call, result: result)) else {
                return nil
            }
            return ToolPresentationMetadata(label: item.label, value: value)
        }

        var elements = definition.sections.compactMap { section in
            resolve(section: section, call: call, result: result, mode: mode)
        }
        if let summary = definition.summary,
           summary.modes.contains(mode),
           let text = resolve(summary: summary, call: call, result: result) {
            elements.append(.summary(label: summary.label, text: text))
        }

        return ResolvedToolPresentation(
            mode: mode,
            title: title,
            action: action,
            target: target,
            kind: definition.kind ?? .other,
            metadata: metadata,
            elements: elements,
            usesAutomaticFallback: false
        )
    }

    public static func resolve(
        call: DirectAgentToolCall,
        result: DirectAgentToolResult? = nil,
        mode: ToolPresentationMode
    ) -> ResolvedToolPresentation {
        resolve(call.presentation, call: call, result: result, mode: mode)
    }

    private static func automaticPresentation(
        call: DirectAgentToolCall,
        result: DirectAgentToolResult?,
        mode: ToolPresentationMode
    ) -> ResolvedToolPresentation {
        var elements: [ToolPresentationElement] = []
        if mode == .expanded {
            let arguments = argumentsValue(for: call)
            if case let .object(object) = arguments, !object.isEmpty {
                elements.append(.parameters(label: "parameters", value: arguments))
            }
        }
        if let result,
           let summary = nonBlank(result.summary) {
            elements.append(.summary(label: "summary", text: summary))
        }
        return ResolvedToolPresentation(
            mode: mode,
            title: nonBlank(call.descriptorTitle) ?? call.name,
            action: nil,
            target: nil,
            kind: .other,
            metadata: [],
            elements: elements,
            usesAutomaticFallback: true
        )
    }

    private static func resolve(
        section: ToolPresentationSectionDefinition,
        call: DirectAgentToolCall,
        result: DirectAgentToolResult?,
        mode: ToolPresentationMode
    ) -> ToolPresentationElement? {
        guard section.isSemanticallyValid,
              section.modes.contains(mode) else {
            return nil
        }
        let languageHint = section.languageHint.flatMap {
            nonBlank(displayString(for: $0, call: call, result: result))
        }

        switch section.kind {
        case .parameters:
            guard let definition = section.value,
                  let value = rawValue(for: definition, call: call, result: result),
                  !isEmptyCollection(value) else {
                return nil
            }
            return .parameters(label: section.label, value: value)
        case .code:
            guard let definition = section.value,
                  let content = contentString(for: definition, call: call, result: result) else {
                return nil
            }
            return .code(
                label: section.label,
                content: content,
                languageHint: languageHint
            )
        case .diff:
            guard let oldDefinition = section.oldValue,
                  let newDefinition = section.newValue,
                  let old = contentString(for: oldDefinition, call: call, result: result),
                  let new = contentString(for: newDefinition, call: call, result: result) else {
                return nil
            }
            return .diff(
                label: section.label,
                old: old,
                new: new,
                languageHint: languageHint
            )
        case .list:
            guard let definition = section.value,
                  let value = rawValue(for: definition, call: call, result: result) else {
                return nil
            }
            let items: [JSONValue]
            if case let .array(array) = value {
                items = array
            } else {
                items = [value]
            }
            guard !items.isEmpty else {
                return nil
            }
            return .list(label: section.label, items: items)
        }
    }

    private static func resolve(
        summary: ToolPresentationSummaryDefinition,
        call: DirectAgentToolCall,
        result: DirectAgentToolResult?
    ) -> String? {
        guard let value = rawValue(for: summary.value, call: call, result: result) else {
            return nil
        }
        let text: String?
        switch summary.strategy {
        case .value:
            text = displayString(for: summary.value, rawValue: value)
        case .firstLine:
            text = plainText(value).map(firstLine)
        case .lineCount:
            text = plainText(value).map { "\(logicalLineCount($0)) lines" }
        case .numberedLineCount:
            text = plainText(value).map {
                let count = numberedLineCount($0)
                let noun = count == 1 ? "line" : "lines"
                return "read \(count) \(noun)"
            }
        case .itemCount:
            text = "\(itemCount(value)) items"
        }
        return nonBlank(text)
    }

    private static func rawValue(
        for definition: ToolPresentationValueDefinition,
        call: DirectAgentToolCall,
        result: DirectAgentToolResult?
    ) -> JSONValue? {
        let root: JSONValue?
        switch definition.source {
        case .arguments:
            root = argumentsValue(for: call)
        case .resultOutput:
            root = result.map { .string($0.output) }
        case .resultSummary:
            root = result.map { .string($0.summary) }
        case .toolName:
            root = .string(call.name)
        case .literal:
            root = definition.literalValue.map(JSONValue.string)
        }

        let selected: JSONValue?
        if definition.source == .arguments,
           !definition.keyPaths.isEmpty,
           let root {
            selected = definition.keyPaths.lazy.compactMap {
                value(at: $0, in: root)
            }.first
        } else {
            selected = root
        }

        if let selected, selected != .null {
            return selected
        }
        return definition.fallback.map(JSONValue.string)
    }

    private static func displayString(
        for definition: ToolPresentationValueDefinition,
        call: DirectAgentToolCall,
        result: DirectAgentToolResult?
    ) -> String? {
        guard let value = rawValue(for: definition, call: call, result: result) else {
            return nil
        }
        return displayString(for: definition, rawValue: value)
    }

    private static func displayString(
        for definition: ToolPresentationValueDefinition,
        rawValue value: JSONValue
    ) -> String? {
        switch definition.format {
        case .automatic, .text, .path, .command, .url:
            return plainText(value, separator: definition.separator)
        case .json:
            return value.prettyPrinted()
        case .stringList:
            if case let .array(values) = value {
                let strings = values.compactMap { plainText($0) }
                return strings.joined(separator: definition.separator ?? ", ")
            }
            return plainText(value, separator: definition.separator)
        case .firstLine:
            return plainText(value).map(firstLine)
        case .lineCount:
            return plainText(value).map { String(logicalLineCount($0)) }
        case .itemCount:
            return String(itemCount(value))
        case .languageHint:
            return plainText(value).flatMap(languageHint)
        }
    }

    private static func contentString(
        for definition: ToolPresentationValueDefinition,
        call: DirectAgentToolCall,
        result: DirectAgentToolResult?
    ) -> String? {
        guard let value = rawValue(for: definition, call: call, result: result) else {
            return nil
        }
        switch definition.format {
        case .json:
            return value.prettyPrinted()
        default:
            return plainText(value, separator: definition.separator)
        }
    }

    private static func argumentsValue(for call: DirectAgentToolCall) -> JSONValue {
        .object(call.argumentsObject.mapValues { JSONValue(jsonObject: $0) })
    }

    private static func value(at keyPath: String, in root: JSONValue) -> JSONValue? {
        if case let .object(object) = root,
           let direct = object[keyPath] {
            return direct
        }
        let components = keyPath
            .split(separator: ".", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else {
            return root
        }

        var current = root
        for component in components {
            switch current {
            case let .object(object):
                guard let next = object[component] else { return nil }
                current = next
            case let .array(array):
                guard let index = Int(component), array.indices.contains(index) else {
                    return nil
                }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    private static func plainText(
        _ value: JSONValue,
        separator: String? = nil
    ) -> String? {
        switch value {
        case let .string(string):
            return string
        case let .number(number):
            if number.isFinite,
               number.rounded(.towardZero) == number,
               number >= Double(Int64.min),
               number <= Double(Int64.max) {
                return String(Int64(number))
            }
            return String(number)
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return nil
        case let .array(values):
            let strings = values.compactMap { plainText($0) }
            if strings.count == values.count {
                return strings.joined(separator: separator ?? ", ")
            }
            return value.prettyPrinted()
        case .object:
            return value.prettyPrinted()
        }
    }

    private static func firstLine(_ value: String) -> String {
        String(value.split(whereSeparator: \.isNewline).first ?? "")
    }

    private static func logicalLineCount(_ value: String) -> Int {
        guard !value.isEmpty else { return 0 }
        return value.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).count
    }

    private static func numberedLineCount(_ value: String) -> Int {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .count { line in
                guard let tab = line.firstIndex(of: "\t") else {
                    return false
                }
                let prefix = line[..<tab]
                    .trimmingCharacters(in: .whitespaces)
                return !prefix.isEmpty && prefix.allSatisfy(\.isWholeNumber)
            }
    }

    private static func itemCount(_ value: JSONValue) -> Int {
        switch value {
        case let .array(values):
            return values.count
        case let .object(object):
            return object.count
        case let .string(string):
            return string.isEmpty ? 0 : logicalLineCount(string)
        case .null:
            return 0
        case .number, .bool:
            return 1
        }
    }

    private static func isEmptyCollection(_ value: JSONValue) -> Bool {
        switch value {
        case let .array(values):
            return values.isEmpty
        case let .object(object):
            return object.isEmpty
        default:
            return false
        }
    }

    private static func languageHint(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let pathExtension = URL(fileURLWithPath: value).pathExtension.lowercased()
        let candidate = pathExtension.isEmpty ? value.lowercased() : pathExtension
        switch candidate {
        case "swift": return "swift"
        case "py", "python": return "python"
        case "js", "javascript", "mjs", "cjs": return "javascript"
        case "ts", "typescript": return "typescript"
        case "json", "jsonl": return "json"
        case "sh", "bash", "zsh", "shell": return "shell"
        case "md", "markdown": return "markdown"
        case "yaml", "yml": return "yaml"
        case "xml": return "xml"
        case "html", "htm": return "html"
        case "css": return "css"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp": return "cpp"
        case "m": return "objective-c"
        case "mm": return "objective-cpp"
        case "java": return "java"
        case "kt", "kotlin": return "kotlin"
        case "go": return "go"
        case "rs", "rust": return "rust"
        case "rb", "ruby": return "ruby"
        case "php": return "php"
        case "sql": return "sql"
        case "diff", "patch": return "diff"
        case "txt", "text": return "text"
        default: return candidate
        }
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
