//
//  ZenSubAgentTranscriptModelTests.swift
//  ZenAppSessionTests
//
//  The projection of a sub-agent transcript and the model of a sub-agent tab
//  over a scripted source and a sleep the test releases, with the fixtures
//  they share.
//

import Foundation
import Synchronization
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

private func call(_ id: String, _ name: String = "local.exec") -> DirectAgentToolCall {
    DirectAgentToolCall(id: id, name: name, argumentsObject: [:], argumentsJSON: "{}")
}

private func result(_ output: String) -> DirectAgentToolResult {
    DirectAgentToolResult(output: output, summary: output)
}

private func transcript(
    _ kinds: [ChatTurnEntry.Kind],
    agentID: String = "agent-1"
) -> ChatSubAgentTranscript {
    ChatSubAgentTranscript(agentID: agentID, kinds: kinds)
}

private let brief = ChatTurnEntry.Kind.userPrompt(text: "Brief", attachments: [], origin: .unknown)

@Suite("Sub-agent transcript projection")
struct ZenSubAgentTranscriptProjectionTests {
    @Test("One row per kind with stable ids; results merge into their call; prompts start turns; phases add no row")
    func projectsTheKinds() {
        let kinds: [ChatTurnEntry.Kind] = [
            brief,
            .thought("Planning the read"),
            .assistantText("Reading."),
            .toolCallStarted(call("a")),
            .toolCallStarted(call("b", "local.read")),
            .toolCallCompleted(call("b", "local.read"), result: result("B")),
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
            .toolCall(call: call("b", "local.read"), result: result("B")),
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

    @Test("The call durations go to the rows of the completed calls that have one, by row id")
    func toolDurations() {
        let kinds: [ChatTurnEntry.Kind] = [
            brief,
            .toolCallStarted(call("a")),
            .toolCallStarted(call("b")),
            .toolCallStarted(call("", "anonymous")),
            .toolCallCompleted(call("a"), result: result("A")),
            .toolCallCompleted(call("", "anonymous"), result: result("anonymous")),
            .toolCallStarted(call("c")),
            .toolCallCompleted(call("c"), result: result("C")),
            .assistantText("Done."),
        ]
        let items = ZenSubAgentTranscriptProjection.items(for: kinds, agentID: "agent-1")
        let durations = ZenSubAgentTranscriptProjection.toolDurations(
            for: items,
            callDurations: ["a": .seconds(1), "b": .seconds(2), "": .seconds(3), "missing": .seconds(4)]
        )
        // `a` completed with a duration; `b` still runs; the call without an
        // id never takes one; `c` completed without one; the prompt and the
        // text are not calls.
        #expect(durations == ["subagent-agent-1-1": .seconds(1)])
        #expect(ZenSubAgentTranscriptProjection.toolDurations(for: items, callDurations: [:]).isEmpty)
        #expect(ZenSubAgentTranscriptProjection.toolDurations(for: [], callDurations: ["a": .seconds(1)]).isEmpty)
    }
}

@MainActor
@Suite("Sub-agent tab model")
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

    @Test("A snapshot whose reasoning grew is applied, with everything else unchanged")
    func appliesTheGrowingReasoning() async {
        let feed = ZenSubAgentFeed(transcript: transcript([brief]))
        let gate = ZenSleepGate()
        let model = model(feed, sleep: gate.sleep)
        model.start()
        await waitUntil("the model subscribes") { feed.isSubscribed }

        feed.yield([agent(thought: "First.", second: 1)])
        await waitUntil("the first update is applied") { model.snapshot?.currentThought == "First." }
        await waitUntil("the model waits") { gate.requests.count == 1 }

        // Only the reasoning differs: no paragraph in progress, same times.
        feed.yield([agent(thought: "First.\n\nSecond.", second: 1)])
        gate.releaseOne()
        await waitUntil("the grown reasoning is applied") {
            model.snapshot?.currentThought == "First.\n\nSecond."
        }
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

        // The end of its tool alone (same name, same event time) reads too:
        // the result is in the transcript now.
        feed.yield([agent(status: .idle, toolName: "local.exec", toolIsRunning: true, second: 2)])
        await waitUntil("a tool that starts reads the transcript") { feed.readCount == 6 }
        feed.yield([agent(status: .idle, toolName: "local.exec", toolIsRunning: false, second: 2)])
        await waitUntil("a tool that ends reads the transcript") { feed.readCount == 7 }
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

        // The end of a tool is shown too, though its name stays: the live
        // activity of the tab draws the placeholder again (the snapshot
        // published is the one without a running tool).
        feed.yield([agent(toolName: "local.exec", toolIsRunning: true, second: 4, error: "boom")])
        await waitUntil("the running tool is shown") { model.snapshot?.currentToolIsRunning == true }
        feed.yield([agent(toolName: "local.exec", toolIsRunning: false, second: 4, error: "boom")])
        await waitUntil("the end of the tool is shown") {
            model.snapshot?.currentToolName == "local.exec" && model.snapshot?.currentToolIsRunning == false
        }
        await settle()
        #expect(snapshotChanges.count == 3)
        #expect(model.snapshot?.currentToolIsRunning == false)
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

    @Test("The tool durations are the transcript's, by row id: a read that adds only a duration shows it, a nil read keeps them")
    func toolDurations() async {
        let kinds: [ChatTurnEntry.Kind] = [
            brief,
            .toolCallStarted(call("a")),
            .toolCallCompleted(call("a"), result: result("A")),
        ]
        // The backend recorded the result before the Core measured the call.
        let feed = ZenSubAgentFeed(transcript: transcript(kinds))
        let model = model(feed)
        model.isSelected = true
        model.start()
        await waitUntil("the transcript is read") { model.availability == .available }
        #expect(model.items.count == 2)
        #expect(model.toolDurations.isEmpty)
        await waitUntil("the model subscribes") { feed.isSubscribed }

        let itemChanges = ZenObservationCounter { _ = model.items }
        let durationChanges = ZenObservationCounter { _ = model.toolDurations }
        // The same kinds, now with the duration.
        feed.setTranscript(ChatSubAgentTranscript(agentID: "agent-1", kinds: kinds, toolDurations: ["a": .seconds(2)]))
        feed.yield([agent(second: 1)])
        await waitUntil("the duration is applied") { model.toolDurations == ["subagent-agent-1-1": .seconds(2)] }
        await settle()
        #expect(itemChanges.count == 0)
        #expect(durationChanges.count == 1)

        // The same transcript read again assigns nothing.
        feed.yield([agent(second: 2)])
        await waitUntil("the transcript is read again") { feed.readCount == 3 }
        await settle()
        #expect(durationChanges.count == 1)

        // A read without a transcript keeps them.
        feed.setTranscript(nil)
        feed.yield([agent(status: .closed, second: 3)])
        await waitUntil("the end is read") { feed.readCount == 4 }
        await settle()
        #expect(model.toolDurations == ["subagent-agent-1-1": .seconds(2)])
        #expect(durationChanges.count == 1)
        #expect(itemChanges.count == 0)
        model.stop()
    }
}
