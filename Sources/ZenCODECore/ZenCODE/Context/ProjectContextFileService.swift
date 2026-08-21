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

    public static func digest(_ value: String) -> String {
        String(format: "%016llx", fnv1aHash(value))
    }
}
