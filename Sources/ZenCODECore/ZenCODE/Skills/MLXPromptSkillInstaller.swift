//
//  MLXPromptSkillInstaller.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation

public struct MLXPromptSkillInstallResult: Sendable {
    public let skill: MLXPromptSkill
    public let destinationURL: URL
    public let sourceURL: URL
}

public enum MLXPromptSkillInstallerError: LocalizedError, Sendable {
    case invalidGitHubURL(String)
    case gitCommandFailed(String)
    case unresolvedGitReference(String)
    case skillNotFound(String)
    case multipleSkillsFound(String)
    case unsafeSkillPath(String)
    case unsafeInstallDestination(source: String, destination: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidGitHubURL(url):
            return "Invalid GitHub skill URL: \(url)."
        case let .gitCommandFailed(message):
            return message
        case let .unresolvedGitReference(reference):
            return "Unable to resolve Git reference '\(reference)' in the skill repository."
        case let .skillNotFound(path):
            return "No SKILL.md found at \(path)."
        case let .multipleSkillsFound(path):
            return "Multiple skills found under \(path). Pass a GitHub /tree/... URL for the specific skill directory."
        case let .unsafeSkillPath(path):
            return "Refusing to install skill outside cloned repository path \(path)."
        case let .unsafeInstallDestination(source, destination):
            return "Refusing to install skill because destination \(destination) would remove source \(source)."
        }
    }
}

public enum MLXPromptSkillInstaller {
    public static func install(
        fromGitHubURL url: URL,
        fileManager: FileManager = .default
    ) async throws -> MLXPromptSkillInstallResult {
        let source = try GitHubSkillSource(url: url)
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("zencode-skill-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let cloneURL = tempRoot.appendingPathComponent("repo", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try await runGit(
            ["clone", "--quiet", source.cloneURL.absoluteString, cloneURL.path],
            timeout: 180
        )

        let sourceDirectoryURL = try await resolveSkillDirectory(
            source: source,
            cloneURL: cloneURL,
            fileManager: fileManager
        )
        return try installSkillDirectory(
            from: sourceDirectoryURL,
            sourceURL: source.originalURL,
            fileManager: fileManager
        )
    }

    public static func install(
        fromLocalURL url: URL,
        destinationRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> MLXPromptSkillInstallResult {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
            throw MLXPromptSkillInstallerError.skillNotFound(standardizedURL.path)
        }

        if !isDirectory.boolValue,
           standardizedURL.lastPathComponent != "SKILL.md" {
            throw MLXPromptSkillInstallerError.skillNotFound(standardizedURL.path)
        }

        let rootURL = isDirectory.boolValue
            ? standardizedURL
            : standardizedURL.deletingLastPathComponent().standardizedFileURL
        let sourceDirectoryURL = try singleSkillDirectory(
            under: rootURL,
            cloneRootURL: rootURL,
            fileManager: fileManager
        )

        return try installSkillDirectory(
            from: sourceDirectoryURL,
            sourceURL: standardizedURL,
            destinationRootURL: destinationRootURL,
            fileManager: fileManager
        )
    }

    static func installSkillDirectory(
        from sourceDirectoryURL: URL,
        sourceURL: URL,
        destinationRootURL explicitDestinationRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> MLXPromptSkillInstallResult {
        let standardizedSourceDirectoryURL = sourceDirectoryURL.standardizedFileURL
        let sourceSkillURL = standardizedSourceDirectoryURL
            .appendingPathComponent("SKILL.md")
            .standardizedFileURL
        let payload = try MLXPromptSkillMarkdownParser.parse(url: sourceSkillURL)
        let destinationRootURL = (
            explicitDestinationRootURL
                ?? MLXPromptSkillCatalog.appCatalogSearchRoots(fileManager: fileManager)[0]
        ).standardizedFileURL
        let destinationURL = destinationRootURL
            .appendingPathComponent(destinationDirectoryName(for: payload), isDirectory: true)
            .standardizedFileURL

        try fileManager.createDirectory(
            at: destinationRootURL,
            withIntermediateDirectories: true
        )

        let sourcePath = standardizedSourceDirectoryURL.path
        let destinationPath = destinationURL.path
        if sourcePath == destinationPath {
            return MLXPromptSkillInstallResult(
                skill: MLXPromptSkill(payload: payload),
                destinationURL: destinationURL,
                sourceURL: sourceURL
            )
        }
        if sourcePath.hasPrefix(destinationPath + "/") {
            throw MLXPromptSkillInstallerError.unsafeInstallDestination(
                source: sourcePath,
                destination: destinationPath
            )
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try copySkillDirectory(
            from: standardizedSourceDirectoryURL,
            to: destinationURL,
            fileManager: fileManager
        )

        let installedPayload = try MLXPromptSkillMarkdownParser.parse(
            url: destinationURL.appendingPathComponent("SKILL.md")
        )
        return MLXPromptSkillInstallResult(
            skill: MLXPromptSkill(payload: installedPayload),
            destinationURL: destinationURL,
            sourceURL: sourceURL
        )
    }

    static func destinationDirectoryName(for payload: MLXPromptSkillPayload) -> String {
        let candidate = payload.canonicalName.nilIfBlank
            ?? payload.title.nilIfBlank
            ?? payload.sourceHash
        let sanitized = candidate
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar)
                    ? Character(String(scalar))
                    : "-"
            }
        let normalized = String(sanitized)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        return normalized.nilIfBlank ?? payload.sourceHash
    }

    private static func resolveSkillDirectory(
        source: GitHubSkillSource,
        cloneURL: URL,
        fileManager: FileManager
    ) async throws -> URL {
        switch source.selector {
        case .none:
            return try singleSkillDirectory(
                under: cloneURL,
                cloneRootURL: cloneURL,
                fileManager: fileManager
            )
        case let .some(selector):
            let resolved = try await resolveSelector(
                selector,
                cloneURL: cloneURL
            )
            try await runGit(
                ["checkout", "--quiet", resolved.checkoutReference],
                workingDirectory: cloneURL
            )

            let selectedURL = cloneURL
                .appendingPathComponents(resolved.pathComponents, isDirectory: selector.kind == .tree)
                .standardizedFileURL
            let directoryURL = selector.kind == .blob
                ? selectedURL.deletingLastPathComponent().standardizedFileURL
                : selectedURL
            return try singleSkillDirectory(
                under: directoryURL,
                cloneRootURL: cloneURL,
                fileManager: fileManager
            )
        }
    }

    private static func resolveSelector(
        _ selector: GitHubSkillSource.Selector,
        cloneURL: URL
    ) async throws -> (checkoutReference: String, pathComponents: [String]) {
        let components = selector.components
        guard !components.isEmpty else {
            throw MLXPromptSkillInstallerError.unresolvedGitReference("")
        }

        for refLength in stride(from: components.count, through: 1, by: -1) {
            let reference = components.prefix(refLength).joined(separator: "/")
            let pathComponents = Array(components.dropFirst(refLength))
            for checkoutReference in [
                reference,
                "origin/\(reference)",
                "refs/tags/\(reference)",
                "refs/heads/\(reference)"
            ] {
                if await gitReferenceExists(checkoutReference, cloneURL: cloneURL) {
                    return (checkoutReference, pathComponents)
                }
            }
        }

        throw MLXPromptSkillInstallerError.unresolvedGitReference(
            components.joined(separator: "/")
        )
    }

    private static func gitReferenceExists(
        _ reference: String,
        cloneURL: URL
    ) async -> Bool {
        do {
            let result = try await runGitAllowingFailure(
                ["rev-parse", "--verify", "\(reference)^{commit}"],
                workingDirectory: cloneURL
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private static func singleSkillDirectory(
        under url: URL,
        cloneRootURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        let standardizedRootURL = cloneRootURL.standardizedFileURL
        guard standardizedURL.path == standardizedRootURL.path
                || standardizedURL.path.hasPrefix(standardizedRootURL.path + "/") else {
            throw MLXPromptSkillInstallerError.unsafeSkillPath(standardizedURL.path)
        }

        let directSkillURL = standardizedURL.appendingPathComponent("SKILL.md")
        if fileManager.fileExists(atPath: directSkillURL.path) {
            return standardizedURL
        }

        let skillURLs = skillMarkdownURLs(
            under: standardizedURL,
            fileManager: fileManager
        )
        guard !skillURLs.isEmpty else {
            throw MLXPromptSkillInstallerError.skillNotFound(standardizedURL.path)
        }
        guard skillURLs.count == 1,
              let skillURL = skillURLs.first else {
            throw MLXPromptSkillInstallerError.multipleSkillsFound(standardizedURL.path)
        }
        return skillURL.deletingLastPathComponent().standardizedFileURL
    }

    private static func skillMarkdownURLs(
        under url: URL,
        fileManager: FileManager
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        while let candidate = enumerator.nextObject() as? URL {
            if candidate.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard candidate.lastPathComponent == "SKILL.md" else {
                continue
            }
            urls.append(candidate.standardizedFileURL)
        }
        return urls
    }

    private static func copySkillDirectory(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }

        while let sourceChildURL = enumerator.nextObject() as? URL {
            if sourceChildURL.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }

            let relativePath = String(
                sourceChildURL.standardizedFileURL.path.dropFirst(sourceURL.standardizedFileURL.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else {
                continue
            }
            let destinationChildURL = destinationURL
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: sourceChildURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                try fileManager.createDirectory(
                    at: destinationChildURL,
                    withIntermediateDirectories: true
                )
            } else {
                try fileManager.copyItem(at: sourceChildURL, to: destinationChildURL)
            }
        }
    }

    private static func runGit(
        _ arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 60
    ) async throws {
        let result = try await runGitAllowingFailure(
            arguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw MLXPromptSkillInstallerError.gitCommandFailed(
                gitFailureMessage(result)
            )
        }
    }

    private static func runGitAllowingFailure(
        _ arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 60
    ) async throws -> AsyncProcessResult {
        try await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            workingDirectory: workingDirectory,
            timeout: timeout,
            stdoutLineLimit: 200
        )
    }

    private static func gitFailureMessage(_ result: AsyncProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = stderr.nilIfBlank ?? stdout.nilIfBlank ?? "git exited with \(result.exitCode)"
        return "Unable to install skill: \(details)"
    }
}

struct GitHubSkillSource: Equatable {
    enum SelectorKind: Equatable {
        case tree
        case blob
    }

    struct Selector: Equatable {
        var kind: SelectorKind
        var components: [String]
    }

    var originalURL: URL
    var owner: String
    var repository: String
    var cloneURL: URL
    var selector: Selector?

    init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            throw MLXPromptSkillInstallerError.invalidGitHubURL(url.absoluteString)
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else {
            throw MLXPromptSkillInstallerError.invalidGitHubURL(url.absoluteString)
        }

        let owner = pathComponents[0]
        let repositoryComponent = pathComponents[1]
        let repository = repositoryComponent.hasSuffix(".git")
            ? String(repositoryComponent.dropLast(4))
            : repositoryComponent
        guard !owner.isEmpty, !repository.isEmpty else {
            throw MLXPromptSkillInstallerError.invalidGitHubURL(url.absoluteString)
        }

        self.originalURL = url
        self.owner = owner
        self.repository = repository
        self.cloneURL = URL(string: "https://github.com/\(owner)/\(repository).git")!
        self.selector = Self.selector(from: Array(pathComponents.dropFirst(2)))
    }

    private static func selector(from pathComponents: [String]) -> Selector? {
        guard let selectorIndex = pathComponents.firstIndex(where: {
            $0 == "tree" || $0 == "blob"
        }) else {
            return nil
        }
        let kind: SelectorKind = pathComponents[selectorIndex] == "blob" ? .blob : .tree
        let components = Array(pathComponents.dropFirst(selectorIndex + 1))
        guard !components.isEmpty else {
            return nil
        }
        return Selector(kind: kind, components: components)
    }
}

private extension URL {
    func appendingPathComponents(
        _ components: [String],
        isDirectory: Bool
    ) -> URL {
        guard !components.isEmpty else {
            return self
        }

        var url = self
        for (index, component) in components.enumerated() {
            url = url.appendingPathComponent(
                component,
                isDirectory: index == components.count - 1 ? isDirectory : true
            )
        }
        return url
    }
}
