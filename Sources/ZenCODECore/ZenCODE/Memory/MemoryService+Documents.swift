//
//  MemoryService+Documents.swift
//  ZenCODE
//

import Foundation

extension MemoryService {
    func memoryDocuments(workspaceRootURL: URL?) -> [MemoryDocument] {
        guard let workspaceRootURL else {
            return []
        }
        return [
            MemoryDocument(
                scope: .project,
                fileURL: workspaceRootURL
                    .standardizedFileURL
                    .appendingPathComponent(Self.filename)
            )
        ]
    }

    func memoryDocument(
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryDocument {
        switch scope {
        case .project:
            guard let workspaceRootURL else {
                throw MemoryServiceError.scopeUnavailable("project")
            }
            return MemoryDocument(
                scope: .project,
                fileURL: workspaceRootURL
                    .standardizedFileURL
                    .appendingPathComponent(Self.filename)
            )
        }
    }

    func readEntries(from document: MemoryDocument) -> [MemoryEntry] {
        guard fileManager.fileExists(atPath: document.fileURL.path),
              let content = try? String(contentsOf: document.fileURL, encoding: .utf8) else {
            return []
        }

        var entries: [MemoryEntry] = []
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
        scope: MemoryScope,
        isArchived: Bool
    ) -> MemoryEntry? {
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
            return MemoryEntry(
                content: content,
                scope: scope,
                id: id,
                isArchived: isArchived
            )
        }

        return MemoryEntry(
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
        _ entries: [MemoryEntry],
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
        scope: MemoryScope,
        activeEntries: [MemoryEntry],
        archivedEntries: [MemoryEntry]
    ) -> String {
        let template: String
        switch scope {
        case .project:
            template = defaultProjectMemoryContent
        }

        let active = render(entries: activeEntries)
        let archived = render(entries: archivedEntries)
        return template
            .replacingOccurrences(of: "## Active\n\n## Archived", with: "## Active\n\n\(active)\n\n## Archived")
            .replacingOccurrences(of: "## Archived", with: "## Archived\n\n\(archived)")
    }

    static func render(entries: [MemoryEntry]) -> String {
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
        MemoryEntry.normalizedContent(content)
    }

    public static func timestampString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) \(timeZone.identifier)"
    }

    func searchScore(entry: MemoryEntry, terms: [String]) -> Int {
        let content = entry.content.lowercased()
        var score = 0
        for term in terms where content.contains(term) {
            score += 10
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

}


struct MemoryDocument {
    let scope: MemoryScope
    let fileURL: URL
}

public enum MemoryServiceError: LocalizedError {
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
