//
//  ZenWindowChannel.swift
//  ZenApp
//
//  The window's channel objects on the chat actor: the hooks of its slot
//  (the response-language lock) and its presenter, which renders nothing but
//  drives the sub-agent overview and the git refresh as the terminal's
//  presenter does.
//

import Foundation
import Synchronization
import ToolCore
import ZenCODECore

/// The hooks of a window's slot. The slot holds them weakly: the window
/// session keeps them.
///
/// The response language is locked, as in the terminal, on the first prompt
/// the operator types in an incarnation (configured language, else the system
/// one), and decided again after a new or loaded session and an agent switch.
/// The lock belongs to the incarnation it was taken in: a later incarnation
/// starts unlocked.
///
/// The task-graph observer follows the session as in the terminal: the first
/// step of `/sessions new` and of a load (`.newSessionWillStart`,
/// `.savedSessionWillLoad`) stops the observer of the controller being
/// replaced, and `.newSessionDidStart` and `.savedSessionDidRestore` start
/// the new controller's, so exactly one observer runs. The steps that change
/// what the status bar shows (a selection, an agent, a session created anew, a
/// new or loaded session) call ``statusFactsHandler``; the steps of a
/// saved-session load call ``savedSessionLoadStepHandler``.
///
/// The session's Telegram topic follows the session as in the terminal: once
/// a new or loaded session runs (`.newSessionDidStart`,
/// `.savedSessionDidRestore`), the slot's Telegram channel, when a
/// `/telegram on` created one, moves its topic to it
/// (``rebindTelegramTopicToCurrentSession()``).
@ChatSessionActor
final class ZenWindowHooks: ChatSessionChannelHooks {
    weak var sessionHost: ChatSessionHost?
    var slotID: ChatSlotID?
    /// The language a lock decides; the configured one, else the system one.
    var languageNameResolver: @Sendable () -> String? = {
        if let code = AgentSettingsManifestStore.load()?.responseLanguage,
           let name = ResponseLanguageResolver.displayName(forCode: code) {
            return name
        }
        return ResponseLanguageResolver.systemDisplayName()
    }
    /// Called when the model, thinking level, agent, or command context of
    /// the next turn may have changed.
    var statusFactsHandler: (@Sendable () -> Void)?
    /// Called when a saved-session load reaches a step
    /// (``ZenSavedSessionLoadStep/init(_:)``), first thing in the hook.
    var savedSessionLoadStepHandler: (@Sendable (ZenSavedSessionLoadStep) -> Void)?

    private var lockedEpoch: UInt64?
    private var languageName: String?

    nonisolated init() {}

    /// The epoch of the incarnation the slot runs now.
    private var currentEpoch: UInt64? {
        guard let sessionHost, let slotID else { return nil }
        return sessionHost.incarnation(in: slotID)?.epoch
    }

    /// The controller of the incarnation the slot runs now.
    private var currentController: ChatSessionController? {
        guard let sessionHost, let slotID else { return nil }
        return sessionHost.incarnation(in: slotID)?.controller
    }

    /// `true` while the current incarnation has its language locked.
    var isResponseLanguageLocked: Bool {
        lockedEpoch != nil && lockedEpoch == currentEpoch
    }

    /// Locks the response language for the current incarnation, once.
    func lockResponseLanguageIfNeeded() {
        guard let epoch = currentEpoch, lockedEpoch != epoch else { return }
        lockedEpoch = epoch
        languageName = languageNameResolver()
    }

    func resetResponseLanguageLock() {
        lockedEpoch = nil
        languageName = nil
    }

    /// Resets a lock taken in another incarnation than `epoch`.
    func resetResponseLanguageLock(unlessLockedIn epoch: UInt64) {
        guard lockedEpoch != epoch else { return }
        resetResponseLanguageLock()
    }

    // MARK: ChatSessionChannelHooks

    func responseLanguageSection() -> String? {
        guard isResponseLanguageLocked, let languageName else { return nil }
        return SystemPromptBuilder.responseLanguageSection(languageName: languageName)
    }

    func responseLanguageShouldLock() {
        lockResponseLanguageIfNeeded()
    }

    func agentDidChange(_ agent: AgentProfile) async {
        resetResponseLanguageLock()
        statusFactsHandler?()
    }

    func sessionDidCreate(reason: ChatSessionRecreationReason) async {
        statusFactsHandler?()
    }

    func selectionDidApply(_ change: ChatSelectionChange, command: ChatSelectionCommand) async {
        statusFactsHandler?()
    }

    func incarnationDidChange(reason: ChatIncarnationChange) async {
        if let step = ZenSavedSessionLoadStep(reason) {
            savedSessionLoadStepHandler?(step)
        }
        switch reason {
        case .newSessionWillStart, .savedSessionWillLoad:
            // On the controller being replaced.
            resetResponseLanguageLock()
            await currentController?.stopTaskGraphObserver()
        case .newSessionDidStart, .savedSessionDidRestore:
            // On the new controller, which the slot already runs.
            await currentController?.startTaskGraphObserver()
            await rebindTelegramTopicToCurrentSession()
            statusFactsHandler?()
        default:
            break
        }
    }

    /// Moves the session's Telegram topic to the session the slot runs now
    /// (`/sessions new`, a load), named after the saved session or, for a
    /// session never saved, as the channel names a new topic. The saved name
    /// is already the restored session's when `.savedSessionDidRestore`
    /// arrives. Nothing happens without a channel (no `/telegram on` ran in
    /// the slot) or outside topic mode.
    private func rebindTelegramTopicToCurrentSession() async {
        guard let sessionHost, let slotID,
              let channel = sessionHost.telegramChannel(in: slotID),
              let controller = currentController else { return }
        // The name of `TelegramChannel.defaultTopicName(workingDirectory:sessionID:)`,
        // which is internal to the core; `rebind` bounds it as Telegram stores it.
        let displayName = controller.savedSessionState.savedSessionName?.nilIfBlank
            ?? "\(controller.workingDirectory.lastPathComponent) · \(controller.sessionID.suffix(8))"
        await channel.rebind(sessionID: controller.sessionID, displayName: displayName)
    }
}

/// The presenter of a window's slot. The window renders the reducer's
/// snapshot, so this presenter renders nothing; like the terminal's presenter
/// it publishes the sub-agent overview around the `agent.*` tool calls (and
/// refreshes it while one runs), which reaches the reducer as an observer, and
/// tells the window when a file-mutation tool settled, the main agent's or a
/// delegated agent's, so it refreshes the git summary. It records the task
/// graphs `/tasks` publishes, for their cards.
/// For voice mode, as the terminal's presenter, it follows the text of the main
/// agent: the comment it writes before a tool call goes to
/// ``voiceCommentaryHandler``, and the final answer of a turn is read from it
/// (``finalAnswer(of:purpose:)``). The thinking is not part of it, and the
/// delegated agents' text never reaches this presenter.
/// Every call returns quickly: the chat actor is shared.
@ChatSessionActor
final class ZenWindowPresenter: ChatSessionPresenter {
    weak var sessionHost: ChatSessionHost?
    var slotID: ChatSlotID?
    /// Called after a file-mutation tool settled, or a delegated agent's
    /// completed.
    var fileMutationHandler: (@Sendable () -> Void)?
    /// Called with the comment the main agent wrote before a tool call,
    /// never blank.
    var voiceCommentaryHandler: (@Sendable (String) -> Void)?
    /// The task graphs `/tasks` published (explicit overviews), oldest first,
    /// until the window takes them (``takeExplicitTaskGraphs()``).
    private(set) var explicitTaskGraphs: [ZenExplicitTaskGraph] = []
    /// The text the main agent wrote since the last tool call, the automatic
    /// continuation of a `/goal` workflow, or the start of the turn: the
    /// terminal's pending assistant output.
    private var assistantBlock = ""
    /// The turn presented assistant text.
    private var receivedAssistantContent = false
    /// The purpose of the turn presented now; `nil` for a turn adopted from
    /// Telegram.
    private var turnPurpose: ChatTurnPurpose?
    /// The final response the turn presented, until it is taken.
    private var finalResponse: DirectAgentResponse?

    nonisolated init() {}

    /// The controller of the incarnation the slot runs now: the presenter is
    /// shared by every incarnation of the slot, so it follows the slot.
    private var controller: ChatSessionController? {
        guard let sessionHost, let slotID else { return nil }
        return sessionHost.incarnation(in: slotID)?.controller
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        // The text written before a tool call is a comment on what is about
        // to happen: voice mode reads it aloud when it can.
        let commentary = assistantBlock
        assistantBlock = ""
        if !commentary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voiceCommentaryHandler?(commentary)
        }
        guard let controller else { return }
        await controller.publishSubAgentOverviewIfChanged(relatedToolName: toolCall.name)
        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
            controller.startSubAgentOverviewRefreshIfNeeded()
        }
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        if ZenGitStatus.isFileMutationTool(toolCall.name) {
            fileMutationHandler?()
        }
        guard let controller else { return }
        await controller.publishSubAgentOverviewIfChanged(relatedToolName: toolCall.name)
        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
            await controller.stopSubAgentOverviewRefresh()
        }
    }

    /// A delegated agent's file mutation refreshes the git summary when it
    /// completes, as the terminal's status bar does; its live artifacts reach
    /// the window through the reducer.
    func presentSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        guard case .completed = event.lifecycle,
              ZenGitStatus.isFileMutationTool(event.toolCall.name) else { return }
        fileMutationHandler?()
    }

    /// Records a graph `/tasks` published (an explicit overview), with the
    /// epoch of the session the slot runs now. An automatic overview records
    /// nothing, without work (the window follows it in the reducer's
    /// snapshot), and neither does an explicit one without graph.
    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication _: ChatOverviewPublication?
    ) async {
        guard origin == .explicit,
              let overview,
              let sessionHost,
              let slotID,
              let epoch = sessionHost.incarnation(in: slotID)?.epoch
        else { return }
        explicitTaskGraphs.append(ZenExplicitTaskGraph(epoch: epoch, overview: overview))
    }

    /// The graphs `/tasks` published since the last call, oldest first.
    func takeExplicitTaskGraphs() -> [ZenExplicitTaskGraph] {
        defer { explicitTaskGraphs.removeAll() }
        return explicitTaskGraphs
    }

    // MARK: Voice mode

    func turnWillStart(_ request: ChatTurnRequest) async {
        resetTurnText()
        turnPurpose = request.purpose
    }

    func presentAssistantContent(_ content: String) async {
        guard !content.isEmpty else { return }
        receivedAssistantContent = true
        assistantBlock += content
    }

    func turnWillContinueAutomatically() async {
        assistantBlock = ""
    }

    func presentFinalResponse(_ response: DirectAgentResponse) async {
        finalResponse = response
    }

    func sessionDidChange(sessionID _: String) async {
        resetTurnText()
    }

    /// The answer voice mode reads at the end of the turn that returned
    /// `result`, as the terminal reads it: the Planner response of a `/plan`
    /// turn; otherwise the text written after the last tool call, or the
    /// response's text when the turn presented no text at all.
    func finalAnswer(of result: ChatTurnResult, purpose: ChatTurnPurpose) -> String {
        defer { resetTurnText() }
        if case .plan = purpose {
            return result.response.text
        }
        return receivedAssistantContent ? assistantBlock : result.response.text
    }

    /// A turn from Telegram is about to be adopted: what it presents to the
    /// window from now on is its own.
    func beginAdoptedTurn() {
        resetTurnText()
    }

    /// The answer of the adopted turn, once it presented its final response
    /// to the window: the text written after its last tool call, or the
    /// response's text; `nil` when it presented none.
    func takeAdoptedFinalAnswer() -> String? {
        defer { resetTurnText() }
        guard let finalResponse else { return nil }
        if case .plan = turnPurpose {
            return finalResponse.text
        }
        return receivedAssistantContent ? assistantBlock : finalResponse.text
    }

    private func resetTurnText() {
        assistantBlock = ""
        receivedAssistantContent = false
        turnPurpose = nil
        finalResponse = nil
    }
}

/// A task graph `/tasks` published, in the session of `epoch`.
struct ZenExplicitTaskGraph: Sendable, Equatable {
    let epoch: UInt64
    let overview: ChatTaskGraphOverview
}

/// The host of the shared consent authorizer: the session host routes the
/// consent of every hosted session to its slot, so this host is asked only
/// for a request no slot runs, which it refuses.
final class ZenRefusingInteractionHost: ChatInteractionHost {
    let capabilities: ChatChannelCapabilities = []

    init() {}

    func requestToolConsent(_ request: AgentToolAuthorizationRequest) async -> ChatConsentDecision? {
        nil
    }
}

/// What the status bar and the welcome view read from the controller, in one
/// hop.
struct ZenControllerFacts: Sendable {
    let modelID: String?
    let thinking: AgentThinkingSelection?
    let agentName: String?
    let commandContext: ChatCommandContext
    let startupSummary: ZenStartupSummary

    /// The facts of the next turn of the incarnation `slotID` runs now; `nil`
    /// when it runs none.
    @ChatSessionActor
    static func read(
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        hooks: ZenWindowHooks
    ) async -> ZenControllerFacts? {
        guard let controller = sessionHost.incarnation(in: slotID)?.controller else { return nil }
        let configuration = await controller.turnSessionConfiguration(
            for: .normal,
            responseLanguageSection: hooks.responseLanguageSection()
        )
        let activeTools = await controller.activeToolsSummary()
        let selection = controller.selection
        return ZenControllerFacts(
            modelID: configuration.modelID ?? controller.environment.launchModelID,
            thinking: configuration.thinkingSelection ?? selection.thinkingOverride,
            agentName: selection.agent?.name,
            // Read at every refresh, as the terminal and ACP read it at each
            // use: `/telegram` shows once the settings enable Telegram.
            commandContext: ZenAppCommands.context(
                for: selection.agent,
                telegramConfigured: ZenAppCommands.isTelegramConfigured()
            ),
            startupSummary: ZenStartupSummary(
                agentName: selection.agent?.displayName,
                activeTools: activeTools,
                activeSkills: controller.selectedPromptSkills()
            )
        )
    }
}

/// The prompts a window hides, posted from the chat actor right before their
/// turn starts and drained by the window before it projects a snapshot.
///
/// The reducer publishes the snapshot that holds a turn's prompt before any
/// presenter sees the turn, so the mark has to be in place before the turn
/// starts: it is posted in the same chat-actor step that checks the
/// reservation and calls `runTurn(_:)`, and the window drains it on the main
/// actor when that snapshot arrives.
final class ZenHiddenPromptMailbox: Sendable {
    struct Mark: Sendable, Equatable {
        let epoch: UInt64
        /// The last sequence of the log before the turn started.
        let afterSequence: Int
    }

    private let marks = Mutex<[Mark]>([])

    init() {}

    func post(_ mark: Mark) {
        marks.withLock { $0.append(mark) }
    }

    func drain() -> [Mark] {
        marks.withLock { marks in
            defer { marks.removeAll() }
            return marks
        }
    }
}
