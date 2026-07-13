//
//  TerminalPromptInputEvent.swift
//  ZenCODE
//

import Foundation

public enum TerminalPromptInputEvent: Sendable {
    case submitted(String)
    case cancelRequested
    case toggleToolDetailsRequested
    case toggleAccessModeRequested
    case endOfInput
}

public struct TerminalCommandSuggestion: Sendable {
    public let command: String
    public let summary: String
    public let requiresArgument: Bool

    public init(
        command: String,
        summary: String,
        requiresArgument: Bool = false
    ) {
        self.command = command
        self.summary = summary
        self.requiresArgument = requiresArgument
    }
}

public struct TerminalPanelModeOverride: Sendable, Equatable {
    public let modeText: String
    public let helpText: String

    public init(modeText: String, helpText: String) {
        self.modeText = modeText
        self.helpText = helpText
    }
}
