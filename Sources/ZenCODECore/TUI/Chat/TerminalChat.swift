//
//  TerminalChat.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import ToolCore

/// TerminalChat coordinates session state; all stateful terminal rendering is isolated by `renderCoordinator`.
///
/// The terminal is one slot of a ``ChatSessionHost`` (``terminalSlotID``): it
/// runs the session of the slot's current incarnation, whose controller is
/// ``chatSession``, and follows the slot from one incarnation to the next
/// (``followIncarnation(_:)``) when `/sessions new` or `/sessions load`
/// replace the session. The host is given by the composition root
/// (`ZenCODECommandLineRunner`, which shuts it down with the runner) or built
/// by `init` over the runner it receives or creates.
///
/// Isolation: every instance member lives on ``ChatSessionActor``, which
/// replaces the previous `@unchecked Sendable` contract with compiler-checked
/// isolation. Blocking POSIX reads must never run on this actor; they are
/// dispatched off-actor through the `…OffActor` helpers in
/// `TerminalChat+InputLoop+Blocking.swift`.
@ChatSessionActor
public final class TerminalChat {
    public let configuration: AgentConfiguration
    public let stdinIsTerminal: Bool
    /// The container of the chat sessions of the process; the terminal's
    /// runner is its runner.
    public let sessionHost: ChatSessionHost
    /// The terminal's slot in ``sessionHost``, open from `init` on.
    public var terminalSlotID: ChatSlotID {
        currentIncarnation.slotID
    }
    public let sessionRunner: AgentCoreSessionRunner
    let runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot?
    public let reader = StdioLineReader()
    public let interactiveReader = TerminalInteractiveLineReader()
    public let permissionAuthorizer: LocalExecPermissionAuthorizer
    public let featureRuntime: SwiftFeatureRuntime
    /// The session the terminal's slot runs, as the host last told the
    /// terminal (``incarnationDidChange(_:)``). Kept once the slot closes or
    /// the host shuts down, so late work finds the last controller, fenced,
    /// instead of nothing. Only its controller, slot, and epoch are read
    /// here; its reservation fields are the host's.
    ///
    /// Implicitly unwrapped only because the slot's descriptor names this
    /// chat as its channel hooks, so the slot can be opened only once `self`
    /// is complete: `init` assigns it right then, before it returns and so
    /// before any task of the chat can start or any member can read it.
    private(set) var currentIncarnation: ChatSessionIncarnation!
    /// Shared chat-session controller: turn pipeline, transcript, `/plan` and
    /// `/goal` state, and file-change artifacts. The session properties below
    /// forward to it on the same actor. It is the controller of the slot's
    /// current incarnation: a new one after `/sessions new` and
    /// `/sessions load`, which start from the launch profile.
    var chatSession: ChatSessionController {
        currentIncarnation.controller
    }
    let chatSessionPresenter: TerminalChatSessionPresenter
    let interactionHost: TerminalInteractionHost
    /// Holds the current turn's assistant block until a tool boundary or the
    /// turn end decides whether it is commentary or the answer.
    var activeAssistantOutput: TerminalAssistantResponseBuffer?
    /// The id of the session the terminal runs. Set through the host, in
    /// place (``ChatSessionHost/adoptSessionID(_:in:)``), only before the
    /// runtime session exists; a refusal (shut down, no session, busy) leaves
    /// the id as it is, and is logged.
    public var sessionID: String {
        get { chatSession.sessionID }
        set {
            do {
                try sessionHost.adoptSessionID(newValue, in: terminalSlotID)
            } catch {
                ZenLogger.warning(
                    .sessionService,
                    "terminal kept session id \(chatSession.sessionID) instead of \(newValue): \(error)"
                )
            }
        }
    }
    public var activeSessionCacheKey: String? {
        get { chatSession.cacheKey }
        set { chatSession.cacheKey = newValue }
    }
    public var activeSessionHistory: [AgentRuntimeMessage] {
        get { chatSession.history }
        set { chatSession.history = newValue }
    }
    public var activeSessionTranscript: [AgentRuntimeMessage] {
        get { chatSession.transcript }
        set { chatSession.transcript = newValue }
    }
    var activeSessionTranscriptRetainedByteCount: Int {
        get { chatSession.transcriptRetainedByteCount }
        set { chatSession.transcriptRetainedByteCount = newValue }
    }
    public var activeSessionSystemPromptOverride: String? {
        get { chatSession.savedSessionState.systemPromptOverride }
        set { chatSession.savedSessionState.systemPromptOverride = newValue }
    }
    public var activeSessionDynamicContextOverride: String? {
        get { chatSession.savedSessionState.dynamicContextOverride }
        set { chatSession.savedSessionState.dynamicContextOverride = newValue }
    }
    public var activeResponseLanguageName: String?
    public var didLockResponseLanguage = false
    public var activeSavedSessionName: String? {
        get { chatSession.savedSessionState.savedSessionName }
        set { chatSession.savedSessionState.savedSessionName = newValue }
    }
    /// Tracks the checkpoint tree for the active session. Populated when a
    /// session is loaded or saved, and updated as messages accumulate.
    public var activeCheckpointTree: SessionCheckpointTree? {
        get { chatSession.savedSessionState.checkpointTree }
        set { chatSession.savedSessionState.checkpointTree = newValue }
    }
    public var printedModelID: String?
    public var didPrintActiveTools = false
    /// Tracks whether the status-bar git summary has already been refreshed
    /// during the current prompt. Read and written by both the periodic
    /// sub-agent overview refresh task and the generation callback; their
    /// accesses are serialized by ``ChatSessionActor`` isolation.
    var didRefreshGitStatusDuringCurrentPrompt = false
    public var selectedAgent: AgentProfile? {
        get { chatSession.selection.agent }
        set { chatSession.selection.agent = newValue }
    }
    /// The controller's launch-folder listing for the selected agent (see
    /// ``ChatSessionController/launchFolderProjectsCache``): ``applyAgentSelection``
    /// and `loadSavedSession` clear it.
    var launchFolderProjectsCache: LaunchFolderProjectsCache? {
        get { chatSession.launchFolderProjectsCache }
        set { chatSession.launchFolderProjectsCache = newValue }
    }

    typealias LaunchFolderProjectsCache = ChatSessionController.LaunchFolderProjectsCache
    public var manualModelIDOverride: String? {
        get { chatSession.selection.modelIDOverride }
        set { chatSession.selection.modelIDOverride = newValue }
    }
    public var manualThinkingSelectionOverride: AgentThinkingSelection? {
        get { chatSession.selection.thinkingOverride }
        set { chatSession.selection.thinkingOverride = newValue }
    }
    public var selectedToolKeys: Set<String> {
        get { chatSession.selection.toolKeys }
        set { chatSession.selection.toolKeys = newValue }
    }
    public var selectedSkillIDs: Set<String> {
        get { chatSession.selection.skillIDs }
        set { chatSession.selection.skillIDs = newValue }
    }
    /// The attachments `/attach` staged for the next prompt (see
    /// ``ChatSessionController/pendingAttachments``).
    public var pendingAttachments: [AgentRuntimeAttachment] {
        get { chatSession.pendingAttachments }
        set { chatSession.pendingAttachments = newValue }
    }
    public var lastFileChangeSummary: TurnFileChangeSummary? {
        get { chatSession.lastFileChangeSummary }
        set { chatSession.lastFileChangeSummary = newValue }
    }
    /// Runtime-only artifact history. It is never serialized with a session.
    var fileArtifactHistory: SessionFileArtifactHistory {
        get { chatSession.fileArtifactHistory }
        set { chatSession.fileArtifactHistory = newValue }
    }
    var activeFileArtifactTurn: FileArtifactTurnContext? {
        get { chatSession.activeFileArtifactTurn }
        set { chatSession.activeFileArtifactTurn = newValue }
    }
    public var activePlan: TerminalSessionPlan? {
        get { chatSession.activePlan }
        set { chatSession.activePlan = newValue }
    }
    /// Plans that follow ``activePlan`` in a Planner sequence, in order.
    public var queuedPlans: [TerminalSessionPlan] {
        get { chatSession.queuedPlans }
        set { chatSession.queuedPlans = newValue }
    }
    /// Ephemeral `/plan` clarification state. Never copy this into snapshots or
    /// persisted session models.
    var planBrainstorming: PlanningCommandRuntimeState? {
        get { chatSession.planBrainstorming }
        set { chatSession.planBrainstorming = newValue }
    }
    /// Ephemeral `/plan` approval state. It records only the plan being confirmed;
    /// the requested Goal itself is consumed immediately and never enters a
    /// checkpoint or persisted session model.
    var pendingPlanApprovalPlanID: String? {
        get { chatSession.pendingPlanApprovalPlanID }
        set { chatSession.pendingPlanApprovalPlanID = newValue }
    }
    /// Ephemeral `/goal` workflow state used to continue the same workflow graph.
    /// It captures the next message only when an explicit signal armed it: the
    /// coordinator's `Workflow question` block, a graph resumed from a previous
    /// session, or an interrupted turn whose non-empty graph was preserved.
    /// Never copy this into snapshots or persisted session models.
    var activeWorkflow: WorkflowCommandRuntimeState? {
        get { chatSession.activeWorkflow }
        set { chatSession.activeWorkflow = newValue }
    }
    /// Live voice loop of the interactive panel, started by `/voice on` with
    /// any agent: local dictation on macOS, sherpa-onnx programs on Linux.
    /// Transient: it lasts only for this TUI session and audio is never
    /// persisted.
    var voiceController: (any TerminalVoiceController)?
    /// Event queue of the running interactive panel loop; `nil` outside it,
    /// where voice mode cannot run.
    var voiceEventQueue: TerminalChatEventQueue?
    /// The spoken dialogue over live shared-chat messages while voice mode
    /// runs: announcements queued, the question being asked, the reply
    /// awaited. Transient like voice mode itself: never copied into snapshots
    /// or checkpoints.
    var voiceChatDialogue = TerminalVoiceChatDialogue()
    /// Sleeps until the answer to a spoken question is overdue.
    var voiceDialogueDeadlineTask: Task<Void, Never>?
    /// How long a spoken question waits for its answer. Mutable so tests can
    /// shorten it.
    var voiceDialogueAnswerTimeout: Duration = .seconds(60)
    /// The task that consumes the task-graph events of the shared observer
    /// (see ``ChatSessionController/taskGraphObserverTask``); `nil` while it
    /// is stopped.
    public var taskGraphObserverTask: Task<Void, Never>? {
        chatSession.taskGraphObserverTask
    }
    /// Periodically republishes the sub-agent overview while a blocking
    /// `agent.*` tool call (e.g. `agent.wait`) is executing (see
    /// ``ChatSessionController/subAgentOverviewRefreshTask``). Started from
    /// `.toolCallStarted` and stopped from `.toolCallCompleted` / end-of-turn.
    var subAgentOverviewRefreshTask: Task<Void, Never>? {
        chatSession.subAgentOverviewRefreshTask
    }
    /// The runner retains this handler across backend rebuilds. Install once
    /// per artifact-history lifetime so a reset fences callbacks from old sessions.
    var didInstallSubAgentToolEventHandler = false
    /// Interval between automatic sub-agent overview refreshes, the one of the
    /// controller's refresher (see ``ChatSubAgentOverviewRefresher/interval``).
    /// Mutable so tests can shorten it.
    var subAgentOverviewRefreshInterval: Duration {
        get { chatSession.subAgentOverviewRefresher.interval }
        set { chatSession.subAgentOverviewRefresher.interval = newValue }
    }
    /// Keys of sub-agent completions already reflected in the statusbar git
    /// summary (agent ID + status + output revision). A sub-agent re-run via
    /// `agent.message` produces a new revision and triggers a fresh refresh.
    /// Mutated by the periodic overview refresh task and the generation
    /// callback, which are serialized by ``ChatSessionActor`` isolation.
    var reflectedSubAgentCompletionKeys = Set<String>()

    /// Records a sub-agent completion key and returns whether it was new (so
    /// the caller refreshes the git summary at most once per completion).
    /// The check-then-act pair is atomic because the whole type is isolated to
    /// ``ChatSessionActor``.
    func recordSubAgentCompletionKey(_ key: String) -> Bool {
        reflectedSubAgentCompletionKeys.insert(key).inserted
    }

    /// Test hook invoked at the start of each refresh tick, the one of the
    /// controller's refresher (see ``ChatSubAgentOverviewRefresher/onTick``).
    /// When set, the tick awaits this closure before rendering, allowing tests
    /// to deterministically gate tick timing. Captured at `start` time; `nil`
    /// in production.
    var onSubAgentOverviewTick: (@Sendable () async -> Void)? {
        get { chatSession.subAgentOverviewRefresher.onTick }
        set { chatSession.subAgentOverviewRefresher.onTick = newValue }
    }
    public var availableSkillsCache: [PromptSkill]? {
        get { chatSession.availableSkillsCache }
        set { chatSession.availableSkillsCache = newValue }
    }
    let renderCoordinator: TerminalChatRenderCoordinator
    /// The event queue of the running input loop, from its start to its
    /// teardown: the ending of a turn the terminal adopted from Telegram
    /// reaches the loop through it (see `TerminalChat+Telegram.swift`).
    var loopEventQueue: TerminalChatEventQueue?
    /// `true` from `/telegram off` while a turn from Telegram was running
    /// until the loop adopted that turn (see
    /// ``takeAdoptedTurnIfNeeded()``).
    var hasAdoptedTelegramTurn = false
    /// Returning `true` stands in for publishing a shared-chat mention the
    /// operator typed or dictated; `nil` in production.
    var onSharedChatPublicationForTesting: (@Sendable () -> Bool)?
    /// Test-only runtime seams. Production leaves these nil/false; they let a
    /// deterministic harness drive the real serialized panel FIFO without raw
    /// terminal I/O or a live model.
    var interactiveRuntimeEventQueueForTesting: TerminalChatEventQueue?
    var bypassInteractivePanelInputForTesting = false
    var onGenerateResponseForTesting: (@Sendable (TerminalPromptAttempt) async throws -> TerminalChatGenerationSuccess)?
    var onInteractiveGenerationStateForTesting: (@Sendable (Bool) -> Void)?
    /// The system, failure, and Markdown messages the terminal writes while
    /// it is not `nil`, one entry per write: a test's capture of what a
    /// command presents.
    var capturedCommandOutputForTesting: [String]?
    var optionalCommandAvailability = TerminalOptionalCommandAvailability.load()
    /// Reads and replaces the user's crontab for `/cron`. Tests install a
    /// stand-in so no command ever touches the real crontab.
    var crontabClient: any CrontabClient = SystemCrontabClient()
    /// Runs a scheduled prompt immediately for `/cron run`. Tests install a
    /// stand-in so no command ever launches a real job.
    var cronJobRunner: any CronJobRunning = SystemCronJobRunner()
    /// Finds the `zen` that ZenCRON will start, given the `PATH` of the ZenCODE
    /// block, for `/cron add`. Tests install a stand-in so no command depends
    /// on what is installed on the machine.
    var cronZenLocator: @Sendable (String) -> String? = { ZenCronJobCommand.locateZen(onPath: $0) }
    /// Checks the ZenCRON host that the lines written by `/cron add` run: it
    /// must be installed by `/setup` and answer `--zencron-version`. Throws a
    /// `ZenCrontabError` otherwise. Tests install a stand-in so no command
    /// depends on what is installed on the machine nor starts a real process.
    var cronZenCRONLocator: @Sendable () async throws -> ZenCRONInstallation.InstalledExecutable = {
        try await ZenCRONInstallation.checkedInstalledExecutable()
    }
    /// The `/cron run` in flight; at most one runs at a time. Only its own task
    /// clears it, once the report is written. Chat teardown cancels the task
    /// (which terminates the child) without clearing it.
    var activeCronRun: (number: Int, task: Task<Void, Never>)?
    var requestedRuntimeSetup = false
    public let statusBar: TerminalStatusBar

    public convenience init(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil,
        runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot? = nil
    ) {
        self.init(
            configuration: configuration,
            stdinIsTerminal: stdinIsTerminal,
            sessionRunner: sessionRunner,
            sessionHost: nil,
            permissionAuthorizer: permissionAuthorizer,
            runtimeSetupResumeSnapshot: runtimeSetupResumeSnapshot,
            telegramTransportFactory: nil
        )
    }

    /// A terminal chat in a slot of `sessionHost`, whose runner is the
    /// terminal's: the composition root that owns the host shuts it down
    /// with the runner (``ChatSessionHost/shutdown(keepingExternalTools:)``).
    /// The host's environment must be the one of `configuration`
    /// (``makeSessionHost(configuration:sessionRunner:)``).
    public convenience init(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionHost: ChatSessionHost,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil,
        runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot? = nil
    ) {
        self.init(
            configuration: configuration,
            stdinIsTerminal: stdinIsTerminal,
            sessionRunner: nil,
            sessionHost: sessionHost,
            permissionAuthorizer: permissionAuthorizer,
            runtimeSetupResumeSnapshot: runtimeSetupResumeSnapshot,
            telegramTransportFactory: nil
        )
    }

    /// Internal seams for deterministic transport and terminal-output tests;
    /// production keeps the real transport and render coordinator. The host
    /// wins over the runner; without both, a runner is created.
    init(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil,
        sessionHost: ChatSessionHost? = nil,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil,
        runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot? = nil,
        telegramTransportFactory: (@Sendable () -> any TelegramHTTPTransport)?,
        renderCoordinator: TerminalChatRenderCoordinator? = nil
    ) {
        self.configuration = configuration
        self.stdinIsTerminal = stdinIsTerminal
        self.runtimeSetupResumeSnapshot = runtimeSetupResumeSnapshot
        self.renderCoordinator = renderCoordinator ?? TerminalChatRenderCoordinator(
            stdinIsTerminal: stdinIsTerminal
        )
        self.statusBar = TerminalStatusBar(
            isEnabled: stdinIsTerminal
                && Self.supportsInteractiveStatusBar()
        )
        let permissionAuthorizer = permissionAuthorizer ?? LocalExecPermissionAuthorizer()
        self.permissionAuthorizer = permissionAuthorizer
        let host: ChatSessionHost
        if let sessionHost {
            host = sessionHost
        } else {
            host = Self.makeSessionHost(
                configuration: configuration,
                sessionRunner: sessionRunner ?? ChatSessionRuntimeFactory.makeSessionRunner(
                    toolAuthorizationHandler: { request in
                        await permissionAuthorizer.authorize(request)
                    },
                    featureRuntime: SwiftFeatureRuntime()
                )
            )
        }
        self.sessionHost = host
        self.sessionRunner = host.runner
        self.featureRuntime = host.runner.swiftFeatureRuntime
        if let telegramTransportFactory {
            host.telegramTransportFactory = telegramTransportFactory
        }
        let chatSessionPresenter = TerminalChatSessionPresenter()
        // Menus and line input need an interactive terminal.
        let interactionHost = TerminalInteractionHost(
            stdinIsTerminal: stdinIsTerminal,
            appMode: configuration.appMode
        )
        self.chatSessionPresenter = chatSessionPresenter
        self.interactionHost = interactionHost
        chatSessionPresenter.chat = self
        interactionHost.chat = self
        // The terminal's slot, with its first session at once: the controller
        // starts from the launch agent and the launch's explicit model, and
        // reads the tool catalog from the runner's feature runtime. After
        // `/setup` the session is the one the setup interrupted. The slot's
        // bindings (presenter, host, hooks, commands) outlive the session, and
        // so does its Telegram channel, created by the first `/telegram on`.
        // The terminal's presenter presents the endings of the turns it does
        // not run (``TerminalChatSessionPresenter/presentTurnEnding(_:)``),
        // so the descriptor needs no handler of its own.
        let descriptor = ChatSlotDescriptor(
            identity: .terminal,
            workingDirectory: configuration.workingDirectory,
            presenter: chatSessionPresenter,
            interaction: .host(interactionHost),
            authorizer: permissionAuthorizer.consentAuthorizer,
            channelHooks: self,
            commandRegistry: Self.commandRegistry,
            // Nobody consumes a reducer of the terminal: the host creates one
            // on demand while Telegram drives the slot.
            publishesState: false,
            // `/sessions new` mints `terminal-<uuid>`, as `newTerminalSessionID()`.
            sessionIDPrefix: Self.sessionIDPrefix
        )
        do {
            currentIncarnation = try host.openSlot(
                descriptor,
                sessionID: runtimeSetupResumeSnapshot?.sessionID ?? Self.newTerminalSessionID()
            )
        } catch {
            preconditionFailure("The terminal cannot open its slot: \(error)")
        }
        host.addIncarnationObserver(to: terminalSlotID) { [weak self] incarnation in
            self?.followIncarnation(incarnation)
        }
    }

    /// The host of a terminal chat over `sessionRunner`, with the environment
    /// of `configuration` and the terminal's sleep-assertion reason: what
    /// `init` builds when it is given none, and what the command-line runner
    /// builds for each chat it runs.
    public nonisolated static func makeSessionHost(
        configuration: AgentConfiguration,
        sessionRunner: AgentCoreSessionRunner
    ) -> ChatSessionHost {
        ChatSessionHost(
            runner: sessionRunner,
            environment: ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: sessionRunner.swiftFeatureRuntime,
                userHomeDirectoryURL: UserHomeDirectory.current()
            ),
            sleepAssertionReason: "ZenCODE terminal session active"
        )
    }

    /// The slot runs `incarnation` now: `/sessions new` or `/sessions load`
    /// replaced the session, or ``sessionID`` changed in place. The terminal
    /// follows: ``chatSession`` is the new controller, and the runner's
    /// sub-agent event handler, bound to the previous artifact history, is
    /// installed again at the next turn. The slot's Telegram channel follows
    /// the slot by itself. Everything else the terminal keeps per session
    /// (status bar, overviews, task-graph observer, staged attachments,
    /// response language) is realigned by the channel hooks of the
    /// operation, in the order they always ran. A slot without session
    /// (closed, shut down) changes nothing: late work keeps finding the last
    /// controller.
    private func followIncarnation(_ incarnation: ChatSessionIncarnation?) {
        guard let incarnation else { return }
        let previous: ChatSessionIncarnation = currentIncarnation
        currentIncarnation = incarnation
        guard incarnation.epoch != previous.epoch else { return }
        didInstallSubAgentToolEventHandler = false
    }

    public static func supportsInteractiveStatusBar() -> Bool {
        AgentOutput.standardErrorIsTerminal
    }

    /// The prefix of every session id of the terminal
    /// (``ChatSlotDescriptor/sessionIDPrefix``).
    nonisolated static let sessionIDPrefix = "terminal"

    public static func newTerminalSessionID() -> String {
        ChatSessionController.mintedSessionID(prefix: sessionIDPrefix)
    }

    public func currentEffectiveModelID() -> String? {
        chatSession.currentEffectiveModelID()
    }

    public static func effectiveModelID(
        selectedAgent: AgentProfile?,
        manualModelIDOverride: String?,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> String? {
        ChatSessionController.effectiveModelID(
            selectedAgent: selectedAgent,
            manualModelIDOverride: manualModelIDOverride,
            manifest: manifest
        )
    }

    /// See ``ChatModelCatalog/modelReferences(for:)``.
    static func modelReferences(for rawModelID: String) -> [String] {
        ChatModelCatalog.modelReferences(for: rawModelID)
    }

    public func run() async throws -> TerminalChatRunOutcome {
        // The machine is kept awake by the host while the slot runs a session,
        // from `init` to the close below.
        let memoryDiagnosticSink =
            MemorySemanticFallbackDiagnostics.installVisibleErrorSink {
                [renderCoordinator] line in
                Task(name: "ZenCODE.TUI.memory-fallback-diagnostic") {
                    await renderCoordinator.writeToolAdjacentSystemMessage(line)
                }
            }
        defer {
            MemorySemanticFallbackDiagnostics.removeVisibleErrorSink(
                token: memoryDiagnosticSink
            )
        }

        let initialInputLine: String?
        if stdinIsTerminal {
            initialInputLine = nil
        } else {
            guard let line = await Self.readStdinLineOffActor(reader: reader) else {
                throw TerminalChatError.noInputReceived
            }
            initialInputLine = line
        }

        applyRuntimeSetupResumeSnapshotIfNeeded()
        await applyInitialAgentSelectionIfNeeded()
        try await handleMissingInitialModelSelectionIfNeeded()
        try applyInitialSkillSelectionIfNeeded()
        await ensureWorkspaceAccessIfNeeded()

        let resumedTaskGraph = runtimeSetupResumeSnapshot == nil
            ? await applyResumableTaskGraphSessionIfNeeded()
            : nil

        resetFileArtifactState()
        try await createCurrentSession()
        await refreshInitialStatusBarContextWindow()
        _ = try await preloadCurrentModel(emitStatus: configuration.hostedModels != nil)

        if stdinIsTerminal {
            AgentOutput.clearTerminalScreenIfNeeded()
        }
        // Capture startup and restored presentation before any resize can
        // rebuild the viewport; semantic session history is not a screen replay.
        let statusBarStarted = await statusBar.start()
        await printStartupSummary()
        if let resumedTaskGraph {
            await writeResumedTaskGraphNotice(resumedTaskGraph)
        }
        if let runtimeSetupResumeSnapshot {
            await renderSavedSessionHistory(runtimeSetupResumeSnapshot.transcriptHistory)
            await writeSystemMessage("Session restored after setup.\n")
        }

        await refreshStatusBarGitStatusSummary()
        do {
            if stdinIsTerminal, statusBarStarted {
                try await runInteractivePanelLoop()
            } else {
                try await runBlockingInputLoop(initialInputLine: initialInputLine)
            }

            let outcome: TerminalChatRunOutcome
            if requestedRuntimeSetup {
                outcome = .setupRequested(await makeRuntimeSetupResumeSnapshot())
            } else {
                outcome = .exited
            }
            await abandonPlanBrainstorming()
            // The slot's session ends: its controller is fenced and its runner
            // session closed, keeping its persisted task graph; the last
            // controller stays readable through `chatSession`.
            await sessionHost.closeSession(in: terminalSlotID, runtimeSession: .close)
            await stopTerminalServices()
            return outcome
        } catch {
            await stopTerminalServices()
            throw error
        }
    }

    private func stopTerminalServices() async {
        // Every way out of the chat (exit, /setup, end of input, a thrown
        // error) passes here. The runner sends SIGTERM synchronously from its
        // cancellation handler, so the child is signalled even if ZenCODE
        // exits right after; the cancelled task prints no report.
        activeCronRun?.task.cancel()
        // The slot's Telegram channel, if `/telegram on` created one: the
        // turn's Telegram side, the shared-chat relay, and the control
        // service, in that order, before the terminal's own services stop.
        // The host shuts it down again with the slot, which changes nothing.
        await sessionHost.telegramChannel(in: terminalSlotID)?.shutdown()
        await statusBar.stop()
    }
}

/// The terminal's channel hooks, declared with the class so that the
/// protocol's `Sendable` requirement is met in the class's own file; the
/// steps are in `TerminalChat+ChannelHooks.swift`.
extension TerminalChat: ChatSessionChannelHooks {}
