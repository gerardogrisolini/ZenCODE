//
//  TerminalChat+SessionUtilities.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    nonisolated static func savedSessionCommandAction(
        rawArguments: String
    ) -> TerminalSavedSessionCommandAction {
        let trimmedArguments = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split into subcommand + remainder for keyword-based actions.
        let firstSpace = trimmedArguments.firstIndex(of: " ")
        let subcommand: String
        let remainder: String
        if let firstSpace {
            subcommand = String(trimmedArguments[..<firstSpace]).lowercased()
            remainder = String(trimmedArguments[trimmedArguments.index(after: firstSpace)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            subcommand = trimmedArguments.lowercased()
            remainder = ""
        }

        switch subcommand {
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
        case "restore":
            return .restore(entryID: remainder)
        default:
            return .saveNamed(trimmedArguments)
        }
    }

    /// See ``ChatSessionController/derivedSessionName(fromFirstPromptIn:)``.
    nonisolated static func derivedSessionName(
        fromFirstPromptIn messages: [AgentRuntimeMessage]
    ) -> String? {
        ChatSessionController.derivedSessionName(fromFirstPromptIn: messages)
    }

    /// See ``ChatSessionController/derivedSessionName(fromFirstPrompt:limit:)``.
    nonisolated static func derivedSessionName(
        fromFirstPrompt prompt: String,
        limit: Int = 40
    ) -> String? {
        ChatSessionController.derivedSessionName(fromFirstPrompt: prompt, limit: limit)
    }

    public nonisolated static func selectedToolSelectionNames(
        _ selectedToolKeys: Set<String>
    ) -> [String] {
        ChatSessionController.selectedToolSelectionNames(selectedToolKeys)
    }

    public nonisolated static func savedSessionCacheKey(
        name: String,
        workingDirectory: URL
    ) -> String {
        ChatSessionController.savedSessionCacheKey(
            name: name,
            workingDirectory: workingDirectory
        )
    }

    public nonisolated static func savedSessionTimestamp(_ date: Date) -> String {
        ChatSessionNoticeText.timestampText(date)
    }

    public nonisolated static func savedSessionTokenCountText(_ value: Int) -> String {
        ChatSessionNoticeText.tokenCountText(value)
    }
}
