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
        guard case let .loaded(content) = readFile(at: fileURL) else {
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
        switch readFile(at: fileURL) {
        case .missing:
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
        try writeDefaultDocument(
            kind: kind,
            at: rootURL.standardizedFileURL,
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
            if let heading = headingTitle(from: line) {
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
    /// uses this API to initialize a project `AGENTS.md`: `/make-agents` asks
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

    private func readFile(at fileURL: URL) -> ProjectContextFileReadState {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        do {
            return .loaded(try String(contentsOf: fileURL, encoding: .utf8))
        } catch {
            return .unreadable
        }
    }

    private static func headingTitle(from line: String) -> String? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
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

    public static func digest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
}

private enum ProjectContextFileReadState {
    case missing
    case loaded(String)
    case unreadable
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
