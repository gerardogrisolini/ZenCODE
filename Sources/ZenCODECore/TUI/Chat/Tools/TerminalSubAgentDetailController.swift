//
//  TerminalSubAgentDetailController.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//

import Foundation
import Synchronization
import ToolCore

/// Drives the `/subagent` detail panel (``TerminalSubAgentDetailPanel``): it
/// lets the operator pick an agent, follows the selected agent, reads its
/// transcript, and presents the framed panel through its ``Environment``.
///
/// The controller keeps the history it shows, not the Core: the Core only
/// reads the live history of the agent's backend (``Environment/transcript``)
/// and answers `nil` once the agent ended and its backend was shut down. A
/// read that answers `nil` never clears the rows, so after the agent ends the
/// panel keeps its last read. Nothing is saved.
///
/// While it shows an agent the controller follows the snapshots of the
/// session's sub-agents (``Environment/snapshotEvents``), keeps the one of its
/// agent (the last one stays when the agent leaves the snapshots), and reads
/// the transcript:
///
/// - When the agent opens, without waiting for the stream. The reload key
///   starts from the snapshot the agent opened with, so the first value of the
///   stream, which repeats it, reads nothing more.
/// - At once on a change of the agent's lifecycle (its status, whether it is
///   pending, its execution revision) from the last snapshot applied.
/// - Whenever an applied snapshot changes the reload key (the lifecycle, the
///   completed execution, the tool, the latest event, the latest update).
///
/// The updates other than the lifecycle changes, header and live activity
/// included, are applied at most once per ``Environment/updateInterval``: a
/// child task iterates the stream and keeps only the newest value while the
/// controller waits (``TerminalSubAgentSnapshotMailbox``), so the latest value
/// is never lost, and it ends the wait early for a lifecycle change. A stream
/// that finishes is subscribed again after
/// ``Environment/resubscribeInterval``; a `nil` stream (the session is gone)
/// ends the following.
///
/// Every frame is drawn for the viewport of the moment
/// (``Environment/viewport``). The primary screen commits a new geometry, and
/// possibly a new footer height, only after the resize signal, so a light task
/// compares the viewport every ``Environment/viewportPollInterval`` and draws
/// again when it changed; a resize signal triggers the same check at once. The
/// check closes the controller with ``CloseReason/layoutUnavailable`` once the
/// screen fell back to append-only output (``Environment/isCancelled``).
///
/// After ``stop()`` the controller never calls ``Environment/present``,
/// ``Environment/onClosed`` or ``Environment/modeDidChange`` again, not even
/// from a read still in flight.
@ChatSessionActor
final class TerminalSubAgentDetailController {
    /// Why the panel closed.
    enum CloseReason: Sendable, Equatable {
        /// The operator dismissed the panel (Esc, or `q` in the agent list).
        case dismissed
        /// A consent request needs the input panel.
        case consent
        /// The chat session ended.
        case sessionEnded
        /// Another panel or command took the panel's place.
        case replaced
        /// The terminal layout fell back to append-only output.
        case layoutUnavailable
    }

    /// Everything the controller reads, waits for, and draws through.
    struct Environment {
        /// The snapshots of the session's sub-agents, now and after every
        /// change; `nil` when the session is not available, which ends the
        /// following.
        var snapshotEvents: @Sendable () async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>?
        /// The live transcript of an agent; `nil` when the session has no
        /// such agent or the agent's backend was shut down.
        var transcript: @Sendable (_ agentID: String) async -> ChatSubAgentTranscript?
        /// Waits for a duration; throws when its task is cancelled.
        var sleep: @Sendable (Duration) async throws -> Void
        /// The rows and columns of the panel's frame, read at every frame.
        var viewport: @ChatSessionActor () -> (rows: Int, columns: Int)
        /// Shows a frame: exactly `viewport().rows` lines, each
        /// `viewport().columns` wide.
        var present: @ChatSessionActor (_ lines: [String]) -> Void
        /// Whether the screen fell back to append-only output.
        var isCancelled: @ChatSessionActor () -> Bool
        /// Called once when the controller closes itself (``close(reason:)``).
        var onClosed: @ChatSessionActor (CloseReason) async -> Void
        /// Called when the panel moves between the agent list
        /// (`isChoosing`) and an agent's detail.
        var modeDidChange: @ChatSessionActor (_ isChoosing: Bool) async -> Void
        /// The title of a model identifier, for the header's model row.
        var modelTitleResolver: (String) -> String
        /// Whether the transcript rows carry ANSI styling.
        var standardErrorIsTerminal: Bool
        /// The shortest time between two applied updates that do not change
        /// the agent's lifecycle.
        var updateInterval: Duration
        /// The wait before a finished snapshot stream is subscribed again.
        var resubscribeInterval: Duration
        /// How often the viewport is compared with the last frame's.
        var viewportPollInterval: Duration
        /// Subscribes `observer` to the terminal resize signals and returns
        /// the cancellation of the subscription.
        var subscribeResize: (_ observer: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)

        init(
            snapshotEvents: @escaping @Sendable () async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>?,
            transcript: @escaping @Sendable (_ agentID: String) async -> ChatSubAgentTranscript?,
            viewport: @escaping @ChatSessionActor () -> (rows: Int, columns: Int),
            present: @escaping @ChatSessionActor (_ lines: [String]) -> Void,
            isCancelled: @escaping @ChatSessionActor () -> Bool,
            onClosed: @escaping @ChatSessionActor (CloseReason) async -> Void,
            modeDidChange: @escaping @ChatSessionActor (_ isChoosing: Bool) async -> Void = { _ in },
            modelTitleResolver: @escaping (String) -> String = { $0 },
            standardErrorIsTerminal: Bool,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            updateInterval: Duration = .milliseconds(500),
            resubscribeInterval: Duration = .seconds(1),
            viewportPollInterval: Duration = .milliseconds(200),
            subscribeResize: @escaping (_ observer: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)
                = Environment.subscribeToTerminalResize
        ) {
            self.snapshotEvents = snapshotEvents
            self.transcript = transcript
            self.sleep = sleep
            self.viewport = viewport
            self.present = present
            self.isCancelled = isCancelled
            self.onClosed = onClosed
            self.modeDidChange = modeDidChange
            self.modelTitleResolver = modelTitleResolver
            self.standardErrorIsTerminal = standardErrorIsTerminal
            self.updateInterval = updateInterval
            self.resubscribeInterval = resubscribeInterval
            self.viewportPollInterval = viewportPollInterval
            self.subscribeResize = subscribeResize
        }

        /// The production ``subscribeResize``: a
        /// ``TerminalResizeCoordinator/shared`` subscription.
        static func subscribeToTerminalResize(
            _ observer: @escaping @Sendable () -> Void
        ) -> @Sendable () -> Void {
            let subscription = TerminalResizeCoordinator.shared.subscribe(observer)
            return { subscription.cancel() }
        }
    }

    /// The body row shown while no read returned a transcript.
    nonisolated static let unavailableRow = "The transcript of this sub-agent is not available."

    // MARK: State

    private let environment: Environment
    /// The panel as the last frame drew it.
    private(set) var panel = TerminalSubAgentDetailPanel()
    /// The agent shown; `nil` while the operator chooses one.
    private(set) var agentID: String?
    /// The latest snapshot of the agent shown. It stays when the agent leaves
    /// the snapshots.
    private(set) var snapshot: DirectSubAgentRuntime.AgentSnapshot?
    /// ``stop()`` ran: the controller calls nothing from now on.
    private(set) var isStopped = false
    /// The transcript reads, for tests.
    private(set) var transcriptReadCount = 0
    /// The transcript renderings (the cache missed), for tests.
    private(set) var transcriptRenderCount = 0

    /// The snapshots the agent list opened with.
    private var choiceSnapshots: [DirectSubAgentRuntime.AgentSnapshot] = []
    /// The latest applied snapshot of the agent, as the reads decide on it.
    private var reloadKey: ReloadKey?
    /// The kinds and the tool durations of the latest transcript applied, and
    /// their revision.
    private var kinds: [ChatTurnEntry.Kind]?
    private var toolDurations: [String: Duration] = [:]
    private var kindsRevision: UInt64 = 0
    private var transcriptRows: TranscriptRows?
    /// The reads started, and the one whose transcript is applied: a read
    /// that answers after a later one was applied is stale.
    private var startedReadCount: UInt64 = 0
    private var appliedRead: UInt64 = 0
    /// Changes whenever the following ends: the work of an earlier agent is
    /// stale.
    private var following: UInt64 = 0
    private var followTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var cancelResizeSubscription: (@Sendable () -> Void)?
    /// The viewport of the last frame presented.
    private var lastViewport: Viewport?

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - Opening and closing

    /// Shows the agent list, one entry per snapshot, focused on the first.
    /// No transcript is read until an agent is confirmed. Does nothing after
    /// ``stop()``.
    func open(choosing snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        guard !isStopped else { return }
        endFollowing()
        choiceSnapshots = snapshots
        agentID = nil
        snapshot = nil
        reloadKey = nil
        panel = TerminalSubAgentDetailPanel(
            mode: .choosing(entries: Self.choiceEntries(snapshots), focusedIndex: 0)
        )
        render()
        watchViewport()
    }

    /// Shows the agent `agentID`, from `snapshot` until the first update, and
    /// starts following it. Does nothing after ``stop()``.
    func open(agentID: String, snapshot: DirectSubAgentRuntime.AgentSnapshot?) {
        guard !isStopped else { return }
        show(agentID: agentID, snapshot: snapshot)
        watchViewport()
    }

    /// Applies a key of the panel. In the agent list ↑/↓ move the focus,
    /// Enter shows the focused agent and Esc/`q` close; in an agent's detail
    /// the scrolling keys scroll and Esc closes (the panel leaves `q` and
    /// Enter to the prompt there). Every other key is
    /// ignored, and so is every key after ``stop()``.
    func handle(_ action: TerminalSubAgentDetailAction) async {
        guard !isStopped else { return }
        switch panel.mode {
        case let .choosing(entries, focusedIndex):
            switch action {
            case .scrollUp, .focusPrevious:
                panel.apply(.focusPrevious, frameRows: environment.viewport().rows)
                render()
            case .scrollDown, .focusNext:
                panel.apply(.focusNext, frameRows: environment.viewport().rows)
                render()
            case .confirm:
                guard !entries.isEmpty else { return }
                let agentID = entries[min(max(0, focusedIndex), entries.count - 1)].agentID
                show(agentID: agentID, snapshot: choiceSnapshots.first { $0.id == agentID })
                await environment.modeDidChange(false)
            case .close:
                await close(reason: .dismissed)
            case .pageUp, .pageDown, .top, .bottom:
                return
            }
        case .showing:
            switch action {
            case .scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom:
                panel.apply(action, frameRows: environment.viewport().rows)
                render()
            case .close:
                await close(reason: .dismissed)
            case .focusPrevious, .focusNext, .confirm:
                return
            }
        }
    }

    /// Stops the controller: cancels the following, the viewport checks, and
    /// the resize subscription. The controller calls nothing from now on.
    /// Idempotent.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        endFollowing()
        viewportTask?.cancel()
        viewportTask = nil
        cancelResizeSubscription?()
        cancelResizeSubscription = nil
    }

    /// Stops the controller, then reports `reason` through
    /// ``Environment/onClosed``. Only the first call after the controller
    /// opened reports; a call after ``stop()`` does nothing.
    func close(reason: CloseReason) async {
        guard !isStopped else { return }
        stop()
        await environment.onClosed(reason)
    }

    // MARK: - Following

    private func show(agentID: String, snapshot: DirectSubAgentRuntime.AgentSnapshot?) {
        endFollowing()
        self.agentID = agentID
        self.snapshot = snapshot
        // The read at the opening covers the snapshot the agent opened with:
        // the stream's first value, which repeats it, reads nothing more.
        reloadKey = snapshot.map(ReloadKey.init)
        kinds = nil
        toolDurations = [:]
        transcriptRows = nil
        panel = TerminalSubAgentDetailPanel(mode: .showing)
        render()

        let following = following
        let snapshotEvents = environment.snapshotEvents
        let sleep = environment.sleep
        let updateInterval = environment.updateInterval
        let resubscribeInterval = environment.resubscribeInterval
        followTask = Task { [weak self] in
            await self?.reloadTranscript(following: following)
            while !Task.isCancelled {
                // `nil`: the session is gone, there is nothing to follow.
                guard let stream = await snapshotEvents() else { return }
                // `self` stays weak while the stream is followed: only an
                // update being applied holds it.
                guard self?.isFollowing(following) == true else { return }
                let mailbox = TerminalSubAgentSnapshotMailbox(
                    agentID: agentID,
                    lifecycle: self?.reloadKey?.lifecycle
                )
                let sleepFailed = await withTaskGroup(of: Void.self) { group -> Bool in
                    // The child iterates the stream; it ends when the stream
                    // finishes or the following is cancelled, which releases
                    // the runtime's observer.
                    group.addTask {
                        await mailbox.pump(stream)
                    }
                    defer { group.cancelAll() }
                    while let delivery = await mailbox.next() {
                        guard let self, self.isFollowing(following), !Task.isCancelled else { return false }
                        await self.apply(delivery, following: following)
                        switch await Self.throttle(mailbox, interval: updateInterval, sleep: sleep) {
                        case .elapsed, .lifecycleChanged:
                            continue
                        case .failed:
                            return true
                        }
                    }
                    return false
                }
                guard !sleepFailed, !Task.isCancelled else { return }
                // The stream finished (no backend yet, or a cancellation).
                do {
                    try await sleep(resubscribeInterval)
                } catch {
                    return
                }
                guard self?.isFollowing(following) == true else { return }
            }
        }
    }

    /// Cancels the following of the current agent; its work still in flight
    /// becomes stale.
    private func endFollowing() {
        following &+= 1
        followTask?.cancel()
        followTask = nil
    }

    private func isFollowing(_ following: UInt64) -> Bool {
        !isStopped && following == self.following
    }

    /// How the wait after an applied update ended.
    private enum ThrottleEnd: Sendable {
        /// The interval elapsed.
        case elapsed
        /// A value that changes the agent's lifecycle arrived first.
        case lifecycleChanged
        /// The sleep threw: the following was cancelled.
        case failed
    }

    /// Waits `interval`, or less when a value that changes the agent's
    /// lifecycle reaches `mailbox` first; the other wait is cancelled.
    private nonisolated static func throttle(
        _ mailbox: TerminalSubAgentSnapshotMailbox,
        interval: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async -> ThrottleEnd {
        await withTaskGroup(of: ThrottleEnd.self) { group in
            group.addTask {
                do {
                    try await sleep(interval)
                    return .elapsed
                } catch {
                    return .failed
                }
            }
            group.addTask {
                await mailbox.waitForLifecycleChange()
                return .lifecycleChanged
            }
            let end = await group.next() ?? .failed
            group.cancelAll()
            return end
        }
    }

    /// Applies the snapshots of one update: the agent's snapshot, then a read
    /// of the transcript when the reload key changed. An update without the
    /// agent changes nothing.
    private func apply(_ delivery: TerminalSubAgentSnapshotMailbox.Delivery, following: UInt64) async {
        guard isFollowing(following), let agentID,
              let agent = delivery.snapshots.first(where: { $0.id == agentID }) else { return }
        snapshot = agent
        let key = ReloadKey(agent)
        let changesLifecycle = delivery.changesLifecycle || key.lifecycle != reloadKey?.lifecycle
        guard changesLifecycle || key != reloadKey else {
            render()
            return
        }
        reloadKey = key
        await reloadTranscript(following: following)
    }

    /// Reads the agent's transcript, applies it, and draws the panel. A read
    /// without a transcript keeps the rows, and so does a read that answers
    /// after a later one was applied. The rows are rendered again when the
    /// kinds or the tool durations changed: the backend records a tool result
    /// before the runtime records the call's duration, so a later read can add
    /// only the duration of a call already shown completed.
    private func reloadTranscript(following: UInt64) async {
        guard isFollowing(following), let agentID else { return }
        startedReadCount &+= 1
        let read = startedReadCount
        transcriptReadCount += 1
        let transcript = await environment.transcript(agentID)
        guard isFollowing(following), !Task.isCancelled else { return }
        if let transcript {
            guard read > appliedRead else { return }
            appliedRead = read
            if kinds != transcript.kinds || toolDurations != transcript.toolDurations {
                kinds = transcript.kinds
                toolDurations = transcript.toolDurations
                kindsRevision &+= 1
            }
            panel.availability = .available
        } else if panel.availability == .loading {
            panel.availability = .unavailable
        }
        render()
    }

    // MARK: - Viewport

    /// Starts the viewport checks: a poll every
    /// ``Environment/viewportPollInterval`` and one at every resize signal.
    private func watchViewport() {
        guard !isStopped, viewportTask == nil, cancelResizeSubscription == nil else { return }
        cancelResizeSubscription = environment.subscribeResize { [weak self] in
            Task { @ChatSessionActor [weak self] in
                await self?.checkLayout()
            }
        }
        let sleep = environment.sleep
        let interval = environment.viewportPollInterval
        viewportTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard let self, !self.isStopped else { return }
                if self.environment.isCancelled() {
                    // This task closes the controller: keep it out of the
                    // cancellation of `stop()`, so `onClosed` runs uncancelled.
                    self.viewportTask = nil
                }
                await self.checkLayout()
                guard !self.isStopped else { return }
            }
        }
    }

    /// Closes the controller once the screen fell back to append-only output;
    /// otherwise draws the panel again when the viewport changed since the
    /// last frame.
    private func checkLayout() async {
        guard !isStopped else { return }
        guard !environment.isCancelled() else {
            await close(reason: .layoutUnavailable)
            return
        }
        guard Viewport(environment.viewport()) != lastViewport else { return }
        render()
    }

    // MARK: - Rendering

    /// Draws the panel for the current viewport and presents it.
    private func render() {
        guard !isStopped else { return }
        let viewport = Viewport(environment.viewport())
        lastViewport = viewport
        var headerRows: [String] = []
        var bodyRows: [String] = []
        if case .showing = panel.mode {
            // The interior width of `TerminalSubAgentDetailPanel.frameLines`.
            let width = max(1, viewport.columns - 4)
            headerRows = header(width: width)
            bodyRows = body(width: width)
        }
        panel.replace(headerRows: headerRows, bodyRows: bodyRows, frameRows: viewport.rows)
        environment.present(panel.frameLines(rows: viewport.rows, columns: viewport.columns))
    }

    private func header(width: Int) -> [String] {
        guard let snapshot else { return [] }
        return TerminalChat.subAgentDetailHeaderRows(
            snapshot,
            modelTitleResolver: environment.modelTitleResolver,
            width: width
        )
    }

    /// The transcript (or the unavailable row), then the live activity of a
    /// pending agent (``TerminalChat/subAgentLiveActivityRows(_:width:standardErrorIsTerminal:)``:
    /// the reasoning in progress or the thinking placeholder, nothing while
    /// the agent runs a tool), one blank row apart when both have rows.
    private func body(width: Int) -> [String] {
        var rows: [String]
        switch panel.availability {
        case .available:
            rows = renderedTranscript(width: width)
        case .unavailable:
            rows = [Self.unavailableRow]
        case .loading:
            rows = []
        }
        if let snapshot, snapshot.pending {
            let activity = TerminalChat.subAgentLiveActivityRows(
                snapshot,
                width: width,
                standardErrorIsTerminal: environment.standardErrorIsTerminal
            )
            if !rows.isEmpty, !activity.isEmpty {
                rows.append("")
            }
            rows += activity
        }
        return rows
    }

    /// The rows of the applied transcript at `width`, rendered again only
    /// when the transcript (its kinds or its tool durations) or the width
    /// changed.
    private func renderedTranscript(width: Int) -> [String] {
        guard let kinds else { return [] }
        if let transcriptRows, transcriptRows.revision == kindsRevision, transcriptRows.width == width {
            return transcriptRows.rows
        }
        transcriptRenderCount += 1
        let rows = TerminalChat.renderSubAgentTranscriptRows(
            kinds,
            toolDurations: toolDurations,
            width: width,
            standardErrorIsTerminal: environment.standardErrorIsTerminal
        )
        transcriptRows = TranscriptRows(revision: kindsRevision, width: width, rows: rows)
        return rows
    }

    /// One entry per snapshot, titled with the agent's name (its id when the
    /// name is blank). Agents that share a name also show their id, muted.
    private static func choiceEntries(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [TerminalSubAgentDetailPanel.ChoiceEntry] {
        let names = snapshots.map { $0.name.nilIfBlank ?? $0.id }
        let counts = names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return zip(snapshots, names).map { snapshot, name in
            let isShared = counts[name, default: 0] > 1 && name != snapshot.id
            return TerminalSubAgentDetailPanel.ChoiceEntry(
                agentID: snapshot.id,
                title: isShared
                    ? "\(name) \(TerminalStyle.Text.muted)\(snapshot.id)\(TerminalStyle.reset)"
                    : name
            )
        }
    }

    // MARK: - Keys

    private struct Viewport: Equatable {
        let rows: Int
        let columns: Int

        init(_ viewport: (rows: Int, columns: Int)) {
            rows = viewport.rows
            columns = viewport.columns
        }
    }

    private struct TranscriptRows {
        let revision: UInt64
        let width: Int
        let rows: [String]
    }

    /// What decides that the transcript may have changed: the agent's
    /// lifecycle, its completed execution, its tool, and its latest event.
    private struct ReloadKey: Equatable {
        let lifecycle: TerminalSubAgentLifecycle
        let completedExecutionRevision: UInt64
        let toolName: String?
        let latestEventAt: Date?
        let updatedAt: Date

        init(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) {
            lifecycle = TerminalSubAgentLifecycle(snapshot)
            completedExecutionRevision = snapshot.completedExecutionRevision
            toolName = snapshot.currentToolName
            latestEventAt = snapshot.latestEventAt
            updatedAt = snapshot.updatedAt
        }
    }
}

/// The lifecycle of a sub-agent in a snapshot: its status, whether it is
/// pending, and its execution revision. A change of it is applied, and the
/// transcript read, without waiting for the throttle.
private struct TerminalSubAgentLifecycle: Equatable, Sendable {
    let status: DirectSubAgentRuntime.Status
    let pending: Bool
    let executionRevision: UInt64

    init(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) {
        status = snapshot.status
        pending = snapshot.pending
        executionRevision = snapshot.executionRevision
    }
}

// MARK: - Mailbox

/// The newest snapshots of one stream, handed from the child task that
/// iterates the stream (``pump(_:)``) to the following loop of a
/// ``TerminalSubAgentDetailController`` that applies them (``next()``).
///
/// It keeps only the newest value, and tells whether a value changes the
/// agent's lifecycle from the last value taken (at first, from the lifecycle
/// it was made with); a change seen in a value that a newer one replaced still
/// counts. ``waitForLifecycleChange()`` lets the controller's throttle end as
/// soon as such a value arrives. Every wait ends when its task is cancelled,
/// and nothing polls.
private final class TerminalSubAgentSnapshotMailbox: Sendable {
    /// A value taken from the mailbox.
    struct Delivery: Sendable {
        let snapshots: [DirectSubAgentRuntime.AgentSnapshot]
        /// The value, or one it replaced, changes the agent's lifecycle.
        let changesLifecycle: Bool
    }

    private enum Waiter {
        case value
        case lifecycleChange
    }

    private struct State {
        var latest: [DirectSubAgentRuntime.AgentSnapshot]?
        /// The lifecycle of the agent in ``latest``; `nil` without the agent.
        var latestLifecycle: TerminalSubAgentLifecycle?
        /// The lifecycle of the agent in the last value taken that had it.
        var lifecycle: TerminalSubAgentLifecycle?
        /// A value put since the last take changes the lifecycle.
        var changesLifecycle = false
        var isFinished = false
        var valueWaiter: CheckedContinuation<Void, Never>?
        var lifecycleWaiter: CheckedContinuation<Void, Never>?

        func isReady(for waiter: Waiter) -> Bool {
            switch waiter {
            case .value:
                latest != nil || isFinished
            case .lifecycleChange:
                changesLifecycle
            }
        }

        mutating func set(_ continuation: CheckedContinuation<Void, Never>?, for waiter: Waiter) {
            switch waiter {
            case .value:
                valueWaiter = continuation
            case .lifecycleChange:
                lifecycleWaiter = continuation
            }
        }

        mutating func take(_ waiter: Waiter) -> CheckedContinuation<Void, Never>? {
            switch waiter {
            case .value:
                defer { valueWaiter = nil }
                return valueWaiter
            case .lifecycleChange:
                defer { lifecycleWaiter = nil }
                return lifecycleWaiter
            }
        }
    }

    private let agentID: String
    private let state: Mutex<State>

    /// - Parameters:
    ///   - agentID: The agent whose lifecycle the mailbox watches.
    ///   - lifecycle: The lifecycle of the last snapshot the controller
    ///     applied.
    init(agentID: String, lifecycle: TerminalSubAgentLifecycle?) {
        self.agentID = agentID
        state = Mutex(State(lifecycle: lifecycle))
    }

    /// Iterates `stream` until it finishes or the task is cancelled, keeping
    /// its newest value, then finishes the mailbox.
    func pump(_ stream: AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>) async {
        for await snapshots in stream {
            put(snapshots)
        }
        finish()
    }

    /// Replaces the value not taken yet with `snapshots`, and wakes the waits
    /// it satisfies.
    func put(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        let lifecycle = snapshots.first { $0.id == agentID }.map(TerminalSubAgentLifecycle.init)
        let waiters = state.withLock { state in
            state.latest = snapshots
            state.latestLifecycle = lifecycle
            if let lifecycle, lifecycle != state.lifecycle {
                state.changesLifecycle = true
            }
            let lifecycleWaiter = state.changesLifecycle ? state.take(.lifecycleChange) : nil
            return (state.take(.value), lifecycleWaiter)
        }
        waiters.0?.resume()
        waiters.1?.resume()
    }

    /// No value comes any more: ``next()`` answers the one not taken yet,
    /// then `nil`.
    func finish() {
        let waiter = state.withLock { state in
            state.isFinished = true
            return state.take(.value)
        }
        waiter?.resume()
    }

    /// The newest value not taken yet, waiting for one; `nil` once the
    /// mailbox finished with nothing left, or when the task is cancelled.
    func next() async -> Delivery? {
        while !Task.isCancelled {
            let delivery = state.withLock { state -> Delivery?? in
                if let latest = state.latest {
                    let delivery = Delivery(snapshots: latest, changesLifecycle: state.changesLifecycle)
                    if let latestLifecycle = state.latestLifecycle {
                        state.lifecycle = latestLifecycle
                    }
                    state.latest = nil
                    state.latestLifecycle = nil
                    state.changesLifecycle = false
                    return .some(delivery)
                }
                return state.isFinished ? .some(nil) : nil
            }
            if let delivery {
                return delivery
            }
            await wait(for: .value)
        }
        return nil
    }

    /// Returns once a value that changes the agent's lifecycle waits to be
    /// taken, or when the task is cancelled.
    func waitForLifecycleChange() async {
        await wait(for: .lifecycleChange)
    }

    private func wait(for waiter: Waiter) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Under the lock, so a cancellation either finds the stored
                // continuation or is seen here.
                let resumesNow = state.withLock { state -> Bool in
                    if state.isReady(for: waiter) || Task.isCancelled {
                        return true
                    }
                    state.set(continuation, for: waiter)
                    return false
                }
                if resumesNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            state.withLock { $0.take(waiter) }?.resume()
        }
    }
}
