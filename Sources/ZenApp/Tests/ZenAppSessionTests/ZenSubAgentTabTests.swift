//
//  ZenSubAgentTabTests.swift
//  ZenAppSessionTests
//
//  The sub-agent tabs without a window: the projection of a sub-agent
//  transcript and of its tool durations, which tab a close selects, the
//  mailbox of the snapshots, and the model of a tab over a scripted source
//  and a sleep the test releases (the throttling, the lifecycle changes, the
//  selection, the re-subscription, the reads, the last read kept, the tool
//  durations, the stop).
//

import Foundation
import Synchronization
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

// MARK: - Fixtures

private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)

func agent(
    _ id: String = "agent-1",
    status: DirectSubAgentRuntime.Status = .running,
    activity: String? = nil,
    thought: String? = nil,
    toolName: String? = nil,
    toolIsRunning: Bool = false,
    second: TimeInterval = 0,
    executionRevision: UInt64 = 0,
    error: String? = nil
) -> DirectSubAgentRuntime.AgentSnapshot {
    DirectSubAgentRuntime.AgentSnapshot(
        id: id,
        name: "Worker \(id)",
        status: status,
        pending: status.isPending,
        currentActivity: activity,
        currentActivityKind: activity == nil && thought == nil ? nil : .thinking,
        currentThought: thought,
        currentToolName: toolName,
        currentToolIsRunning: toolIsRunning,
        latestEventAt: referenceDate.addingTimeInterval(second),
        latestOutput: nil,
        executionRevision: executionRevision,
        latestError: error,
        createdAt: referenceDate,
        updatedAt: referenceDate.addingTimeInterval(second)
    )
}

// MARK: - Tabs

@Suite("Window tabs")
struct ZenWindowTabTests {
    private let tabs = ZenWindowTab.tabs(subAgentIDs: ["a", "b", "c"])

    @Test("The conversation comes first, then the sub-agents in the order they were opened")
    func tabsOrder() {
        #expect(tabs == [.chat, .subAgent("a"), .subAgent("b"), .subAgent("c")])
        #expect(ZenWindowTab.tabs(subAgentIDs: []) == [.chat])
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
