//
//  TerminalChat+SessionUtilities.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// See ``ChatSessionController/savedSessionCommandAction(rawArguments:)``.
    nonisolated static func savedSessionCommandAction(
        rawArguments: String
    ) -> TerminalSavedSessionCommandAction {
        ChatSessionController.savedSessionCommandAction(rawArguments: rawArguments)
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
