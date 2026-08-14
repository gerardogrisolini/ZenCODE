//
//  ProjectContextFileService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum ProjectContextFileKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case agents
    case memory

    public static var allCases: [ProjectContextFileKind] {
        [.agents, .memory]
    }

    public var id: String {
        rawValue
    }

    public var filename: String {
        switch self {
        case .agents:
            return AgentsContextService.filename
        case .memory:
            return MemoryService.filename
        }
    }

    /// Whether this service may create or replace the file on disk.
    ///
    /// `MEMORY.md` is a legacy journal: the graph store imports it read-only,
    /// exactly once, and durable memory then lives in the engine graph. Nothing
    /// in ZenCODE writes the journal back, so the writing entry points must
    /// refuse it rather than resurrect a second source of truth — or, worse,
    /// overwrite a user's journal with a template before it was imported.
    public var supportsDocumentWrites: Bool {
        switch self {
        case .agents:
            return true
        case .memory:
            return false
        }
    }
}

public struct ProjectContextDocument: Hashable, Sendable {
    public struct Section: Hashable, Sendable {
        public let title: String
        public let content: String
    }

    public let kind: ProjectContextFileKind
    public let rootURL: URL
    public let fileURL: URL
    public let content: String
    public let sections: [Section]
    public let digest: String
}

public struct ProjectContextFileService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func document(
        kind: ProjectContextFileKind,
        at rootURL: URL
    ) -> ProjectContextDocument? {
        let standardizedRootURL = rootURL.standardizedFileURL
        let fileURL = standardizedRootURL.appendingPathComponent(kind.filename)
        guard case let .loaded(content) = readContextFile(at: fileURL, fileManager: fileManager) else {
            return nil
        }

        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else {
            return nil
        }

        return ProjectContextDocument(
            kind: kind,
            rootURL: standardizedRootURL,
            fileURL: fileURL.standardizedFileURL,
            content: normalizedContent,
            sections: Self.sections(from: normalizedContent),
            digest: Self.digest(normalizedContent)
        )
    }

    public func createDefaultDocument(
        kind: ProjectContextFileKind,
        at rootURL: URL,
        projectName: String
    ) throws -> ProjectContextDocument {
        let standardizedRootURL = rootURL.standardizedFileURL
        let fileURL = standardizedRootURL.appendingPathComponent(kind.filename)
        switch readContextFile(at: fileURL, fileManager: fileManager) {
        case .missing:
            // MEMORY.md is only imported. In particular this legacy generic
            // initializer must not create an empty journal just because the
            // caller asked for the default document.
            guard kind.supportsDocumentWrites else {
                throw CocoaError(.fileNoSuchFile)
            }
            break
        case .unreadable:
            throw ProjectContextFileServiceError.unreadableDocument(fileURL)
        case .loaded:
            if let existingDocument = document(kind: kind, at: standardizedRootURL) {
                return existingDocument
            }
            throw ProjectContextFileServiceError.emptyDocument(fileURL)
        }

        return try writeDefaultDocument(
            kind: kind,
            at: standardizedRootURL,
            projectName: projectName
        )
    }

    public func regenerateDefaultDocument(
        kind: ProjectContextFileKind,
        at rootURL: URL,
        projectName: String
    ) throws -> ProjectContextDocument {
        let standardizedRootURL = rootURL.standardizedFileURL
        try Self.requireWritable(
            kind,
            at: standardizedRootURL.appendingPathComponent(kind.filename)
        )
        return try writeDefaultDocument(
            kind: kind,
            at: standardizedRootURL,
            projectName: projectName
        )
    }

    public func materializeDocument(
        kind: ProjectContextFileKind,
        content: String,
        at rootURL: URL
    ) throws -> ProjectContextDocument {
        let standardizedRootURL = rootURL.standardizedFileURL
        let fileURL = standardizedRootURL.appendingPathComponent(kind.filename)
        try Self.requireWritable(kind, at: fileURL)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else {
            throw CocoaError(.fileWriteUnknown)
        }

        try normalizedContent.write(to: fileURL, atomically: true, encoding: .utf8)

        guard let document = document(kind: kind, at: standardizedRootURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return document
    }

    public static func sections(from markdown: String) -> [ProjectContextDocument.Section] {
        var sections: [ProjectContextDocument.Section] = []
        var currentTitle: String?
        var currentLines: [String] = []

        func flush() {
            guard let title = currentTitle else {
                currentLines.removeAll()
                return
            }

            let content = currentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(ProjectContextDocument.Section(title: title, content: content))
            currentLines.removeAll()
        }

        for line in markdown.components(separatedBy: .newlines) {
            if let heading = line.markdownHeadingTitle() {
                flush()
                currentTitle = heading
            } else {
                currentLines.append(line)
            }
        }

        flush()
        return sections
    }

    /// Compatibility content for generic context-file callers. ZenCODE never
    /// uses this API to initialize a project `AGENTS.md`: `/agents-md` asks
    /// the active model to inspect the workspace and author supported guidance.
    public static func defaultContent(
        kind: ProjectContextFileKind,
        projectName: String,
        rootPath: String,
        fileManager: FileManager = .default
    ) -> String {
        switch kind {
        case .agents:
            // Preserve the existing API without inferring a project name,
            // ecosystem, layout, commands, or other workspace facts.
            return "# AGENTS.md\n"
        case .memory:
            return MemoryService.defaultProjectMemoryContent
        }
    }

    private func writeDefaultDocument(
        kind: ProjectContextFileKind,
        at rootURL: URL,
        projectName: String
    ) throws -> ProjectContextDocument {
        let standardizedRootURL = rootURL.standardizedFileURL
        let fileURL = standardizedRootURL.appendingPathComponent(kind.filename)
        // Belt and braces: the public entry points already refused a read-only
        // kind, and this stops a future caller from bypassing them.
        try Self.requireWritable(kind, at: fileURL)
        let content = Self.defaultContent(
            kind: kind,
            projectName: projectName,
            rootPath: standardizedRootURL.path,
            fileManager: fileManager
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        guard let document = document(kind: kind, at: standardizedRootURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return document
    }

    public static func digest(_ value: String) -> String {
        String(format: "%016llx", fnv1aHash(value))
    }

    /// Fails before touching the file system for a kind this service only reads.
    private static func requireWritable(
        _ kind: ProjectContextFileKind,
        at fileURL: URL
    ) throws {
        guard kind.supportsDocumentWrites else {
            // Keep the public error enum source-compatible. This generic Cocoa
            // error still tells writing entry points to leave the import-only
            // journal untouched without adding a new public enum case.
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

public enum ProjectContextFileServiceError: LocalizedError {
    case unreadableDocument(URL)
    case emptyDocument(URL)

    public var errorDescription: String? {
        switch self {
        case let .unreadableDocument(url):
            return "Context file could not be read safely at \(url.path); it was left unchanged."
        case let .emptyDocument(url):
            return "Context file already exists but is empty at \(url.path); it was left unchanged."
        }
    }
}
