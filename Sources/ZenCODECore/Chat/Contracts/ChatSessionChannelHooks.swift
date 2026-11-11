//
//  ChatSessionChannelHooks.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Why an operation creates the session anew.
public enum ChatSessionRecreationReason: Sendable, Equatable {
    /// The channel started its first session and loaded its model.
    case sessionStarted
    /// A model other than the current one was selected.
    case modelChanged
    /// An agent profile was activated.
    case agentSwitched
    /// A saved session replaced the active one and its model is loaded.
    case savedSessionLoaded
}

/// A selection command of the shared dispatcher, as
/// ``ChatSessionChannelHooks/selectionDidApply(_:command:)`` names it.
public enum ChatSelectionCommand: Sendable, Equatable {
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

/// One step of an operation that changes the session a channel runs, as
/// ``ChatSessionChannelHooks/incarnationDidChange(reason:)`` names it: the
/// operation, the step, and what the step hands the channel.
///
/// `/sessions new` and the load of a saved session (`/sessions`, `/sessions
/// restore`, ``ChatSessionController/loadSavedSession(_:checkpointEntryID:)``)
/// replace the session; on a controller a ``ChatSessionHost`` runs they
/// replace the incarnation of its slot, so their first step
/// (``newSessionWillStart``, ``savedSessionWillLoad``) runs on the controller
/// being replaced, before the switch, and the later ones on the new
/// controller. `/sessions compact` changes the session in place.
public enum ChatIncarnationChange: Sendable, Equatable {
    /// `/sessions new` is about to discard the active session: the terminal
    /// stops its task-graph observer and unlocks the response language here.
    case newSessionWillStart
    /// `/sessions new` started the new session, before its closing notice is
    /// presented: the terminal binds its task-graph observer to it, starts its
    /// status bar over, drops the staged attachments, clears its sub-agent
    /// overview, and moves the session's Telegram topic here. Not sent when
    /// the session could not be created.
    case newSessionDidStart
    /// A saved session is about to replace the active one. Sent first, before
    /// the planning discussion is abandoned and the active runtime session is
    /// discarded.
    case savedSessionWillLoad
    /// The saved session's conversation, saved-session link, and selection
    /// are installed (workspace access included). Sent right before its model
    /// is loaded and its runtime session restored.
    case savedSessionWillRestore
    /// The saved session's runtime session, prompt skills, and task graph are
    /// restored. `transcript` is the conversation to present, oldest first;
    /// `contextWindow` the context window the session was saved with. Sent
    /// before the loaded notice is presented and the engine checkpoint is
    /// restored: the point where a channel that replays a restored
    /// conversation presents it.
    case savedSessionDidRestore(
        transcript: [AgentRuntimeMessage],
        contextWindow: DirectAgentContextWindowStatus?
    )
    /// `/sessions compact` compacted the conversation to `contextWindow`,
    /// before its closing notice is presented: the terminal shows the window
    /// on its status bar here. Not sent when there was nothing to compact.
    case sessionDidCompact(contextWindow: DirectAgentContextWindowStatus)
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
/// points, in the order documented on each method. The steps of a session
/// replacement and of a compaction are one hook,
/// ``incarnationDidChange(reason:)``, whose ``ChatIncarnationChange`` names
/// the step. The hooks carry no output of their own: notices still reach the
/// channel through the ``ChatSessionPresenter`` or the operation's result.
/// The one exception is ``ChatIncarnationChange/savedSessionDidRestore(transcript:contextWindow:)``,
/// the point where a channel that replays a restored conversation presents
/// it, so that the replay precedes the loaded notice and the engine
/// checkpoint exactly where it always did; the operation's result carries the
/// same transcript for channels that set no hooks. The approval of a plan
/// (`/plan approve`) calls ``responseLanguageShouldLock()`` before its
/// implementation turn starts.
///
/// The shared dispatcher of slash commands
/// (``ChatSessionController/handleCommandLine(_:context:)``) calls the
/// command hooks at the points the terminal's own command handlers ran the
/// same steps: ``selectionDidApply(_:command:)`` once a selection command
/// applied a selection, before its closing notices are presented; and, for
/// `/sessions`, ``commandContextWindow()`` for the context window the channel
/// shows, and ``incarnationDidChange(reason:)`` around a new session and after
/// a compaction. The id of the session `/sessions new` starts is the slot's
/// (``ChatSlotDescriptor/sessionIDPrefix``), not the channel's.
///
/// The controller holds the hooks weakly. A channel without such steps sets
/// none, and every method has a no-op default.
@ChatSessionActor
public protocol ChatSessionChannelHooks: AnyObject, Sendable {
    /// The response-language section of the system prompt, read at every
    /// composition a selection operation performs, right where it composes.
    /// `nil` adds none.
    func responseLanguageSection() -> String?

    /// The active agent changed to `agent`. Called right after the selection
    /// takes the agent, before its profile is applied and before any session
    /// configuration is composed.
    func agentDidChange(_ agent: AgentProfile) async

    /// The session is about to be created, optionally after its backend was
    /// stopped for a selection change.
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

    /// A step of `/sessions new`, of the load of a saved session, or of
    /// `/sessions compact`, which `reason` names with what the step hands the
    /// channel, at the point its ``ChatIncarnationChange`` case documents.
    func incarnationDidChange(reason: ChatIncarnationChange) async

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

    // MARK: Turns of other channels

    /// The configuration of a turn of `purpose` that another channel of the
    /// slot (its Telegram channel) runs on `controller`: the composition this
    /// channel gives its own turns, so a turn from Telegram runs with the same
    /// system prompt, response-language section, grant, and purpose tools as
    /// one typed on the channel. The default is the controller's own
    /// composition with ``responseLanguageSection()``
    /// (``ChatSessionController/turnSessionConfiguration(for:responseLanguageSection:)``),
    /// which is the terminal's; a channel that composes its turns otherwise
    /// overrides it. A channel that no longer runs `controller`'s session (an
    /// ACP session that closed) throws instead of composing, and the turn is
    /// released without starting.
    func turnSessionConfiguration(
        for purpose: ChatTurnPurpose,
        controller: ChatSessionController
    ) async throws -> AgentCoreSessionConfiguration

    /// Runs `body`, the turn that another channel of the slot (its Telegram
    /// channel) starts on `controller`, in the environment this channel gives
    /// its own turns: whatever a turn typed on the channel has around it
    /// beyond its configuration (a text file system the host client serves,
    /// the prompt-skill selection of the active agent). The channel sets that
    /// environment up, runs `body` once inside it, and returns what `body`
    /// returns or rethrows what it throws; it never runs `body` more than
    /// once, and skips it only to refuse the turn, by throwing before it
    /// runs, when it no longer runs `controller`'s session. The default runs
    /// `body` as it is, which is the terminal's: its turns have no
    /// environment of their own.
    func runTurnFromAnotherChannel(
        controller: ChatSessionController,
        _ body: () async throws -> ChatTurnResult
    ) async throws -> ChatTurnResult
}

extension ChatSessionChannelHooks {
    public func responseLanguageSection() -> String? {
        nil
    }

    public func agentDidChange(_ agent: AgentProfile) async {}

    public func sessionWillCreate(reason: ChatSessionRecreationReason) async {}

    public func sessionDidCreate(reason: ChatSessionRecreationReason) async {}

    public func modelPreloadDidEmit(_ event: DirectAgentEvent) async {}

    public func modelDidPreload(_ modelID: String, reason: ChatSessionRecreationReason) async {}

    public func incarnationDidChange(reason: ChatIncarnationChange) async {}

    public func responseLanguageShouldLock() {}

    public func selectionDidApply(_ change: ChatSelectionChange, command: ChatSelectionCommand) async {}

    public func commandContextWindow() async -> DirectAgentContextWindowStatus? {
        nil
    }

    public func turnSessionConfiguration(
        for purpose: ChatTurnPurpose,
        controller: ChatSessionController
    ) async -> AgentCoreSessionConfiguration {
        await controller.turnSessionConfiguration(
            for: purpose,
            responseLanguageSection: responseLanguageSection()
        )
    }

    public func runTurnFromAnotherChannel(
        controller: ChatSessionController,
        _ body: () async throws -> ChatTurnResult
    ) async throws -> ChatTurnResult {
        try await body()
    }
}
