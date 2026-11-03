//
//  ZenSubAgentTabTests.swift
//  ZenAppSessionTests
//
//  The sub-agent tabs without a window: the projection of a sub-agent
//  transcript, which tab a close selects, the mailbox of the snapshots, and
//  the model of a tab over a scripted source and a sleep the test releases
//  (the throttling, the lifecycle changes, the selection, the
//  re-subscription, the reads, the last read kept, the stop).
//

import Foundation
import Synchronization
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

// MARK: - Fixtures

private func call(_ id: String, _ name: String = "local.exec") -> DirectAgentToolCall {
    DirectAgentToolCall(id: id, name: name, argumentsObject: [:], argumentsJSON: "{}")
}

private func result(_ output: String) -> DirectAgentToolResult {
    DirectAgentToolResult(output: output, summary: output)
}

private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)

private func agent(
    _ id: String = "agent-1",
    status: DirectSubAgentRuntime.Status = .running,
    activity: String? = nil,
    toolName: String? = nil,
    second: TimeInterval = 0,
    executionRevision: UInt64 = 0,
    error: String? = nil
) -> DirectSubAgentRuntime.AgentSnapshot {
    DirectSubAgentRuntime.AgentSnapshot(
        id: id,
        name: "Worker \(id)",
        role: "Developer",
        status: status,
        pending: status.isPending,
        currentActivity: activity,
        currentActivityKind: activity == nil ? nil : .thinking,
        currentToolName: toolName,
        latestEventAt: referenceDate.addingTimeInterval(second),
        latestOutput: nil,
        executionRevision: executionRevision,
        latestError: error,
        createdAt: referenceDate,
        updatedAt: referenceDate.addingTimeInterval(second)
    )
}

private func transcript(
    _ kinds: [ChatTurnEntry.Kind],
    agentID: String = "agent-1"
) -> ChatSubAgentTranscript {
    ChatSubAgentTranscript(agentID: agentID, kinds: kinds)
}

private let brief = ChatTurnEntry.Kind.userPrompt(text: "Brief", attachments: [], origin: .unknown)

// MARK: - Projection

@Suite("Sub-agent transcript projection")
struct ZenSubAgentTranscriptProjectionTests {
    @Test("One row per kind with stable ids; results merge into their call; prompts start turns; phases add no row")
    func projectsTheKinds() {
        let kinds: [ChatTurnEntry.Kind] = [
            brief,
            .thought("Planning the read"),
            .assistantText("Reading."),
            .toolCallStarted(call("a")),
            .toolCallStarted(call("b", "local.readFile")),
            .toolCallCompleted(call("b", "local.readFile"), result: result("B")),
            .toolCallCompleted(call("a"), result: result("A")),
            .turnPhase(.modelReturned),
            .userPrompt(text: "Follow-up", attachments: [], origin: .unknown),
            .assistantText("Done."),
            .toolCallStarted(call("c")),
        ]
        let items = ZenSubAgentTranscriptProjection.items(for: kinds, agentID: "agent-1")
        #expect(items.map(\.id) == [0, 1, 2, 3, 4, 8, 9, 10].map { "subagent-agent-1-\($0)" })
        #expect(items.map(\.content) == [
            .userPrompt(text: "Brief", attachments: [], origin: .unknown),
            .thought("Planning the read", isStreaming: false),
            .assistantText("Reading.", isStreaming: false),
            .toolCall(call: call("a"), result: result("A")),
            .toolCall(call: call("b", "local.readFile"), result: result("B")),
            .userPrompt(text: "Follow-up", attachments: [], origin: .unknown),
            .assistantText("Done.", isStreaming: false),
            // A call still running has no result.
            .toolCall(call: call("c"), result: nil),
        ])
        // Every prompt starts a turn, so a separator goes before the second.
        #expect(items.map(\.startsTurn) == [true, false, false, false, false, true, false, false])
        #expect(items.allSatisfy { $0.turnID == nil })
    }

    @Test("Calls without an id complete oldest first; a result without its call adds no row")
    func callsWithoutID() {
        let kinds: [ChatTurnEntry.Kind] = [
            .toolCallStarted(call("", "first")),
            .toolCallStarted(call("", "second")),
            .toolCallCompleted(call("", "first"), result: result("1")),
            .toolCallCompleted(call("", "second"), result: result("2")),
            .toolCallCompleted(call("orphan"), result: result("3")),
        ]
        let items = ZenSubAgentTranscriptProjection.items(for: kinds, agentID: "a")
        #expect(items.map(\.id) == ["subagent-a-0", "subagent-a-1"])
        #expect(items.map(\.content) == [
            .toolCall(call: call("", "first"), result: result("1")),
            .toolCall(call: call("", "second"), result: result("2")),
        ])
    }

    @Test("A growing transcript keeps the ids of its rows, and the ids name the agent")
    func idsAreStable() {
        let kinds: [ChatTurnEntry.Kind] = [
            brief,
            .assistantText("Reading."),
            .toolCallStarted(call("a")),
            .toolCallCompleted(call("a"), result: result("A")),
            .assistantText("Done."),
        ]
        let early = ZenSubAgentTranscriptProjection.items(for: Array(kinds.prefix(3)), agentID: "agent-1")
        let late = ZenSubAgentTranscriptProjection.items(for: kinds, agentID: "agent-1")
        #expect(early.map(\.id) == Array(late.map(\.id).prefix(3)))
        #expect(early[2].content == .toolCall(call: call("a"), result: nil))
        #expect(late[2].content == .toolCall(call: call("a"), result: result("A")))
        #expect(ZenSubAgentTranscriptProjection.items(for: kinds, agentID: "agent-2").first?.id == "subagent-agent-2-0")
        #expect(ZenSubAgentTranscriptProjection.rowIDPrefix(agentID: "agent-2") == "subagent-agent-2-")
        #expect(ZenSubAgentTranscriptProjection.items(for: [], agentID: "agent-1").isEmpty)
        #expect(ZenSubAgentTranscriptProjection.items(for: [.turnPhase(.started)], agentID: "agent-1").isEmpty)
    }
}

// MARK: - Tabs

@Suite("Window tabs")
struct ZenWindowTabTests {
    private let tabs = ZenWindowTab.tabs(subAgentIDs: ["a", "b", "c"])

    @Test("The conversation comes first, then the sub-agents in the order they were opened")
    func tabsOrder() {
        #expect(tabs == [.chat, .subAgent("a"), .subAgent("b"), .subAgent("c")])
        #expect(ZenWindowTab.tabs(subAgentIDs: []) == [.chat])
        #expect(ZenWindowTab.chat.agentID == nil)
        #expect(ZenWindowTab.subAgent("b").agentID == "b")
    }

    @Test("Closing a tab that is not selected keeps the selection")
    func closingAnotherTab() {
        #expect(ZenWindowTab.selection(afterClosing: "b", in: tabs, selected: .subAgent("c")) == .subAgent("c"))
        #expect(ZenWindowTab.selection(afterClosing: "b", in: tabs, selected: .chat) == .chat)
    }

    @Test("Closing the selected tab selects the tab after it, else the one before it, else the conversation")
    func closingTheSelectedTab() {
        #expect(ZenWindowTab.selection(afterClosing: "b", in: tabs, selected: .subAgent("b")) == .subAgent("c"))
        #expect(ZenWindowTab.selection(afterClosing: "a", in: tabs, selected: .subAgent("a")) == .subAgent("b"))
        #expect(ZenWindowTab.selection(afterClosing: "c", in: tabs, selected: .subAgent("c")) == .subAgent("b"))
        let single = ZenWindowTab.tabs(subAgentIDs: ["a"])
        #expect(ZenWindowTab.selection(afterClosing: "a", in: single, selected: .subAgent("a")) == .chat)
        // A tab that is not in the list leaves the conversation.
        #expect(ZenWindowTab.selection(afterClosing: "z", in: single, selected: .subAgent("z")) == .chat)
    }
}

// MARK: - Model

/// A scripted source for the model of a sub-agent tab: the streams it
/// subscribes to, the transcript it reads, and what it did.
final class ZenSubAgentFeed: Sendable {
    private struct State {
        var transcript: ChatSubAgentTranscript?
        var continuation: AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>.Continuation?
        /// The next subscriptions answer with a stream that finished.
        var finishedStreams = 0
        /// The subscriptions answer `nil`: the session is gone.
        var isGone = false
        var subscriptionCount = 0
        var terminationCount = 0
        var readCount = 0
    }

    private let state: Mutex<State>

    init(transcript: ChatSubAgentTranscript?, finishedStreams: Int = 0) {
        state = Mutex(State(transcript: transcript, finishedStreams: finishedStreams))
    }

    var source: ZenSubAgentTranscriptSource {
        ZenSubAgentTranscriptSource(
            snapshotEvents: { [self] in subscribe() },
            transcript: { [self] in read() }
        )
    }

    var subscriptionCount: Int { state.withLock { $0.subscriptionCount } }
    var terminationCount: Int { state.withLock { $0.terminationCount } }
    var readCount: Int { state.withLock { $0.readCount } }
    var isSubscribed: Bool { state.withLock { $0.continuation != nil } }

    func setTranscript(_ transcript: ChatSubAgentTranscript?) {
        state.withLock { $0.transcript = transcript }
    }

    /// The session is gone: the next subscriptions answer `nil`.
    func goAway() {
        state.withLock { $0.isGone = true }
    }

    func yield(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        let continuation = state.withLock { $0.continuation }
        continuation?.yield(snapshots)
    }

    /// Finishes the stream the model iterates.
    func finishStream() {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.finish()
    }

    private func subscribe() -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>? {
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
        if outcome.finished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.terminationCount += 1 }
            }
        }
        return stream
    }

    private func read() -> ChatSubAgentTranscript? {
        state.withLock { state in
            state.readCount += 1
            return state.transcript
        }
    }
}

/// A sleep that ends only when the test releases it, recording the
/// durations asked; it throws when its task is cancelled. A cancelled sleep
/// is over: the next release ends the sleep after it.
final class ZenSleepGate: Sendable {
    private struct State {
        var requests: [Duration] = []
        var released = 0
        var cancellations = 0
    }

    private let state = Mutex(State())

    var requests: [Duration] { state.withLock { $0.requests } }
    /// The sleeps cancelled before their release.
    var cancellations: Int { state.withLock { $0.cancellations } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await wait(duration) }
    }

    /// Ends the oldest sleep not released yet, now or when it starts.
    func releaseOne() {
        state.withLock { $0.released += 1 }
    }

    private func wait(_ duration: Duration) async throws {
        let index = state.withLock { state in
            state.requests.append(duration)
            return state.requests.count - 1
        }
        let deadline = ContinuousClock.now + zenTestDeadline
        while state.withLock({ $0.released <= index }) {
            guard ContinuousClock.now < deadline else {
                Issue.record("A sleep was never released")
                throw CancellationError()
            }
            do {
                try await Task.sleep(for: .milliseconds(2))
            } catch {
                state.withLock { state in
                    state.cancellations += 1
                    if state.released == index {
                        state.released += 1
                    }
                }
                throw error
            }
        }
    }
}

// MARK: - Mailbox

@Suite("Sub-agent snapshot mailbox")
struct ZenSubAgentSnapshotMailboxTests {
    @Test("It keeps the newest value and flags the lifecycle changes of its agent, a replaced one too")
    func newestValueAndLifecycle() async {
        let mailbox = ZenSubAgentSnapshotMailbox(agentID: "agent-1", lifecycle: ZenSubAgentLifecycle(agent()))
        // A newer event of the same lifecycle replaces the value, unflagged.
        mailbox.put([agent(second: 1)])
        mailbox.put([agent(second: 2)])
        let first = await mailbox.next()
        #expect(first?.snapshots.first?.latestEventAt == referenceDate.addingTimeInterval(2))
        #expect(first?.changesLifecycle == false)

        // A change that a newer value replaced still counts, and wakes the
        // wait for a change.
        mailbox.put([agent(status: .idle, second: 3)])
        mailbox.put([agent(status: .running, second: 4)])
        await mailbox.waitForLifecycleChange()
        let second = await mailbox.next()
        #expect(second?.snapshots.first?.latestEventAt == referenceDate.addingTimeInterval(4))
        #expect(second?.changesLifecycle == true)

        // Another agent's change, or a value without the agent, is not one.
        mailbox.put([agent("agent-2", status: .idle)])
        #expect(await mailbox.next()?.changesLifecycle == false)
        // The comparison is with the last value taken that had the agent.
        mailbox.put([agent(status: .idle, second: 5)])
        #expect(await mailbox.next()?.changesLifecycle == true)
        mailbox.put([agent(status: .idle, second: 6)])
        #expect(await mailbox.next()?.changesLifecycle == false)

        // Finished: the value not taken yet, then nothing.
        mailbox.put([agent(status: .idle, second: 7)])
        mailbox.finish()
        #expect(await mailbox.next()?.snapshots.first?.latestEventAt == referenceDate.addingTimeInterval(7))
        #expect(await mailbox.next() == nil)
    }

    @Test("Its waits end when a value comes, when it finishes, or when their task is cancelled")
    func waitsEnd() async {
        let mailbox = ZenSubAgentSnapshotMailbox(agentID: "agent-1", lifecycle: nil)
        let waitingValue = Task { await mailbox.next()?.snapshots.count }
        try? await Task.sleep(for: .milliseconds(20))
        mailbox.put([agent()])
        #expect(await waitingValue.value == 1)

        let cancelledValue = Task { await mailbox.next() == nil }
        try? await Task.sleep(for: .milliseconds(20))
        cancelledValue.cancel()
        #expect(await cancelledValue.value)

        let cancelledChange = Task { await mailbox.waitForLifecycleChange() }
        try? await Task.sleep(for: .milliseconds(20))
        cancelledChange.cancel()
        await cancelledChange.value

        let finished = Task { await mailbox.next() == nil }
        try? await Task.sleep(for: .milliseconds(20))
        mailbox.finish()
        #expect(await finished.value)
    }
}

@MainActor
@Suite("Sub-agent tab model", .serialized)
struct ZenSubAgentTranscriptModelTests {
    /// A short real sleep: the model never waits for the test.
    private static let quickSleep: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .milliseconds(1))
    }

    private func model(
        _ feed: ZenSubAgentFeed,
        snapshot: DirectSubAgentRuntime.AgentSnapshot? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = quickSleep
    ) -> ZenSubAgentTranscriptModel {
        ZenSubAgentTranscriptModel(
            agentID: "agent-1",
            snapshot: snapshot,
            source: feed.source,
            updateInterval: .milliseconds(500),
            resubscribeInterval: .seconds(1),
            sleep: sleep
        )
    }

    /// Lets the model's task run for a while, for the checks that nothing
    /// happens.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    @Test("It reads the transcript when it starts, then follows its agent's snapshot")
    func readsAndFollows() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief, .assistantText("Working.")]))
        let initial = agent(second: 0)
        let model = model(feed, snapshot: initial)
        #expect(model.availability == .loading)
        #expect(model.snapshot?.updatedAt == initial.updatedAt)
        model.start()
        await waitUntil("the transcript is read") { model.availability == .available }
        #expect(model.items.map(\.id) == ["subagent-agent-1-0", "subagent-agent-1-1"])

        await waitUntil("the model subscribes") { feed.isSubscribed }
        feed.yield([agent("agent-2"), agent(activity: "Reading the file.", second: 1)])
        await waitUntil("the agent's snapshot is applied") { model.snapshot?.currentActivity == "Reading the file." }
        model.stop()
        #expect(model.isStopped)
    }

    @Test("At most one update per interval; the newest snapshot sent during the wait is the one applied")
    func throttlesUpdates() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief]))
        let gate = ZenSleepGate()
        let model = model(feed, sleep: gate.sleep)
        model.start()
        await waitUntil("the model subscribes") { feed.isSubscribed }

        feed.yield([agent(activity: "one", second: 1)])
        await waitUntil("the first update is applied") { model.snapshot?.currentActivity == "one" }
        await waitUntil("the model waits") { gate.requests == [.milliseconds(500)] }
        #expect(model.updateCount == 1)

        // During the wait nothing is applied, and the stream keeps the newest.
        feed.yield([agent(activity: "two", second: 2)])
        feed.yield([agent(activity: "three", second: 3)])
        feed.yield([agent(activity: "four", second: 4)])
        await settle()
        #expect(model.updateCount == 1)
        #expect(model.snapshot?.currentActivity == "one")

        gate.releaseOne()
        await waitUntil("the newest update is applied") { model.snapshot?.currentActivity == "four" }
        #expect(model.updateCount == 2)
        await waitUntil("the model waits again") { gate.requests.count == 2 }
        model.stop()
    }

    @Test("The first value of the stream repeats the snapshot the tab opened with: no second read")
    func noSecondReadOnOpening() async {
        let opening = agent(second: 0)
        let feed = ZenSubAgentFeed(transcript: transcript([brief]))
        let model = model(feed, snapshot: opening)
        model.isSelected = true
        model.start()
        await waitUntil("the model subscribes") { feed.isSubscribed }
        feed.yield([opening])
        await waitUntil("the first value is applied") { model.updateCount == 1 }
        await settle()
        #expect(feed.readCount == 1)
        #expect(model.transcriptReadCount == 1)

        // A newer snapshot reads again.
        feed.yield([agent(second: 1)])
        await waitUntil("a newer snapshot reads the transcript") { feed.readCount == 2 }
        model.stop()
    }

    @Test("In the selected tab the transcript is read again only when the agent changes in a way that can change it")
    func readsOnRelevantChanges() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief]))
        let model = model(feed)
        model.isSelected = true
        model.start()
        await waitUntil("the model subscribes") { feed.isSubscribed }
        feed.yield([agent(second: 1)])
        await waitUntil("the update is applied") { model.updateCount == 1 }
        await waitUntil("the transcript is read again") { feed.readCount == 2 }

        // Another agent changed: the same snapshot of this one reads nothing.
        feed.yield([agent(second: 1), agent("agent-2", second: 5)])
        await waitUntil("the update is applied") { model.updateCount == 2 }
        await settle()
        #expect(feed.readCount == 2)
        #expect(model.transcriptReadCount == 2)

        // Its tool, its state, or its latest event changes: read again.
        feed.yield([agent(toolName: "local.exec", second: 1)])
        await waitUntil("a new tool reads the transcript") { feed.readCount == 3 }
        feed.yield([agent(status: .idle, toolName: "local.exec", second: 1)])
        await waitUntil("a new state reads the transcript") { feed.readCount == 4 }
        feed.yield([agent(status: .idle, toolName: "local.exec", second: 2)])
        await waitUntil("a new event reads the transcript") { feed.readCount == 5 }
        model.stop()
    }

    @Test("A hidden tab reads only on lifecycle changes, and catches up when it is selected")
    func hiddenTabReads() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief]))
        let model = model(feed, snapshot: agent(second: 0))
        model.start()
        await waitUntil("the transcript is read") { model.availability == .available }
        await waitUntil("the model subscribes") { feed.isSubscribed }
        #expect(feed.readCount == 1)

        // A new tool and a new event: applied, and a read is due.
        feed.setTranscript(transcript([brief, .assistantText("Working.")]))
        feed.yield([agent(toolName: "local.exec", second: 1)])
        await waitUntil("the snapshot is applied") { model.snapshot?.currentToolName == "local.exec" }
        await settle()
        #expect(feed.readCount == 1)
        #expect(model.items.count == 1)
        #expect(model.isReloadDue)

        // Selected: the due read runs at once.
        model.isSelected = true
        await waitUntil("the due read runs") { model.items.count == 2 }
        #expect(feed.readCount == 2)
        #expect(!model.isReloadDue)
        // Selected again with no read due: nothing.
        model.isSelected = false
        model.isSelected = true
        await settle()
        #expect(feed.readCount == 2)

        // Hidden again, a turn that ends is read at once: the end of the
        // conversation is kept before the agent is closed.
        model.isSelected = false
        feed.setTranscript(transcript([brief, .assistantText("Working."), .assistantText("Done.")]))
        feed.yield([agent(status: .idle, second: 2)])
        await waitUntil("the end of the turn is read") { model.items.count == 3 }
        #expect(feed.readCount == 3)
        #expect(!model.isReloadDue)
        model.stop()
    }

    @Test("A lifecycle change is applied and read at once, during the throttle; other changes wait for it")
    func lifecycleChangesSkipTheThrottle() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief]))
        let gate = ZenSleepGate()
        let model = model(feed, snapshot: agent(second: 0), sleep: gate.sleep)
        model.start()
        await waitUntil("the model subscribes") { feed.isSubscribed }
        feed.yield([agent(activity: "one", second: 1)])
        await waitUntil("the first update is applied") { model.snapshot?.currentActivity == "one" }
        await waitUntil("the model waits") { gate.requests == [.milliseconds(500)] }
        #expect(feed.readCount == 1)

        // A newer event waits for the throttle.
        feed.yield([agent(activity: "two", second: 2)])
        await settle()
        #expect(model.updateCount == 1)
        #expect(model.snapshot?.currentActivity == "one")

        // The agent stops being pending: applied and read without a release,
        // in a hidden tab too.
        feed.setTranscript(transcript([brief, .assistantText("Done.")]))
        feed.yield([agent(status: .idle, second: 3)])
        await waitUntil("the lifecycle change is applied") { model.snapshot?.status == .idle }
        await waitUntil("the transcript is read") { model.items.count == 2 }
        #expect(model.updateCount == 2)
        #expect(feed.readCount == 2)
        // The interrupted wait was cancelled, and the model waits again.
        await waitUntil("the model waits again") { gate.requests.count == 2 }
        #expect(gate.cancellations == 1)

        // Its execution revision alone is a lifecycle change too.
        feed.yield([agent(status: .idle, second: 3, executionRevision: 1)])
        await waitUntil("the new execution is read") { feed.readCount == 3 }
        #expect(model.updateCount == 3)
        await waitUntil("the model waits again") { gate.requests.count == 3 }
        model.stop()
    }

    @Test("Observed properties change only when what they hold changes")
    func assignsOnlyChanges() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief]))
        let model = model(feed)
        model.isSelected = true
        model.start()
        await waitUntil("the model subscribes") { feed.isSubscribed }
        feed.yield([agent(second: 1)])
        await waitUntil("the transcript is read again") { model.transcriptReadCount == 2 && feed.readCount == 2 }
        await settle()

        let itemChanges = ZenObservationCounter { _ = model.items }
        let snapshotChanges = ZenObservationCounter { _ = model.snapshot }
        let flagChanges = ZenObservationCounter {
            _ = model.availability
        }
        // A newer event of a pending agent: the transcript is read again, it
        // is the same, and the tab shows nothing new (a live timer).
        feed.yield([agent(second: 2)])
        await waitUntil("the transcript is read again") { feed.readCount == 3 }
        await settle()
        #expect(itemChanges.count == 0)
        #expect(snapshotChanges.count == 0)
        #expect(flagChanges.count == 0)

        // A transcript that grew changes the rows only.
        feed.setTranscript(transcript([brief, .assistantText("Done.")]))
        feed.yield([agent(second: 3)])
        await waitUntil("the rows change") { model.items.count == 2 }
        await settle()
        #expect(itemChanges.count == 1)
        #expect(snapshotChanges.count == 0)
        #expect(flagChanges.count == 0)

        // A shown change of the agent changes its snapshot.
        feed.yield([agent(second: 3, error: "boom")])
        await waitUntil("the snapshot changes") { model.snapshot?.latestError == "boom" }
        await settle()
        #expect(snapshotChanges.count == 1)
        model.stop()
    }

    @Test("The tab keeps its last read: the agent's end, its backend shut down, and its record pruned clear nothing")
    func keepsTheLastRead() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief, .assistantText("Working.")]))
        let model = model(feed)
        model.start()
        await waitUntil("the model subscribes") { feed.isSubscribed }
        feed.yield([agent(second: 1, error: "boom")])
        await waitUntil("the snapshot is applied") { model.snapshot?.latestError == "boom" }
        await waitUntil("the rows are shown") { model.items.count == 2 }

        // The agent was closed: its backend is shut down, so the read finds
        // no transcript, and the rows stay.
        feed.setTranscript(nil)
        feed.yield([agent(status: .closed, second: 2, error: "boom")])
        await waitUntil("the end is read") { model.transcriptReadCount == 3 }
        await settle()
        #expect(model.snapshot?.status == .closed)
        #expect(model.items.count == 2)
        #expect(model.availability == .available)

        // The record was pruned: the agent leaves the snapshots, and the tab
        // keeps its last snapshot too.
        feed.yield([agent("agent-2", second: 3)])
        await waitUntil("the update is applied") { model.updateCount == 3 }
        await settle()
        #expect(model.snapshot?.status == .closed)
        #expect(model.items.count == 2)
        #expect(model.availability == .available)
        model.stop()
    }

    @Test("Without a transcript the tab is unavailable until one is read")
    func unavailableUntilRead() async {
        let feed = ZenSubAgentFeed(transcript: nil)
        let model = model(feed)
        model.start()
        await waitUntil("the first read answers") { model.availability == .unavailable }
        #expect(model.items.isEmpty)

        feed.setTranscript(transcript([brief]))
        await waitUntil("the model subscribes") { feed.isSubscribed }
        feed.yield([agent(second: 1)])
        await waitUntil("the transcript is available") { model.availability == .available }
        #expect(model.items.count == 1)
        model.stop()
    }

    @Test("A stream that finished is subscribed again after the interval; a session that is gone ends the model's work")
    func resubscribes() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief]), finishedStreams: 1)
        let gate = ZenSleepGate()
        let model = model(feed, sleep: gate.sleep)
        model.start()
        // The first stream finished at once (no backend yet): wait, then again.
        await waitUntil("the model waits to subscribe again") { gate.requests == [.seconds(1)] }
        #expect(feed.subscriptionCount == 1)
        gate.releaseOne()
        await waitUntil("the model subscribes again") { feed.subscriptionCount == 2 && feed.isSubscribed }

        feed.yield([agent(activity: "Back.", second: 1)])
        await waitUntil("the update is applied") { model.snapshot?.currentActivity == "Back." }
        await waitUntil("the model waits") { gate.requests.count == 2 }
        #expect(gate.requests.last == .milliseconds(500))

        // The stream ends, and the session is gone by the next subscription.
        feed.goAway()
        feed.finishStream()
        gate.releaseOne()
        await waitUntil("the model waits to subscribe again") { gate.requests.count == 3 }
        #expect(gate.requests.last == .seconds(1))
        gate.releaseOne()
        await waitUntil("the model asks once more") { feed.subscriptionCount == 3 }
        await settle()
        #expect(feed.subscriptionCount == 3)
        #expect(gate.requests.count == 3)
        #expect(model.snapshot?.currentActivity == "Back.")
        model.stop()
    }

    @Test("Stop cancels the work: the stream is released and nothing is applied after it")
    func stopEndsTheWork() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief]))
        let gate = ZenSleepGate()
        let model = model(feed, sleep: gate.sleep)
        model.start()
        await waitUntil("the model subscribes") { feed.isSubscribed }
        feed.yield([agent(activity: "one", second: 1)])
        await waitUntil("the model waits") { gate.requests.count == 1 }

        model.stop()
        await waitUntil("the stream is released") { feed.terminationCount == 1 }
        feed.yield([agent(activity: "two", second: 2)])
        gate.releaseOne()
        await settle()
        #expect(model.snapshot?.currentActivity == "one")
        #expect(model.updateCount == 1)
        #expect(feed.subscriptionCount == 1)

        // A stopped model does not start again.
        model.start()
        await settle()
        #expect(feed.subscriptionCount == 1)
    }
}
