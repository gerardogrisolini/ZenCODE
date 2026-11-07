//
//  TerminalSubAgentDetailControllerTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: - Fakes

/// A scripted session for the controller: the snapshot streams it subscribes
/// to, the transcript it reads, and what it did. Reads can be held until the
/// test releases them.
private final class DetailFeed: Sendable {
    private struct State {
        var transcript: ChatSubAgentTranscript?
        var continuation: AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>.Continuation?
        /// The next subscriptions answer with a stream that finished.
        var finishedStreams: Int
        /// The subscriptions answer `nil`: the session is gone.
        var isGone = false
        var subscriptionCount = 0
        var reads: [String] = []
        var holdsReads = false
        var heldReads: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(transcript: ChatSubAgentTranscript?, finishedStreams: Int) {
        state = Mutex(State(transcript: transcript, finishedStreams: finishedStreams))
    }

    var subscriptionCount: Int { state.withLock { $0.subscriptionCount } }
    var isSubscribed: Bool { state.withLock { $0.continuation != nil } }
    var reads: [String] { state.withLock { $0.reads } }
    var heldReadCount: Int { state.withLock { $0.heldReads.count } }

    func setTranscript(_ transcript: ChatSubAgentTranscript?) {
        state.withLock { $0.transcript = transcript }
    }

    func goAway() {
        state.withLock { $0.isGone = true }
    }

    func yield(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        let continuation = state.withLock { $0.continuation }
        continuation?.yield(snapshots)
    }

    /// Finishes the stream the controller iterates.
    func finishStream() {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.finish()
    }

    /// The next reads wait until ``releaseReads()``.
    func holdReads() {
        state.withLock { $0.holdsReads = true }
    }

    func releaseReads() {
        let held = state.withLock { state in
            state.holdsReads = false
            defer { state.heldReads = [] }
            return state.heldReads
        }
        held.forEach { $0.resume() }
    }

    func subscribe() -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>? {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [DirectSubAgentRuntime.AgentSnapshot].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let outcome = state.withLock { state -> (isGone: Bool, finished: Bool) in
            state.subscriptionCount += 1
            if state.isGone { return (true, false) }
            if state.finishedStreams > 0 {
                state.finishedStreams -= 1
                return (false, true)
            }
            state.continuation = continuation
            return (false, false)
        }
        if outcome.isGone { return nil }
        if outcome.finished { continuation.finish() }
        return stream
    }

    func read(_ agentID: String) async -> ChatSubAgentTranscript? {
        let holds = state.withLock { state in
            state.reads.append(agentID)
            return state.holdsReads
        }
        if holds {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumesNow = state.withLock { state in
                    guard state.holdsReads else { return true }
                    state.heldReads.append(continuation)
                    return false
                }
                if resumesNow { continuation.resume() }
            }
        }
        return state.withLock { $0.transcript }
    }
}

/// A sleep that ends only when the test releases it, by duration; it throws
/// when its task is cancelled. Nothing sleeps for real.
private final class DetailSleepGate: Sendable {
    private struct Waiter {
        let id: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var nextID = 0
        var waiters: [Waiter] = []
        var requests: [Duration] = []
    }

    private let state = Mutex(State())

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await wait(duration) }
    }

    /// The sleeps of `duration` waiting for a release.
    func pendingCount(_ duration: Duration) -> Int {
        state.withLock { state in state.waiters.filter { waiter in waiter.duration == duration }.count }
    }

    /// The sleeps of `duration` ever asked.
    func requestCount(_ duration: Duration) -> Int {
        state.withLock { state in state.requests.filter { request in request == duration }.count }
    }

    /// Ends the oldest sleep of `duration` waiting; `false` when none waits.
    @discardableResult
    func release(_ duration: Duration) -> Bool {
        let waiter = state.withLock { state -> Waiter? in
            guard let index = state.waiters.firstIndex(where: { $0.duration == duration }) else { return nil }
            return state.waiters.remove(at: index)
        }
        waiter?.continuation.resume()
        return waiter != nil
    }

    private func wait(_ duration: Duration) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            state.requests.append(duration)
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let isCancelled = state.withLock { state in
                    guard !Task.isCancelled else { return true }
                    state.waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                    return false
                }
                if isCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// The terminal resize signal: one observer at a time, fired by the test.
private final class DetailResizeSignal: Sendable {
    private struct State {
        var observer: (@Sendable () -> Void)?
        var cancellations = 0
    }

    private let state = Mutex(State())

    var isSubscribed: Bool { state.withLock { $0.observer != nil } }
    var cancellationCount: Int { state.withLock { $0.cancellations } }

    func subscribe(_ observer: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        state.withLock { $0.observer = observer }
        return { [self] in
            state.withLock { state in
                state.observer = nil
                state.cancellations += 1
            }
        }
    }

    func signal() {
        state.withLock { $0.observer }?()
    }
}

/// The screen and the caller around a controller: the frames presented, the
/// close reasons, and the mode changes.
@ChatSessionActor
private final class DetailHarness {
    static let updateInterval: Duration = .milliseconds(500)
    static let resubscribeInterval: Duration = .seconds(1)
    static let pollInterval: Duration = .milliseconds(200)

    let feed: DetailFeed
    let gate = DetailSleepGate()
    let resize = DetailResizeSignal()
    var viewport: (rows: Int, columns: Int) = (rows: 20, columns: 60)
    var isCancelled = false
    private(set) var frames: [[String]] = []
    private(set) var closeReasons: [TerminalSubAgentDetailController.CloseReason] = []
    /// Whether the task that reported each close was cancelled.
    private(set) var closedWhileCancelled: [Bool] = []
    private(set) var modeChanges: [Bool] = []

    init(transcript: ChatSubAgentTranscript?, finishedStreams: Int = 0) {
        feed = DetailFeed(transcript: transcript, finishedStreams: finishedStreams)
    }

    func makeController() -> TerminalSubAgentDetailController {
        let feed = feed
        let resize = resize
        return TerminalSubAgentDetailController(environment: .init(
            snapshotEvents: { feed.subscribe() },
            transcript: { await feed.read($0) },
            viewport: { self.viewport },
            present: { self.frames.append($0) },
            isCancelled: { self.isCancelled },
            onClosed: { reason in
                self.closeReasons.append(reason)
                self.closedWhileCancelled.append(Task.isCancelled)
            },
            modeDidChange: { self.modeChanges.append($0) },
            standardErrorIsTerminal: false,
            sleep: gate.sleep,
            updateInterval: Self.updateInterval,
            resubscribeInterval: Self.resubscribeInterval,
            viewportPollInterval: Self.pollInterval,
            subscribeResize: { resize.subscribe($0) }
        ))
    }
}

// MARK: - Tests

@ChatSessionActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalSubAgentDetailControllerTests {
    private func agent(
        _ id: String = "agent-1",
        name: String = "worker",
        status: DirectSubAgentRuntime.Status = .running,
        pending: Bool = true,
        executionRevision: UInt64 = 1,
        activity: String? = nil,
        second: TimeInterval = 0
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            name: name,
            role: "Reviews the change",
            status: status,
            pending: pending,
            currentActivity: activity,
            currentActivityKind: activity == nil ? nil : .content,
            latestEventAt: referenceDate.addingTimeInterval(second),
            latestOutput: nil,
            executionRevision: executionRevision,
            latestError: nil,
            createdAt: referenceDate,
            updatedAt: referenceDate.addingTimeInterval(second)
        )
    }

    private func transcript(_ blocks: [String], agentID: String = "agent-1") -> ChatSubAgentTranscript {
        ChatSubAgentTranscript(agentID: agentID, kinds: blocks.map { .assistantText($0) })
    }

    /// The transcript rows of `blocks` at the interior width of a frame
    /// `columns` wide.
    private func rows(_ blocks: [String], columns: Int = 60) -> [String] {
        TerminalChat.renderSubAgentTranscriptRows(
            blocks.map { .assistantText($0) },
            width: columns - 4,
            standardErrorIsTerminal: false
        )
    }

    private func header(_ snapshot: DirectSubAgentRuntime.AgentSnapshot, columns: Int = 60) -> [String] {
        TerminalChat.subAgentDetailHeaderRows(snapshot, modelTitleResolver: { $0 }, width: columns - 4)
    }

    private func liveActivity(_ snapshot: DirectSubAgentRuntime.AgentSnapshot, columns: Int = 60) -> [String] {
        TerminalChat.subAgentLiveActivityRows(
            snapshot,
            width: columns - 4,
            // The harness environment's `standardErrorIsTerminal`.
            standardErrorIsTerminal: false
        )
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting until \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Lets the controller's tasks run, for the checks that nothing happens.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
    }

    // MARK: Reads

    @Test func readsTheTranscriptAtOnceWhenAnAgentOpens() async {
        let harness = DetailHarness(transcript: transcript(["FIRST_BLOCK"]))
        let controller = harness.makeController()
        let initial = agent(status: .idle, pending: false)
        controller.open(agentID: "agent-1", snapshot: initial)
        // The frame shows at once, before the read answers.
        #expect(harness.frames.count == 1)
        #expect(controller.panel.mode == .showing)
        #expect(controller.panel.availability == .loading)
        #expect(controller.panel.headerRows == header(initial))
        #expect(controller.panel.bodyRows.isEmpty)

        await waitUntil("the transcript is read") { controller.panel.availability == .available }
        #expect(harness.feed.reads == ["agent-1"])
        #expect(controller.panel.bodyRows == rows(["FIRST_BLOCK"]))
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))
        #expect(harness.frames.last?.count == 20)

        // The stream's first value repeats the snapshot the agent opened
        // with: it reads nothing more.
        await waitUntil("the controller subscribes") { harness.feed.isSubscribed }
        harness.feed.yield([agent("agent-2"), initial])
        await waitUntil("the update is applied") {
            harness.gate.pendingCount(DetailHarness.updateInterval) == 1
        }
        #expect(controller.transcriptReadCount == 1)
        controller.stop()
    }

    @Test func readsAgainAtOnceWhenTheLifecycleChanges() async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent())
        await waitUntil("the controller subscribes") { harness.feed.isSubscribed }
        harness.feed.yield([agent(second: 1)])
        await waitUntil("the update reads") { controller.transcriptReadCount == 2 }
        await waitUntil("the controller waits") { harness.gate.pendingCount(DetailHarness.updateInterval) == 1 }

        // A lifecycle change ends the wait: applied and read without a release.
        harness.feed.setTranscript(transcript(["FIRST", "DONE"]))
        let ended = agent(status: .idle, pending: false, second: 2)
        harness.feed.yield([ended])
        await waitUntil("the lifecycle change is read") { controller.panel.bodyRows == rows(["FIRST", "DONE"]) }
        #expect(controller.transcriptReadCount == 3)
        #expect(controller.snapshot?.status == .idle)
        #expect(controller.panel.headerRows == header(ended))
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))
        controller.stop()
    }

    @Test func throttlesTheChangesThatKeepTheLifecycle() async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent())
        await waitUntil("the controller subscribes") { harness.feed.isSubscribed }
        harness.feed.yield([agent(second: 1)])
        await waitUntil("the first update reads") { controller.transcriptReadCount == 2 }
        await waitUntil("the controller waits") { harness.gate.pendingCount(DetailHarness.updateInterval) == 1 }

        // During the wait nothing is applied; the newest value is kept.
        harness.feed.yield([agent(second: 2)])
        harness.feed.yield([agent(activity: "LATEST", second: 3)])
        await settle()
        #expect(controller.transcriptReadCount == 2)
        #expect(controller.snapshot?.latestEventAt == referenceDate.addingTimeInterval(1))

        #expect(harness.gate.release(DetailHarness.updateInterval))
        await waitUntil("the newest value is applied") { controller.transcriptReadCount == 3 }
        await waitUntil("the controller waits again") {
            harness.gate.pendingCount(DetailHarness.updateInterval) == 1
        }
        let latest = agent(activity: "LATEST", second: 3)
        #expect(controller.snapshot?.latestEventAt == latest.latestEventAt)
        // A pending agent shows its live activity below the transcript.
        #expect(controller.panel.bodyRows == rows(["FIRST"]) + [""] + liveActivity(latest))
        // The unchanged transcript is not rendered again.
        #expect(controller.transcriptRenderCount == 1)
        controller.stop()
    }

    @Test func aReadWithoutTranscriptNeverClearsTheRows() async {
        let harness = DetailHarness(transcript: nil)
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent(status: .idle, pending: false))
        await waitUntil("the read answers nil") { controller.panel.availability == .unavailable }
        #expect(controller.panel.bodyRows == [TerminalSubAgentDetailController.unavailableRow])

        // The first read that answers applies the transcript.
        harness.feed.setTranscript(transcript(["KEPT"]))
        await waitUntil("the controller subscribes") { harness.feed.isSubscribed }
        let running = agent(second: 1)
        harness.feed.yield([running])
        await waitUntil("the transcript is read") { controller.panel.availability == .available }
        #expect(controller.panel.bodyRows == rows(["KEPT"]) + [""] + liveActivity(running))

        // A later read without transcript keeps the rows, never the
        // unavailable row.
        harness.feed.setTranscript(nil)
        harness.feed.yield([agent(status: .closed, pending: false, second: 2)])
        await waitUntil("the closed agent is drawn") { controller.panel.bodyRows == rows(["KEPT"]) }
        #expect(controller.transcriptReadCount == 3)
        #expect(controller.panel.availability == .available)
        #expect(!controller.panel.bodyRows.contains(TerminalSubAgentDetailController.unavailableRow))
        controller.stop()
    }

    @Test func subscribesAgainAfterTheStreamFinishes() async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]), finishedStreams: 1)
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent())
        await waitUntil("the controller waits to subscribe again") {
            harness.gate.pendingCount(DetailHarness.resubscribeInterval) == 1
        }
        #expect(harness.feed.subscriptionCount == 1)
        #expect(harness.gate.release(DetailHarness.resubscribeInterval))
        await waitUntil("the controller subscribes again") { harness.feed.isSubscribed }
        #expect(harness.feed.subscriptionCount == 2)

        // The new stream is followed.
        harness.feed.yield([agent(status: .idle, pending: false, second: 1)])
        await waitUntil("the update is applied") { controller.snapshot?.status == .idle }

        // Once the session is gone the following ends.
        await waitUntil("the controller waits") { harness.gate.pendingCount(DetailHarness.updateInterval) == 1 }
        harness.feed.goAway()
        harness.feed.finishStream()
        #expect(harness.gate.release(DetailHarness.updateInterval))
        await waitUntil("the controller waits to subscribe again") {
            harness.gate.pendingCount(DetailHarness.resubscribeInterval) == 1
        }
        #expect(harness.gate.release(DetailHarness.resubscribeInterval))
        await waitUntil("the controller asks again") { harness.feed.subscriptionCount == 3 }
        await settle()
        #expect(harness.gate.pendingCount(DetailHarness.resubscribeInterval) == 0)
        #expect(harness.feed.subscriptionCount == 3)
        // The last snapshot stays.
        #expect(controller.snapshot?.status == .idle)
        controller.stop()
    }

    // MARK: Keys

    @Test func scrollingUpStopsFollowingAndBottomResumesIt() async {
        let blocks = (0..<10).map { "BLOCK_\($0)" }
        let harness = DetailHarness(transcript: transcript(blocks))
        harness.viewport = (rows: 8, columns: 40)
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent(status: .idle, pending: false))
        await waitUntil("the transcript is read") { controller.panel.availability == .available }
        #expect(controller.panel.bodyRows == rows(blocks, columns: 40))
        let capacity = controller.panel.bodyCapacity(frameRows: 8)
        let maximum = controller.panel.bodyRows.count - capacity
        #expect(capacity > 0)
        #expect(controller.panel.isFollowing)
        #expect(controller.panel.scrollOffset == maximum)

        await controller.handle(.scrollUp)
        #expect(!controller.panel.isFollowing)
        #expect(controller.panel.scrollOffset == maximum - 1)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 8, columns: 40))

        // The keys of the agent list do nothing here.
        let scrolled = controller.panel
        await controller.handle(.focusNext)
        await controller.handle(.confirm)
        #expect(controller.panel == scrolled)
        #expect(harness.modeChanges.isEmpty)

        // A longer transcript keeps the rows being read in place.
        let longer = blocks + ["BLOCK_10", "BLOCK_11"]
        harness.feed.setTranscript(transcript(longer))
        await waitUntil("the controller subscribes") { harness.feed.isSubscribed }
        harness.feed.yield([agent(status: .idle, pending: false, executionRevision: 2, second: 1)])
        await waitUntil("the longer transcript is read") {
            controller.panel.bodyRows == rows(longer, columns: 40)
        }
        #expect(!controller.panel.isFollowing)
        #expect(controller.panel.scrollOffset == maximum - 1)

        await controller.handle(.bottom)
        #expect(controller.panel.isFollowing)
        #expect(controller.panel.scrollOffset
            == controller.panel.bodyRows.count - controller.panel.bodyCapacity(frameRows: 8))
        #expect(harness.frames.last == controller.panel.frameLines(rows: 8, columns: 40))

        await controller.handle(.close)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
    }

    @Test func theListMovesTheFocusAndEnterOpensTheFocusedAgent() async {
        let harness = DetailHarness(transcript: transcript(["SECOND_AGENT"], agentID: "agent-2"))
        let controller = harness.makeController()
        let agents = [
            agent("agent-1", name: "worker"),
            agent("agent-2", name: "worker", status: .idle, pending: false),
            agent("agent-3", name: "reviewer"),
            agent("agent-4", name: "  ")
        ]
        controller.open(choosing: agents)
        func focus() -> Int? {
            guard case let .choosing(_, focusedIndex) = controller.panel.mode else { return nil }
            return focusedIndex
        }
        guard case let .choosing(entries, _) = controller.panel.mode else {
            Issue.record("The list is not shown")
            return
        }
        let muted = TerminalStyle.Text.muted, reset = TerminalStyle.reset
        #expect(entries.map(\.agentID) == ["agent-1", "agent-2", "agent-3", "agent-4"])
        // Agents sharing a name show their id, muted; a blank name is the id.
        #expect(entries.map(\.title) == [
            "worker \(muted)agent-1\(reset)", "worker \(muted)agent-2\(reset)", "reviewer", "agent-4"
        ])
        #expect(focus() == 0)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))

        await controller.handle(.scrollDown)
        #expect(focus() == 1)
        await controller.handle(.scrollUp)
        #expect(focus() == 0)
        await controller.handle(.scrollUp)
        #expect(focus() == 3)
        await controller.handle(.focusNext)
        #expect(focus() == 0)
        await controller.handle(.focusNext)
        #expect(focus() == 1)
        await controller.handle(.pageDown)
        await controller.handle(.bottom)
        #expect(focus() == 1)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))

        // The list reads nothing.
        await settle()
        #expect(harness.feed.reads.isEmpty)
        #expect(harness.feed.subscriptionCount == 0)

        await controller.handle(.confirm)
        #expect(controller.panel.mode == .showing)
        #expect(controller.agentID == "agent-2")
        #expect(harness.modeChanges == [false])
        #expect(controller.panel.headerRows == header(agents[1]))
        await waitUntil("the agent's transcript is read") { controller.panel.availability == .available }
        #expect(harness.feed.reads == ["agent-2"])
        #expect(controller.panel.bodyRows == rows(["SECOND_AGENT"]))
        controller.stop()
    }

    // MARK: Closing

    @Test func closingIsIdempotentAndNothingFollowsIt() async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        controller.open(choosing: [agent()])
        #expect(harness.resize.isSubscribed)

        await controller.handle(.close)
        await controller.close(reason: .replaced)
        await controller.close(reason: .dismissed)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.resize.cancellationCount == 1)
        await waitUntil("the poll is cancelled") { harness.gate.pendingCount(DetailHarness.pollInterval) == 0 }

        let frames = harness.frames.count
        await controller.handle(.scrollDown)
        await controller.handle(.confirm)
        controller.open(agentID: "agent-1", snapshot: agent())
        controller.open(choosing: [agent()])
        controller.stop()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(harness.modeChanges.isEmpty)
        #expect(harness.feed.reads.isEmpty)
        #expect(harness.closeReasons == [.dismissed])
    }

    @Test func nothingIsPresentedAfterStopNotEvenByAReadInFlight() async {
        let harness = DetailHarness(transcript: transcript(["LATE"]))
        harness.feed.holdReads()
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent())
        await waitUntil("the read is in flight") { harness.feed.heldReadCount == 1 }
        let frames = harness.frames.count

        controller.stop()
        controller.stop()
        harness.feed.releaseReads()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(controller.panel.availability == .loading)
        #expect(harness.feed.subscriptionCount == 0)
        #expect(harness.resize.cancellationCount == 1)

        // A close after a stop reports nothing.
        await controller.close(reason: .dismissed)
        #expect(harness.closeReasons.isEmpty)
    }

    // MARK: Viewport

    @Test func drawsAgainWhenTheViewportChanges() async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        let snapshot = agent(status: .idle, pending: false)
        controller.open(agentID: "agent-1", snapshot: snapshot)
        await waitUntil("the transcript is read") { controller.panel.availability == .available }
        await waitUntil("the poll waits") { harness.gate.pendingCount(DetailHarness.pollInterval) == 1 }

        // A poll that finds the same viewport draws nothing.
        let frames = harness.frames.count
        #expect(harness.gate.release(DetailHarness.pollInterval))
        await waitUntil("the next poll waits") { harness.gate.requestCount(DetailHarness.pollInterval) == 2 }
        #expect(harness.frames.count == frames)

        // A poll that finds a new viewport draws for it.
        harness.viewport = (rows: 12, columns: 40)
        #expect(harness.gate.release(DetailHarness.pollInterval))
        await waitUntil("the panel is drawn again") { harness.frames.last?.count == 12 }
        #expect(harness.frames.last == controller.panel.frameLines(rows: 12, columns: 40))
        #expect(controller.panel.headerRows == header(snapshot, columns: 40))
        #expect(controller.panel.bodyRows == rows(["FIRST"], columns: 40))
        #expect(controller.transcriptRenderCount == 2)

        // A resize signal checks at once, without the poll.
        harness.viewport = (rows: 10, columns: 50)
        harness.resize.signal()
        await waitUntil("the panel is drawn again") { harness.frames.last?.count == 10 }
        #expect(harness.frames.last == controller.panel.frameLines(rows: 10, columns: 50))
        controller.stop()
    }

    @Test(arguments: [false, true])
    func closesWhenTheScreenTurnsAppendOnly(throughResizeSignal: Bool) async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent())
        await waitUntil("the poll waits") { harness.gate.pendingCount(DetailHarness.pollInterval) == 1 }

        harness.isCancelled = true
        if throughResizeSignal {
            harness.resize.signal()
        } else {
            #expect(harness.gate.release(DetailHarness.pollInterval))
        }
        await waitUntil("the controller closes") { !harness.closeReasons.isEmpty }
        #expect(harness.closeReasons == [.layoutUnavailable])
        // `onClosed` runs in a task that is not cancelled.
        #expect(harness.closedWhileCancelled == [false])
        #expect(controller.isStopped)
        #expect(harness.resize.cancellationCount == 1)

        let frames = harness.frames.count
        harness.isCancelled = false
        harness.viewport = (rows: 10, columns: 40)
        harness.resize.signal()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(harness.closeReasons == [.layoutUnavailable])
    }
}
