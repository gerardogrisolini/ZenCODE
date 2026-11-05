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
            statusFactsHandler?()
        default:
            break
        }
    }
}

/// The presenter of a window's slot. The window renders the reducer's
/// snapshot, so this presenter renders nothing; like the terminal's presenter
/// it publishes the sub-agent overview around the `agent.*` tool calls (and
/// refreshes it while one runs), which reaches the reducer as an observer, and
/// tells the window when a file-mutation tool settled so it refreshes the git
/// summary. It records the task graphs `/tasks` publishes, for their cards.
/// Every call returns quickly: the chat actor is shared.
@ChatSessionActor
final class ZenWindowPresenter: ChatSessionPresenter {
    weak var sessionHost: ChatSessionHost?
    var slotID: ChatSlotID?
    /// Called after a file-mutation tool settled.
    var fileMutationHandler: (@Sendable () -> Void)?
    /// The task graphs `/tasks` published (explicit overviews), oldest first,
    /// until the window takes them (``takeExplicitTaskGraphs()``).
    private(set) var explicitTaskGraphs: [ZenExplicitTaskGraph] = []

    nonisolated init() {}

    /// The controller of the incarnation the slot runs now: the presenter is
    /// shared by every incarnation of the slot, so it follows the slot.
    private var controller: ChatSessionController? {
        guard let sessionHost, let slotID else { return nil }
        return sessionHost.incarnation(in: slotID)?.controller
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
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
            commandContext: ZenAppCommands.context(for: selection.agent),
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
