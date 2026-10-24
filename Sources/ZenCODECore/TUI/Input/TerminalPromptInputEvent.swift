//
//  TerminalPromptInputEvent.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

public enum TerminalPromptInputEvent: Sendable {
    case submitted(String)
    case cancelRequested
    case toggleAccessModeRequested
    case toggleSharedChatReaderRequested
    case sharedChatReaderNavigation(TerminalSharedChatReaderAction)
    case endOfInput
}

public struct TerminalCommandSuggestion: Sendable, Equatable {
    public let command: String
    public let summary: String
    public let requiresArgument: Bool
    /// A guide row only explains the slot under the cursor (for example
    /// `<minute>`); it is never a value to type. It is listed and selected like
    /// any other row, but accepting it does nothing: Tab leaves the draft
    /// untouched and Enter sends the line exactly as typed.
    public let isHint: Bool

    public init(
        command: String,
        summary: String,
        requiresArgument: Bool = false,
        isHint: Bool = false
    ) {
        self.command = command
        self.summary = summary
        self.requiresArgument = requiresArgument
        self.isHint = isHint
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
