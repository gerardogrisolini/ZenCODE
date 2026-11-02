//
//  ChatSessionState.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The choices that shape what a session runs with: the active agent profile,
/// the model and thinking level picked by the operator, and the tool and skill
/// selections. The controller owns it; channels mirror it for display.
public struct ChatSessionSelection: Sendable, Equatable {
    /// The active agent profile; `nil` when the session runs without one.
    public var agent: AgentProfile?
    /// The model chosen explicitly (`/models`, a restored session) over the
    /// agent's default binding; `nil` while the agent's default applies.
    public var modelIDOverride: String?
    /// The thinking level chosen explicitly (`/think`, `/models`); `nil` while
    /// the model's or agent's default applies.
    public var thinkingOverride: AgentThinkingSelection?
    /// Keys of the selected tool groups (see ``TerminalToolSelectionItem``).
    public var toolKeys: Set<String>
    /// IDs of the selected prompt skills.
    public var skillIDs: Set<String>

    public init(
        agent: AgentProfile? = nil,
        modelIDOverride: String? = nil,
        thinkingOverride: AgentThinkingSelection? = nil,
        toolKeys: Set<String> = [],
        skillIDs: Set<String> = []
    ) {
        self.agent = agent
        self.modelIDOverride = modelIDOverride
        self.thinkingOverride = thinkingOverride
        self.toolKeys = toolKeys
        self.skillIDs = skillIDs
    }
}

/// What ties the active session to a saved session and to the prompt it was
/// restored with. Saving, loading, and compacting a session replace it.
public struct ChatSavedSessionState: Sendable, Equatable {
    /// Name of the saved session the active session was saved to or loaded
    /// from; `nil` while it has never been saved.
    public var savedSessionName: String?
    /// The checkpoint tree of the saved session, branched as the active
    /// session grows.
    public var checkpointTree: SessionCheckpointTree?
    /// The system prompt restored from a saved or compacted session, which
    /// replaces the one composed from the current selection.
    public var systemPromptOverride: String?
    /// The dynamic context stored next to ``systemPromptOverride``.
    public var dynamicContextOverride: String?

    public init(
        savedSessionName: String? = nil,
        checkpointTree: SessionCheckpointTree? = nil,
        systemPromptOverride: String? = nil,
        dynamicContextOverride: String? = nil
    ) {
        self.savedSessionName = savedSessionName
        self.checkpointTree = checkpointTree
        self.systemPromptOverride = systemPromptOverride
        self.dynamicContextOverride = dynamicContextOverride
    }
}

/// The session state a channel mirrors, sent to
/// ``ChatSessionPresenter/presentSessionStateChanged(_:)`` whenever a
/// selection or the saved-session link changes.
public struct ChatSessionState: Sendable, Equatable {
    public var selection: ChatSessionSelection
    public var savedSession: ChatSavedSessionState

    public init(
        selection: ChatSessionSelection = ChatSessionSelection(),
        savedSession: ChatSavedSessionState = ChatSavedSessionState()
    ) {
        self.selection = selection
        self.savedSession = savedSession
    }
}
