//
//  ZenSubAgentTranscriptModel.swift
//  ZenApp
//
//  The model of a sub-agent tab: the agent's latest snapshot and the last
//  transcript it read, as rows, followed live from the session the tab was
//  opened in and kept for as long as the tab stays open.
//

import Foundation
import Observation
import Synchronization
import ToolCore
import ZenCODECore

/// The state of one sub-agent tab of a window: the agent's latest snapshot
/// (``snapshot``), the last transcript read, as rows (``items``), and the
/// durations the Core measured of its tool calls (``toolDurations``), from
/// the session the tab was opened in.
///
/// The page keeps the history, not the Core. The Core only reads the live
/// history of the agent's backend
/// (`ChatSessionController.subAgentTranscript(agentID:)`) and answers `nil`
/// once the agent ended and its backend was shut down. The model keeps the
/// last transcript it read for as long as the tab stays open: a read that
/// answers `nil` (an agent that ended, a backend shut down, a pruned record)
/// never clears the rows, so after the agent ends the tab shows its last
/// read. Nothing is saved.
///
/// While it runs (from ``start()`` to ``stop()``) the model follows the
/// snapshots of the session's sub-agents
/// (`AgentCoreSessionRunner.subAgentSnapshotEvents(rootSessionID:)`), keeps
/// the one of its agent, and reads the transcript:
///
/// - When it starts. The reload key starts from the snapshot the tab opened
///   with, so the first value of the stream, which repeats that snapshot,
///   reads nothing more.
/// - At once on a change of the agent's lifecycle (its status, whether it is
///   pending, its execution revision) from the last snapshot applied: the
///   snapshot is applied and the transcript read without waiting for the
///   throttle, in the selected tab and in a hidden one alike.
/// - In the selected tab (``isSelected``), whenever an applied snapshot
///   changes the reload key (the lifecycle, the tool, the latest event, the
///   latest update).
/// - In a hidden tab, only on the lifecycle changes: any other change of the
///   reload key marks a read as due, done as soon as the tab is selected.
///
/// The lifecycle reads of a hidden tab save the end of the conversation: the
/// turn of an agent ends with a lifecycle change, and the read made then
/// keeps the conversation before the coordinator closes the agent and its
/// backend, shut down, takes the history away.
///
/// The updates other than the lifecycle changes are applied at most once per
/// ``updateInterval``: the stream is iterated by a child task that keeps only
/// the newest value while the model waits (``ZenSubAgentSnapshotMailbox``),
/// so the latest value is never lost, and that wakes the model during the
/// wait for a lifecycle change. A stream that finishes (the runtime had no
/// backend yet) is subscribed again after ``resubscribeInterval``, for as
/// long as the model runs.
///
/// Every observed property is assigned only when it changes. When the agent
/// leaves the snapshots, the model keeps the snapshot it showed last.
@MainActor
@Observable
public final class ZenSubAgentTranscriptModel: Identifiable {
    /// Whether the model has a transcript of the agent to show.
    public enum Availability: Equatable, Sendable {
        /// The first read has not answered yet.
        case loading
        /// ``ZenSubAgentTranscriptModel/items`` holds the transcript of the
        /// latest read that returned one.
        case available
        /// No read returned a transcript yet: the agent ended before the tab
        /// read its history, the session has no such agent, or no backend.
        case unavailable
    }

    /// The shortest time between two applied updates: twice a second.
    public nonisolated static let defaultUpdateInterval: Duration = .milliseconds(500)
    /// The wait before the model subscribes again to a snapshot stream that
    /// finished.
    public nonisolated static let defaultResubscribeInterval: Duration = .seconds(1)

    /// The sub-agent of the tab.
    public nonisolated let agentID: String

    public nonisolated var id: String {
        agentID
    }

    // MARK: Observable state

    /// The latest snapshot of the agent; `nil` before the first one. It stays
    /// when the agent leaves the snapshots.
    public private(set) var snapshot: DirectSubAgentRuntime.AgentSnapshot?
    /// The last transcript read, as rows
    /// (``ZenSubAgentTranscriptProjection/items(for:agentID:)``). A read
    /// without a transcript keeps them.
    public private(set) var items: [ZenTranscriptItem] = []
    /// The durations the Core measured of the completed tool calls of
    /// ``items``, by row id
    /// (``ZenSubAgentTranscriptProjection/toolDurations(for:callDurations:)``
    /// of `ChatSubAgentTranscript.toolDurations`), so a call that ran before
    /// the tab opened has its time too. Recomputed when the transcript's kinds
    /// or its durations change: the backend records a tool result before the
    /// Core records the call's duration, so a later read can add only a
    /// duration. A read without a transcript keeps them.
    public private(set) var toolDurations: [String: Duration] = [:]
    /// Whether ``items`` holds a transcript.
    public private(set) var availability: Availability = .loading

    // MARK: Selection

    /// Whether the tab of the model is the selected tab of its window. The
    /// window sets it whenever its selection changes, the opening of the tab
    /// included. Selecting a tab with a read due reads the transcript at
    /// once.
    @ObservationIgnored var isSelected = false {
        didSet {
            guard isSelected, !oldValue, isReloadDue, !isStopped else { return }
            selectionReloadTask?.cancel()
            selectionReloadTask = Task { [weak self] in
                await self?.reloadTranscript()
            }
        }
    }

    // MARK: Composition

    @ObservationIgnored private let source: ZenSubAgentTranscriptSource
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let updateInterval: Duration
    @ObservationIgnored private let resubscribeInterval: Duration

    // MARK: Private state

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The read started by a selection (see ``isSelected``).
    @ObservationIgnored private var selectionReloadTask: Task<Void, Never>?
    /// ``stop()`` ran: the model writes nothing from now on.
    @ObservationIgnored private(set) var isStopped = false
    /// The kinds of the latest transcript applied.
    @ObservationIgnored private var kinds: [ChatTurnEntry.Kind]?
    /// The tool durations of the latest transcript applied, by call id.
    @ObservationIgnored private var callDurations: [String: Duration] = [:]
    /// The latest applied snapshot of the agent, as the reads decide on it;
    /// it starts from the snapshot the tab opened with.
    @ObservationIgnored private var reloadKey: ReloadKey?
    /// A hidden tab put a read off: it reads when it is selected.
    @ObservationIgnored private(set) var isReloadDue = false
    /// The reads started, and the one whose transcript is applied: a read
    /// that answers after a later one was applied is stale.
    @ObservationIgnored private var startedReadCount: UInt64 = 0
    @ObservationIgnored private var appliedRead: UInt64 = 0
    /// The updates applied (a batch of snapshots each), for tests.
    @ObservationIgnored private(set) var updateCount = 0
    /// The transcript reads, for tests.
    @ObservationIgnored private(set) var transcriptReadCount = 0

    /// - Parameters:
    ///   - agentID: The sub-agent of the tab.
    ///   - snapshot: The agent's snapshot as the window knows it, shown until
    ///     the first update, and the reload key the reads start from.
    ///   - source: Where the snapshots and the transcript are read.
    ///   - updateInterval: The shortest time between two applied updates
    ///     that do not change the agent's lifecycle.
    ///   - resubscribeInterval: The wait before a finished stream is
    ///     subscribed again.
    ///   - sleep: Waits for a duration; throws when the task is cancelled.
    init(
        agentID: String,
        snapshot: DirectSubAgentRuntime.AgentSnapshot?,
        source: ZenSubAgentTranscriptSource,
        updateInterval: Duration = ZenSubAgentTranscriptModel.defaultUpdateInterval,
        resubscribeInterval: Duration = ZenSubAgentTranscriptModel.defaultResubscribeInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.agentID = agentID
        self.snapshot = snapshot
        // The read at the start covers the snapshot the tab opened with: the
        // stream's first value, which repeats it, reads nothing more.
        reloadKey = snapshot.map(ReloadKey.init)
        self.source = source
        self.updateInterval = updateInterval
        self.resubscribeInterval = resubscribeInterval
        self.sleep = sleep
    }

    // MARK: - Running

    /// Starts following the agent: reads its transcript, then its snapshots.
    /// A second call, or a call after ``stop()``, does nothing.
    func start() {
        guard task == nil, !isStopped else { return }
        let agentID = agentID
        let source = source
        let sleep = sleep
        let updateInterval = updateInterval
        let resubscribeInterval = resubscribeInterval
        task = Task { [weak self] in
            await self?.reloadTranscript()
            while !Task.isCancelled {
                // `nil`: the session the tab belongs to is gone.
                guard let stream = await source.snapshotEvents() else { return }
                // `self` stays weak while the model follows the stream: only
                // an update being applied holds it.
                guard self != nil else { return }
                let mailbox = ZenSubAgentSnapshotMailbox(agentID: agentID, lifecycle: self?.reloadKey?.lifecycle)
                let sleepFailed = await withTaskGroup(of: Void.self) { group -> Bool in
                    // The child iterates the stream; it ends when the stream
                    // finishes or the model's task is cancelled, which
                    // releases the runtime's observer.
                    group.addTask {
                        await mailbox.pump(stream)
                    }
                    defer { group.cancelAll() }
                    while let delivery = await mailbox.next() {
                        guard let self, !Task.isCancelled else { return false }
                        await self.apply(delivery)
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
                guard self != nil else { return }
            }
        }
    }

    /// Stops following the agent and cancels the model's tasks; the model
    /// keeps what it shows and writes nothing from now on.
    func stop() {
        isStopped = true
        task?.cancel()
        task = nil
        selectionReloadTask?.cancel()
        selectionReloadTask = nil
    }

    // MARK: - Updates

    /// How the wait after an applied update ended.
    private enum ThrottleEnd: Sendable {
        /// The interval elapsed.
        case elapsed
        /// A value that changes the agent's lifecycle arrived first.
        case lifecycleChanged
        /// The sleep threw: the model's task was cancelled.
        case failed
    }

    /// Waits `interval`, or less when a value that changes the agent's
    /// lifecycle reaches `mailbox` first; the other wait is cancelled.
    private nonisolated static func throttle(
        _ mailbox: ZenSubAgentSnapshotMailbox,
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

    /// Applies the snapshots of one update: the agent's snapshot when it
    /// shows something new, then a read of the transcript when it is due (see
    /// the type's documentation). An update without the agent changes
    /// nothing.
    private func apply(_ delivery: ZenSubAgentSnapshotMailbox.Delivery) async {
        guard !isStopped else { return }
        updateCount += 1
        guard let agent = delivery.snapshots.first(where: { $0.id == agentID }) else { return }
        if snapshot.map(DisplayKey.init) != DisplayKey(agent) {
            snapshot = agent
        }
        let key = ReloadKey(agent)
        let changesLifecycle = delivery.changesLifecycle || key.lifecycle != reloadKey?.lifecycle
        guard changesLifecycle || key != reloadKey else { return }
        reloadKey = key
        if changesLifecycle || isSelected {
            await reloadTranscript()
        } else {
            isReloadDue = true
        }
    }

    /// Reads the agent's transcript and applies it. A read without a
    /// transcript keeps the rows the model has, and so does a read that
    /// answers after a later one was applied.
    private func reloadTranscript() async {
        guard !isStopped else { return }
        isReloadDue = false
        startedReadCount += 1
        let read = startedReadCount
        transcriptReadCount += 1
        let transcript = await source.transcript()
        guard !isStopped, !Task.isCancelled else { return }
        guard let transcript else {
            if availability == .loading {
                availability = .unavailable
            }
            return
        }
        guard read > appliedRead else { return }
        appliedRead = read
        let kindsChanged = kinds != transcript.kinds
        if kindsChanged {
            kinds = transcript.kinds
            let rows = ZenSubAgentTranscriptProjection.items(for: transcript.kinds, agentID: agentID)
            if items != rows {
                items = rows
            }
        }
        if kindsChanged || callDurations != transcript.toolDurations {
            callDurations = transcript.toolDurations
            let durations = ZenSubAgentTranscriptProjection.toolDurations(
                for: items,
                callDurations: transcript.toolDurations
            )
            if toolDurations != durations {
                toolDurations = durations
            }
        }
        if availability != .available {
            availability = .available
        }
    }

    // MARK: - Keys

    /// What a sub-agent tab shows of a snapshot: two snapshots with the same
    /// key look alike, so the newer one is not published.
    private struct DisplayKey: Equatable {
        let name: String
        let role: String
        let profileName: String?
        let taskID: String?
        let taskAttemptOrdinal: Int?
        let status: DirectSubAgentRuntime.Status
        let pending: Bool
        let configuredModelID: String?
        let modelID: String?
        let activityKind: DirectSubAgentRuntime.ActivityKind?
        let activity: String?
        /// The reasoning of the thinking phase grows after the paragraph in
        /// progress ended too: the live activity shows it.
        let thought: String?
        let toolName: String?
        let toolTarget: String?
        /// The end of the call flips it while its name and target stay: the
        /// live activity shows the placeholder again.
        let toolIsRunning: Bool
        let cachedPromptTokens: Int?
        let promptTokens: Int?
        let completionTokens: Int?
        let latestOutput: String?
        let latestError: String?
        let createdAt: Date
        /// The duration of an agent that is not pending ends at its latest
        /// update; a pending one shows a live timer instead.
        let finishedAt: Date?

        init(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) {
            name = snapshot.name
            role = snapshot.role
            profileName = snapshot.profileName
            taskID = snapshot.taskID
            taskAttemptOrdinal = snapshot.taskAttemptOrdinal
            status = snapshot.status
            pending = snapshot.pending
            configuredModelID = snapshot.configuredModelID
            modelID = snapshot.modelID
            activityKind = snapshot.currentActivityKind
            activity = snapshot.currentActivity
            thought = snapshot.currentThought
            toolName = snapshot.currentToolName
            toolTarget = snapshot.currentToolTarget
            toolIsRunning = snapshot.currentToolIsRunning
            cachedPromptTokens = snapshot.latestMetrics?.cachedPromptTokenCount
            promptTokens = snapshot.latestMetrics?.promptTokenCount
            completionTokens = snapshot.latestMetrics?.completionTokenCount
            latestOutput = snapshot.latestOutput
            latestError = snapshot.latestError
            createdAt = snapshot.createdAt
            finishedAt = snapshot.pending ? nil : snapshot.updatedAt
        }
    }

    /// What decides that the transcript may have changed: the agent's
    /// lifecycle, its completed execution, its tool and whether it runs (the
    /// end of the call adds its result to the transcript), and its latest
    /// event.
    private struct ReloadKey: Equatable {
        let lifecycle: ZenSubAgentLifecycle
        let completedExecutionRevision: UInt64
        let toolName: String?
        let toolIsRunning: Bool
        let latestEventAt: Date?
        let updatedAt: Date

        init(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) {
            lifecycle = ZenSubAgentLifecycle(snapshot)
            completedExecutionRevision = snapshot.completedExecutionRevision
            toolName = snapshot.currentToolName
            toolIsRunning = snapshot.currentToolIsRunning
            latestEventAt = snapshot.latestEventAt
            updatedAt = snapshot.updatedAt
        }
    }
}

/// The lifecycle of a sub-agent in a snapshot: its status, whether it is
/// pending, and its execution revision. A change of it is applied, and the
/// transcript read, without waiting for the throttle.
struct ZenSubAgentLifecycle: Equatable, Sendable {
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
/// iterates the stream (``pump(_:)``) to the loop of a
/// ``ZenSubAgentTranscriptModel`` that applies them (``next()``).
///
/// It keeps only the newest value, and tells whether a value changes the
/// agent's lifecycle from the last value taken (at first, from the lifecycle
/// it was made with); a change seen in a value that a newer one replaced
/// still counts. ``waitForLifecycleChange()`` lets the model's throttle end
/// as soon as such a value arrives. Every wait ends when its task is
/// cancelled, and nothing polls.
final class ZenSubAgentSnapshotMailbox: Sendable {
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
        var latestLifecycle: ZenSubAgentLifecycle?
        /// The lifecycle of the agent in the last value taken that had it.
        var lifecycle: ZenSubAgentLifecycle?
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
    ///   - lifecycle: The lifecycle of the last snapshot the model applied.
    init(agentID: String, lifecycle: ZenSubAgentLifecycle?) {
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
        let lifecycle = snapshots.first { $0.id == agentID }.map(ZenSubAgentLifecycle.init)
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

// MARK: - Source

/// Where a sub-agent tab reads: the snapshots of the session's sub-agents and
/// the transcript of its agent.
struct ZenSubAgentTranscriptSource: Sendable {
    /// The snapshots of the session's sub-agents, now and after every change;
    /// `nil` when the session the tab belongs to is no longer the window's,
    /// so there is nothing more to follow.
    var snapshotEvents: @Sendable () async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>?
    /// The live transcript of the agent; `nil` when the session has no such
    /// agent, the agent's backend was shut down, the session has no backend,
    /// or it is no longer the window's.
    var transcript: @Sendable () async -> ChatSubAgentTranscript?

    /// The agent `agentID` of the incarnation `epoch` of `slotID`, read on
    /// the chat actor for that incarnation only: once the slot runs another
    /// session, both reads answer `nil`.
    static func incarnation(
        epoch: UInt64,
        agentID: String,
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID
    ) -> ZenSubAgentTranscriptSource {
        ZenSubAgentTranscriptSource(
            snapshotEvents: {
                await ZenSubAgentSteps.snapshotEvents(in: sessionHost, slotID: slotID, epoch: epoch)
            },
            transcript: {
                await ZenSubAgentSteps.transcript(agentID: agentID, in: sessionHost, slotID: slotID, epoch: epoch)
            }
        )
    }
}

/// The reads of a sub-agent tab on the chat actor, each for one incarnation.
@ChatSessionActor
enum ZenSubAgentSteps {
    /// The controller `slotID` runs now, when it is the one of `epoch`.
    static func controller(in sessionHost: ChatSessionHost, slotID: ChatSlotID, epoch: UInt64) -> ChatSessionController? {
        guard let incarnation = sessionHost.incarnation(in: slotID), incarnation.epoch == epoch else { return nil }
        return incarnation.controller
    }

    /// The snapshots of the sub-agents of the incarnation's session, from the
    /// host's runner with the session as the root session.
    static func snapshotEvents(
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        epoch: UInt64
    ) async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>? {
        guard let controller = controller(in: sessionHost, slotID: slotID, epoch: epoch) else { return nil }
        return await sessionHost.runner.subAgentSnapshotEvents(rootSessionID: controller.sessionID)
    }

    static func transcript(
        agentID: String,
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        epoch: UInt64
    ) async -> ChatSubAgentTranscript? {
        guard let controller = controller(in: sessionHost, slotID: slotID, epoch: epoch) else { return nil }
        return await controller.subAgentTranscript(agentID: agentID)
    }
}
