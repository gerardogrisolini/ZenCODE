//
//  ZenWindowSession.swift
//  ZenApp
//
//  One window of the app: one slot of the session host, the observable state
//  of its session, and the operator's actions on it.
//

import Foundation
import Observation
import ToolCore
import ZenCODECore

/// The session of one window: one slot of the app's `ChatSessionHost`, which
/// runs one incarnation at a time (a new or loaded session replaces it).
///
/// The window renders the state of the current incarnation's reducer: the
/// closed rows (``transcript``), the block still streaming (``liveThought``,
/// ``liveAssistantText``), the status bar (``status``), and the request it
/// waits for (``pendingRequest``), with the point of the window its menus
/// open over (``pendingRequestAnchor``). Each is published on its own and
/// assigned only when it changes, so a streamed token touches the live block
/// alone.
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
/// The window observes its session's shared-chat room (``sharedChat``): the
/// messages for the operator show in the reader, one at a time
/// (``toggleSharedChatReader()``, ``navigateSharedChat(_:)``); a message for
/// the coordinator runs a hidden coordinator turn once the window is idle, as
/// any line of the executor; and a line that starts with a live `@mention`
/// (``mentionSuggestions``) is sent to the room at once, even while a line
/// runs, never queued. The reader and the roster are transient state of the
/// window: never saved, and reset with a new or loaded session.
///
/// The window has tabs (``tabs``): the conversation (``ZenWindowTab/chat``),
/// always first and never closed, then the transcript of each sub-agent the
/// operator opened (``openSubAgentTab(_:)``), in the order they were opened,
/// each followed by its own ``ZenSubAgentTranscriptModel``, which keeps what
/// it read for as long as the tab stays open and knows whether its tab is
/// the selected one. Only the operator opens and selects tabs; the commands
/// the operator launches (``run(_:menuAnchor:)``, the session operations)
/// select the conversation before they start, so their result shows; a new
/// or loaded session closes the sub-agent tabs and selects the conversation,
/// and closing the window stops them. The tabs are transient state of the
/// window: never saved.
///
/// The window's slot runs on a runner of its own (``runner``), a sibling of
/// the host's runner that the host owns and shuts down with the slot: the
/// model, agent, thinking level, tools, and skills of its sessions change
/// while the sessions of the other slots run, without restarting them.
///
/// The access mode (``ZenAppRuntime/localExecAccessMode``, the terminal's
/// Ctrl+G) is app-wide: ``toggleFullAccess()`` changes it on the runner of
/// every session, and each open session shows the change in its status bar
/// (``ZenWindowStatus/localExecAccessMode``) and in a message row. A session
/// added later starts with the current mode, without the row.
///
/// `/telegram on` hands the window's slot to the Telegram chat that setup
/// linked, as in the terminal: the chat drives the session, and the window is
/// dormant (``isDrivenFromTelegram``). It still shows the session live
/// through the reducer, but runs only `/telegram`, `/telegram off`, and
/// `/exit` (the host refuses every other line), refuses a live mention, the
/// access-mode switch, attachments, and the sidebar's loads and deletes with
/// `ChatSlotAdmission.dormantRefusalText`, keeps its queue whole, stops
/// nothing, and leaves the room's coordinator turns to the chat. The texts
/// the channel has for the window arrive as message rows. `/telegram off`
/// takes the slot back, with no catch-up (the window showed it all live); a
/// turn from Telegram still running then is adopted: it counts as the
/// window's line until its reservation is released
/// (``adoptedTelegramPromptID``), and Stop stops it.
///
/// A control that launches a command asks ``refusesNow(_:)`` whether the
/// window would refuse it now (a command that does not run while a prompt is
/// running, with a line running) and shows itself disabled meanwhile; the
/// refusal itself, and its message, are unchanged.
///
/// Voice mode (`/voice`, ``ZenAppRuntime/voiceState``) is the app's, one for
/// every window, and follows the active window
/// (``ZenAppRuntime/activeVoiceWindowID``); the window is its host there
/// (``ZenWindowVoiceHost``). While it is the active one, the speech
/// recognized but not sent yet shows live at the end of ``draft``
/// (``voiceDictation``), voice sends the whole draft by the voice rules, the
/// final answers of its turns and the comments of its main agent are read
/// aloud, the messages of its room for the operator are announced, and its
/// prompts carry voice mode's instruction. An edit of the draft turns the
/// dictation shown into ordinary text. Esc (``handleEscape()``) stops a
/// reading and leaves the draft alone.
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
    /// The runner the slot's sessions run on: the slot's own, a sibling of
    /// the host's runner. The host owns it and shuts it down when the slot
    /// closes or the host shuts down.
    public nonisolated let runner: AgentCoreSessionRunner
    /// Brings the session forward, when its window is attached: selects it
    /// in the window that hosts it (``ZenWorkspaceWindow``) and brings that
    /// window or native tab to the front.
    @ObservationIgnored public var bringToFront: (@MainActor () -> Void)?
    /// Runs once when ``closeRequested`` becomes `true`: the window that
    /// hosts the session closes it (``ZenWorkspaceWindow/closeSession(_:)``).
    @ObservationIgnored var closeRequestHandler: (@MainActor (ZenWindowSession) -> Void)?

    // MARK: Observable state

    /// The epoch of the incarnation the window shows; `nil` before its first
    /// snapshot. It changes with a new or loaded session.
    public internal(set) var epoch: UInt64?
    /// The closed rows of the transcript (see ``ZenTranscriptProjection``),
    /// reassigned only when a row changes; the block still streaming is not
    /// here.
    public internal(set) var transcript: [ZenTranscriptItem] = []
    /// The reasoning of the block still streaming; empty when none.
    public internal(set) var liveThought = ""
    /// The assistant content of the block still streaming; empty when none.
    public internal(set) var liveAssistantText = ""
    /// The turn the block still streaming belongs to; `nil` when nothing
    /// streams.
    public internal(set) var liveTurnID: Int?
    /// The id of the block still streaming, unique across blocks and
    /// sessions (``ZenTranscriptProjection/liveBlockID(for:)``); `nil` when
    /// nothing streams.
    public internal(set) var liveBlockID: String?
    /// The latest sub-agent overview.
    public internal(set) var subAgents = ChatSubAgentOverview(snapshots: [])
    /// The oldest interaction the session waits for.
    public internal(set) var pendingRequest: ChatPendingRequest?
    /// The point of the window from which the operator launched the line
    /// that asked for ``pendingRequest`` (``run(_:menuAnchor:)``), where its
    /// menus open; `nil` when they open over the composer: a line typed or
    /// launched elsewhere, a request no line of the window asked for, no
    /// request. Assigned with ``pendingRequest``, in the same turn of the
    /// main actor: a new request takes the anchor of the latest line
    /// launched with one that still runs, else `nil`, and keeps it for as
    /// long as it waits.
    public internal(set) var pendingRequestAnchor: ZenMenuAnchor?
    /// A line runs that is not beside another one: a turn, or a command,
    /// possibly waiting for an answer.
    public internal(set) var isBusy = false
    /// A turn is generating.
    public internal(set) var isGenerating = false
    /// The prompts waiting for the running line to end, oldest first.
    public internal(set) var queuedLines: [ZenQueuedLine] = []
    /// The status bar.
    public internal(set) var status: ZenWindowStatus
    /// What the welcome view shows about the next turn, as the terminal's
    /// startup summary (agent, active tools, active skills), read with the
    /// status bar; `nil` until it is first read.
    public internal(set) var startupSummary: ZenStartupSummary?
    /// The session's title: the saved name, else one derived from the first
    /// prompt the operator typed in the session
    /// (``ZenTranscriptProjection/title(fromPrompt:limit:)``), else `nil`.
    public internal(set) var sessionTitle: String?
    /// The name of the saved session the session was saved to or loaded from.
    public internal(set) var currentSavedSessionName: String?
    /// The name of the saved session the sidebar loads
    /// (``loadSavedSession(named:)``), while the conversation shows a loading
    /// indicator in its place; `nil` otherwise. Set when the
    /// load starts (not when it is refused), and cleared once the window
    /// applied the snapshot that shows how the load ended (the restored
    /// conversation, or its failure), when the window follows another
    /// session, or when it closes. A `/sessions load` line does not set it.
    /// Transient state of the window: never saved.
    public internal(set) var loadingSavedSessionName: String?
    /// The step of the sidebar load ``loadingSavedSessionName`` names, which
    /// the loading indicator shows: ``ZenSavedSessionLoadStep/reading`` when
    /// the load starts, then the steps of the slot's hooks, only forward;
    /// `nil` whenever ``loadingSavedSessionName`` is. Transient state of the
    /// window: never saved.
    public internal(set) var loadingSavedSessionStep: ZenSavedSessionLoadStep?
    /// `/exit` ran: the session should close (call ``close()``). When it
    /// becomes `true`, ``closeRequestHandler`` runs.
    public internal(set) var closeRequested = false {
        didSet {
            if closeRequested, !oldValue {
                closeRequestHandler?(self)
            }
        }
    }
    /// ``close()`` ran, or the runtime shut down.
    public internal(set) var isClosed = false
    /// The facts that decide which commands the operator sees.
    public internal(set) var commandContext: ChatCommandContext = []
    /// The commands the operator sees now, in display order.
    public internal(set) var commandDescriptors: [ChatCommandDescriptor] = ZenAppCommands.visibleDescriptors(in: [])
    /// The text of the input field. A change that is not the dictation's own
    /// (the operator typed or edited, a recall of the history, a submit)
    /// turns the dictation shown into ordinary text: voice forgets it.
    public var draft = "" {
        didSet {
            draftDidChange(from: oldValue)
        }
    }
    /// The voice dictation shown at the end of ``draft``, while this window
    /// is the one voice mode follows; its preview covers ``draft`` from
    /// ``ZenVoiceDictationDraft/Preview/start`` to the end.
    public internal(set) var voiceDictation = ZenVoiceDictationDraft()
    /// The latest change the dictation made to ``draft``, for the composer's
    /// cursor (``ZenVoiceDictationDraft/cursor(_:after:draftCount:)``);
    /// `nil` before the first.
    public internal(set) var voiceDictationUpdate: ZenVoiceDictationUpdate?
    /// The file artifacts of the transcript's `.fileArtifacts` rows, grouped
    /// by artifact turn (``ZenArtifactTurnGroup/groups(in:)``), for the
    /// artifacts sidebar; reassigned only when they change.
    public internal(set) var fileArtifacts: [ZenArtifactTurnGroup] = []
    /// The artifacts sidebar shows. Transient state of the window: never
    /// saved, kept across new and loaded sessions, and changed only by the
    /// operator (``toggleArtifactsSidebar()``, `/artifacts`, the sidebar).
    public var isArtifactsSidebarPresented = false
    /// The tab the window shows. Transient state of the window: never saved,
    /// back to ``ZenWindowTab/chat`` with a new or loaded session and with a
    /// command the operator launches, and otherwise changed only by the
    /// operator (``selectTab(_:)``, ``openSubAgentTab(_:)``,
    /// ``closeSubAgentTab(_:)``).
    public internal(set) var selectedTab: ZenWindowTab = .chat
    /// The models of the open sub-agent tabs, in the order the operator
    /// opened them.
    public internal(set) var subAgentTabs: [ZenSubAgentTranscriptModel] = []
    /// The shared-chat messages of the current session and what the operator
    /// read of them. Changed by the room's messages and by the operator alone
    /// (``toggleSharedChatReader()``, ``navigateSharedChat(_:)``).
    public internal(set) var sharedChat = ZenSharedChatReader()
    /// Whether the shared-chat reader is open, ``sharedChat``'s
    /// ``ZenSharedChatReader/isReaderOpen`` observed on its own: assigned
    /// only when it changes, so a view that needs just this bit (the menu) is
    /// not invalidated by every room message.
    public internal(set) var isSharedChatReaderOpen = false
    /// The active participants of the current session's room by id, the
    /// operator included, for the route labels of the reader.
    public internal(set) var sharedChatParticipants: [String: AgentSharedChat.Participant] = [:]
    /// The live `@mentions` the composer offers: `@coordinator`, `@all`, then
    /// one per active agent, from one roster snapshot
    /// (``refreshMentionSuggestions()``).
    public internal(set) var mentionSuggestions: [SharedChatMentionParser.Suggestion] =
        ZenWindowSession.emptyMentionSuggestions

    /// The latest snapshot of the current incarnation's reducer. Not
    /// observed: a view observes the properties derived from it.
    @ObservationIgnored public internal(set) var snapshot: ChatSessionSnapshot?

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

    /// Whether the sidebar's session operations are currently admitted.
    public var canManageSessions: Bool {
        !isClosed && !isLineRunningOrWaiting && !isDrivenFromTelegram
    }

    /// Whether the composer can pick or drop attachments. Prompts still queue
    /// while a line runs; attachments deliberately do not.
    public var canAttachFiles: Bool {
        !isClosed && !isLineRunning && !isDrivenFromTelegram
    }

    /// The tabs of the window: ``ZenWindowTab/chat``, then the open sub-agent
    /// tabs, in the order they were opened.
    public var tabs: [ZenWindowTab] {
        ZenWindowTab.tabs(subAgentIDs: subAgentTabs.map(\.agentID))
    }

    /// What voice mode does now, app-wide (``ZenAppRuntime/voiceState``):
    /// every window shows it, the active one or not.
    public var voiceState: VoiceModeSessionState {
        runtime?.voiceState ?? .off
    }

    /// Voice mode follows this window (``ZenAppRuntime/activeVoiceWindowID``).
    public var isVoiceWindow: Bool {
        runtime?.activeVoiceWindowID == id
    }

    // MARK: Composition

    @ObservationIgnored let sessionHost: ChatSessionHost
    @ObservationIgnored weak var runtime: ZenAppRuntime?
    @ObservationIgnored let hooks: ZenWindowHooks
    @ObservationIgnored let presenter: ZenWindowPresenter
    /// The prompts the turn step hides, for the projection.
    @ObservationIgnored let hiddenPrompts = ZenHiddenPromptMailbox()
    /// The incarnation the window follows.
    @ObservationIgnored var current: ChatSessionIncarnation
    /// Awaited by the turn step right after it reserved the prompt, for
    /// tests.
    @ObservationIgnored var turnDidReserve: (@Sendable () async -> Void)?
    /// Awaited before each snapshot is applied, for tests; when `nil`, a
    /// snapshot is applied without suspending.
    @ObservationIgnored var snapshotWillApply: (@Sendable () async -> Void)?
    /// The observation of the current session's shared-chat room.
    @ObservationIgnored let sharedChatObservation: ZenSharedChatObservation
    /// The window as the host of the app's voice session.
    @ObservationIgnored let voiceHost: ZenWindowVoiceHost
    /// The dictation itself is changing ``draft``: not an edit.
    @ObservationIgnored var isApplyingVoiceDictation = false
    /// Awaited before an auto-trigger of the shared chat is answered, for
    /// tests.
    @ObservationIgnored var sharedChatTriggerWillResolve: (@Sendable () async -> Void)?
    /// Awaited on the chain of the busy declarations right before the
    /// window's own answer to an auto-trigger (its claim, `.started`, or its
    /// give-back, `.declined`) reaches the Core, for tests. It runs on the
    /// chain, so it must never await the chain itself
    /// (``ZenSharedChatObservation/flushConsumerBusy()``,
    /// ``ZenSharedChatObservation/serialized(_:)``, a give-back): it would
    /// wait on itself.
    @ObservationIgnored var sharedChatClaimWillResolve:
        (@Sendable (AgentSharedChatAutoTriggerResolution) async -> Void)?

    // MARK: Telegram

    /// Telegram drives the window's slot: the window is dormant. Read from the
    /// host after each `/telegram on` and `/telegram off`, the only lines that
    /// change it. Views read it to disable operations that would be refused.
    var isDrivenFromTelegram = false
    /// The prompt of the turn from Telegram that `/telegram off` adopted,
    /// while it is still reserved: the window treats the turn as its line
    /// meanwhile (``watchAdoptedTelegramTurn(_:)``). Observed: it enters
    /// ``isLineRunning``, which the controls that launch a command read
    /// (``refusesNow(_:)``), and nothing else changes when the adopted turn
    /// ends. It is written only when the turn is adopted, when it ends
    /// (``adoptedTelegramTurnDidEnd(_:)``), and when the window closes, never
    /// while it streams, so observing it costs no extra updates.
    var adoptedTelegramPromptID: UUID?
    /// Waits between two reads of the adopted turn's reservation; throws when
    /// the task is cancelled. Replaced by tests.
    @ObservationIgnored var adoptedTelegramTurnSleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
    /// Follows ``adoptedTelegramPromptID`` until its reservation is released.
    @ObservationIgnored var adoptedTelegramTurnTask: Task<Void, Never>?

    // MARK: State shared with the extensions

    @ObservationIgnored var projection = ZenTranscriptProjection()
    @ObservationIgnored var history = ZenPromptHistory()
    @ObservationIgnored var lineTask: Task<Void, Never>?
    /// The stop of the exclusive line that runs, `nil` between lines; a new
    /// one for every line.
    @ObservationIgnored var lineStop: ZenLineStop?
    @ObservationIgnored var besideTasks: [UUID: Task<Void, Never>] = [:]
    /// The lines launched with a menu anchor that still run, oldest first,
    /// each with a token of its own: two may overlap (an exclusive line that
    /// ends and a command beside it), and the end of one keeps the other's.
    @ObservationIgnored var runningMenuAnchors: [(token: UUID, anchor: ZenMenuAnchor)] = []
    @ObservationIgnored var incarnationTask: Task<Void, Never>?
    @ObservationIgnored var snapshotTask: Task<Void, Never>?
    @ObservationIgnored var gitTask: Task<Void, Never>?
    @ObservationIgnored var gitRefreshPending = false
    @ObservationIgnored var statusTask: Task<Void, Never>?
    /// The model, thinking level, agent, or command context of the next turn
    /// may have changed since they were read.
    @ObservationIgnored var statusFactsAreStale = true
    /// The latest read of the status facts; an older read that ends later is
    /// dropped.
    @ObservationIgnored var statusFactsGeneration = 0
    /// The number of reads of the status facts, for tests.
    @ObservationIgnored var statusFactsReadCount = 0
    /// The context window the latest snapshot reported; `nil` until a turn
    /// reports one.
    @ObservationIgnored var lastSnapshotContextWindow: DirectAgentContextWindowStatus?
    /// The context window the settings configure for the model of the next
    /// turn, as the latest read of the status facts found it.
    @ObservationIgnored var configuredContextWindow: DirectAgentContextWindowStatus?
    /// The task graph of the last snapshot applied, to tell a change of the
    /// graph.
    @ObservationIgnored var lastSnapshotTaskGraph: ChatTaskGraphOverview?
    /// The task-graph card of the latest turn that showed one; `nil` before
    /// one, and in a new or loaded session.
    @ObservationIgnored var turnTaskGraphCard: TurnTaskGraphCard?

    /// The task-graph card of a turn: the local row the turn added, which
    /// moves with the graph's changes while the turn generates.
    struct TurnTaskGraphCard {
        let turnID: Int
        let id: UUID
    }
    /// The publication of the sub-agent overview while it shows a sub-agent
    /// at work, with a token of its own; `nil` while it shows none (see
    /// ``followPendingSubAgentsIfNeeded()``).
    @ObservationIgnored var pendingSubAgentsFollow: (token: UUID, task: Task<Void, Never>)?
    /// How often ``pendingSubAgentsFollow`` publishes the overview: as often
    /// as the controller's refresh during an `agent.*` call. A test shortens
    /// it.
    @ObservationIgnored var pendingSubAgentsInterval: Duration = .seconds(2)
    /// The readable mention handles of ``mentionSuggestions`` (handle →
    /// participant id), for the parser.
    @ObservationIgnored var mentionHandles: [String: String] = [:]
    /// The latest read of the room's roster; an older read that ends later
    /// is dropped, and so is one of a room the window left.
    @ObservationIgnored var rosterGeneration = 0
    @ObservationIgnored var rosterTask: Task<Void, Never>?
    /// The window's claims of an auto-trigger (`.started`) on the chain of the
    /// busy declarations, from the moment each is enqueued until the window
    /// decided what to do with its result. Only the declarations count them
    /// as busy (``isSharedChatConsumerBusy``). A counter rather than a flag,
    /// so the claim of a retired observation that is still on its way and
    /// the claim of its replacement never clear each other. Changed only by
    /// ``beginSharedChatClaim()`` and ``endSharedChatClaim()``.
    @ObservationIgnored var sharedChatClaimsInFlight = 0
    /// The mentions being sent.
    @ObservationIgnored var mentionTasks: [UUID: Task<Void, Never>] = [:]
    /// The sidebar load ``loadingSavedSessionName`` belongs to; a later load
    /// replaces it.
    @ObservationIgnored var savedSessionLoadGeneration = 0
    /// The last log entry of the slot's reducer when the sidebar load ended:
    /// ``loadingSavedSessionName`` clears once an applied snapshot of
    /// ``current`` reaches it. `nil` while the load runs and once cleared.
    @ObservationIgnored var savedSessionLoadAnchor: ZenWindowSteps.Anchor?

    private init(
        id: UUID,
        workspace: URL,
        runtime: ZenAppRuntime,
        hooks: ZenWindowHooks,
        presenter: ZenWindowPresenter,
        incarnation: ChatSessionIncarnation,
        runner: AgentCoreSessionRunner,
        localExecAccessMode: AgentLocalExecAccessMode
    ) {
        self.id = id
        self.workspace = workspace
        self.slotID = incarnation.slotID
        self.runner = runner
        self.sessionHost = runtime.sessionHost
        self.runtime = runtime
        self.hooks = hooks
        self.presenter = presenter
        self.current = incarnation
        self.status = ZenWindowStatus(
            workspace: workspace,
            localExecAccessMode: localExecAccessMode
        )
        self.sharedChatObservation = ZenSharedChatObservation(environment: .runner(runner))
        self.voiceHost = ZenWindowVoiceHost(windowID: id, voice: runtime.voice)
        voiceHost.window.set(self)
    }

    /// Opens a slot for `workspace` on a runner of its own and starts its
    /// first session clean, as a first launch on `workspace` would: from the
    /// defaults of that folder's project (``ChatSessionHost/newSession(in:sessionID:)``),
    /// with the agent's tools and skills and the launch's `--skills` applied.
    /// Every later `/sessions new` typed in the window keeps the selection of
    /// the session it replaces. The slot's runner takes the app's access mode
    /// before the first session starts; a toggle that ends while the window
    /// opens reaches it once ``ZenAppRuntime`` registered the window. On a
    /// failure the slot is closed, and the host shuts its runner down with it.
    static func open(
        runtime: ZenAppRuntime,
        workspace: URL
    ) async throws -> ZenWindowSession {
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
            publishesState: true,
            keepsSelectionOnNewSession: true,
            usesDedicatedRunner: true
        )
        let slotID = try await sessionHost.openSlot(descriptor)
        await ZenWindowSteps.bind(hooks: hooks, presenter: presenter, to: sessionHost, slotID: slotID)
        do {
            guard let runner = await sessionHost.runner(in: slotID) else {
                throw ChatSessionHostError.unknownSlot
            }
            // The app's access mode, before the slot's first session starts.
            let accessMode = runtime.localExecAccessMode
            await runner.setLocalExecAccessMode(accessMode)
            let sessionID = "\(ChatSlotDescriptor.defaultSessionIDPrefix)-\(UUID().uuidString.lowercased())"
            let incarnation = try await sessionHost.newSession(in: slotID, sessionID: sessionID)
            await incarnation.controller.applyInitialAgentSelectionIfNeeded()
            try await incarnation.controller.applyInitialSkillSelectionIfNeeded()
            let controller = incarnation.controller
            // As the terminal does before its startup summary, create the
            // runtime session and load the model. Reading the tool descriptors
            // then uses the live backend, including runtime-discovered feature
            // tools such as Xcode, whose discovery may request authorization.
            // The hooks start the first session's task-graph observer when
            // the session is created (`sessionDidCreate(reason:)`) and move
            // it with the session from now on.
            try await controller.startInitialSession()
            let window = ZenWindowSession(
                id: id,
                workspace: workspace,
                runtime: runtime,
                hooks: hooks,
                presenter: presenter,
                incarnation: incarnation,
                runner: runner,
                localExecAccessMode: accessMode
            )
            await window.start()
            // The startup offer of the task graphs earlier sessions left
            // incomplete, as the window's line, only when there is something
            // to offer (ZenWindowSession+ResumeTaskGraph.swift). The window
            // is not returned yet, so only a line of its new room could start
            // during the pre-check; the window then offers nothing.
            if await window.hasOfferableResumableTaskGraphs(), !window.isBusy {
                window.startExclusive { [weak window] _ in
                    await window?.runResumableTaskGraphOffer()
                }
            }
            return window
        } catch {
            // The host shuts the slot's runner down with the slot.
            await sessionHost.closeSlot(slotID)
            throw error
        }
    }

    private func start() async {
        let voiceHost = voiceHost
        await ZenWindowSteps.setHandlers(
            presenter: presenter,
            hooks: hooks,
            fileMutation: { [weak self] in
                Task { @MainActor in self?.refreshGitStatus() }
            },
            statusFacts: { [weak self] in
                Task { @MainActor in self?.statusFactsDidChange() }
            },
            savedSessionLoadStep: { [weak self] step in
                Task { @MainActor in self?.savedSessionLoadDidReach(step) }
            },
            voiceCommentary: { [weak voiceHost] commentary in
                guard let voiceHost else { return }
                voiceHost.post(.commentary(commentary, host: voiceHost))
            },
            subAgentCommentary: { [weak voiceHost] commentary in
                voiceHost?.postSubAgentCommentary(commentary)
            }
        )
        observeSnapshots(of: current)
        startSharedChat()
        await followSharedChat(of: current)
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

    // MARK: - Testing

    /// Waits until no line runs, beside or queued, no turn adopted from
    /// Telegram runs, no mention is being sent, and no status read is
    /// scheduled; `false` when `timeout` passed first.
    func waitUntilIdle(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lineTask == nil, besideTasks.isEmpty, mentionTasks.isEmpty, queuedLines.isEmpty,
               adoptedTelegramPromptID == nil, statusTask == nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}
