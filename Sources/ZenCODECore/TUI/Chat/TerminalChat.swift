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
/// Isolation: every instance member lives on ``TerminalChatActor``, which
/// replaces the previous `@unchecked Sendable` contract with compiler-checked
/// isolation. Blocking POSIX reads must never run on this actor; they are
/// dispatched off-actor through the `…OffActor` helpers in
/// `TerminalChat+InputLoop+Blocking.swift`.
@TerminalChatActor
public final class TerminalChat {
    public let configuration: AgentConfiguration
    public let stdinIsTerminal: Bool
    public let sessionRunner: AgentCoreSessionRunner
    let runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot?
    public let reader = StdioLineReader()
    public let interactiveReader = TerminalInteractiveLineReader()
    public let permissionAuthorizer: LocalExecPermissionAuthorizer
    public let featureRuntime: SwiftFeatureRuntime
    /// Shared chat-session controller: turn pipeline, transcript, `/plan` and
    /// `/goal` state, and file-change artifacts. The session properties below
    /// forward to it on the same actor.
    let chatSession: ChatSessionController
    let chatSessionPresenter: TerminalChatSessionPresenter
    let interactionHost: TerminalInteractionHost
    /// Holds the current turn's assistant block until a tool boundary or the
    /// turn end decides whether it is commentary or the answer.
    var activeAssistantOutput: TerminalAssistantResponseBuffer?
    public var sessionID: String {
        get { chatSession.sessionID }
        set { chatSession.sessionID = newValue }
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
    var activeSessionTranscriptCountedMessageCount: Int {
        get { chatSession.transcriptCountedMessageCount }
        set { chatSession.transcriptCountedMessageCount = newValue }
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
    /// accesses are serialized by ``TerminalChatActor`` isolation.
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
    /// Ephemeral `/plan` clarification state. Never copy this into snapshots or
    /// persisted session models.
    var planBrainstorming: TerminalPlanBrainstormingState? {
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
    /// callback, which are serialized by ``TerminalChatActor`` isolation.
    var reflectedSubAgentCompletionKeys = Set<String>()

    /// Records a sub-agent completion key and returns whether it was new (so
    /// the caller refreshes the git summary at most once per completion).
    /// The check-then-act pair is atomic because the whole type is isolated to
    /// ``TerminalChatActor``.
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
    public let telegramControlService: TerminalTelegramControlService
    let telegramSessionRouter: TerminalTelegramSessionRouter
    let telegramRouteRuntimeState: TerminalTelegramRouteRuntimeState
    let telegramPermissionBroker = TerminalTelegramPermissionBroker()
    public var telegramControlState = TerminalTelegramControlState.inactive()
    public var telegramLinkedChatID: Int64?
    public var telegramLinkedChatTitle: String?
    /// Telegram user id of the last linked-chat sender, used to bind outbound
    /// artifact consent offers to the operator who will confirm them.
    public var telegramLinkedUserID: Int64?
    /// Last validated route binding. Shared-chat relay/receipts and synthetic
    /// coordinator origins are fenced by this exact generation and topic.
    var telegramActiveRouteLease: TerminalTelegramRouteLease?
    /// Origin of the turn currently generating. Unlike the reporter itself,
    /// this remains populated while Telegram is off so `/telegram on` can attach
    /// the in-flight turn without waiting for the next prompt.
    var activeTelegramTurnOrigin: TerminalPromptOrigin?
    /// Ordered Telegram channel of the turn currently generating, when that
    /// turn's progress is mirrored to the linked chat. Permission dialogue is
    /// enqueued here so it cannot overtake the tool activity that raised it.
    var activeTelegramProgressReporter: TerminalTelegramTurnProgressReporter?
    /// Lifecycle-safe typing lease held for the mirrored turn, if any. Replaced
    /// atomically by the next turn's lease; released at turn end and fenced by
    /// generation inside the lease manager.
    var activeTelegramPresenceLease: TerminalTelegramPresenceLeaseManager.Lease?
    /// Cancels an active Telegram-originated generation as soon as its route
    /// generation is revoked/rebound/closed.
    var telegramRouteValidationTask: Task<Void, Never>?
    var telegramRuntimeEventQueue: TerminalChatEventQueue?
    /// Test-only runtime seams. Production leaves these nil/false; they let a
    /// deterministic harness drive the real serialized panel FIFO without raw
    /// terminal I/O or a live model.
    var interactiveRuntimeEventQueueForTesting: TerminalChatEventQueue?
    var bypassInteractivePanelInputForTesting = false
    var onGenerateResponseForTesting: (@Sendable (TerminalPromptAttempt) async throws -> TerminalChatGenerationSuccess)?
    var onInteractiveGenerationStateForTesting: (@Sendable (Bool) -> Void)?
    enum TelegramWorkEffectForTesting: Sendable {
        case attachmentDownload
        case voiceTranscription
        case sharedChatPublication
    }
    /// Returning true records and consumes the effect before external I/O.
    var onTelegramWorkEffectForTesting: (@Sendable (TelegramWorkEffectForTesting) -> Bool)?
    /// Test seam for direct turn-message delivery when no progress reporter owns
    /// the linked chat. `nil` in production.
    var onDirectTelegramTurnMessage: (@Sendable (TerminalTelegramTurnPayload, Int64) async -> Bool)?
    /// Presentation emitted while a Telegram coordinator command is handled
    /// synchronously. `nil` outside that narrow transport adapter scope.
    var telegramImmediateCommandOutput: [String]?
    /// Pending ForceReply receipts for coordinator commands that require an
    /// argument. A reply must match both the receipt and its original route.
    var telegramCommandReplyBindings: [TerminalTelegramCommandReplyKey: TerminalTelegramCommandReplyBinding] = [:]
    /// Test seam for bot-control messages. Production sends through the service.
    var onTelegramSystemMessage: (@Sendable (String, Int64) async -> Bool)?
    /// Route-aware test seam; production is nil. Kept alongside the legacy hook
    /// so existing tests and embedders remain source-compatible.
    var onTelegramRoutedSystemMessage: (@Sendable (String, Int64, Int?) async -> Bool)?
    /// Test seam for mention picker cards. Production uses the Telegram service.
    var onTelegramMentionPickerMessage: (@Sendable (String, Int64, TerminalTelegramReplyMarkup) async -> Int?)?
    /// `true` when the root response block currently streaming already produced
    /// visible text. Used to detect that a Telegram on/off transition happened
    /// in the middle of a response.
    var telegramRootResponseBlockHasContent = false
    /// `true` when the root response block currently streaming must not be
    /// mirrored: part of it was produced while Telegram was off, so publishing
    /// the remainder would send a partial suffix of a response the remote chat
    /// never saw the beginning of. Cleared at the next boundary, where a new
    /// block starts.
    var telegramRootResponseBlockIsSuppressed = false
    /// `true` when at least one intermediate root response was already mirrored
    /// during the current turn, so the accumulated turn text must not be
    /// mirrored again as the final response.
    var telegramDidPublishIntermediateRootResponse = false
    /// Change signature of the task-graph overview already mirrored to Telegram
    /// during the current turn, so republished identical content does not spam
    /// the remote chat. Sub-agent overviews are terminal-only. Reset when a new
    /// turn begins.
    var mirroredTaskGraphOverviewSignature: String?
    /// Mirroring epoch of the current turn. Advanced (via the coordinator) at
    /// every turn boundary and compared against the epoch each notification
    /// carried at enqueue time: a notification delivered after its turn ended
    /// is discarded instead of being adopted by the next turn's reporter.
    var currentTelegramMirrorEpoch = 0
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
    /// True only while the interactive panel loop, the single surface that
    /// consumes Telegram ingress, is running. The blocking fallback still
    /// forwards live messages, but nothing there reads what Telegram sends back,
    /// so cards must not invite a reply that would be silently dropped.
    var readsTelegramIngress = false
    /// Telegram chat that originated a live shared-chat message, keyed by the
    /// transient bus message identity. A coordinator auto-trigger carries the
    /// same identities, allowing its synthetic turn to retain the remote
    /// response destination instead of being treated as terminal-local work.
    ///
    /// The bus transcript itself remains surface-neutral; this is deliberately
    /// TUI-local delivery metadata and is consumed when the matching trigger
    /// starts. Its bound matches the retained shared-chat transcript.
    var telegramSharedChatMessageOrigins: [UUID: TerminalPromptOrigin] = [:]
    /// FIFO order for the bounded Telegram shared-chat origin ledger.
    var telegramSharedChatMessageOriginOrder: [UUID] = []
    /// Backing storage for ``telegramSharedChatRelay``. The relay captures this
    /// chat weakly to reach the Telegram transport, so it cannot be built in
    /// `init` as a stored `let` without capturing a partially initialised self.
    /// It stays module-internal so tests can install a relay with a stubbed
    /// sender instead of reaching the network.
    var telegramSharedChatRelayStorage: TerminalTelegramSharedChatRelay?
    /// Owns all Telegram voice download/transcription tasks across control toggles.
    let telegramVoiceTranscriptions = TerminalVoiceTranscriptionRegistry()

    /// Forwards operator-directed shared-chat messages to the linked chat and
    /// resolves Telegram replies back to their sender. Created on first use and
    /// owned for the whole chat lifetime, so its ledger survives
    /// `/telegram off` → `/telegram on`.
    var telegramSharedChatRelay: TerminalTelegramSharedChatRelay {
        if let relay = telegramSharedChatRelayStorage {
            return relay
        }
        let relay = TerminalTelegramSharedChatRelay(
            validateLease: { [weak self] lease in
                guard let self else { return false }
                return (try? await self.telegramSessionRouter.validate(lease)) != nil
            },
            send: { [weak self] text, chatID, lease in
                await self?.sendTelegramSharedChatCard(text, to: chatID, lease: lease) ?? nil
            }
        )
        telegramSharedChatRelayStorage = relay
        return relay
    }

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
            permissionAuthorizer: permissionAuthorizer,
            runtimeSetupResumeSnapshot: runtimeSetupResumeSnapshot,
            telegramTransportFactory: nil
        )
    }

    /// Internal seams for deterministic transport and terminal-output tests;
    /// production keeps the real transport and render coordinator.
    init(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil,
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
        if let sessionRunner {
            self.sessionRunner = sessionRunner
            self.featureRuntime = sessionRunner.swiftFeatureRuntime
        } else {
            let featureRuntime = SwiftFeatureRuntime()
            self.featureRuntime = featureRuntime
            self.sessionRunner = AgentCoreSessionRunner(
                defaultToolAuthorizationHandler: { request in
                    await permissionAuthorizer.authorize(request)
                },
                swiftFeatureRuntime: featureRuntime
            )
        }
        self.telegramControlService = TerminalTelegramControlService(
            transportFactory: telegramTransportFactory ?? { NIOTelegramHTTPTransport() }
        )
        let telegramSettings = AgentSettingsManifestStore.load()?.telegram
        let telegramRouter = TerminalTelegramSessionRouter(
            linkedChatID: telegramSettings?.linkedChatID,
            ownerUserID: telegramSettings?.ownerUserID,
            routes: telegramSettings?.routes ?? [],
            persist: { ownerUserID, routes in
                try AgentSettingsManifestStore.saveTelegramRoutes(routes, ownerUserID: ownerUserID)
            }
        )
        self.telegramSessionRouter = telegramRouter
        self.telegramRouteRuntimeState = TerminalTelegramRouteRuntimeState(router: telegramRouter)
        let chatSessionPresenter = TerminalChatSessionPresenter()
        // Menus and line input need an interactive terminal.
        let interactionHost = TerminalInteractionHost(
            stdinIsTerminal: stdinIsTerminal,
            appMode: configuration.appMode
        )
        self.chatSessionPresenter = chatSessionPresenter
        self.interactionHost = interactionHost
        // The controller starts from the launch agent and the launch's
        // explicit model, and reads the tool catalog from the runner's
        // feature runtime.
        self.chatSession = ChatSessionController(
            sessionID: Self.newTerminalSessionID(),
            managementRuntime: self.sessionRunner,
            environment: ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: self.sessionRunner.swiftFeatureRuntime,
                userHomeDirectoryURL: UserHomeDirectory.current()
            ),
            workingDirectory: configuration.workingDirectory,
            presenter: chatSessionPresenter,
            host: interactionHost,
            authorizer: permissionAuthorizer.consentAuthorizer
        )
        chatSessionPresenter.chat = self
        interactionHost.chat = self
        chatSession.channelHooks = self
        chatSession.commandRegistry = Self.commandRegistry
    }

    public static func supportsInteractiveStatusBar() -> Bool {
        AgentOutput.standardErrorIsTerminal
    }

    public static func newTerminalSessionID() -> String {
        "terminal-\(UUID().uuidString.lowercased())"
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
        let sleepAssertion = ZenSleepAssertion(
            reason: "ZenCODE terminal session active"
        )
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
            sleepAssertion.invalidate()
        }
        await installOverviewMirroringHandler()

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
            await sessionRunner.closeSession(id: sessionID)
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
        telegramControlState.isActive = false
        let validationTask = telegramRouteValidationTask
        telegramRouteValidationTask = nil
        validationTask?.cancel()
        await validationTask?.value
        let reporter = activeTelegramProgressReporter
        activeTelegramProgressReporter = nil
        if let reporter { await reporter.shutdown() }
        if let presence = activeTelegramPresenceLease {
            activeTelegramPresenceLease = nil
            await telegramControlService.releasePresenceLease(presence)
        }
        if let lease = activeTelegramTurnOrigin?.telegramLease {
            await telegramRouteRuntimeState.teardown(lease: lease)
        }
        // Quiesce the relay before the transport it uses: its drain worker must
        // not outlive the service it sends through.
        await telegramSharedChatRelayStorage?.shutdown()
        _ = await telegramControlService.stop()
        await statusBar.stop()
    }
}

struct TerminalTelegramCommandReplyKey: Hashable, Sendable {
    let chatID: Int64
    let receiptMessageID: Int
}

struct TerminalTelegramCommandReplyBinding: Sendable {
    let command: String
    let chatID: Int64
    let lease: TerminalTelegramRouteLease
}
