//
//  ChatSessionHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation

/// The container of the chat sessions of one process: the slots a channel
/// opens (``ChatSlotDescriptor``), the session each slot runs now
/// (``ChatSessionIncarnation``), and what every session shares: the
/// ``AgentCoreSessionRunner``, the Telegram route authority and poller, the
/// sleep assertion held while a session exists, and the epoch counter.
///
/// A slot runs one incarnation at a time. A new or loaded session is a new
/// incarnation with a new controller and reducer, built from the slot's
/// bindings and the launch profile: selection, plan, workflow, and transcript
/// never carry over, and the previous incarnation is fenced, its pending
/// requests refused, before the new one exists. A hosted controller's own
/// session replacements (`/sessions new`, a saved-session load) come back
/// here as new incarnations (see ``ChatSessionHostBinding``). One prompt runs
/// per incarnation: ``reservePrompt(in:)`` checks and reserves in one step, and
/// every check followed by a write is one call of the host
/// (``withReservedIncarnation(_:_:)``, ``withLiveIncarnation(_:epoch:_:)``), so
/// a channel in another isolation domain never splits them across a
/// suspension.
///
/// The task graphs stay with the runner's orchestrator; the host owns only
/// the incarnations. It is isolated to ``ChatSessionActor``, the isolation of
/// the controllers and reducers it creates, so it reaches them without
/// hopping.
@ChatSessionActor
public final class ChatSessionHost {
    /// What happens to the runner's session when its incarnation ends.
    public enum RuntimeSessionDisposition: Sendable {
        /// Close it, keeping its persisted task graph: a channel's close.
        case close
        /// Discard it, with its persisted task graph: a new or loaded session
        /// replacing it.
        case discard
        /// Leave it to the caller.
        case keep
    }

    /// The runtime every session runs on.
    public nonisolated let runner: AgentCoreSessionRunner
    /// The launch facts every controller reads.
    public nonisolated let environment: ChatSessionEnvironment
    nonisolated let sleepAssertionReason: String
    /// `true` once ``shutdown()`` ran: every later operation fails or is a
    /// no-op, and late work finds no live incarnation.
    public private(set) var isShutDown = false
    private(set) var slots: [ChatSlotID: ChatSlot] = [:]
    private var nextSessionEpochValue: UInt64 = 1
    private var sleepAssertion: ZenSleepAssertion?
    /// The Telegram route authority shared by the companions of every slot,
    /// created on first use (see `ChatSessionHost+Telegram.swift`).
    var telegramRouterStorage: TerminalTelegramSessionRouter?
    /// The Bot API poller shared by them, created with the router.
    var telegramDispatcherStorage: TerminalTelegramBotDispatcher?

    /// A host over `runner`, which it shuts down with itself.
    ///
    /// - Parameters:
    ///   - environment: The launch facts of every controller.
    ///   - sleepAssertionReason: The reason of the assertion that keeps the
    ///     machine awake while a slot runs a session.
    public nonisolated init(
        runner: AgentCoreSessionRunner,
        environment: ChatSessionEnvironment,
        sleepAssertionReason: String = "ZenCODE chat session active"
    ) {
        self.runner = runner
        self.environment = environment
        self.sleepAssertionReason = sleepAssertionReason
    }

    /// A host with a runner built by
    /// ``ChatSessionRuntimeFactory/makeSessionRunner(toolAuthorizationHandler:featureRuntime:mcpRuntime:backendFactory:)``
    /// and the environment of `configuration`.
    public nonisolated convenience init(
        configuration: AgentConfiguration,
        toolAuthorizationHandler: AgentToolAuthorizationHandler?,
        featureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime(),
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = ChatSessionRuntimeFactory.productionBackendFactory,
        userHomeDirectoryURL: URL? = nil,
        sleepAssertionReason: String = "ZenCODE chat session active"
    ) {
        let runner = ChatSessionRuntimeFactory.makeSessionRunner(
            toolAuthorizationHandler: toolAuthorizationHandler,
            featureRuntime: featureRuntime,
            mcpRuntime: mcpRuntime,
            backendFactory: backendFactory
        )
        self.init(
            runner: runner,
            environment: ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: featureRuntime,
                userHomeDirectoryURL: userHomeDirectoryURL
            ),
            sleepAssertionReason: sleepAssertionReason
        )
    }

    // MARK: - Slots

    /// Opens a slot without a session. Throws `.shutDown` after
    /// ``shutdown()`` and `.statePublishingRequired` when the descriptor asks
    /// with pending requests but publishes no state.
    public func openSlot(_ descriptor: ChatSlotDescriptor) throws(ChatSessionHostError) -> ChatSlotID {
        guard !isShutDown else { throw .shutDown }
        if case .pendingRequests = descriptor.interaction, !descriptor.publishesState {
            throw .statePublishingRequired
        }
        let id = ChatSlotID()
        slots[id] = ChatSlot(id: id, descriptor: descriptor)
        return id
    }

    /// Opens a slot and starts its first session, with the id `sessionID`, in
    /// one step without suspending: for a channel that must run a session
    /// from the moment it exists (the terminal, whose session is read before
    /// it runs). Same failures as ``openSlot(_:)``, and nothing is open after
    /// one. As with ``newSession(in:sessionID:)``, the runner session is not
    /// created here.
    public func openSlot(
        _ descriptor: ChatSlotDescriptor,
        sessionID: String
    ) throws(ChatSessionHostError) -> ChatSessionIncarnation {
        let slotID = try openSlot(descriptor)
        guard let slot = slots[slotID] else { throw .unknownSlot }
        let incarnation = makeIncarnation(in: slot, sessionID: sessionID)
        slot.setIncarnation(incarnation)
        updateSleepAssertion()
        return incarnation
    }

    /// Closes the slot: ends its session like ``closeSession(in:runtimeSession:)``
    /// and forgets the slot, so its id is unknown from now on. Nothing happens
    /// for an unknown slot.
    public func closeSlot(
        _ slotID: ChatSlotID,
        runtimeSession: RuntimeSessionDisposition = .close
    ) async {
        guard let slot = slots.removeValue(forKey: slotID) else { return }
        let previous = endIncarnation(of: slot)
        slot.endObservation()
        updateSleepAssertion()
        if let previous {
            await disposeRuntimeSession(of: previous, runtimeSession)
        }
    }

    /// The open slots, in no particular order.
    var slotIDs: [ChatSlotID] {
        Array(slots.keys)
    }

    /// The session `slotID` runs now, as the host knows it at this moment;
    /// `nil` for an unknown slot or a slot without session.
    public func incarnation(in slotID: ChatSlotID) -> ChatSessionIncarnation? {
        slots[slotID]?.incarnation
    }

    /// The reducer of the session `slotID` runs now, when the slot publishes
    /// state.
    public func reducer(in slotID: ChatSlotID) -> ChatSessionStateReducer? {
        slots[slotID]?.incarnation?.reducer
    }

    /// Registers `observer`, called after every change of the slot's
    /// incarnation with the new one (or `nil`), and returns its token; `nil`
    /// for an unknown slot. The observer is not called for the current
    /// incarnation.
    @discardableResult
    func addIncarnationObserver(
        to slotID: ChatSlotID,
        _ observer: @escaping @ChatSessionActor (ChatSessionIncarnation?) -> Void
    ) -> UUID? {
        guard let slot = slots[slotID] else { return nil }
        let token = UUID()
        slot.incarnationObservers[token] = observer
        return token
    }

    func removeIncarnationObserver(_ token: UUID, from slotID: ChatSlotID) {
        slots[slotID]?.incarnationObservers.removeValue(forKey: token)
    }

    /// A stream of the incarnations of `slotID`: the current one at once
    /// (`nil` between sessions), then each new one. Like a reducer's
    /// snapshots, a slow consumer skips to the newest. The stream ends when
    /// the consumer stops iterating, when the slot closes, or on shutdown;
    /// for an unknown slot it ends at once.
    public func incarnations(in slotID: ChatSlotID) -> AsyncStream<ChatSessionIncarnation?> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ChatSessionIncarnation?.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        guard let slot = slots[slotID] else {
            continuation.finish()
            return stream
        }
        let token = UUID()
        continuation.yield(slot.incarnation)
        slot.incarnationObservers[token] = { incarnation in
            continuation.yield(incarnation)
        }
        slot.incarnationStreams[token] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @ChatSessionActor in
                guard let slot = self.slots[slotID] else { return }
                slot.incarnationObservers.removeValue(forKey: token)
                slot.incarnationStreams.removeValue(forKey: token)
            }
        }
        return stream
    }

    // MARK: - Sessions

    /// Ends the session the slot runs, if any, and starts a new one with the
    /// id `sessionID`: a controller from the launch profile with the slot's
    /// bindings, and its reducer when the slot publishes state. The runner
    /// session of the previous incarnation is discarded, as `/sessions new`
    /// does; its runner session for `sessionID` is not created here: the
    /// channel composes and creates it as it needs.
    ///
    /// Throws `.sessionBusy` while the current session has a prompt or a
    /// reconfiguration reserved: cancel it first.
    @discardableResult
    public func newSession(
        in slotID: ChatSlotID,
        sessionID: String
    ) async throws(ChatSessionHostError) -> ChatSessionIncarnation {
        let slot = try replaceableSlot(slotID)
        let previous = endIncarnation(of: slot)
        let incarnation = makeIncarnation(in: slot, sessionID: sessionID)
        slot.setIncarnation(incarnation)
        updateSleepAssertion()
        if let previous {
            await disposeRuntimeSession(of: previous, .discard)
        }
        return incarnation
    }

    /// Ends the session the slot runs, if any, and loads the saved session
    /// `name` of the slot's project into a new incarnation.
    ///
    /// The sequence is the one of
    /// ``ChatSessionController/loadSavedSession(_:checkpointEntryID:)``, split
    /// across the two controllers: the channel's first step
    /// (``ChatSessionChannelHooks/savedSessionWillLoad()``) and the end of the
    /// planning discussion run on the controller being replaced, before the
    /// switch, where the in-place load runs them before it discards the
    /// session; the saved session is then installed into the new controller,
    /// with the remaining hooks and notices in their order.
    ///
    /// What the slot runs afterwards: when the saved session does not exist
    /// or the current session is busy, nothing changed and the slot keeps its
    /// incarnation; once the new incarnation exists, the slot runs it even
    /// when the load then fails, as the controller stays on the session it
    /// already switched to.
    @discardableResult
    public func loadSavedSession(
        in slotID: ChatSlotID,
        name: String,
        checkpointEntryID: String? = nil
    ) async throws -> ChatSessionOperationOutcome {
        let slot = try replaceableSlot(slotID)
        let savedSessions = try TerminalSessionStore.savedSessions(for: slot.workingDirectory)
        guard let savedSession = savedSessions.first(where: { $0.name == name }) else {
            throw ChatSessionHostError.savedSessionNotFound(name)
        }
        return try await loadSavedSession(in: slotID, savedSession, checkpointEntryID: checkpointEntryID)
    }

    /// ``loadSavedSession(in:name:checkpointEntryID:)`` with the saved session
    /// itself. `controller`, when given, is the hosted controller delegating
    /// its own load: `.noSession` when the slot no longer runs it, as a
    /// replaced controller replaces nothing.
    func loadSavedSession(
        in slotID: ChatSlotID,
        _ savedSession: TerminalSavedSession,
        checkpointEntryID: String?,
        requestedBy controller: ChatSessionController? = nil
    ) async throws -> ChatSessionOperationOutcome {
        var slot = try replaceableSlot(slotID)
        if let controller, slot.incarnation?.controller !== controller {
            throw ChatSessionHostError.noSession
        }
        if let current = slot.incarnation {
            await current.controller.prepareForSavedSessionLoad()
            // Reserved or replaced while the channel's step ran: the switch is
            // refused, and only that step happened.
            slot = try replaceableSlot(slotID)
            guard slot.incarnation?.epoch == current.epoch else {
                throw ChatSessionHostError.noSession
            }
        }
        let previous = endIncarnation(of: slot)
        let incarnation = makeIncarnation(in: slot, sessionID: savedSession.sessionID)
        slot.setIncarnation(incarnation)
        updateSleepAssertion()
        if let previous {
            await disposeRuntimeSession(of: previous, .discard)
        }
        return try await incarnation.controller.installSavedSession(
            savedSession,
            checkpointEntryID: checkpointEntryID
        )
    }

    /// The next incarnation of `slotID` for the hosted `controller` that
    /// delegates its `/sessions new`: ``newSession(in:sessionID:)``, refused
    /// with `.noSession` when the slot no longer runs `controller`, as a
    /// replaced controller replaces nothing.
    func replaceIncarnation(
        of controller: ChatSessionController,
        in slotID: ChatSlotID,
        sessionID: String
    ) async throws(ChatSessionHostError) -> ChatSessionIncarnation {
        guard !isShutDown else { throw .shutDown }
        guard let slot = slots[slotID] else { throw .unknownSlot }
        guard slot.incarnation?.controller === controller else { throw .noSession }
        return try await newSession(in: slotID, sessionID: sessionID)
    }

    /// Gives the session `slotID` runs now the id `sessionID`, in place: the
    /// controller, its epoch, selection, plan, and transcript stay, the
    /// controller and the incarnation take the id, the observers are told
    /// with the same epoch, and the reducer, when the slot publishes state,
    /// starts its log over under the new id (``ChatSessionStateReducer/sessionDidChange(sessionID:)``,
    /// which keeps the epoch). Nothing happens for the id the session has.
    ///
    /// For a channel that continues persisted work under the id it was
    /// persisted with before the runtime session exists (the terminal
    /// resuming a task graph at startup): the runner is not told, so a
    /// session it already created keeps its id there, and from then on a new
    /// session is the way. Throws `.sessionBusy` while a prompt or a
    /// reconfiguration is reserved, and `.noSession`, `.unknownSlot`, and
    /// `.shutDown` as ``reservePrompt(in:)`` does.
    public func adoptSessionID(
        _ sessionID: String,
        in slotID: ChatSlotID
    ) throws(ChatSessionHostError) {
        guard !isShutDown else { throw .shutDown }
        guard let slot = slots[slotID] else { throw .unknownSlot }
        guard var incarnation = slot.incarnation else { throw .noSession }
        guard incarnation.activePromptID == nil, incarnation.operationState == .idle else {
            throw .sessionBusy
        }
        guard incarnation.sessionID != sessionID else { return }
        incarnation.controller.sessionID = sessionID
        incarnation.sessionID = sessionID
        slot.setIncarnation(incarnation)
        incarnation.reducer?.resetForSession(sessionID)
    }

    /// Ends the session the slot runs: fences its controller, drops its
    /// reservation, refuses its pending requests, detaches its reducer, and
    /// leaves the slot without session; then disposes of the runner session
    /// as `runtimeSession` says, unless another slot still runs a session
    /// with the same id. Nothing happens for an unknown slot or a slot
    /// without session.
    public func closeSession(
        in slotID: ChatSlotID,
        runtimeSession: RuntimeSessionDisposition = .close
    ) async {
        guard let slot = slots[slotID], let previous = endIncarnation(of: slot) else { return }
        slot.setIncarnation(nil)
        updateSleepAssertion()
        await disposeRuntimeSession(of: previous, runtimeSession)
    }

    /// Ends every session and slot, before the first suspension, so that no
    /// late work finds a live incarnation, then shuts the runner down: all of
    /// it, or with `keepingExternalTools` only its model backend and
    /// sessions, keeping the connected external MCP servers alive
    /// (``AgentCoreSessionRunner/shutdownBackendKeepingExternalTools()``),
    /// for a channel that rebuilds its chat on the same runner, as the
    /// terminal does after `/setup`. A second call is a no-op, whichever way
    /// the first one went.
    public func shutdown(keepingExternalTools: Bool = false) async {
        guard !isShutDown else { return }
        isShutDown = true
        let closingSlots = slots.values
        slots.removeAll()
        for slot in closingSlots {
            _ = endIncarnation(of: slot)
            slot.endObservation()
        }
        updateSleepAssertion()
        if keepingExternalTools {
            await runner.shutdownBackendKeepingExternalTools()
        } else {
            await runner.shutdown()
        }
    }

    // MARK: - Incarnations

    func makeSessionEpoch() -> UInt64 {
        let epoch = nextSessionEpochValue
        nextSessionEpochValue &+= 1
        return epoch
    }

    /// The slot whose session may be replaced now.
    private func replaceableSlot(_ slotID: ChatSlotID) throws(ChatSessionHostError) -> ChatSlot {
        guard !isShutDown else { throw .shutDown }
        guard let slot = slots[slotID] else { throw .unknownSlot }
        if let current = slot.incarnation,
           current.activePromptID != nil || current.operationState != .idle {
            throw .sessionBusy
        }
        return slot
    }

    /// A new incarnation of `slot` for the session `sessionID`: its epoch,
    /// its reducer and pending-request host when the slot publishes state,
    /// and its controller with the slot's bindings, the reducer attached
    /// before anything can be presented, bound to this host so that its own
    /// session replacements come back here.
    private func makeIncarnation(in slot: ChatSlot, sessionID: String) -> ChatSessionIncarnation {
        let epoch = makeSessionEpoch()
        // The controller starts from the launch profile; the reducer is seeded
        // with the same state, as it is created first.
        let reducer: ChatSessionStateReducer? = slot.publishesState
            ? ChatSessionStateReducer(
                sessionID: sessionID,
                workingDirectory: slot.workingDirectory,
                defaultOrigin: slot.defaultOrigin,
                state: ChatSessionState(
                    selection: ChatSessionController.initialSelection(for: environment)
                ),
                epoch: epoch,
                maximumLogBytes: ChatSessionController.maximumTranscriptBytes,
                keepsEpochOnSessionChange: true
            )
            : nil
        let interactionHost: any ChatInteractionHost
        let pendingRequestHost: ChatPendingRequestHost?
        switch slot.interaction {
        case let .host(host):
            interactionHost = host
            pendingRequestHost = nil
        case let .pendingRequests(capabilities, gatesWorkspaceAccess, openExternal):
            // `openSlot` refused this interaction without a reducer.
            let host = ChatPendingRequestHost(
                reducer: reducer!,
                capabilities: capabilities,
                gatesWorkspaceAccess: gatesWorkspaceAccess,
                openExternal: openExternal
            )
            interactionHost = host
            pendingRequestHost = host
        }
        let controller = ChatSessionController(
            sessionID: sessionID,
            managementRuntime: runner,
            environment: environment,
            workingDirectory: slot.workingDirectory,
            presenter: slot.presenter,
            host: interactionHost,
            authorizer: slot.authorizer,
            retainsTranscript: slot.retainsTranscript,
            retainsFileArtifactHistory: slot.retainsFileArtifactHistory
        )
        controller.channelHooks = slot.channelHooks
        if let commandRegistry = slot.commandRegistry {
            controller.commandRegistry = commandRegistry
        }
        if let reducer {
            controller.attachCompanionPresenter(reducer)
        }
        controller.hostBinding = ChatSessionHostBinding(host: self, slotID: slot.id)
        return ChatSessionIncarnation(
            slotID: slot.id,
            sessionID: sessionID,
            epoch: epoch,
            controller: controller,
            reducer: reducer,
            pendingRequestHost: pendingRequestHost
        )
    }

    /// Ends the incarnation of `slot` without suspending: the controller is
    /// fenced, so a turn still running cannot write session state back, the
    /// reservation is dropped, the pending requests are refused, and the
    /// reducer stops following the controller. Returns it for the runner
    /// disposal; the caller installs what follows it.
    private func endIncarnation(of slot: ChatSlot) -> ChatSessionIncarnation? {
        guard var incarnation = slot.incarnation else { return nil }
        incarnation.controller.cancelActiveTurn()
        incarnation.pendingRequestHost?.cancelPendingRequests()
        if let reducer = incarnation.reducer {
            incarnation.controller.detachCompanionPresenter(reducer)
        }
        incarnation.activePromptID = nil
        incarnation.operationState = .idle
        slot.incarnation = nil
        return incarnation
    }

    /// Applies `disposition` to the runner session of an ended incarnation,
    /// unless another slot still runs a session with the same id, which then
    /// owns the runner session.
    private func disposeRuntimeSession(
        of incarnation: ChatSessionIncarnation,
        _ disposition: RuntimeSessionDisposition
    ) async {
        guard !isShutDown, !isSessionRunning(incarnation.sessionID) else { return }
        switch disposition {
        case .close:
            await runner.closeSession(id: incarnation.sessionID)
        case .discard:
            await runner.resetSession(id: incarnation.sessionID)
        case .keep:
            return
        }
    }

    /// Whether a slot runs a session with the id `sessionID` now.
    func isSessionRunning(_ sessionID: String) -> Bool {
        slots.values.contains { $0.incarnation?.sessionID == sessionID }
    }

    // MARK: - Sleep assertion

    /// Keeps the machine awake while any slot runs a session.
    private func updateSleepAssertion() {
        let hasSession = slots.values.contains { $0.incarnation != nil }
        if hasSession {
            if sleepAssertion == nil {
                sleepAssertion = ZenSleepAssertion(reason: sleepAssertionReason)
            }
        } else {
            sleepAssertion?.invalidate()
            sleepAssertion = nil
        }
    }
}
