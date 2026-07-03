//
//  MemoryEntry.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated enum MemoryScope: String, Codable, CaseIterable, Hashable, Sendable {
    case global
    case project
}

public nonisolated struct MemoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var scope: MemoryScope
    public var content: String
    public var isArchived: Bool

    public init(
        content: String,
        scope: MemoryScope = .project,
        id: UUID = UUID(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.scope = scope
        self.content = Self.normalizedContent(content)
        self.isArchived = isArchived
    }

    public var title: String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Memory"
        guard firstLine.count > 80 else {
            return firstLine.isEmpty ? "Memory" : firstLine
        }
        return String(firstLine.prefix(77)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    public static func normalizedContent(_ content: String) -> String {
        let normalizedLineEndings = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalizedLineEndings
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[ \t]+"#,
                with: " ",
                options: .regularExpression
            )
    }
}
