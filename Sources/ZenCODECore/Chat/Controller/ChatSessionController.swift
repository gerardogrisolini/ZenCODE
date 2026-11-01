//
//  ChatSessionController.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Runs the chat turns of one session for any channel.
///
/// The controller owns the turn pipeline shared by the terminal chat, the ACP
/// bridge, and the headless runner: purpose-specific planning and workflow
/// bookkeeping, the session transcript, file-change tracking and artifacts,
/// and the mapping of runtime events onto a ``ChatSessionPresenter``. Channels
/// keep their transport (rendering, JSON-RPC, JSONL) and their own commands.
///
/// It also owns what the session runs with: the selection (agent, model,
/// thinking, tools, skills), the link to a saved session, and the composition
/// of the session configuration and system prompt from them (see
/// `ChatSessionController+Composition.swift`).
///
/// All state is isolated to ``ChatSessionActor``. A turn writes back only
/// while it is still current: the session it started on is still the active
/// one and no channel invalidated it (see ``cancelActiveTurn(armingWorkflowRecovery:)``).
@ChatSessionActor
public final class ChatSessionController {
    /// The runtime the turn pipeline drives.
    let runtime: any ChatSessionRuntime
    /// The runtime behind the session operations and the tool catalog, the
    /// same object as ``runtime``. `nil` for a controller that only runs
    /// turns, whose tool catalog then lists no MCP tool.
    let managementRuntime: (any ChatSessionManagementRuntime)?
    /// What the channel launched the process with.
    public let environment: ChatSessionEnvironment
    /// The models the session can choose from.
    public let modelCatalog: ChatModelCatalog
    public let workingDirectory: URL
    /// The channel's presenter. The controller presents through
    /// ``effectivePresenter(for:)``, which adds the observers.
    let presenter: any ChatSessionPresenter
    /// The observers that see the session's output before ``presenter``, in
    /// the order they were added, held until they are removed (see
    /// ``addObserver(_:)``).
    private(set) var observers: [any ChatSessionObserver] = []
    public let host: any ChatInteractionHost
    /// The channel's own steps between the steps of a selection operation
    /// (see ``ChatSessionChannelHooks``). Held weakly; `nil` for a channel
    /// without such steps.
    public weak var channelHooks: (any ChatSessionChannelHooks)?
    public let authorizer: ChatToolConsentAuthorizer
    /// `false` for channels that never read the session transcript, so a
    /// long-lived session does not retain a copy nobody presents or saves.
    let retainsTranscript: Bool
    /// `false` for channels that never present the artifact history
    /// (`/artifacts`): finished turns are dropped once sealed.
    let retainsFileArtifactHistory: Bool

    /// The active session. Channels set it when they switch, restore, or
    /// reset the session; a running turn stops writing back once it changes.
    public internal(set) var sessionID: String
    var cacheKey: String?
    var history: [AgentRuntimeMessage] = []
    /// Detailed presentation/save transcript, bounded independently of the
    /// runtime context (see ``maximumTranscriptBytes``).
    public internal(set) var transcript: [AgentRuntimeMessage] = [] {
        didSet { transcriptByteCountIsStale = true }
    }
    var transcriptRetainedByteCount = 0
    /// `true` once ``transcript`` changed after ``transcriptRetainedByteCount``
    /// was last counted, so the next append counts it again. The empty initial
    /// transcript is counted (0 bytes).
    var transcriptByteCountIsStale = false
    /// Transient `/plan` and `/goal` state and the turn fence, shared with
    /// the channel under one lock.
    nonisolated let stateStore = ChatSessionStateStore()
    var lastFileChangeSummary: TurnFileChangeSummary?
    /// The attachments `/attach` staged for the next prompt the operator
    /// sends (see ``consumePendingAttachments()``). Transient: never saved
    /// with the session.
    var pendingAttachments: [AgentRuntimeAttachment] = []
    /// Runtime-only artifact history. It is never serialized with a session.
    var fileArtifactHistory = SessionFileArtifactHistory()
    var activeFileArtifactTurn: ChatFileArtifactTurn?
    /// Publishes the task-graph overview while the graph changes, from the
    /// moment the channel starts it (see ``startTaskGraphObserver()``).
    let taskGraphObserver = ChatTaskGraphObserver()
    /// Publishes the sub-agent overview while a blocking `agent.*` tool call
    /// executes, from the moment the channel starts it (see
    /// ``startSubAgentOverviewRefreshIfNeeded(presenter:)``).
    let subAgentOverviewRefresher = ChatSubAgentOverviewRefresher()
    /// The slash commands ``handleCommandLine(_:context:)`` resolves: the
    /// shared ones, with the channel's own commands among them. The channel
    /// sets it when it has commands of its own; until then only the shared
    /// commands are known.
    public var commandRegistry = ChatCommandRegistry(shared: ChatCommandRegistry.sharedDescriptors)
    /// The host whose slot runs this controller as one incarnation, with the
    /// slot, set by the host as it creates the controller; `nil` for a
    /// controller a channel runs on its own. The operations that replace the
    /// session (``startNewSession(newSessionID:)``,
    /// ``loadSavedSession(_:checkpointEntryID:)``) go through it: a new
    /// incarnation of the slot, with a new controller, instead of a switch
    /// in place; this controller is fenced and runs nothing afterwards.
    var hostBinding: ChatSessionHostBinding?

    /// The agent, model, thinking, tool, and skill choices of the session. A
    /// new controller starts from the launch agent and the launch's explicit
    /// model.
    public internal(set) var selection: ChatSessionSelection
    /// The link to the saved session and the prompt it was restored with.
    public internal(set) var savedSessionState = ChatSavedSessionState()
    /// The launch-folder listing read for the selected agent when its role
    /// delegates by role, together with the selection it was read for. The
    /// prompt is recomposed on every send, so the listing must be a snapshot
    /// taken at selection time instead of a fresh scan: selecting an agent and
    /// loading a saved session clear it, and the next composition (the session
    /// creation) reads the folder again. Transient: never copied into
    /// snapshots, checkpoints, or persisted session models.
    var launchFolderProjectsCache: LaunchFolderProjectsCache?
    /// The installed prompt skills, discovered on first use. Cleared when a
    /// skill is installed or uninstalled.
    var availableSkillsCache: [PromptSkill]?

    /// A launch-folder listing and the key (see
    /// ``ProjectAgentSelectionStore/selectionKey(for:)``) of the agent
    /// selection it was read for.
    struct LaunchFolderProjectsCache: Sendable {
        let agentKey: String
        let projects: LaunchFolderProjects
    }

    /// A controller that only runs turns: session operations and the MCP part
    /// of the tool catalog are unavailable (``managementRuntime`` is `nil`).
    ///
    /// Nonisolated so channels living in another isolation domain can create
    /// a session's controller synchronously.
    public nonisolated convenience init(
        sessionID: String,
        runtime: any ChatSessionRuntime,
        environment: ChatSessionEnvironment,
        workingDirectory: URL,
        presenter: any ChatSessionPresenter,
        host: any ChatInteractionHost,
        authorizer: ChatToolConsentAuthorizer,
        retainsTranscript: Bool = true,
        retainsFileArtifactHistory: Bool = true
    ) {
        self.init(
            sessionID: sessionID,
            runtime: runtime,
            managementRuntime: nil,
            environment: environment,
            workingDirectory: workingDirectory,
            presenter: presenter,
            host: host,
            authorizer: authorizer,
            retainsTranscript: retainsTranscript,
            retainsFileArtifactHistory: retainsFileArtifactHistory
        )
    }

    /// A controller that runs turns and the session operations on
    /// `managementRuntime`.
    ///
    /// Nonisolated so channels living in another isolation domain (the ACP
    /// bridge actor) can create a session's controller synchronously.
    public nonisolated convenience init(
        sessionID: String,
        managementRuntime: any ChatSessionManagementRuntime,
        environment: ChatSessionEnvironment,
        workingDirectory: URL,
        presenter: any ChatSessionPresenter,
        host: any ChatInteractionHost,
        authorizer: ChatToolConsentAuthorizer,
        retainsTranscript: Bool = true,
        retainsFileArtifactHistory: Bool = true
    ) {
        self.init(
            sessionID: sessionID,
            runtime: managementRuntime,
            managementRuntime: managementRuntime,
            environment: environment,
            workingDirectory: workingDirectory,
            presenter: presenter,
            host: host,
            authorizer: authorizer,
            retainsTranscript: retainsTranscript,
            retainsFileArtifactHistory: retainsFileArtifactHistory
        )
    }

    private nonisolated init(
        sessionID: String,
        runtime: any ChatSessionRuntime,
        managementRuntime: (any ChatSessionManagementRuntime)?,
        environment: ChatSessionEnvironment,
        workingDirectory: URL,
        presenter: any ChatSessionPresenter,
        host: any ChatInteractionHost,
        authorizer: ChatToolConsentAuthorizer,
        retainsTranscript: Bool,
        retainsFileArtifactHistory: Bool
    ) {
        self.sessionID = sessionID
        self.runtime = runtime
        self.managementRuntime = managementRuntime
        self.environment = environment
        self.modelCatalog = ChatModelCatalog(environment: environment)
        self.selection = Self.initialSelection(for: environment)
        self.workingDirectory = workingDirectory
        self.presenter = presenter
        self.host = host
        self.authorizer = authorizer
        self.retainsTranscript = retainsTranscript
        self.retainsFileArtifactHistory = retainsFileArtifactHistory
    }

    // MARK: - Presentation

    /// The selection a new controller starts from: the launch agent and the
    /// launch's explicit model. A reducer created before its controller is
    /// seeded with it.
    nonisolated static func initialSelection(for environment: ChatSessionEnvironment) -> ChatSessionSelection {
        ChatSessionSelection(
            agent: environment.launchAgent,
            modelIDOverride: environment.explicitModelID
        )
    }

    /// Adds `observer`, which from now on receives every call of the
    /// presenter before the channel's presenter does, whatever channel
    /// presents the session, a turn already running included (see
    /// ``ChatObservedPresenter``). The controller holds it until it is
    /// removed. Adding an observer that is already added changes nothing.
    public func addObserver(_ observer: any ChatSessionObserver) {
        let identifier = ObjectIdentifier(observer)
        guard !observers.contains(where: { ObjectIdentifier($0) == identifier }) else {
            return
        }
        observers.append(observer)
    }

    /// Removes `observer`, identified by its object identity, and releases
    /// it: it receives nothing more, a turn already running included.
    /// Removing an observer that is not added changes nothing.
    public func removeObserver(_ observer: any ChatSessionObserver) {
        let identifier = ObjectIdentifier(observer)
        observers.removeAll { ObjectIdentifier($0) == identifier }
    }

    /// The presenter an operation presents on: the request's presenter, or
    /// the controller's when the request binds none or there is no request,
    /// with the observers presented first, read at every call.
    func effectivePresenter(for request: ChatTurnRequest?) -> any ChatSessionPresenter {
        ChatObservedPresenter(primary: request?.presenter ?? presenter, controller: self)
    }

    // MARK: - Command state shortcuts

    /// Transient `/plan` and `/goal` state. Never persisted except
    /// ``ChatCommandState/activePlan``. A snapshot: write it, and run every
    /// read-check-write sequence, through ``ChatSessionStateStore/withLock(_:)``.
    nonisolated var commandState: ChatCommandState {
        stateStore.commandState
    }

    /// The approved plan the session follows, if any. Unlike the rest of the
    /// command state, a channel may persist it with the session.
    public internal(set) var activePlan: TerminalSessionPlan? {
        get { commandState.activePlan }
        set { stateStore.withLock { $0.commandState.activePlan = newValue } }
    }

    var planBrainstorming: PlanningCommandRuntimeState? {
        get { commandState.planBrainstorming }
        set { stateStore.withLock { $0.commandState.planBrainstorming = newValue } }
    }

    var pendingPlanApprovalPlanID: String? {
        get { commandState.pendingPlanApprovalPlanID }
        set { stateStore.withLock { $0.commandState.pendingPlanApprovalPlanID = newValue } }
    }

    var activeWorkflow: WorkflowCommandRuntimeState? {
        get { commandState.activeWorkflow }
        set { stateStore.withLock { $0.commandState.activeWorkflow = newValue } }
    }

    /// Coordinator tools the purpose adds to the session grant, from the single
    /// table in ``ChatTurnPurpose/additionalToolNames(activePlan:)``. Channels
    /// apply them while building the turn configuration, because the grant
    /// also shapes the system prompt and the profile tool policy.
    public nonisolated func additionalToolNames(for purpose: ChatTurnPurpose) -> Set<String> {
        purpose.additionalToolNames(activePlan: commandState.activePlan)
    }

    // MARK: - Turn fence

    /// `true` while the turn identified by `token`, started on `sessionID`,
    /// may still write session state back. A `nil` token checks the session
    /// only, for operations that run outside a turn.
    func isCurrentTurn(_ token: UUID?, sessionID turnSessionID: String) -> Bool {
        sessionID == turnSessionID && stateStore.withLock { state in
            token == nil || state.activeTurnToken == token
        }
    }

    /// Runs `body` on the command state only while the turn is current, in
    /// one locked step. Returns `false` (without running `body`) otherwise.
    @discardableResult
    func updateCommandStateIfCurrent(
        _ token: UUID?,
        sessionID turnSessionID: String,
        _ body: (inout ChatCommandState) -> Void
    ) -> Bool {
        guard sessionID == turnSessionID else { return false }
        return commitCommandState(ifToken: token, body)
    }

    /// The fenced write every command-state commit goes through: runs `body`
    /// on the command state while `token` is the turn token, in the same
    /// locked step that checks it, and returns `false` (without running
    /// `body`) otherwise. A `nil` token always runs `body`. It checks the
    /// token only; callers that also fence on the session check it first.
    @discardableResult
    nonisolated func commitCommandState(
        ifToken token: UUID?,
        _ body: (inout ChatCommandState) -> Void
    ) -> Bool {
        stateStore.withLock { state in
            guard token == nil || state.activeTurnToken == token else { return false }
            body(&state.commandState)
            return true
        }
    }

    func beginTurnToken() -> UUID {
        let token = UUID()
        stateStore.withLock { $0.activeTurnToken = token }
        return token
    }

    func endTurnToken(_ token: UUID) {
        stateStore.withLock { state in
            if state.activeTurnToken == token {
                state.activeTurnToken = nil
            }
        }
    }

    /// Invalidates the running turn: from now on it cannot write session
    /// state back. A cancelled `/goal` turn is armed for recovery in the same
    /// locked step, so the next message can resume its workflow.
    public nonisolated func cancelActiveTurn(armingWorkflowRecovery: Bool = false) {
        stateStore.withLock { state in
            state.activeTurnToken = nil
            guard armingWorkflowRecovery, var workflow = state.commandState.activeWorkflow else {
                return
            }
            if !workflow.isAwaitingReply {
                workflow.armForRecoverableFailure(reason: "cancelled")
            }
            state.commandState.activeWorkflow = workflow
        }
    }

    // MARK: - Transcript retention

    /// The runtime conversation has its own context-window compaction, but the
    /// presentation/save transcript historically retained every detailed tool and
    /// reasoning block forever. Keep that secondary copy bounded independently.
    nonisolated static let maximumTranscriptBytes = 128 * 1_024 * 1_024

    private nonisolated static let transcriptTruncationNotice =
        "[Earlier detailed transcript omitted to keep session memory bounded.]"

    func replaceTranscript(with messages: [AgentRuntimeMessage]) {
        transcript = Self.boundedTranscript(messages)
        synchronizeTranscriptByteCount()
    }

    func appendTranscript(_ message: AgentRuntimeMessage) {
        appendTranscript(contentsOf: [message])
    }

    func appendTranscript(contentsOf messages: [AgentRuntimeMessage]) {
        guard !messages.isEmpty else { return }
        synchronizeTranscriptByteCountIfNeeded()
        transcript.append(contentsOf: messages)
        transcriptRetainedByteCount = Self.saturatingSum(
            transcriptRetainedByteCount,
            Self.transcriptRetainedByteCount(messages)
        )
        transcriptByteCountIsStale = false

        guard transcriptRetainedByteCount > Self.maximumTranscriptBytes else {
            return
        }
        transcript = Self.boundedTranscript(transcript)
        synchronizeTranscriptByteCount()
    }

    nonisolated static func boundedTranscript(
        _ messages: [AgentRuntimeMessage],
        maximumBytes: Int = maximumTranscriptBytes
    ) -> [AgentRuntimeMessage] {
        let maximumBytes = max(1, maximumBytes)
        guard transcriptRetainedByteCount(messages) > maximumBytes else {
            return messages
        }

        let notice = AgentRuntimeMessage(
            role: .system,
            content: transcriptTruncationNotice
        )
        let noticeBytes = transcriptRetainedByteCount(notice)
        var remainingBytes = max(0, maximumBytes - noticeBytes)
        var retainedNewestFirst: [AgentRuntimeMessage] = []

        for message in messages.reversed() {
            // Rebounding an already-truncated transcript replaces its old marker
            // rather than stacking another marker every time the cap is reached.
            if message.role == .system,
               message.content == transcriptTruncationNotice {
                continue
            }
            let messageBytes = transcriptRetainedByteCount(message)
            guard messageBytes <= remainingBytes else { break }
            retainedNewestFirst.append(message)
            remainingBytes -= messageBytes
        }

        return [notice] + Array(retainedNewestFirst.reversed())
    }

    nonisolated static func transcriptRetainedByteCount(
        _ messages: [AgentRuntimeMessage]
    ) -> Int {
        messages.reduce(0) { partial, message in
            saturatingSum(partial, transcriptRetainedByteCount(message))
        }
    }

    nonisolated static func transcriptRetainedByteCount(
        _ message: AgentRuntimeMessage
    ) -> Int {
        var total = 256 // Value/array storage overhead; deliberately conservative.
        addRetainedBytes(message.content, to: &total)
        addRetainedBytes(message.reasoningContent, to: &total)
        addRetainedBytes(message.reasoningItemsJSON, to: &total)
        addRetainedBytes(message.thinkingBlocksJSON, to: &total)
        addRetainedBytes(message.anthropicContentBlocksJSON, to: &total)
        addRetainedBytes(message.providerResponseID, to: &total)
        addRetainedBytes(message.toolCallID, to: &total)
        addRetainedBytes(message.toolName, to: &total)

        for attachment in message.attachments {
            total = saturatingSum(total, transcriptRetainedByteCount(attachment))
        }
        for toolCall in message.toolCalls {
            total = saturatingSum(
                total,
                transcriptRetainedToolCallByteCount(
                    id: toolCall.id,
                    name: toolCall.name,
                    argumentsJSON: toolCall.argumentsJSON
                )
            )
        }
        return total
    }

    /// The retained bytes of one attachment, counted the same way in the
    /// transcript and in the session log (see ``ChatTurnEntry``).
    nonisolated static func transcriptRetainedByteCount(
        _ attachment: AgentRuntimeAttachment
    ) -> Int {
        var total = 128
        total = saturatingSum(total, attachment.data?.count ?? 0)
        addRetainedBytes(attachment.fileURL?.path, to: &total)
        addRetainedBytes(attachment.contentType, to: &total)
        addRetainedBytes(attachment.originalFilename, to: &total)
        return total
    }

    /// The retained bytes of one tool call, counted the same way in the
    /// transcript and in the session log (see ``ChatTurnEntry``).
    nonisolated static func transcriptRetainedToolCallByteCount(
        id: String?,
        name: String,
        argumentsJSON: String
    ) -> Int {
        var total = 96
        addRetainedBytes(id, to: &total)
        addRetainedBytes(name, to: &total)
        addRetainedBytes(argumentsJSON, to: &total)
        return total
    }

    private func synchronizeTranscriptByteCountIfNeeded() {
        guard transcriptByteCountIsStale else {
            return
        }
        synchronizeTranscriptByteCount()
    }

    private func synchronizeTranscriptByteCount() {
        transcriptRetainedByteCount = Self.transcriptRetainedByteCount(transcript)
        transcriptByteCountIsStale = false
    }

    nonisolated static func addRetainedBytes(_ text: String?, to total: inout Int) {
        total = saturatingSum(total, text?.utf8.count ?? 0)
    }

    nonisolated static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        guard rhs <= Int.max - lhs else { return Int.max }
        return lhs + rhs
    }
}
