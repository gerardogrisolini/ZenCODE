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

nonisolated func toolRequestUsesWorkspaceRelativePaths(
    _ toolName: String
) -> Bool {
    toolName.hasPrefix("local.")
        || toolName.hasPrefix("search.")
        || toolName.hasPrefix("text.")
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

    let path: String
    if rawValue.hasPrefix("file://"),
       let url = URL(string: rawValue),
       url.isFileURL {
        path = url.path
    } else {
        path = rawValue
    }

    return URL(fileURLWithPath: path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
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
