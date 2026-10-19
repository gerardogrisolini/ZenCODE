import Foundation
import ToolCore

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    func flattenedText() -> String {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return String(format: "%g", value)
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return ""
        case let .array(values):
            return values
                .map { $0.flattenedText() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case let .object(object):
            if let text = object["text"]?.stringValue {
                return text
            }
            if object["type"]?.stringValue == "hardBreak" {
                return "\n"
            }
            if let content = object["content"]?.arrayValue {
                let separator = blockSeparatingTypes.contains(object["type"]?.stringValue ?? "") ? "\n" : " "
                return content
                    .map { $0.flattenedText() }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: separator)
            }
            if let name = object["name"]?.stringValue {
                return name
            }
            if let displayName = object["displayName"]?.stringValue {
                return displayName
            }
            if let value = object["value"]?.stringValue {
                return value
            }
            if let url = object["url"]?.stringValue {
                return url
            }
            return object
                .sorted { $0.key < $1.key }
                .map { $0.value.flattenedText() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

        @unknown default:
            return ""
        }
    }

    private var blockSeparatingTypes: Set<String> {
        [
            "paragraph",
            "bulletList",
            "orderedList",
            "listItem",
            "blockquote",
            "heading",
            "panel"
        ]
    }
}

extension Array where Element == String {
    func deduplicated() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in self {
            guard let normalized = value.nilIfBlank else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                result.append(normalized)
            }
        }
        return result
    }
}
