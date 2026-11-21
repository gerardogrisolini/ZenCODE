//
//  MemoryTool+Arguments.swift
//  ZenCODE
//
//  Parsing of the arguments the memory tools accept.
//

import Foundation
import ToolCore

extension MemoryTool {
    static func parsedContent(from arguments: [String: JSONValue]) -> String? {
        let content = arguments["content"]?.stringValue
            ?? arguments["text"]?.stringValue
            ?? arguments["note"]?.stringValue
        return MemoryContent.normalized(content ?? "").isEmpty ? nil : content
    }

    static func parsedTags(from arguments: [String: JSONValue]) -> [String]? {
        guard let rawTags = arguments["tags"]?.arrayValue else {
            return nil
        }
        var seen = Set<String>()
        return rawTags.compactMap { value -> String? in
            guard let tag = value.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  !tag.isEmpty,
                  seen.insert(tag).inserted else {
                return nil
            }
            return tag
        }
    }

    static func parsedCategory(from arguments: [String: JSONValue]) -> MemoryCategory {
        parsedOptionalCategory(from: arguments) ?? .fact
    }

    private static func parsedOptionalCategory(from arguments: [String: JSONValue]) -> MemoryCategory? {
        switch arguments["category"]?.stringValue?.lowercased() {
        case "fact": return .fact
        case "preference": return .preference
        case "entity": return .entity
        case "correction": return .correction
        default: return nil
        }
    }

    /// Read/search narrowing: every listed tag is required; `category` is
    /// exact. Unknown category spellings are ignored rather than rejected.
    static func parsedFilter(from arguments: [String: JSONValue]) -> MemoryEntryFilter {
        MemoryEntryFilter(
            tags: parsedTags(from: arguments) ?? [],
            category: parsedOptionalCategory(from: arguments)
        )
    }

    static func parsedOffset(from arguments: [String: JSONValue]) -> Int {
        let raw = arguments["offset"]?.numberValue ?? 0
        guard raw.isFinite, raw > 0 else { return 0 }
        return Int(exactly: min(raw, 1_000_000).rounded(.towardZero)) ?? 0
    }

    /// Prepends the journal `Timestamp:` annotation when the author omitted it,
    /// reporting whether it actually generated one.
    static func contentWithTimestampIfNeeded(
        _ content: String,
        context: MemoryToolContext
    ) -> (content: String, generatedTimestamp: Bool) {
        guard !contentContainsTimestamp(content) else {
            return (content, false)
        }

        let stamped = """
        \(MemoryAutoTimestamp.line(for: context.currentDate, timeZone: context.currentTimeZone))
        \(content)
        """
        return (stamped, true)
    }

    private static func contentContainsTimestamp(_ content: String) -> Bool {
        MemoryEntryMetadata(content: content).timestamp != nil
    }

    static func parsedIncludeArchived(from arguments: [String: JSONValue]) -> Bool {
        arguments["includeArchived"]?.boolValue
            ?? arguments["include_archived"]?.boolValue
            ?? false
    }

    static func parsedDetail(from arguments: [String: JSONValue]) -> RenderDetail {
        let rawValue = arguments["detail"]?.stringValue
            ?? arguments["mode"]?.stringValue
            ?? RenderDetail.full.rawValue
        return RenderDetail(rawValue: rawValue.lowercased()) ?? .full
    }

    static func parsedLimit(from arguments: [String: JSONValue]) -> Int {
        let rawLimit = arguments["limit"]?.numberValue ?? 8
        guard rawLimit.isFinite else {
            return 8
        }
        let clampedLimit = min(max(rawLimit, 1), 50)
        return Int(exactly: clampedLimit.rounded(.towardZero)) ?? 8
    }
}
