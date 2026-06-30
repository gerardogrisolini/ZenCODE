//
//  ToolRequestCompatibilitySupport+XcodeSnippetSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

nonisolated func strippedXcodeReadPrefixesIfNeeded(
    from rawValue: String
) -> String {
    let lines = rawValue.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else {
        return rawValue
    }
    guard looksLikeWrappedXcodeReadSnippet(rawValue) else {
        return rawValue
    }

    let firstNonEmptyLine = lines.first { !$0.isEmpty }
    guard let firstNonEmptyLine,
          xcodeReadLinePrefixMatch(in: firstNonEmptyLine).matches else {
        return rawValue
    }

    var strippedLines = [String]()
    var strippedAnyPrefix = false

    for line in lines {
        guard !line.isEmpty else {
            strippedLines.append(line)
            continue
        }

        let prefixMatch = xcodeReadLinePrefixMatch(in: line)
        if prefixMatch.matches {
            strippedLines.append(prefixMatch.remainingText)
            strippedAnyPrefix = true
        } else {
            strippedLines.append(line)
        }
    }

    guard strippedAnyPrefix else {
        return rawValue
    }

    return strippedLines.joined(separator: "\n")
}

nonisolated func unwrappedLikelyWrappedXcodeSnippetIfNeeded(
    from rawValue: String
) -> String? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2,
          let delimiter = trimmed.first,
          trimmed.last == delimiter,
          delimiter == "\"" || delimiter == "`" else {
        return nil
    }

    let startIndex = trimmed.index(after: trimmed.startIndex)
    let endIndex = trimmed.index(before: trimmed.endIndex)
    guard startIndex <= endIndex else {
        return nil
    }

    let unwrapped = String(trimmed[startIndex ..< endIndex])
    guard looksLikeWrappedXcodeReadSnippet(unwrapped) else {
        return nil
    }

    return unwrapped
}

nonisolated func looksLikeWrappedXcodeReadSnippet(
    _ candidate: String
) -> Bool {
    let lines = candidate
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let nonEmptyLines = lines.filter {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !nonEmptyLines.isEmpty else {
        return false
    }

    var prefixedLineCount = 0
    var sawLeadingPaddingBeforeLineNumber = false

    for line in nonEmptyLines {
        let prefixMatch = xcodeReadLinePrefixMatch(in: line)
        guard prefixMatch.matches else {
            continue
        }

        prefixedLineCount += 1
        if line.first == " " {
            sawLeadingPaddingBeforeLineNumber = true
        }
    }

    guard prefixedLineCount > 0 else {
        return false
    }

    return prefixedLineCount >= 2 || sawLeadingPaddingBeforeLineNumber
}

nonisolated func restoredLikelySwiftMemberAccessPrefixes(
    in rawValue: String
) -> String {
    let lines = rawValue.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else {
        return rawValue
    }

    var repairedLines = lines
    var blockAnchorIndents: [Int] = []
    var previousNonEmptyLine: (text: String, indent: Int)?
    var repairedAnyLine = false

    for index in repairedLines.indices {
        let originalLine = repairedLines[index]
        let trimmedLine = originalLine.trimmingCharacters(in: .whitespaces)
        guard !trimmedLine.isEmpty else {
            continue
        }

        let indentation = leadingWhitespacePrefix(in: originalLine)
        let indentCount = indentation.count

        while let lastAnchorIndent = blockAnchorIndents.last,
              indentCount < lastAnchorIndent {
            blockAnchorIndents.removeLast()
        }

        var normalizedLine = trimmedLine
        if shouldRestoreSwiftMemberAccessPrefix(
            for: trimmedLine,
            indentCount: indentCount,
            previousNonEmptyLine: previousNonEmptyLine,
            blockAnchorIndents: blockAnchorIndents
        ) {
            normalizedLine = "." + trimmedLine
            repairedLines[index] = indentation + normalizedLine
            repairedAnyLine = true
        }

        if normalizedLine == "}" {
            previousNonEmptyLine = (normalizedLine, indentCount)
            continue
        }

        if normalizedLine.hasSuffix("{"),
           isLikelySwiftExpressionAnchor(normalizedLine),
           blockAnchorIndents.last != indentCount {
            blockAnchorIndents.append(indentCount)
        }

        previousNonEmptyLine = (normalizedLine, indentCount)
    }

    guard repairedAnyLine else {
        return rawValue
    }

    return repairedLines.joined(separator: "\n")
}

nonisolated func xcodeReadLinePrefixMatch(
    in line: String
) -> (matches: Bool, remainingText: String) {
    var index = line.startIndex

    while index < line.endIndex,
          line[index] == " " {
        index = line.index(after: index)
    }

    let digitsStart = index
    while index < line.endIndex, line[index].isNumber {
        index = line.index(after: index)
    }

    guard index > digitsStart,
          index < line.endIndex,
          line[index] == "\t" else {
        return (false, line)
    }

    let remainingStart = line.index(after: index)
    return (
        true,
        String(line[remainingStart...])
    )
}

nonisolated let swiftMemberAccessExcludedKeywords: Set<String> = [
    "as",
    "await",
    "break",
    "case",
    "catch",
    "continue",
    "default",
    "defer",
    "do",
    "else",
    "fallthrough",
    "for",
    "func",
    "guard",
    "if",
    "in",
    "init",
    "let",
    "repeat",
    "return",
    "switch",
    "throw",
    "try",
    "var",
    "while"
]

nonisolated func shouldRestoreSwiftMemberAccessPrefix(
    for trimmedLine: String,
    indentCount: Int,
    previousNonEmptyLine: (text: String, indent: Int)?,
    blockAnchorIndents: [Int]
) -> Bool {
    guard isLikelySwiftMemberAccessCandidate(trimmedLine) else {
        return false
    }

    guard let previousNonEmptyLine else {
        return false
    }

    if previousNonEmptyLine.text == "}",
       blockAnchorIndents.last == indentCount {
        return true
    }

    if previousNonEmptyLine.text.hasPrefix("."),
       previousNonEmptyLine.indent == indentCount {
        return true
    }

    if indentCount > previousNonEmptyLine.indent,
       !previousNonEmptyLine.text.hasSuffix("{"),
       isLikelySwiftExpressionAnchor(previousNonEmptyLine.text) {
        return true
    }

    return false
}

nonisolated func isLikelySwiftMemberAccessCandidate(
    _ trimmedLine: String
) -> Bool {
    guard !trimmedLine.hasPrefix("."),
          let firstCharacter = trimmedLine.first,
          firstCharacter.isLowercase,
          let keyword = initialSwiftIdentifier(in: trimmedLine),
          !swiftMemberAccessExcludedKeywords.contains(keyword) else {
        return false
    }

    return trimmedLine.range(
        of: #"^[a-z][A-Za-z0-9_]*\s*(\(|\{)"#,
        options: .regularExpression
    ) != nil
}

nonisolated func isLikelySwiftExpressionAnchor(
    _ trimmedLine: String
) -> Bool {
    guard !trimmedLine.isEmpty else {
        return false
    }

    if trimmedLine.hasPrefix(".") {
        return true
    }

    if let keyword = initialSwiftIdentifier(in: trimmedLine),
       swiftMemberAccessExcludedKeywords.contains(keyword) {
        return false
    }

    return trimmedLine.range(
        of: #"^[A-Za-z_][A-Za-z0-9_\.]*\s*(\([^=]*\))?\s*\{?$"#,
        options: .regularExpression
    ) != nil
}

nonisolated func initialSwiftIdentifier(
    in trimmedLine: String
) -> String? {
    let identifierPrefix = trimmedLine.prefix { character in
        character.isLetter || character.isNumber || character == "_"
    }
    guard !identifierPrefix.isEmpty else {
        return nil
    }
    return String(identifierPrefix)
}

public nonisolated func leadingWhitespacePrefix(
    in line: String
) -> String {
    String(line.prefix { $0 == " " || $0 == "\t" })
}
