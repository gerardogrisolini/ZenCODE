//
//  XcodeIndentationRetrySupport.swift
//  ZenCODE
//

import Foundation
import ToolCore

public nonisolated func xcodeClosestMatchSnippetFromMessage(
    _ message: String?
) -> String? {
    guard let message,
          let markerRange = message.range(of: "Closest match found") else {
        return nil
    }

    let snippetStart = message[markerRange.upperBound...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !snippetStart.isEmpty else {
        return nil
    }

    var lines = snippetStart.components(separatedBy: .newlines)
    if let firstLine = lines.first,
       !xcodeReadLinePrefixMatch(in: firstLine).matches {
        lines.removeFirst()
    }

    return lines
        .map { line in
            line.replacingOccurrences(
                of: #"^\s*\d+\t?"#,
                with: "",
                options: .regularExpression
            )
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .newlines)
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

nonisolated func xcodeMutationResultNeedsIndentationRetry(
    _ object: [String: JSONValue]
) -> Bool {
    let editsApplied = Int(object["editsApplied"]?.numberValue ?? 0)
    if editsApplied > 0 {
        return false
    }

    if let success = object["success"]?.boolValue {
        return success == false
    }

    return object["message"]?.stringValue?.contains("Closest match found") == true
}
