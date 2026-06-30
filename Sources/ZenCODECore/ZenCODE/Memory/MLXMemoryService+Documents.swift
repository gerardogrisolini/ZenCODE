//
//  MLXMemoryService+Documents.swift
//  ZenCODE
//

import Foundation

extension MLXMemoryService {
    func memoryDocuments(workspaceRootURL: URL?) -> [MemoryDocument] {
        var documents = [
            MemoryDocument(scope: .global, fileURL: globalMemoryFileURL())
        ]
        if let workspaceRootURL {
            documents.append(
                MemoryDocument(
                    scope: .project,
                    fileURL: workspaceRootURL
                        .standardizedFileURL
                        .appendingPathComponent(Self.filename)
                )
            )
        }
        return documents
    }

    func memoryDocument(
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryDocument {
        switch scope {
        case .global:
            return MemoryDocument(scope: .global, fileURL: globalMemoryFileURL())
        case .project:
            guard let workspaceRootURL else {
                throw MLXMemoryServiceError.scopeUnavailable("project")
            }
            return MemoryDocument(
                scope: .project,
                fileURL: workspaceRootURL
                    .standardizedFileURL
                    .appendingPathComponent(Self.filename)
            )
        }
    }

    func readEntries(from document: MemoryDocument) -> [MLXMemoryEntry] {
        guard fileManager.fileExists(atPath: document.fileURL.path),
              let content = try? String(contentsOf: document.fileURL, encoding: .utf8) else {
            return []
        }

        var entries: [MLXMemoryEntry] = []
        var sectionIsActive = false
        var sectionIsArchived = false
        var currentEntryLines: [String] = []
        var currentEntryIsArchived = false

        func flushCurrentEntry() {
            guard !currentEntryLines.isEmpty else {
                return
            }
            defer {
                currentEntryLines.removeAll()
            }
            guard let entry = Self.entry(
                fromEntryContent: currentEntryLines.joined(separator: "\n"),
                scope: document.scope,
                isArchived: currentEntryIsArchived
            ) else {
                return
            }
            entries.append(entry)
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flushCurrentEntry()
                let sectionTitle = line
                    .dropFirst(3)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                sectionIsActive = sectionTitle.localizedCaseInsensitiveContains("active")
                sectionIsArchived = sectionTitle.localizedCaseInsensitiveContains("archived")
                continue
            }

            guard sectionIsActive || sectionIsArchived else {
                continue
            }
            if line.hasPrefix("- ") {
                flushCurrentEntry()
                currentEntryLines = [String(line.dropFirst(2))]
                currentEntryIsArchived = sectionIsArchived
                continue
            }

            guard !currentEntryLines.isEmpty,
                  let continuationLine = Self.entryContinuationLine(from: rawLine) else {
                continue
            }
            currentEntryLines.append(continuationLine)
        }
        flushCurrentEntry()
        return entries
    }

    static func entry(
        fromEntryContent content: String,
        scope: MLXMemoryScope,
        isArchived: Bool
    ) -> MLXMemoryEntry? {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return nil
        }

        let idPrefix = "[id:"
        if trimmedContent.lowercased().hasPrefix(idPrefix),
           let closingBracket = trimmedContent.firstIndex(of: "]") {
            let rawID = trimmedContent[trimmedContent.index(trimmedContent.startIndex, offsetBy: idPrefix.count)..<closingBracket]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = trimmedContent[trimmedContent.index(after: closingBracket)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: rawID), !content.isEmpty else {
                return nil
            }
            return MLXMemoryEntry(
                content: content,
                scope: scope,
                id: id,
                isArchived: isArchived
            )
        }

        return MLXMemoryEntry(
            content: trimmedContent,
            scope: scope,
            isArchived: isArchived
        )
    }

    static func entryContinuationLine(from line: String) -> String? {
        if line.hasPrefix("  ") {
            return String(line.dropFirst(2))
        }
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        return nil
    }

    func writeEntries(
        _ entries: [MLXMemoryEntry],
        to document: MemoryDocument
    ) throws {
        try fileManager.createDirectory(
            at: document.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let activeEntries = entries.filter { !$0.isArchived }
        let archivedEntries = entries.filter(\.isArchived)
        let content = Self.documentContent(
            scope: document.scope,
            activeEntries: activeEntries,
            archivedEntries: archivedEntries
        )
        try content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(to: document.fileURL, atomically: true, encoding: .utf8)
    }

    static func documentContent(
        scope: MLXMemoryScope,
        activeEntries: [MLXMemoryEntry],
        archivedEntries: [MLXMemoryEntry]
    ) -> String {
        let template: String
        switch scope {
        case .global:
            template = defaultGlobalMemoryContent
        case .project:
            template = defaultProjectMemoryContent
        }

        let active = render(entries: activeEntries)
        let archived = render(entries: archivedEntries)
        return template
            .replacingOccurrences(of: "## Active\n\n## Archived", with: "## Active\n\n\(active)\n\n## Archived")
            .replacingOccurrences(of: "## Archived", with: "## Archived\n\n\(archived)")
    }

    static func render(entries: [MLXMemoryEntry]) -> String {
        guard !entries.isEmpty else {
            return ""
        }
        return entries.map { entry in
            let lines = normalizedBulletContent(entry.content)
                .components(separatedBy: "\n")
            let firstLine = lines.first ?? ""
            let continuation = lines.dropFirst()
                .map { "  \($0)" }
                .joined(separator: "\n")
            let header = "- [id: \(entry.id.uuidString.uppercased())] \(firstLine)"
            return continuation.isEmpty ? header : "\(header)\n\(continuation)"
        }
        .joined(separator: "\n")
    }

    static func normalizedBulletContent(_ content: String) -> String {
        MLXMemoryEntry.normalizedContent(content)
    }

    func archiveActiveSavedSessionIndexEntries(forProjectPath projectPath: String) throws {
        let entries = readEntries(
            scope: .global,
            workspaceRootURL: nil,
            includeArchived: false,
            limit: .max
        )
        for entry in entries
            where Self.savedSessionIndexProjectPath(in: entry) == projectPath {
            _ = try setArchived(
                true,
                id: entry.id,
                scope: .global,
                workspaceRootURL: nil
            )
        }
    }

    static func savedSessionIndexProjectPath(in entry: MLXMemoryEntry) -> String? {
        let lines = entry.content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains(where: {
            $0.localizedCaseInsensitiveCompare("Kind: saved-session") == .orderedSame
        }) else {
            return nil
        }
        guard let projectLine = lines.first(where: {
            $0.lowercased().hasPrefix("project:")
        }) else {
            return nil
        }
        let path = projectLine
            .dropFirst("Project:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
    }

    public static func timestampString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) \(timeZone.identifier)"
    }

    func searchScore(entry: MLXMemoryEntry, terms: [String]) -> Int {
        let content = entry.content.lowercased()
        var score = 0
        for term in terms {
            if content.contains(term) {
                score += 10
            }
            if entry.scope.rawValue.contains(term) {
                score += 3
            }
        }
        if entry.scope == .project {
            score += 2
        }
        return score
    }

    func workspaceRootURL(for workspaceContext: XcodeWorkspaceContext?) -> URL? {
        guard let path = XcodeWorkspaceContext.normalizedProjectRootPath(
            explicitPath: workspaceContext?.workspacePath,
            workspacePath: workspaceContext?.workspacePath
        ) else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    func globalMemoryDirectoryURLResolved() -> URL {
        if let globalMemoryDirectoryURL {
            return globalMemoryDirectoryURL.standardizedFileURL
        }

        return MLXAppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
    }

}


struct MemoryDocument {
    let scope: MLXMemoryScope
    let fileURL: URL
}

public enum MLXMemoryServiceError: LocalizedError {
    case missingField(String)
    case scopeUnavailable(String)
    case invalidIdentifier(String)
    case entryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .missingField(field):
            return "Missing memory field: \(field)."
        case let .scopeUnavailable(scope):
            return "The \(scope) memory scope is not available in the current context."
        case let .invalidIdentifier(identifier):
            return "Invalid memory identifier: \(identifier)."
        case let .entryNotFound(identifier):
            return "No active memory entry was found for \(identifier)."
        }
    }
}
