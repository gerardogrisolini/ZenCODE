//
//  TerminalChat+SessionUtilities.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    static func savedSessionCommandAction(
        rawArguments: String
    ) -> TerminalSavedSessionCommandAction {
        let trimmedArguments = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
                switch trimmedArguments.lowercased() {
        case "":
            return .list
        case "delete":
            return .delete
        case "new":
            return .newSession
        case "save":
            return .saveActive
        case "compact":
            return .compact
        default:
            return .saveNamed(trimmedArguments)
        }
    }

    /// Derives a session name from the first user prompt in a message list.
    /// Used when `/sessions save` runs without an active saved session so a new
    /// snapshot is named after what the user first asked instead of failing.
    static func derivedSessionName(
        fromFirstPromptIn messages: [AgentRuntimeMessage]
    ) -> String? {
        guard let firstPrompt = messages.first(where: { $0.role == .user })?.content else {
            return nil
        }
        return derivedSessionName(fromFirstPrompt: firstPrompt)
    }

    /// Reduces a raw prompt to a concise single-line session name, truncating at
    /// a word boundary when it exceeds `limit`. Returns nil for blank prompts.
    static func derivedSessionName(
        fromFirstPrompt prompt: String,
        limit: Int = 40
    ) -> String? {
        let singleLine = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else {
            return nil
        }
        guard singleLine.count > limit else {
            return singleLine
        }

        let truncated = String(singleLine.prefix(limit))
        if let lastSpace = truncated.lastIndex(of: " ") {
            let wordBounded = String(truncated[..<lastSpace])
                .trimmingCharacters(in: .whitespaces)
            if !wordBounded.isEmpty {
                return wordBounded
            }
        }
        return truncated.trimmingCharacters(in: .whitespaces)
    }

    public static func selectedToolSelectionNames(
        _ selectedToolKeys: Set<String>
    ) -> [String] {
        selectedToolKeys.sorted()
    }

    public static func savedSessionCacheKey(
        name: String,
        workingDirectory: URL
    ) -> String {
        let stem = TerminalSessionStore.filenameStem(for: name)
        return "\(AgentKVCachePersistencePolicy.terminalDiskCacheKey(workingDirectoryPath: workingDirectory.path)):session:\(stem)"
    }

    public static func savedSessionTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func savedSessionTokenCountText(_ value: Int) -> String {
        let absoluteValue = abs(value)
                if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
