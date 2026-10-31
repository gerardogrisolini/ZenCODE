//
//  ChatSessionChannelHooks.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Why an operation creates the session anew.
enum ChatSessionRecreationReason: Sendable, Equatable {
    /// A model other than the current one was selected.
    case modelChanged
    /// An agent profile was activated.
    case agentSwitched
    /// A saved session replaced the active one and its model is loaded.
    case savedSessionLoaded
}

/// A selection command of the shared dispatcher, as
/// ``ChatSessionChannelHooks/selectionDidApply(_:command:)`` names it.
enum ChatSelectionCommand: Sendable, Equatable {
    /// `/models`.
    case models
    /// `/think`.
    case thinking
    /// `/agents`, and an agent the channel picked itself.
    case agents
    /// `/tools`, and a tool selection the channel applied itself.
    case tools
    /// `/skills` (selection, install, uninstall).
    case skills
}

/// The channel's own steps between one step and another of a session or
/// selection operation, or of a shared command.
///
/// A selection that recreates the session (another model, another agent)
/// runs several runtime steps in a row: it stops the backend, creates the
/// session, and loads the model. Loading a saved session discards the active
/// session, installs the saved one, loads its model, and restores its runtime
/// session and task graph. A channel may keep its own state in step with each
/// of them (a display of the active model, an observer bound to the session,
/// a per-agent setting); the controller calls these hooks at those exact
/// points, in the order documented on each method. The hooks carry no output
/// of their own: notices still reach the channel through the
/// ``ChatSessionPresenter`` or the operation's result. The one exception is
/// ``savedSessionDidRestore(transcript:contextWindow:)``, the point where a
/// channel that replays a restored conversation presents it, so that the
/// replay precedes the loaded notice and the engine checkpoint exactly where
/// it always did; the operation's result carries the same transcript for
/// channels that set no hooks. The approval of a plan (`/plan approve`) calls
/// ``responseLanguageShouldLock()`` before its implementation turn starts.
///
/// The shared dispatcher of slash commands
/// (``ChatSessionController/handleCommandLine(_:context:)``) calls the
/// command hooks at the points the terminal's own command handlers ran the
/// same steps: ``selectionDidApply(_:command:)`` once a selection command
/// applied a selection, before its closing notices are presented; and, for
/// `/sessions`, ``commandContextWindow()`` and ``newSessionID()`` for the
/// values the channel knows, ``sessionWillStartNew()`` and
/// ``sessionDidStartNew()`` around a new session, and
/// ``sessionDidCompact(contextWindow:)`` after a compaction.
///
/// The controller holds the hooks weakly. A channel without such steps sets
/// none, and every method has a no-op default.
@ChatSessionActor
protocol ChatSessionChannelHooks: AnyObject, Sendable {
    /// The response-language section of the system prompt, read at every
    /// composition a selection operation performs, right where it composes.
    /// `nil` adds none.
    func responseLanguageSection() -> String?

    /// The active agent changed to `agent`. Called right after the selection
    /// takes the agent, before its profile is applied and before any session
    /// configuration is composed.
    func agentDidChange(_ agent: AgentProfile) async

    /// The backend was stopped and the session is about to be created anew.
    func sessionWillCreate(reason: ChatSessionRecreationReason) async

    /// The session was created and its prompt skills applied; the model has
    /// not been loaded yet.
    func sessionDidCreate(reason: ChatSessionRecreationReason) async

    /// An event the backend sent while loading the model, in event order.
    /// When no hooks are set the controller forwards these events to the
    /// presenter instead.
    func modelPreloadDidEmit(_ event: DirectAgentEvent) async

    /// The model `modelID` finished loading; the operation is about to
    /// return (a saved-session load goes on restoring the session).
    func modelDidPreload(_ modelID: String, reason: ChatSessionRecreationReason) async

    /// A saved session is about to replace the active one. Called first,
    /// before the planning discussion is abandoned and the active runtime
    /// session is discarded.
    func savedSessionWillLoad() async

    /// The saved session's conversation, saved-session link, and selection
    /// are installed (workspace access included). Called right before its
    /// model is loaded and its runtime session restored.
    func savedSessionWillRestore() async

    /// The saved session's runtime session, prompt skills, and task graph are
    /// restored. `transcript` is the conversation to present, oldest first;
    /// `contextWindow` the context window the session was saved with. Called
    /// before the loaded notice is presented and the engine checkpoint is
    /// restored.
    func savedSessionDidRestore(
        transcript: [AgentRuntimeMessage],
        contextWindow: DirectAgentContextWindowStatus?
    ) async

    /// A plan was approved and its implementation turn, a prompt written in
    /// English that the operator never typed, is about to start. A loaded
    /// plan can be the first turn of a new session, so a channel that locks
    /// the session's response language on the first prompt the operator
    /// types locks it now, before the turn composes its system prompt.
    /// Called after the plan becomes the approved active plan and before the
    /// approval's notice is returned.
    func responseLanguageShouldLock()

    // MARK: Command steps

    /// The selection command `command` applied a selection, which the
    /// session took as `change`. Called before the command's closing notices
    /// are presented, where the terminal refreshed its status bar (`/models`
    /// applied in place, `/think`, `/skills`) and recorded that the active
    /// tools of an applied `/tools` selection were printed (the terminal
    /// recorded it after writing the notices, which never read it). Not
    /// called when no selection was applied.
    func selectionDidApply(_ change: ChatSelectionChange, command: ChatSelectionCommand) async

    /// The context window the channel shows for the session, read by
    /// `/sessions save`, `/sessions <name>` (saved with the session) and
    /// `/sessions compact` (its maximum, when positive, bounds the
    /// compaction), right before the operation runs, as the terminal read
    /// its status bar. `nil` when the channel shows none.
    func commandContextWindow() async -> DirectAgentContextWindowStatus?

    /// The ID of the session `/sessions new` starts, read right before the
    /// session is replaced, as the terminal minted it. `nil` lets the
    /// controller mint one.
    func newSessionID() -> String?

    /// `/sessions new` is about to discard the active session: the terminal
    /// stopped its task-graph observer and unlocked the response language
    /// here.
    func sessionWillStartNew() async

    /// `/sessions new` started the new session, before its closing notice is
    /// presented: the terminal bound its task-graph observer to it, started
    /// its status bar over, dropped the staged attachments, and cleared its
    /// sub-agent overview here. Not called when the session could not be
    /// created.
    func sessionDidStartNew() async

    /// `/sessions compact` compacted the conversation to `contextWindow`,
    /// before its closing notice is presented: the terminal showed the
    /// window on its status bar here. Not called when there was nothing to
    /// compact.
    func sessionDidCompact(contextWindow: DirectAgentContextWindowStatus) async
}

extension ChatSessionChannelHooks {
    func responseLanguageSection() -> String? {
        nil
    }

    func agentDidChange(_ agent: AgentProfile) async {}

    func sessionWillCreate(reason: ChatSessionRecreationReason) async {}

    func sessionDidCreate(reason: ChatSessionRecreationReason) async {}

    func modelPreloadDidEmit(_ event: DirectAgentEvent) async {}

    func modelDidPreload(_ modelID: String, reason: ChatSessionRecreationReason) async {}

    func savedSessionWillLoad() async {}

    func savedSessionWillRestore() async {}

    func savedSessionDidRestore(
        transcript: [AgentRuntimeMessage],
        contextWindow: DirectAgentContextWindowStatus?
    ) async {}

    func responseLanguageShouldLock() {}

    func selectionDidApply(_ change: ChatSelectionChange, command: ChatSelectionCommand) async {}

    func commandContextWindow() async -> DirectAgentContextWindowStatus? {
        nil
    }

    func newSessionID() -> String? {
        nil
    }

    func sessionWillStartNew() async {}

    func sessionDidStartNew() async {}

    func sessionDidCompact(contextWindow: DirectAgentContextWindowStatus) async {}
}
