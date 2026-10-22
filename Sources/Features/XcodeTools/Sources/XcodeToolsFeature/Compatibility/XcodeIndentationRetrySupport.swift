//
//  XcodeIndentationRetrySupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Extracts the code snippet that follows Xcode's "Closest match found"
/// marker. Text on the marker's own line (`:`/`at line 12:`) is header, every
/// following line belongs to the snippet. Line numbers are stripped only when
/// the snippet is actually numbered in the `XcodeRead` format, so a plain
/// snippet whose code starts with a digit (`0.5 * x`) is left intact.
public nonisolated func xcodeClosestMatchSnippetFromMessage(
    _ message: String?
) -> String? {
    guard let message,
          let markerRange = message.range(of: "Closest match found") else {
        return nil
    }

    var lines = message[markerRange.upperBound...].components(separatedBy: .newlines)
    let headerRemainder = lines.removeFirst()
    if lines.isEmpty, xcodeReadLinePrefixMatch(in: headerRemainder).matches {
        lines = [headerRemainder]
    }

    let isNumbered = lines.contains { xcodeReadLinePrefixMatch(in: $0).matches }
    let snippet = lines
        .map { line in
            guard isNumbered else {
                return line
            }
            return line.replacingOccurrences(
                of: #"^\s*\d+\t?"#,
                with: "",
                options: .regularExpression
            )
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .newlines)
    return snippet.isEmpty ? nil : snippet
}

nonisolated func indentationInsensitiveSnippetEquivalent(
    _ lhs: String,
    _ rhs: String
) -> Bool {
    let lhsLines = lhs
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let rhsLines = rhs
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    guard lhsLines.count == rhsLines.count else {
        return false
    }

    for (lhsLine, rhsLine) in zip(lhsLines, rhsLines) {
        guard lhsLine.trimmingCharacters(in: .whitespaces)
                == rhsLine.trimmingCharacters(in: .whitespaces) else {
            return false
        }
    }

    return true
}

nonisolated func indentationAdjustedReplacementSnippet(
    originalOldString: String,
    originalNewString: String,
    matchedOldString: String
) -> String? {
    guard indentationInsensitiveSnippetEquivalent(
        originalOldString,
        matchedOldString
    ) else {
        return nil
    }

    let oldLines = originalOldString
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let newLines = originalNewString
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let matchedLines = matchedOldString
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)

    guard oldLines.count == matchedLines.count else {
        return nil
    }

    return indentationAdjustedReplacementLines(
        oldLines: oldLines,
        newLines: newLines,
        matchedLines: matchedLines
    ).joined(separator: "\n")
}

nonisolated func indentationAdjustedReplacementLines(
    oldLines: [String],
    newLines: [String],
    matchedLines: [String]
) -> [String] {
    var indentationByOldLevel: [Int: String] = [:]
    for (oldLine, matchedLine) in zip(oldLines, matchedLines) {
        let trimmedOldLine = oldLine.trimmingCharacters(in: .whitespaces)
        guard !trimmedOldLine.isEmpty else {
            continue
        }

        let oldLevel = leadingWhitespacePrefix(in: oldLine).count
        indentationByOldLevel[oldLevel] = indentationByOldLevel[oldLevel]
            ?? leadingWhitespacePrefix(in: matchedLine)
    }

    let defaultIndentation = matchedLines.first(where: {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }).map(leadingWhitespacePrefix(in:)) ?? ""

    return newLines.enumerated().map { index, newLine in
        let trimmedNewLine = newLine.trimmingCharacters(in: .whitespaces)
        guard !trimmedNewLine.isEmpty else {
            return ""
        }

        let newLevel = leadingWhitespacePrefix(in: newLine).count
        let matchedLineIndentation: String?
        if matchedLines.indices.contains(index) {
            matchedLineIndentation = leadingWhitespacePrefix(in: matchedLines[index])
        } else {
            matchedLineIndentation = nil
        }
        let resolvedIndentation =
            indentationByOldLevel[newLevel]
            ?? matchedLineIndentation
            ?? defaultIndentation

        return resolvedIndentation + trimmedNewLine
    }
}

nonisolated func xcodeMutationResultObject(
    from result: JSONValue
) -> [String: JSONValue]? {
    guard let rootObject = result.objectValue else {
        return nil
    }

    if let structuredObject = rootObject["structuredContent"]?.objectValue {
        return structuredObject
    }

    return rootObject
}

/// The human-readable message of a mutation result: the structured `message`
/// when present, otherwise the text items of a standard MCP `content` array
/// (which is where `isError` results carry their explanation).
nonisolated func xcodeMutationResultMessage(
    from result: JSONValue
) -> String? {
    guard let rootObject = result.objectValue else {
        return nil
    }
    if let message = xcodeMutationResultObject(from: result)?["message"]?.stringValue
        ?? rootObject["message"]?.stringValue {
        return message
    }
    guard case let .array(items) = rootObject["content"] else {
        return nil
    }
    let texts = items.compactMap { $0.objectValue?["text"]?.stringValue }
    return texts.isEmpty ? nil : texts.joined(separator: "\n")
}

nonisolated func xcodeMutationResultNeedsIndentationRetry(
    _ object: [String: JSONValue],
    message: String? = nil
) -> Bool {
    let rawEditsApplied = object["editsApplied"]?.numberValue ?? 0
    if rawEditsApplied.isFinite, rawEditsApplied > 0 {
        return false
    }

    if let success = object["success"]?.boolValue {
        return success == false
    }

    return (message ?? object["message"]?.stringValue)?.contains("Closest match found") == true
}
