//
//  AgentsContextService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct AgentsContextDocument: Hashable, Sendable {
    public enum Scope: String, Hashable, Sendable {
        case global
        case project
    }

    public let scope: Scope
    public let fileURL: URL
    public let content: String
    public let digest: String
}

public final class AgentsContextService {
    public static let filename = "AGENTS.md"

    public static var defaultGlobalAgentsContent: String {
        """
        # AGENTS.md

        ## Global Operating Rules

        - You are ZenCODE, a coding agent running on the user's machine.
        - Work as a careful assistant: do what the user asked, do not invent extra requirements, and do not expand scope without a clear reason.
        - Ground conclusions and edits in current files, tool output, user messages, and loaded persistent context rather than guesses.
        - Briefly explain the intent behind non-obvious or risky actions before making them.
        - Ask focused questions when they help; otherwise make conservative choices that fit the project.
        - Treat the current working directory as the default root for local filesystem, shell, search, Git, and workspace-scoped work.
        - Prefer live evidence from files, Git state, build output, tests, and tool results over assumptions or stale context.
        - Preserve unrelated user changes and do not revert work you did not make.
        - Keep edits scoped to the user's request and follow existing project patterns.
        - Use available tools when needed, and ask before destructive or irreversible actions.

        ## Commands

        - For Xcode projects, use the Xcode tool for builds, tests, diagnostics, and file navigation whenever it is active.
        - Use `xcodebuild` only as a CLI fallback when the Xcode tool is not active or unavailable.
        """
    }

    private let fileManager: FileManager
    private let globalAgentsDirectoryURL: URL?

    public init(
        fileManager: FileManager = .default,
        globalAgentsDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.globalAgentsDirectoryURL = globalAgentsDirectoryURL
    }

    public func promptSection(
        for workspaceContext: XcodeWorkspaceContext?
    ) -> String? {
        promptSection(workspaceRootURL: workspaceRootURL(for: workspaceContext))
    }

    public func promptSection(
        workingDirectory: URL?
    ) -> String? {
        promptSection(workspaceRootURL: workingDirectory?.standardizedFileURL)
    }

    public func promptSection(
        workspaceRootURL: URL?
    ) -> String? {
        let documents = agentsDocuments(workspaceRootURL: workspaceRootURL)
        guard !documents.isEmpty else {
            return nil
        }

        let renderedDocuments = documents
            .compactMap(renderDocument)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !renderedDocuments.isEmpty else {
            return nil
        }

        return """
        Persistent operating context:
        Apply the global context first. If project context is present, treat it as additive project-specific guidance rather than a replacement.
        Use this context silently. Do not mention, summarize, or justify actions by referencing its source files unless the user explicitly asks about them.

        \(renderedDocuments)

        If global and project context conflict, prefer the more specific project instruction only when it is clearly about this project and does not contradict the user's current request or direct tool evidence.
        """
    }

    public func fingerprint(
        for workspaceContext: XcodeWorkspaceContext?
    ) -> String? {
        fingerprint(workspaceRootURL: workspaceRootURL(for: workspaceContext))
    }

    public func fingerprint(
        workspaceRootURL: URL?
    ) -> String? {
        let fingerprints = agentsDocuments(workspaceRootURL: workspaceRootURL)
            .map { "\($0.scope.rawValue):\($0.digest)" }
        return fingerprints.isEmpty ? nil : fingerprints.joined(separator: "|")
    }

    public func agentsDocuments(
        workspaceRootURL: URL?
    ) -> [AgentsContextDocument] {
        var documents: [AgentsContextDocument] = []

        if let globalDocument = globalDocumentCreatingIfNeeded() {
            documents.append(globalDocument)
        }

        if let workspaceRootURL,
           let projectDocument = document(
            at: workspaceRootURL
                .standardizedFileURL
                .appendingPathComponent(Self.filename),
            scope: .project
           ),
           projectDocument.fileURL != documents.first?.fileURL {
            documents.append(projectDocument)
        }

        return documents
    }

    @discardableResult
    public func ensureGlobalAgentsFileExists() -> URL? {
        let fileURL = globalAgentsFileURL()

        if fileManager.fileExists(atPath: fileURL.path),
           let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedContent.isEmpty {
                return fileURL
            }
        }

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.defaultGlobalAgentsContent
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .appending("\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    public func globalAgentsFileURL() -> URL {
        globalAgentsDirectoryURLResolved()
            .appendingPathComponent(Self.filename)
            .standardizedFileURL
    }

    private func globalDocumentCreatingIfNeeded() -> AgentsContextDocument? {
        guard let fileURL = ensureGlobalAgentsFileExists() else {
            return nil
        }
        return document(at: fileURL, scope: .global)
    }

    private func document(
        at fileURL: URL,
        scope: AgentsContextDocument.Scope
    ) -> AgentsContextDocument? {
        let standardizedFileURL = fileURL.standardizedFileURL
        guard fileManager.fileExists(atPath: standardizedFileURL.path),
              let content = try? String(contentsOf: standardizedFileURL, encoding: .utf8) else {
            return nil
        }

        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else {
            return nil
        }

        return AgentsContextDocument(
            scope: scope,
            fileURL: standardizedFileURL,
            content: normalizedContent,
            digest: Self.digest(normalizedContent)
        )
    }

    private func renderDocument(_ document: AgentsContextDocument) -> String? {
        let title: String
        switch document.scope {
        case .global:
            title = "Global context"
        case .project:
            title = "Project context"
        }
        let content = runtimePromptContent(from: document.content)
        guard !content.isEmpty else {
            return nil
        }

        return """
        \(title):
        \(content)
        """
    }

    private func runtimePromptContent(from content: String) -> String {
        var filteredLines: [String] = []
        var skippingRuntimeOnlySection = false

        for line in content.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let headingTitle = Self.headingTitle(from: trimmedLine) {
                let normalizedHeading = Self.normalizedHeading(headingTitle)
                if normalizedHeading == "agents-md" {
                    skippingRuntimeOnlySection = false
                    continue
                }
                skippingRuntimeOnlySection = normalizedHeading == "context-strategy"
                if skippingRuntimeOnlySection {
                    continue
                }
            }

            if skippingRuntimeOnlySection || Self.isRuntimeOnlyAgentsMetaLine(trimmedLine) {
                continue
            }

            filteredLines.append(line)
        }

        return Self.collapsedBlankLines(in: filteredLines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headingTitle(from line: String) -> String? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("#") else {
            return nil
        }

        let markerCount = trimmedLine.prefix { $0 == "#" }.count
        guard markerCount > 0,
              markerCount <= 3,
              trimmedLine.dropFirst(markerCount).first == " " else {
            return nil
        }

        let title = trimmedLine
            .dropFirst(markerCount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func normalizedHeading(_ heading: String) -> String {
        heading
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isRuntimeOnlyAgentsMetaLine(_ line: String) -> Bool {
        let foldedLine = line
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        guard foldedLine.contains("agents.md")
            || foldedLine.contains("this file")
            || foldedLine.contains("cross-project behavior") else {
            return false
        }

        let runtimeOnlyMarkers = [
            "complement",
            "duplicate",
            "project-specific facts",
            "generic coding workflow",
            "keep only",
            "keep this file",
            "put cross-project",
            "cross-project behavior"
        ]
        return runtimeOnlyMarkers.contains { foldedLine.contains($0) }
    }

    private static func collapsedBlankLines(in content: String) -> String {
        var lines: [String] = []
        var previousWasBlank = false

        for line in content.components(separatedBy: .newlines) {
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank, previousWasBlank {
                continue
            }
            lines.append(line)
            previousWasBlank = isBlank
        }

        return lines.joined(separator: "\n")
    }

    private func workspaceRootURL(for workspaceContext: XcodeWorkspaceContext?) -> URL? {
        guard let path = XcodeWorkspaceContext.normalizedProjectRootPath(
            explicitPath: workspaceContext?.workspacePath,
            workspacePath: workspaceContext?.workspacePath
        ) else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func globalAgentsDirectoryURLResolved() -> URL {
        if let globalAgentsDirectoryURL {
            return globalAgentsDirectoryURL.standardizedFileURL
        }

        return AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
    }

    private static func digest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
