//
//  ToolRequestCompatibilitySupport+PathSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

nonisolated let workspaceRelativePathArgumentKeys: Set<String> = [
    "cwd",
    "destinationPath",
    "destination_path",
    "dir",
    "directory",
    "directoryPath",
    "directory_path",
    "filePath",
    "file_path",
    "path",
    "sourcePath",
    "sourceFilePath",
    "source_file_path",
    "source_path",
    "workingDirectory",
    "working_directory"
]

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
    guard let rootObject = result.mlxObjectValue else {
        return nil
    }

    if let structuredObject = rootObject["structuredContent"]?.mlxObjectValue {
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

nonisolated func toolRequestUsesWorkspaceRelativePaths(
    _ toolName: String
) -> Bool {
    toolName.hasPrefix("local.")
        || toolName.hasPrefix("search.")
        || toolName.hasPrefix("text.")
        || toolName.hasPrefix("Xcode")
        || toolName == "ExecuteSnippet"
        || toolName == "RenderPreview"
}

nonisolated func toolRequestUsesSkillRelativePaths(
    _ toolName: String
) -> Bool {
    toolName.hasPrefix("local.")
        || toolName.hasPrefix("search.")
        || toolName.hasPrefix("text.")
}

nonisolated func normalizedWorkspaceRootPath(
    _ rawValue: String?
) -> String? {
    guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawValue.isEmpty else {
        return nil
    }

    return XcodeWorkspaceContext.normalizedProjectRootPath(
        explicitPath: rawValue,
        workspacePath: rawValue
    )
}

public nonisolated func shouldDropLeadingMissingWorkspaceContainer(
    _ firstComponent: String,
    workspaceRootURL: URL?
) -> Bool {
    let trimmedComponent = firstComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedComponent.isEmpty else {
        return false
    }

    let foldedComponent = trimmedComponent.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
    )
    if let workspaceRootURL {
        let foldedRootName = workspaceRootURL.lastPathComponent.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if !foldedRootName.isEmpty, foldedComponent == foldedRootName {
            return true
        }
    }

    if trimmedComponent.contains("_") {
        return true
    }

    if trimmedComponent.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) {
        return true
    }

    return trimmedComponent.contains(where: \.isUppercase)
}

nonisolated func normalizedWorkspaceRelativeToolPath(
    _ rawPath: String,
    workspaceRootPath: String?
) -> String? {
    guard let workspaceRootPath = normalizedWorkspaceRootPath(workspaceRootPath) else {
        return nil
    }

    let workspaceRootURL = URL(fileURLWithPath: workspaceRootPath).standardizedFileURL
    let directURL = workspaceRootURL.appendingPathComponent(rawPath).standardizedFileURL
    if FileManager.default.fileExists(atPath: directURL.path) {
        return nil
    }

    if let collapsedDuplicatedRootPath = normalizedRelativePathAvoidingDuplicatedWorkspaceRoot(
        rawPath,
        workspaceRootURL: workspaceRootURL
    ) {
        return collapsedDuplicatedRootPath
    }

    return normalizedRelativePathByDroppingLeadingMissingWorkspaceContainer(
        rawPath,
        workspaceRootURL: workspaceRootURL
    )
}

nonisolated func normalizedRelativePathAvoidingDuplicatedWorkspaceRoot(
    _ rawPath: String,
    workspaceRootURL: URL
) -> String? {
    let rootName = workspaceRootURL.lastPathComponent
    guard !rootName.isEmpty else {
        return nil
    }

    let components = rawPath
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
    guard components.count >= 2,
          components[0] == rootName,
          components[1] == rootName else {
        return nil
    }

    let directURL = workspaceRootURL.appendingPathComponent(rawPath).standardizedFileURL
    if FileManager.default.fileExists(atPath: directURL.path) {
        return nil
    }

    let collapsedPath = components.dropFirst().joined(separator: "/")
    guard !collapsedPath.isEmpty else {
        return nil
    }

    let collapsedURL = workspaceRootURL.appendingPathComponent(collapsedPath).standardizedFileURL
    let collapsedParentURL = collapsedURL.deletingLastPathComponent()
    let directParentURL = directURL.deletingLastPathComponent()

    let collapsedExists = FileManager.default.fileExists(atPath: collapsedURL.path)
    let collapsedParentExists = FileManager.default.fileExists(atPath: collapsedParentURL.path)
    let directParentExists = FileManager.default.fileExists(atPath: directParentURL.path)

    guard collapsedExists || (collapsedParentExists && !directParentExists) else {
        return nil
    }

    return collapsedPath
}

nonisolated func normalizedRelativePathByDroppingLeadingMissingWorkspaceContainer(
    _ rawPath: String,
    workspaceRootURL: URL
) -> String? {
    let components = rawPath
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
    guard components.count >= 2 else {
        return nil
    }

    let directURL = workspaceRootURL.appendingPathComponent(rawPath).standardizedFileURL
    if FileManager.default.fileExists(atPath: directURL.path) {
        return nil
    }

    let firstComponentURL = workspaceRootURL
        .appendingPathComponent(components[0])
        .standardizedFileURL
    guard !FileManager.default.fileExists(atPath: firstComponentURL.path) else {
        return nil
    }
    guard shouldDropLeadingMissingWorkspaceContainer(
        components[0],
        workspaceRootURL: workspaceRootURL
    ) else {
        return nil
    }

    let collapsedPath = components.dropFirst().joined(separator: "/")
    guard !collapsedPath.isEmpty else {
        return nil
    }

    let collapsedURL = workspaceRootURL.appendingPathComponent(collapsedPath).standardizedFileURL
    let collapsedParentURL = collapsedURL.deletingLastPathComponent()
    let directParentURL = directURL.deletingLastPathComponent()

    let collapsedExists = FileManager.default.fileExists(atPath: collapsedURL.path)
    let collapsedParentExists = FileManager.default.fileExists(atPath: collapsedParentURL.path)
    let directParentExists = FileManager.default.fileExists(atPath: directParentURL.path)

    guard collapsedExists || (collapsedParentExists && !directParentExists) else {
        return nil
    }

    return collapsedPath
}

nonisolated func resolvedSkillRelativeToolPath(
    _ normalizedPath: String,
    skillRootURLs: [URL]
) -> String? {
    let exactMatches = skillRootURLs.compactMap { skillRootURL -> String? in
        let candidateURL = skillRootURL
            .appendingPathComponent(normalizedPath)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return nil
        }

        return candidateURL.path
    }

    guard exactMatches.count == 1 else {
        return nil
    }

    return exactMatches[0]
}
