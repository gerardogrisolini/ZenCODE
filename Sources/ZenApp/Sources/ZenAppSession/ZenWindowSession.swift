//
//  ZenWindowSession.swift
//  ZenApp
//
//  One window of the app: one slot of the session host, the observable state
//  of its session, and the operator's actions on it.
//

import Foundation
import Observation
import Synchronization
import ToolCore
import ZenCODECore

/// The session of one window: one slot of the app's `ChatSessionHost`, which
/// runs one incarnation at a time (a new or loaded session replaces it).
///
/// The window renders the state of the current incarnation's reducer: the
/// closed rows (``transcript``), the block still streaming (``liveThought``,
/// ``liveAssistantText``), the status bar (``status``), and the request it
/// waits for (``pendingRequest``). Each is published on its own and assigned
/// only when it changes, so a streamed token touches the live block alone.
/// A prompt a command built (`/plan`, `/goal`, `/review`, an approved plan, a
/// Planner continuation) is hidden, as in the terminal: its turn shows, its
/// prompt does not. A reply the operator typed that the session absorbs (the
/// goal of `/plan approve`, a Planner question, a `/goal` workflow) shows as
/// their prompt, a local row, while the prompt it built stays hidden.
///
/// Lines run through one serial executor, as in the terminal: one line at a
/// time (a turn, or a command that waits for an answer); a command that runs
/// while a prompt is generating runs beside it, a prompt waits in
/// ``queuedLines`` (at most ``queueCapacity``), any other command is refused.
///
/// The file artifacts of the transcript show in the artifacts sidebar
/// (``fileArtifacts``), which only the operator shows and hides
/// (``toggleArtifactsSidebar()``, `/artifacts`).
///
/// The window has tabs (``tabs``): the conversation (``ZenWindowTab/chat``),
/// always first and never closed, then the transcript of each sub-agent the
/// operator opened (``openSubAgentTab(_:)``), in the order they were opened,
/// each followed by its own ``ZenSubAgentTranscriptModel``, which keeps what
/// it read for as long as the tab stays open and knows whether its tab is
/// the selected one. Only the operator opens and selects tabs; the commands
/// the operator launches (``run(_:)``, the session operations) select the
/// conversation before they start, so their result shows; a new or loaded
/// session closes the sub-agent tabs and selects the conversation, and
/// closing the window stops them. The tabs are transient state of the
/// window: never saved.
///
/// Every action returns at once; the work runs in tasks that hop to the chat
/// actor.
@MainActor
@Observable
public final class ZenWindowSession: Identifiable {
    /// The capabilities of a window's pending-request host.
    public nonisolated static let capabilities: ChatChannelCapabilities = [
        .toolConsent, .serialConsentDialogs, .liveFileArtifacts, .singleChoice,
        .multipleChoice, .focusedMultipleChoice, .textInput, .externalOpen,
        .attachmentPicker,
    ]
    /// The prompts that wait at most, as in the terminal
    /// (`ChatPromptQueue.defaultCapacity`).
    public nonisolated static let queueCapacity = ChatPromptQueue<String>.defaultCapacity
    /// The answer to a prompt the full queue refuses, the terminal's.
    public nonisolated static let queueFullMessage =
        "ZenCODE: prompt queue is full; wait for the current prompt to finish."

    public nonisolated let id: UUID
    /// The working directory of every session of the window.
    public nonisolated let workspace: URL
    /// The window's slot in the host.
    public nonisolated let slotID: ChatSlotID

    // MARK: Observable state

    /// The epoch of the incarnation the window shows; `nil` before its first
    /// snapshot. It changes with a new or loaded session.
    public private(set) var epoch: UInt64?
    /// The closed rows of the transcript (see ``ZenTranscriptProjection``),
    /// reassigned only when a row changes; the block still streaming is not
    /// here.
    public private(set) var transcript: [ZenTranscriptItem] = []
    /// The reasoning of the block still streaming; empty when none.
    public private(set) var liveThought = ""
    /// The assistant content of the block still streaming; empty when none.
    public private(set) var liveAssistantText = ""
    /// The turn the block still streaming belongs to; `nil` when nothing
    /// streams.
    public private(set) var liveTurnID: Int?
    /// The id of the block still streaming, unique across blocks and
    /// sessions (``ZenTranscriptProjection/liveBlockID(for:)``); `nil` when
    /// nothing streams.
    public private(set) var liveBlockID: String?
    /// The task graph to show: the latest one when it is significant or the
    /// operator asked for it with `/tasks`.
    public private(set) var taskGraph: ChatTaskGraphOverview?
    /// The latest sub-agent overview.
    public private(set) var subAgents = ChatSubAgentOverview(snapshots: [])
    /// The oldest interaction the session waits for.
    public private(set) var pendingRequest: ChatPendingRequest?
    /// A line runs that is not beside another one: a turn, or a command,
    /// possibly waiting for an answer.
    public private(set) var isBusy = false
    /// A turn is generating.
    public private(set) var isGenerating = false
    /// The prompts waiting for the running line to end, oldest first.
    public private(set) var queuedLines: [ZenQueuedLine] = []
    /// The status bar.
    public private(set) var status: ZenWindowStatus
    /// The session's title: the saved name, else one derived from the first
    /// prompt the operator typed in the session
    /// (``ZenTranscriptProjection/title(fromPrompt:limit:)``), else `nil`.
    public private(set) var sessionTitle: String?
    /// The name of the saved session the session was saved to or loaded from.
    public private(set) var currentSavedSessionName: String?
    /// `/exit` ran: the window should close (call ``close()``).
    public private(set) var closeRequested = false
    /// ``close()`` ran, or the runtime shut down.
    public private(set) var isClosed = false
    /// The facts that decide which commands the operator sees.
    public private(set) var commandContext: ChatCommandContext = []
    /// The commands the operator sees now, in display order.
    public private(set) var commandDescriptors: [ChatCommandDescriptor] = ZenAppCommands.visibleDescriptors(in: [])
    /// The text of the input field.
    public var draft = ""
    /// The file artifacts of the transcript's `.fileArtifacts` rows, grouped
    /// by artifact turn (``ZenArtifactTurnGroup/groups(in:)``), for the
    /// artifacts sidebar; reassigned only when they change.
    public private(set) var fileArtifacts: [ZenArtifactTurnGroup] = []
    /// The artifacts sidebar shows. Transient state of the window: never
    /// saved, kept across new and loaded sessions, and changed only by the
    /// operator (``toggleArtifactsSidebar()``, `/artifacts`, the sidebar).
    public var isArtifactsSidebarPresented = false
    /// The tab the window shows. Transient state of the window: never saved,
    /// back to ``ZenWindowTab/chat`` with a new or loaded session and with a
    /// command the operator launches, and otherwise changed only by the
    /// operator (``selectTab(_:)``, ``openSubAgentTab(_:)``,
    /// ``closeSubAgentTab(_:)``).
    public private(set) var selectedTab: ZenWindowTab = .chat
    /// The models of the open sub-agent tabs, in the order the operator
    /// opened them.
    public private(set) var subAgentTabs: [ZenSubAgentTranscriptModel] = []

    /// The latest snapshot of the current incarnation's reducer. Not
    /// observed: a view observes the properties derived from it.
    @ObservationIgnored public private(set) var snapshot: ChatSessionSnapshot?

    /// The block still streaming as rows, reasoning first: `<liveBlockID>-thought`
    /// and `<liveBlockID>-assistant`, each when it is not empty. Computed from
    /// ``liveThought``, ``liveAssistantText``, ``liveTurnID``, and
    /// ``liveBlockID``.
    public var liveItems: [ZenTranscriptItem] {
        guard let liveBlockID else { return [] }
        var items: [ZenTranscriptItem] = []
        if !liveThought.isEmpty {
            items.append(ZenTranscriptItem(
                id: "\(liveBlockID)-thought",
                turnID: liveTurnID,
                content: .thought(liveThought, isStreaming: true)
            ))
        }
        if !liveAssistantText.isEmpty {
            items.append(ZenTranscriptItem(
                id: "\(liveBlockID)-assistant",
                turnID: liveTurnID,
                content: .assistantText(liveAssistantText, isStreaming: true)
            ))
        }
        return items
    }

    /// The saved sessions of the workspace, most recently saved first, from
    /// the shell of the runtime.
    public var savedSessions: [ChatSavedSessionSummary] {
        runtime?.shell.savedSessions[workspace.standardizedFileURL] ?? []
    }

    /// The prompts submitted in this window, oldest first.
    public var promptHistory: [String] {
        history.entries
    }

    /// The tabs of the window: ``ZenWindowTab/chat``, then the open sub-agent
    /// tabs, in the order they were opened.
    public var tabs: [ZenWindowTab] {
        ZenWindowTab.tabs(subAgentIDs: subAgentTabs.map(\.agentID))
    }

    // MARK: Composition

    @ObservationIgnored let sessionHost: ChatSessionHost
    @ObservationIgnored weak var runtime: ZenAppRuntime?
    @ObservationIgnored let hooks: ZenWindowHooks
    @ObservationIgnored let presenter: ZenWindowPresenter
    /// The prompts the turn step hides, for the projection.
    @ObservationIgnored let hiddenPrompts = ZenHiddenPromptMailbox()
    /// The incarnation the window follows.
    @ObservationIgnored private(set) var current: ChatSessionIncarnation
    /// Awaited by the turn step right after it reserved the prompt, for
    /// tests.
    @ObservationIgnored var turnDidReserve: (@Sendable () async -> Void)?

    // MARK: Private state

    @ObservationIgnored private var projection = ZenTranscriptProjection()
    @ObservationIgnored private var history = ZenPromptHistory()
    @ObservationIgnored private var lineTask: Task<Void, Never>?
    /// The stop of the exclusive line that runs, `nil` between lines; a new
    /// one for every line.
    @ObservationIgnored private var lineStop: ZenLineStop?
    @ObservationIgnored private var besideTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var incarnationTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var gitTask: Task<Void, Never>?
    @ObservationIgnored private var gitRefreshPending = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// The model, thinking level, agent, or command context of the next turn
    /// may have changed since they were read.
    @ObservationIgnored private var statusFactsAreStale = true
    /// The latest read of the status facts; an older read that ends later is
    /// dropped.
    @ObservationIgnored private var statusFactsGeneration = 0
    /// The number of reads of the status facts, for tests.
    @ObservationIgnored private(set) var statusFactsReadCount = 0
    @ObservationIgnored private var lastSnapshotTaskGraph: ChatTaskGraphOverview?
    @ObservationIgnored private var explicitTaskGraphID: String?

    private init(
        id: UUID,
        workspace: URL,
        runtime: ZenAppRuntime,
        hooks: ZenWindowHooks,
        presenter: ZenWindowPresenter,
        incarnation: ChatSessionIncarnation
    ) {
        self.id = id
        self.workspace = workspace
        self.slotID = incarnation.slotID
        self.sessionHost = runtime.sessionHost
        self.runtime = runtime
        self.hooks = hooks
        self.presenter = presenter
        self.current = incarnation
        self.status = ZenWindowStatus(workspace: workspace)
    }

    /// Opens a slot for `workspace` and starts its first session: the launch
    /// agent's tools and skills, the task-graph observer, then the slot's
    /// incarnations.
    static func open(runtime: ZenAppRuntime, workspace: URL) async throws -> ZenWindowSession {
        let id = UUID()
        let hooks = ZenWindowHooks()
        let presenter = ZenWindowPresenter()
        let sessionHost = runtime.sessionHost
        let descriptor = ChatSlotDescriptor(
            identity: .window(id.uuidString.lowercased()),
            workingDirectory: workspace,
            presenter: presenter,
            interaction: .pendingRequests(
                capabilities: capabilities,
                gatesWorkspaceAccess: false,
                openExternal: runtime.openExternal
            ),
            authorizer: runtime.authorizer,
            channelHooks: hooks,
            commandRegistry: ZenAppCommands.registry,
            defaultOrigin: .app,
            publishesState: true
        )
        let slotID = try await sessionHost.openSlot(descriptor)
        await ZenWindowSteps.bind(hooks: hooks, presenter: presenter, to: sessionHost, slotID: slotID)
        do {
            let incarnation = try await sessionHost.newSession(
                in: slotID,
                sessionID: "\(ChatSlotDescriptor.defaultSessionIDPrefix)-\(UUID().uuidString.lowercased())"
            )
            let controller = incarnation.controller
            await controller.applyInitialAgentSelectionIfNeeded()
            try await controller.applyInitialSkillSelectionIfNeeded()
            // The first session's observer; the hooks move it with the
            // session from now on.
            await controller.startTaskGraphObserver()
            let window = ZenWindowSession(
                id: id,
                workspace: workspace,
                runtime: runtime,
                hooks: hooks,
                presenter: presenter,
                incarnation: incarnation
            )
            await window.start()
            return window
        } catch {
            await sessionHost.closeSlot(slotID)
            throw error
        }
    }

    private func start() async {
        await ZenWindowSteps.setHandlers(
            presenter: presenter,
            hooks: hooks,
            fileMutation: { [weak self] in
                Task { @MainActor in self?.refreshGitStatus() }
            },
            statusFacts: { [weak self] in
                Task { @MainActor in self?.statusFactsDidChange() }
            }
        )
        observeSnapshots(of: current)
        let incarnations = await sessionHost.incarnations(in: slotID)
        incarnationTask = Task { [weak self] in
            for await incarnation in incarnations {
                guard let self else { return }
                await self.follow(incarnation)
            }
        }
        await refreshStatus()
        refreshGitStatus()
    }

    // MARK: - Following the slot

    /// Follows a new incarnation of the slot: its snapshots, and its status
    /// facts. The hooks move the task-graph observer with it.
    private func follow(_ incarnation: ChatSessionIncarnation?) async {
        // A slot without session keeps showing the last one.
        guard !isClosed, let incarnation, incarnation.epoch != current.epoch else { return }
        current = incarnation
        // The sub-agents of the earlier session are not this one's.
        closeSubAgentTabs()
        explicitTaskGraphID = nil
        lastSnapshotTaskGraph = nil
        if taskGraph != nil {
            taskGraph = nil
        }
        await hooks.resetResponseLanguageLock(unlessLockedIn: incarnation.epoch)
        guard !isClosed, current.epoch == incarnation.epoch else { return }
        observeSnapshots(of: incarnation)
        statusFactsDidChange()
    }

    private func observeSnapshots(of incarnation: ChatSessionIncarnation) {
        snapshotTask?.cancel()
        guard let reducer = incarnation.reducer else { return }
        snapshotTask = Task { [weak self] in
            let snapshots = await reducer.snapshots()
            for await snapshot in snapshots {
                guard let self, !Task.isCancelled else { return }
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: ChatSessionSnapshot) {
        guard !isClosed, snapshot.epoch == current.epoch else { return }
        // The prompts hidden before this snapshot was published.
        for mark in hiddenPrompts.drain() {
            projection.hidePrompt(after: mark.afterSequence, epoch: mark.epoch)
        }
        let wasGenerating = isGenerating
        self.snapshot = snapshot
        if epoch != snapshot.epoch {
            epoch = snapshot.epoch
        }
        if projection.update(with: snapshot) {
            transcript = projection.items
            let groups = ZenArtifactTurnGroup.groups(in: transcript)
            if fileArtifacts != groups {
                fileArtifacts = groups
            }
        }
        updateLiveBlock(from: snapshot)
        updateTaskGraph(from: snapshot)
        if subAgents != snapshot.subAgents {
            subAgents = snapshot.subAgents
        }
        let firstRequest = snapshot.pendingRequests.first
        if pendingRequest != firstRequest {
            pendingRequest = firstRequest
        }
        let generating = snapshot.turn.isGenerating
        if isGenerating != generating {
            isGenerating = generating
        }
        var newStatus = status
        newStatus.isGenerating = generating
        if generating, !wasGenerating {
            newStatus.turnStartedAt = Date()
        }
        newStatus.metrics = snapshot.turn.metrics
        newStatus.contextWindow = snapshot.turn.contextWindow
        newStatus.subscriptionUsage = snapshot.turn.subscriptionUsage
        if newStatus != status {
            status = newStatus
        }
        let savedName = Self.nonBlank(snapshot.savedSession.savedSessionName)
        let title = savedName ?? projection.firstVisiblePromptTitle
        if sessionTitle != title {
            sessionTitle = title
        }
        if currentSavedSessionName != snapshot.savedSession.savedSessionName {
            currentSavedSessionName = snapshot.savedSession.savedSessionName
        }
    }

    /// Publishes the block still streaming, each part on its own.
    private func updateLiveBlock(from snapshot: ChatSessionSnapshot) {
        let turn = snapshot.turn
        if liveThought != turn.liveThought {
            liveThought = turn.liveThought
        }
        if liveAssistantText != turn.liveAssistantText {
            liveAssistantText = turn.liveAssistantText
        }
        let blockID = projection.liveBlockID(for: snapshot)
        let turnID = blockID == nil ? nil : turn.turnID
        if liveTurnID != turnID {
            liveTurnID = turnID
        }
        if liveBlockID != blockID {
            liveBlockID = blockID
        }
    }

    /// Shows the latest graph when it is significant or when it is the graph
    /// the operator asked for with `/tasks`.
    private func updateTaskGraph(from snapshot: ChatSessionSnapshot) {
        guard snapshot.taskGraph != lastSnapshotTaskGraph else { return }
        lastSnapshotTaskGraph = snapshot.taskGraph
        let visible: ChatTaskGraphOverview?
        if let graph = snapshot.taskGraph,
           graph.isSignificant || graph.graph.id == explicitTaskGraphID {
            visible = graph
        } else {
            visible = nil
        }
        if visible != taskGraph {
            taskGraph = visible
        }
    }

    // MARK: - Status

    /// Reads the model, thinking level, agent, and command context of the
    /// next turn from the controller the slot runs now.
    private func refreshStatus() async {
        statusFactsAreStale = false
        statusFactsGeneration &+= 1
        let generation = statusFactsGeneration
        statusFactsReadCount += 1
        let facts = await ZenControllerFacts.read(in: sessionHost, slotID: slotID, hooks: hooks)
        guard !isClosed, generation == statusFactsGeneration, let facts else { return }
        var newStatus = status
        newStatus.modelID = facts.modelID
        newStatus.thinking = facts.thinking
        newStatus.agentName = facts.agentName
        if newStatus != status {
            status = newStatus
        }
        if commandContext != facts.commandContext {
            commandContext = facts.commandContext
            commandDescriptors = ZenAppCommands.visibleDescriptors(in: facts.commandContext)
        }
    }

    /// A hook or a new incarnation changed what the status bar shows: read it
    /// again now when no line runs, otherwise when the line ends.
    private func statusFactsDidChange() {
        guard !isClosed else { return }
        statusFactsAreStale = true
        if !isBusy, besideTasks.isEmpty {
            scheduleStatusRefresh()
        }
    }

    /// Reads the status facts in a task of their own until they are current.
    private func scheduleStatusRefresh() {
        guard !isClosed, statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while let self, self.statusFactsAreStale, !self.isClosed {
                await self.refreshStatus()
            }
            self?.statusTask = nil
        }
    }

    /// Reads the git summary of the workspace again, off the main actor; a
    /// refresh asked while one runs runs once more after it.
    public func refreshGitStatus() {
        guard !isClosed else { return }
        guard gitTask == nil else {
            gitRefreshPending = true
            return
        }
        let workspace = workspace
        gitTask = Task { [weak self] in
            let summary = await ZenGitStatus.summary(in: workspace)
            guard let self else { return }
            self.gitTask = nil
            guard !self.isClosed else { return }
            if self.status.gitStatus != summary {
                self.status.gitStatus = summary
            }
            if self.gitRefreshPending {
                self.gitRefreshPending = false
                self.refreshGitStatus()
            }
        }
    }

    // MARK: - Local rows

    /// Adds a row of the window after the last log entry the reducer holds now.
    private func appendLocal(_ content: ZenTranscriptItem.Content) async {
        guard !isClosed else { return }
        let anchor = await ZenWindowSteps.anchor(in: sessionHost, slotID: slotID)
        guard !isClosed else { return }
        insertLocal(ZenLocalTranscriptItem(
            epoch: anchor?.epoch ?? current.epoch,
            anchorSequence: anchor?.sequence ?? snapshot.map(ZenLocalTranscriptItem.anchorSequence(in:)) ?? 0,
            content: content
        ))
    }

    /// Adds a row of the window at once, after the last log entry the window
    /// has seen.
    private func appendLocalNow(_ content: ZenTranscriptItem.Content) {
        guard !isClosed else { return }
        insertLocal(ZenLocalTranscriptItem(
            epoch: snapshot?.epoch ?? current.epoch,
            anchorSequence: snapshot.map(ZenLocalTranscriptItem.anchorSequence(in:)) ?? 0,
            content: content
        ))
    }

    private func insertLocal(_ item: ZenLocalTranscriptItem) {
        projection.insertLocal(item)
        if projection.composeIfNeeded() {
            transcript = projection.items
        }
    }

    /// Shows `line`, a reply the operator typed, as their prompt, as the
    /// terminal does: the session absorbed it (the goal of `/plan approve`, a
    /// Planner question, a `/goal` workflow) and the model receives the
    /// prompt the reply built, which stays hidden. Anchored at `anchor`, read
    /// before the reply ran.
    private func echoReply(_ line: String, anchor: ZenWindowSteps.Anchor?) {
        guard !isClosed else { return }
        insertLocal(ZenLocalTranscriptItem(
            epoch: anchor?.epoch ?? current.epoch,
            anchorSequence: anchor?.sequence ?? snapshot.map(ZenLocalTranscriptItem.anchorSequence(in:)) ?? 0,
            content: .userPrompt(text: line, attachments: [], origin: .app)
        ))
    }

    /// `true` when `outcome` starts a turn whose prompt shows: one the
    /// operator typed.
    private static func startsVisibleTurn(_ outcome: ChatCommandOutcome) -> Bool {
        if case let .startTurn(_, _, locksResponseLanguage) = outcome.action {
            return locksResponseLanguage
        }
        return false
    }

    // MARK: - Lines

    /// Submits ``draft``: records it in the prompt history and routes it as
    /// the terminal does (see ``ZenLineRoute``). The draft is cleared unless
    /// the line is refused. A blank draft does nothing.
    public func submitDraft() {
        let line = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !isClosed else { return }
        history.record(line)
        if route(line) {
            draft = ""
        }
    }

    /// Runs `line` through the window's executor, routed like a submitted
    /// line, without touching the draft or the history. The conversation is
    /// selected first, so the line's result shows (the menu and toolbar
    /// commands come here).
    public func run(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isClosed else { return }
        selectTab(.chat)
        route(trimmed)
    }

    /// Routes `line`; `false` when it was refused.
    @discardableResult
    private func route(_ line: String) -> Bool {
        let route = ZenLineRoute.route(
            for: line,
            isLineRunning: isBusy,
            hasQueuedLines: !queuedLines.isEmpty,
            registry: ZenAppCommands.registry,
            context: commandContext
        )
        switch route {
        case .run:
            startLine(line)
        case .runBeside:
            startBeside(line)
        case .queue:
            guard queuedLines.count < Self.queueCapacity else {
                appendLocalNow(.local(text: Self.queueFullMessage, isFailure: true))
                return false
            }
            queuedLines.append(ZenQueuedLine(text: line))
            drainQueueIfIdle()
        case let .refuse(message):
            appendLocalNow(.local(text: message, isFailure: true))
            return false
        }
        return true
    }

    private func startLine(_ line: String) {
        startExclusive { [weak self] stop in
            await self?.execute(line, stop: stop)
        }
    }

    /// Runs `work` as the one line of the executor, with a stop of its own
    /// (a stop of the previous line does not reach it); the queue drains
    /// after it.
    private func startExclusive(_ work: @escaping @MainActor (ZenLineStop) async -> Void) {
        isBusy = true
        let stop = ZenLineStop()
        lineStop = stop
        lineTask = Task { [weak self] in
            await work(stop)
            self?.lineDidEnd()
        }
    }

    private func lineDidEnd() {
        lineTask = nil
        lineStop = nil
        isBusy = false
        guard !isClosed else { return }
        if statusFactsAreStale {
            scheduleStatusRefresh()
        }
        drainQueueIfIdle()
    }

    private func drainQueueIfIdle() {
        guard !isBusy, !isClosed, !queuedLines.isEmpty else { return }
        let next = queuedLines.removeFirst()
        startLine(next.text)
    }

    private func startBeside(_ line: String) {
        let token = UUID()
        besideTasks[token] = Task { [weak self] in
            // Stop ends the exclusive line, not a command beside it.
            await self?.execute(line, stop: ZenLineStop())
            guard let self else { return }
            self.besideTasks[token] = nil
            if self.statusFactsAreStale, !self.isBusy, self.besideTasks.isEmpty {
                self.scheduleStatusRefresh()
            }
        }
    }

    /// Removes a prompt from the queue before it runs.
    public func removeQueuedLine(_ id: UUID) {
        queuedLines.removeAll { $0.id == id }
    }

    /// The flow of one line (Docs/embedding.md, "Running a Line"), then the
    /// status facts when the line may have changed them, and the git summary.
    /// `stop` keeps a turn the line builds from starting once the operator
    /// stopped the line.
    private func execute(_ line: String, stop: ZenLineStop) async {
        guard !isClosed else { return }
        await perform(line, stop: stop)
        guard !isClosed else { return }
        if ZenAppCommands.changesStatusFacts(line) {
            statusFactsAreStale = true
        }
        if statusFactsAreStale {
            await refreshStatus()
        }
        refreshGitStatus()
    }

    private func perform(_ line: String, stop: ZenLineStop) async {
        if case let .refused(text) = await sessionHost.admitLine(line, in: slotID) {
            await appendLocal(.local(text: text, isFailure: true))
            return
        }
        guard let incarnation = await sessionHost.incarnation(in: slotID) else {
            await appendLocal(.local(text: Self.text(for: ChatSessionHostError.noSession), isFailure: true))
            return
        }
        let controller = incarnation.controller
        var prompt = line
        var purpose = ChatTurnPurpose.normal
        var typedByOperator = true

        let isCommand = line.hasPrefix("/")
        let outcome: ChatCommandOutcome?
        if isCommand {
            await appendLocal(.commandLine(line))
            outcome = await controller.handleCommandLine(line, context: commandContext)
        } else {
            // Read before the reply runs, so its echo precedes what it shows.
            let anchor = await ZenWindowSteps.anchor(in: sessionHost, slotID: slotID)
            outcome = await controller.pendingReplyAction(for: line)
            if let outcome, !Self.startsVisibleTurn(outcome) {
                echoReply(line, anchor: anchor)
            }
        }
        guard !isClosed else { return }
        if let outcome {
            await ZenWindowSteps.present(outcome.notices, in: sessionHost, slotID: slotID)
            if isCommand, ZenAppCommands.registry.descriptor(forLine: line)?.command == "/tasks" {
                await showRequestedTaskGraph()
            }
            switch outcome.action {
            case let .startTurn(commandPrompt, commandPurpose, locksResponseLanguage):
                prompt = commandPrompt
                purpose = commandPurpose
                typedByOperator = locksResponseLanguage
            case .channelCommand:
                await runChannelCommand(line)
                return
            default:
                return
            }
        }
        guard !isClosed else { return }
        await runTurn(
            prompt: prompt,
            purpose: purpose,
            typedByOperator: typedByOperator,
            stop: stop,
            controller: controller
        )
    }

    /// The commands only the window runs: `/exit`, and `/artifacts`, which
    /// toggles the artifacts sidebar (with arguments it answers the core's
    /// notice and toggles nothing); every other channel command of the
    /// shared layer is not offered by the app.
    private func runChannelCommand(_ line: String) async {
        switch ZenAppCommands.registry.descriptor(forLine: line)?.command {
        case ZenAppCommands.exit.command:
            closeRequested = true
        case ZenAppCommands.artifacts.command:
            let arguments = ChatCommandRegistry.arguments(from: line, commandPrefix: ZenAppCommands.artifacts.command)
            if arguments.isEmpty {
                toggleArtifactsSidebar()
            } else {
                await ZenWindowSteps.present([.artifactsTakeNoArguments], in: sessionHost, slotID: slotID)
            }
        default:
            await appendLocal(.local(text: "`\(line)` is not available in the app.", isFailure: true))
        }
    }

    /// Shows the artifacts sidebar when it is hidden, hides it otherwise.
    public func toggleArtifactsSidebar() {
        isArtifactsSidebarPresented.toggle()
    }

    // MARK: - Tabs

    /// The model of the open tab of the sub-agent `agentID`; `nil` when no
    /// such tab is open.
    public func subAgentTab(_ agentID: String) -> ZenSubAgentTranscriptModel? {
        subAgentTabs.first { $0.agentID == agentID }
    }

    /// Opens the tab of the sub-agent `agentID` of the current session, after
    /// the open ones, unless it is open already, and selects it. The tab
    /// starts with the agent's snapshot from the latest overview and follows
    /// the agent from then on, selected before it starts.
    public func openSubAgentTab(_ agentID: String) {
        guard !isClosed else { return }
        guard subAgentTab(agentID) == nil else {
            selectTab(.subAgent(agentID))
            return
        }
        let model = ZenSubAgentTranscriptModel(
            agentID: agentID,
            snapshot: subAgents.snapshots.first { $0.id == agentID },
            source: .incarnation(epoch: current.epoch, agentID: agentID, in: sessionHost, slotID: slotID)
        )
        subAgentTabs.append(model)
        selectTab(.subAgent(agentID))
        model.start()
    }

    /// Closes the tab of the sub-agent `agentID` and stops its model. When it
    /// was selected, the tab after it is selected, else the one before it
    /// (``ZenWindowTab/selection(afterClosing:in:selected:)``).
    public func closeSubAgentTab(_ agentID: String) {
        guard let index = subAgentTabs.firstIndex(where: { $0.agentID == agentID }) else { return }
        let selection = ZenWindowTab.selection(afterClosing: agentID, in: tabs, selected: selectedTab)
        subAgentTabs[index].stop()
        subAgentTabs.remove(at: index)
        setSelectedTab(selection)
    }

    /// Selects `tab`, when it is ``ZenWindowTab/chat`` or an open sub-agent
    /// tab.
    public func selectTab(_ tab: ZenWindowTab) {
        guard tabs.contains(tab) else { return }
        setSelectedTab(tab)
    }

    /// Selects `tab` and tells every sub-agent model whether its tab is the
    /// selected one (``ZenSubAgentTranscriptModel/isSelected``).
    private func setSelectedTab(_ tab: ZenWindowTab) {
        if selectedTab != tab {
            selectedTab = tab
        }
        for model in subAgentTabs {
            let isSelected = tab == .subAgent(model.agentID)
            if model.isSelected != isSelected {
                model.isSelected = isSelected
            }
        }
    }

    /// Closes every sub-agent tab, stopping their models, and selects the
    /// conversation.
    private func closeSubAgentTabs() {
        stopSubAgentTabs()
        if !subAgentTabs.isEmpty {
            subAgentTabs = []
        }
        setSelectedTab(.chat)
    }

    private func stopSubAgentTabs() {
        for model in subAgentTabs {
            model.stop()
        }
    }

    /// Runs one turn in one chat-actor step (see
    /// ``ZenWindowSteps/runTurn(_:controller:in:slotID:hooks:hiddenPrompts:didReserve:)``),
    /// then shows how it ended.
    private func runTurn(
        prompt: String,
        purpose: ChatTurnPurpose,
        typedByOperator: Bool,
        stop: ZenLineStop,
        controller: ChatSessionController
    ) async {
        let outcome = await ZenWindowSteps.runTurn(
            ZenTurnStart(prompt: prompt, purpose: purpose, typedByOperator: typedByOperator, stop: stop),
            controller: controller,
            in: sessionHost,
            slotID: slotID,
            hooks: hooks,
            hiddenPrompts: hiddenPrompts,
            didReserve: turnDidReserve
        )
        switch outcome {
        case .finished:
            break
        case let .refused(error):
            await appendLocal(.local(text: Self.text(for: error), isFailure: true))
        case .cancelledBeforeStart:
            await appendLocal(.local(text: Self.turnCancelledText, isFailure: false))
        case let .failed(error):
            if let failure = error as? ChatTurnFailure {
                if failure.isCancellation {
                    await appendLocal(.local(text: Self.turnCancelledText, isFailure: false))
                } else {
                    await appendLocal(.local(
                        text: "Turn failed: \(failure.underlying.localizedDescription)",
                        isFailure: true
                    ))
                }
            } else {
                await appendLocal(.local(text: error.localizedDescription, isFailure: true))
            }
        }
    }

    /// `/tasks` shows the graph it published, significant or not.
    private func showRequestedTaskGraph() async {
        let graph = await ZenWindowSteps.taskGraph(in: sessionHost, slotID: slotID)
        guard !isClosed else { return }
        explicitTaskGraphID = graph?.graph.id
        lastSnapshotTaskGraph = graph
        if taskGraph != graph {
            taskGraph = graph
        }
    }

    // MARK: - Stop and answers

    /// Esc of the terminal: cancels the turn that runs (the host fences it
    /// and drops its reservation, then the line's task is cancelled) and
    /// refuses the open requests, so a command waiting for an answer unwinds.
    /// The line's stop is set at once, before anything suspends, so a turn
    /// the line has not started yet never starts, reserved or not. The queue
    /// is kept.
    public func stop() {
        guard !isClosed else { return }
        lineStop?.request()
        let sessionHost = sessionHost
        let slotID = slotID
        let line = lineTask
        Task {
            if await ZenWindowSteps.stop(in: sessionHost, slotID: slotID) {
                line?.cancel()
            }
        }
    }

    /// Answers the pending request `requestID` of the session the slot runs
    /// now; `nil` refuses it.
    public func answer(_ requestID: UUID, with answer: ChatPendingRequest.Answer?) {
        guard !isClosed else { return }
        let sessionHost = sessionHost
        let slotID = slotID
        Task {
            await ZenWindowSteps.answer(requestID, with: answer, in: sessionHost, slotID: slotID)
        }
    }

    // MARK: - History

    /// Puts the previous prompt of the history in the draft (↑ of the
    /// terminal); `false` when there is nothing older.
    @discardableResult
    public func recallPreviousPrompt() -> Bool {
        guard let text = history.recallPrevious(currentDraft: draft) else { return false }
        draft = text
        return true
    }

    /// Puts the next prompt of the history in the draft, or the draft from
    /// before the recall past the newest one (↓ of the terminal); `false`
    /// when no recall is in progress.
    @discardableResult
    public func recallNextPrompt() -> Bool {
        guard let text = history.recallNext(currentDraft: draft) else { return false }
        draft = text
        return true
    }

    // MARK: - Attachments

    /// Stages `urls` for the next prompt, one `/attach` command per file, as
    /// one line of the executor. Refused while a line runs.
    public func attach(_ urls: [URL]) {
        guard !isClosed, !urls.isEmpty else { return }
        let lines = urls.map(Self.attachCommandLine(for:))
        guard !isBusy else {
            refuseWhileBusy(command: "/attach")
            return
        }
        startExclusive { [weak self] stop in
            for line in lines {
                await self?.execute(line, stop: stop)
            }
        }
    }

    /// `/attach "<path>"`, with the quotes and backslashes of the path
    /// escaped for the `/attach` argument splitter.
    static func attachCommandLine(for url: URL) -> String {
        let path = url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "/attach \"\(escaped)\""
    }

    // MARK: - Sessions

    /// `/sessions new`. Refused while a line runs. Selects the conversation
    /// first, as every session operation does, so its result shows.
    public func startNewSession() {
        runOperationLine("/sessions new")
    }

    /// `/sessions save`. Refused while a line runs.
    public func saveSession() {
        runOperationLine("/sessions save")
    }

    /// Loads the saved session `name` of the workspace into a new
    /// incarnation. Refused while a line runs.
    public func loadSavedSession(named name: String) {
        guard !isClosed else { return }
        selectTab(.chat)
        guard !isBusy else {
            refuseWhileBusy(command: "/sessions")
            return
        }
        startExclusive { [weak self] _ in
            await self?.performLoad(named: name)
        }
    }

    /// Deletes the saved session `name` of the workspace. Refused while a
    /// line runs.
    public func deleteSavedSession(named name: String) {
        guard !isClosed else { return }
        selectTab(.chat)
        guard !isBusy else {
            refuseWhileBusy(command: "/sessions")
            return
        }
        startExclusive { [weak self] _ in
            await self?.performDelete(named: name)
        }
    }

    private func runOperationLine(_ line: String) {
        guard !isClosed else { return }
        selectTab(.chat)
        guard !isBusy else {
            refuseWhileBusy(command: ZenLineRoute.commandToken(of: line))
            return
        }
        startLine(line)
    }

    private func refuseWhileBusy(command: String) {
        appendLocalNow(.local(
            text: ZenLineRoute.generatingCommandMessage(
                for: command,
                registry: ZenAppCommands.registry,
                context: commandContext
            ),
            isFailure: true
        ))
    }

    private func performLoad(named name: String) async {
        do {
            let outcome = try await sessionHost.loadSavedSession(in: slotID, name: name, checkpointEntryID: nil)
            await ZenWindowSteps.present(outcome.notices, in: sessionHost, slotID: slotID)
        } catch let error as ChatSessionHostError {
            await appendLocal(.local(text: Self.text(for: error), isFailure: true))
        } catch {
            await appendLocal(.local(text: error.localizedDescription, isFailure: true))
        }
        guard !isClosed else { return }
        // A load changes the incarnation, or tried to.
        await refreshStatus()
        refreshGitStatus()
    }

    private func performDelete(named name: String) async {
        guard let controller = await sessionHost.incarnation(in: slotID)?.controller else {
            await appendLocal(.local(text: Self.text(for: ChatSessionHostError.noSession), isFailure: true))
            return
        }
        do {
            let outcome = try await controller.deleteSavedSessions(names: [name])
            await ZenWindowSteps.present(outcome.notices, in: sessionHost, slotID: slotID)
        } catch {
            await appendLocal(.local(text: error.localizedDescription, isFailure: true))
        }
    }

    // MARK: - Close

    /// Ends the window. It writes nothing from now on; one chat-actor step
    /// closes the slot, which fences the turn that runs, drops its
    /// reservation, and refuses the open requests before it suspends; the
    /// task-graph observer is stopped; then the window's tasks are cancelled
    /// and the runtime forgets the window.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        queuedLines = []
        await ZenWindowSteps.close(sessionHost, slotID: slotID)
        cancelWork()
        runtime?.windowDidClose(self)
    }

    /// Marks the window closed and drops its queue at once, for the
    /// runtime's shutdown: the window writes nothing from now on. Its work
    /// is cancelled by the runtime (``cancelWork()``) only after the host
    /// shutdown fenced every controller, so a cancelled turn cannot write
    /// back first. A second call does nothing.
    func markClosed() {
        guard !isClosed else { return }
        isClosed = true
        queuedLines = []
    }

    /// Cancels the window's tasks and leaves it idle. Called once its slot
    /// ended (``close()``, the runtime's shutdown); a second call does
    /// nothing more.
    func cancelWork() {
        incarnationTask?.cancel()
        incarnationTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        gitTask?.cancel()
        gitTask = nil
        statusTask?.cancel()
        statusTask = nil
        lineTask?.cancel()
        lineTask = nil
        lineStop = nil
        for task in besideTasks.values {
            task.cancel()
        }
        besideTasks = [:]
        queuedLines = []
        isBusy = false
        // The tabs stay as they are; their models stop.
        stopSubAgentTabs()
    }

    // MARK: - Testing

    /// Waits until no line runs, beside or queued, and no status read is
    /// scheduled; `false` when `timeout` passed first.
    func waitUntilIdle(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lineTask == nil, besideTasks.isEmpty, queuedLines.isEmpty, statusTask == nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    // MARK: - Texts

    /// The ending of a turn the operator stopped.
    static let turnCancelledText = "Turn cancelled."

    static func text(for error: ChatSessionHostError) -> String {
        switch error {
        case .sessionBusy:
            "ZenCODE: a prompt is already running in this session."
        case .shutDown:
            "ZenCODE: the app is shutting down."
        case .noSession, .unknownSlot:
            "ZenCODE: this window has no session."
        case let .savedSessionNotFound(name):
            "ZenCODE: saved session '\(name)' not found."
        default:
            "ZenCODE: \(error)"
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

// MARK: - Steps on the chat actor

/// What a turn runs with.
struct ZenTurnStart: Sendable {
    let prompt: String
    let purpose: ChatTurnPurpose
    /// The operator typed the prompt: it locks the response language, takes
    /// the staged attachments, and shows. A prompt a command built does none
    /// of these.
    let typedByOperator: Bool
    /// The stop of the line that runs the turn.
    let stop: ZenLineStop
}

/// The stop of one exclusive line, shared by ``ZenWindowSession/stop()``
/// (main actor) and the turn step (chat actor). The stop sets it before it
/// suspends and the step reads it in the same check as the reservation, so
/// a stop that lands before the prompt is even reserved still keeps the
/// line's turn from starting.
final class ZenLineStop: Sendable {
    private let requested = Mutex(false)

    /// The operator stopped the line.
    var isRequested: Bool {
        requested.withLock { $0 }
    }

    func request() {
        requested.withLock { $0 = true }
    }
}

/// How a turn step ended.
enum ZenTurnOutcome: Sendable {
    /// The turn ran to its end.
    case finished
    /// The prompt could not be reserved.
    case refused(ChatSessionHostError)
    /// The reservation was dropped (a stop, a close), the line was stopped,
    /// or the line was cancelled before the turn started: it did not start.
    case cancelledBeforeStart
    /// The turn failed or was cancelled while it ran.
    case failed(any Error)
}

/// The window's steps that read and write the host in one hop.
@ChatSessionActor
enum ZenWindowSteps {
    struct Anchor: Sendable {
        let epoch: UInt64
        let sequence: Int
    }

    static func bind(
        hooks: ZenWindowHooks,
        presenter: ZenWindowPresenter,
        to sessionHost: ChatSessionHost,
        slotID: ChatSlotID
    ) {
        hooks.sessionHost = sessionHost
        hooks.slotID = slotID
        presenter.sessionHost = sessionHost
        presenter.slotID = slotID
    }

    static func setHandlers(
        presenter: ZenWindowPresenter,
        hooks: ZenWindowHooks,
        fileMutation: @escaping @Sendable () -> Void,
        statusFacts: @escaping @Sendable () -> Void
    ) {
        presenter.fileMutationHandler = fileMutation
        hooks.statusFactsHandler = statusFacts
    }

    /// The last log entry of the current reducer, for a local row.
    static func anchor(in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> Anchor? {
        guard let snapshot = sessionHost.reducer(in: slotID)?.snapshot else { return nil }
        return Anchor(
            epoch: snapshot.epoch,
            sequence: ZenLocalTranscriptItem.anchorSequence(in: snapshot)
        )
    }

    /// Runs one turn of `controller` as one step: reserves the prompt, locks
    /// the response language for a prompt the operator typed, composes the
    /// configuration, then, only while the reservation still holds, the line
    /// is not stopped (``ZenTurnStart/stop``), and its task is not cancelled,
    /// takes the staged attachments (typed prompts only), marks a prompt a
    /// command built as hidden, and runs the turn, with no suspension between
    /// the check and `runTurn(_:)`; the reservation is released after it. A
    /// stop that lands before the check, even before the reservation, leaves
    /// the turn unstarted, never unfenced.
    static func runTurn(
        _ start: ZenTurnStart,
        controller: ChatSessionController,
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        hooks: ZenWindowHooks,
        hiddenPrompts: ZenHiddenPromptMailbox,
        didReserve: (@Sendable () async -> Void)?
    ) async -> ZenTurnOutcome {
        let reservation: ChatPromptReservation
        do {
            reservation = try sessionHost.reservePrompt(in: slotID)
        } catch {
            return .refused(error)
        }
        // The command that built the turn ran on the controller the slot runs.
        guard sessionHost.withReservedIncarnation(reservation, { $0.controller === controller }) == true else {
            sessionHost.releasePrompt(reservation)
            return .refused(.noSession)
        }
        await didReserve?()
        if start.typedByOperator {
            hooks.lockResponseLanguageIfNeeded()
        }
        let configuration = await controller.turnSessionConfiguration(
            for: start.purpose,
            responseLanguageSection: hooks.responseLanguageSection()
        )
        // From here to `runTurn(_:)` nothing suspends.
        guard sessionHost.holdsPrompt(reservation), !start.stop.isRequested, !Task.isCancelled else {
            sessionHost.releasePrompt(reservation)
            return .cancelledBeforeStart
        }
        let attachments = start.typedByOperator ? controller.consumePendingAttachments() : []
        if !start.typedByOperator, let snapshot = sessionHost.reducer(in: slotID)?.snapshot {
            hiddenPrompts.post(ZenHiddenPromptMailbox.Mark(
                epoch: snapshot.epoch,
                afterSequence: ZenLocalTranscriptItem.anchorSequence(in: snapshot)
            ))
        }
        let outcome: ZenTurnOutcome
        do {
            _ = try await controller.runTurn(ChatTurnRequest(
                prompt: start.prompt,
                attachments: attachments,
                purpose: start.purpose,
                sessionConfiguration: configuration,
                origin: .app
            ))
            outcome = .finished
        } catch {
            outcome = .failed(error)
        }
        sessionHost.releasePrompt(reservation)
        return outcome
    }

    /// Presents the closing notices of an operation on the current reducer.
    static func present(
        _ notices: [ChatSessionNotice],
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID
    ) async {
        guard !notices.isEmpty, let reducer = sessionHost.reducer(in: slotID) else { return }
        for notice in notices {
            await reducer.presentSessionNotice(notice)
        }
    }

    /// The task graph the current reducer holds.
    static func taskGraph(in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> ChatTaskGraphOverview? {
        sessionHost.reducer(in: slotID)?.snapshot.taskGraph
    }

    /// Cancels the prompt reserved on the slot, if one is; `true` when it
    /// cancelled one.
    static func cancelPrompt(in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> Bool {
        guard sessionHost.incarnation(in: slotID)?.activePromptID != nil else { return false }
        return sessionHost.cancelPrompt(in: slotID) != nil
    }

    /// The stop of a window, in one step: cancels the prompt reserved on the
    /// slot and refuses the open requests of the session it runs now; `true`
    /// when it cancelled a prompt.
    static func stop(in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> Bool {
        let cancelled = cancelPrompt(in: sessionHost, slotID: slotID)
        sessionHost.incarnation(in: slotID)?.pendingRequestHost?.cancelPendingRequests()
        return cancelled
    }

    /// Answers the request `id` of the session the slot runs now.
    static func answer(
        _ id: UUID,
        with answer: ChatPendingRequest.Answer?,
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID
    ) {
        _ = sessionHost.incarnation(in: slotID)?.pendingRequestHost?.resolve(id, answer: answer)
    }

    /// The close of a window: closing the slot fences the turn that runs,
    /// drops its reservation, and refuses the open requests in one step,
    /// before it suspends; then the task-graph observer of the session the
    /// slot ran is stopped.
    static func close(_ sessionHost: ChatSessionHost, slotID: ChatSlotID) async {
        let controller = sessionHost.incarnation(in: slotID)?.controller
        await sessionHost.closeSlot(slotID)
        await controller?.stopTaskGraphObserver()
    }

    /// The shutdown of the runtime: one `shutdown()` of the host ends every
    /// slot, then the observers of the sessions they ran are stopped.
    static func shutdown(_ sessionHost: ChatSessionHost, slotIDs: [ChatSlotID]) async {
        let controllers = slotIDs.compactMap { sessionHost.incarnation(in: $0)?.controller }
        await sessionHost.shutdown()
        for controller in controllers {
            await controller.stopTaskGraphObserver()
        }
    }
}
