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
            elements: elements
        )
    }

    public static func resolve(
        call: DirectAgentToolCall,
        result: DirectAgentToolResult? = nil,
        mode: ToolPresentationMode
    ) -> ResolvedToolPresentation {
        guard let presentation = call.presentation else {
            return genericPresentation(call: call, result: result, mode: mode)
        }
        return resolve(presentation, call: call, result: result, mode: mode)
    }

    private static func genericPresentation(
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
            elements: elements
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
        case .composite:
            root = compositeValue(for: definition, call: call, result: result)
        }

        let selected: JSONValue?
        if definition.source == .arguments,
           !definition.keyPaths.isEmpty,
           let root {
            switch definition.selection ?? .first {
            case .first:
                selected = definition.keyPaths.lazy.compactMap {
                    value(at: $0, in: root)
                }.first
            case .collect:
                selected = collectedValue(
                    keyPaths: definition.keyPaths,
                    root: root
                )
            case .perItemFirst:
                selected = perItemValue(
                    collectionKeyPaths: definition.keyPaths,
                    itemKeyPaths: definition.itemKeyPaths ?? [],
                    root: root
                )
            }
        } else {
            selected = root
        }

        if let selected, !isEmptyPresentationValue(selected) {
            return selected
        }
        return definition.fallback.map(JSONValue.string)
    }

    private static func compositeValue(
        for definition: ToolPresentationValueDefinition,
        call: DirectAgentToolCall,
        result: DirectAgentToolResult?
    ) -> JSONValue? {
        let components = definition.components ?? []
        switch definition.composition {
        case .firstAvailable:
            return components.lazy.compactMap {
                displayString(for: $0, call: call, result: result)
            }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(JSONValue.string)
        case .joined:
            let values = components.compactMap {
                displayString(for: $0, call: call, result: result)
            }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !values.isEmpty else {
                return nil
            }
            return .string(values.joined(separator: definition.separator ?? " "))
        case .collected:
            let values = components.compactMap {
                rawValue(for: $0, call: call, result: result)
            }.flatMap { value -> [JSONValue] in
                if case let .array(items) = value {
                    return items
                }
                return [value]
            }
            let deduplicatedValues = deduplicated(values)
            return deduplicatedValues.isEmpty ? nil : .array(deduplicatedValues)
        case nil:
            return nil
        }
    }

    private static func collectedValue(
        keyPaths: [String],
        root: JSONValue
    ) -> JSONValue? {
        var values: [JSONValue] = []
        for keyPath in keyPaths {
            guard let value = value(at: keyPath, in: root) else {
                continue
            }
            if case let .array(items) = value {
                values.append(contentsOf: items)
            } else {
                values.append(value)
            }
        }
        let deduplicatedValues = deduplicated(values)
        return deduplicatedValues.isEmpty ? nil : .array(deduplicatedValues)
    }

    private static func perItemValue(
        collectionKeyPaths: [String],
        itemKeyPaths: [String],
        root: JSONValue
    ) -> JSONValue? {
        guard !itemKeyPaths.isEmpty,
              let collection = collectionKeyPaths.lazy.compactMap({
                  value(at: $0, in: root)
              }).first,
              case let .array(items) = collection else {
            return nil
        }
        let values = items.compactMap { item in
            itemKeyPaths.lazy.compactMap { value(at: $0, in: item) }.first
        }
        let deduplicatedValues = deduplicated(values)
        return deduplicatedValues.isEmpty ? nil : .array(deduplicatedValues)
    }

    private static func deduplicated(_ values: [JSONValue]) -> [JSONValue] {
        var seen = Set<JSONValue>()
        return values.filter { value in
            !isEmptyPresentationValue(value) && seen.insert(value).inserted
        }
    }

    private static func isEmptyPresentationValue(_ value: JSONValue) -> Bool {
        switch value {
        case .null:
            return true
        case let .string(value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .array(values):
            return values.isEmpty
        case let .object(values):
            return values.isEmpty
        case .bool, .number:
            return false
        }
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
        let rendered: String?
        switch definition.format {
        case .automatic, .text, .path, .command, .url:
            rendered = plainText(value, separator: definition.separator)
        case .json:
            rendered = value.prettyPrinted()
        case .stringList:
            if case let .array(values) = value {
                let strings = values.compactMap { plainText($0) }
                rendered = strings.joined(separator: definition.separator ?? ", ")
            } else {
                rendered = plainText(value, separator: definition.separator)
            }
        case .firstLine:
            rendered = plainText(value).map(firstLine)
        case .lineCount:
            rendered = plainText(value).map { String(logicalLineCount($0)) }
        case .itemCount:
            rendered = String(itemCount(value))
        case .languageHint:
            rendered = plainText(value).flatMap(languageHint)
        case .patchPaths:
            rendered = plainText(value).flatMap(patchDisplayTarget)
        }
        guard let rendered else {
            return nil
        }
        return (definition.prefix ?? "") + rendered + (definition.suffix ?? "")
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

    private static func patchDisplayTarget(_ rawPatch: String) -> String? {
        var seen = Set<String>()
        var paths: [String] = []
        func append(_ rawValue: String) {
            var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != "/dev/null" else { return }
            if value.hasPrefix("a/") || value.hasPrefix("b/") {
                value = String(value.dropFirst(2))
            }
            guard !value.isEmpty,
                  value != "/dev/null",
                  seen.insert(value).inserted else { return }
            paths.append(value)
        }
        for line in rawPatch.components(separatedBy: "\n") {
            let prefixes = [
                "*** Add File: ", "*** Update File: ", "*** Delete File: ",
                "+++ ", "--- "
            ]
            if let prefix = prefixes.first(where: { line.hasPrefix($0) }) {
                append(String(line.dropFirst(prefix.count)))
            }
        }
        guard let first = paths.first else { return nil }
        return paths.count == 1 ? first : "\(first) (+\(paths.count - 1) more)"
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
