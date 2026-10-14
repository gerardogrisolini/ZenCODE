import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func terminalOnlySubAgentOverviewDoesNotEnterMirrorQueue() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let recorder = OverviewMirrorRecorder()
        await renderer.setOverviewMirroringHandler { notification, _ in
            if case .taskGraph = notification {
                await recorder.record(.taskGraph)
            }
        }

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:terminal-only",
            text: "Agents updated.\n",
        )
        await renderer.waitForOverviewMirrorsToDrain()

        #expect(await recorder.recordedKinds().isEmpty)
    }

    @Test
    func completedSubAgentResponsesMirrorOncePerTokenAndInSnapshotOrder() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        let recorder = ResponseMirrorRecorder()
        await renderer.setOverviewMirroringHandler { notification, _ in
            if case let .subAgentResponse(response) = notification {
                await recorder.record(response)
            }
        }
        let first = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "worker\u{1F}1",
            heading: "   ✅ Response from first:\n",
            markdown: "Same answer"
        )
        let second = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "reviewer\u{1F}1",
            heading: "   ✅ Response from second:\n",
            markdown: "Second answer"
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:one",
            text: "thinking: hidden\ntool: hidden\nmetadata: hidden\n",
            responses: [first, second],
        )
        // A status/closure refresh with the same completion revisions must not
        // publish either response again.
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:refresh",
            text: "different overview only",
            responses: [first, second],
        )
        // A new revision remains a new response even when its Markdown is the
        // same as an earlier completion.
        let revisedFirst = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "worker\u{1F}2",
            heading: first.heading,
            markdown: first.markdown
        )
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:revision-two",
            text: "overview only",
            responses: [revisedFirst],
        )
        await renderer.waitForOverviewMirrorsToDrain()

        #expect(await recorder.tokens() == ["worker\u{1F}1", "reviewer\u{1F}1", "worker\u{1F}2"])
    }

    @Test
    func completedSubAgentResponseUsesMarkdownAndRendersOnlyOnce() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let response = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "agent-1:completion-1",
            heading: "   ✅ Response from reviewer:\n",
            markdown: "**Finished** with `code`.\n\n- first\n- second"
        )

        let first = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:completed",
            text: "Agents completed.\n",
            responses: [response],
        )
        let duplicate = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:completed",
            text: "Agents completed.\n",
            responses: [response],
        )
        let refreshed = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:refreshed",
            text: "Agents refreshed.\n",
            responses: [response],
        )

        let events = await renderer.capturedWriteEvents()
        let stdout = events.renderedText(on: .standardOutput)
        let stderr = events.renderedText(on: .standardError)
        let snapshot = await renderer.snapshot()

        #expect(first == .rendered)
        #expect(duplicate == .unchanged)
        #expect(refreshed == .rendered)
        #expect(stdout.isEmpty)
        #expect(stderr.components(separatedBy: "Finished").count - 1 == 1)
        #expect(stderr.contains("\u{1B}[1mFinished\u{1B}[0m"))
        #expect(stderr.contains("\(TerminalMarkdownPalette.detected.inlineCodeForeground)code\u{1B}[0m"))
        #expect(!stderr.contains("**Finished**"))
        #expect(stderr.components(separatedBy: "Response from reviewer").count - 1 == 1)
        #expect(stderr.contains("Agents refreshed."))
        #expect(snapshot.lastRenderedSubAgentOverviewSignature == "agents:refreshed")
    }

    @Test
    func completedSubAgentResponseImmediatelyFollowsMetadataAndIsIndented() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        let response = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "agent-1:completion-1",
            heading: "   ✅ Response from reviewer:\n",
            markdown: "First paragraph.\n\n- first\n- second\nA follow-up line."
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:completed",
            text: "Agents completed.\n",
            responses: [response],
        )

        let stderr = await renderer.capturedText(on: .standardError)

        #expect(
            stderr == "Agents completed.\n   ✅ Response from reviewer:\n   First paragraph.\n   \n   - first\n   - second\n   A follow-up line.\n\n"
        )
    }

    @Test
    func deferredSubAgentResponseIsConsumedOnlyAfterItRenders() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        let response = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "agent-2:completion-1",
            heading: "   ✅ Response from planner:\n",
            markdown: "Deferred answer"
        )
        await renderer.setOverviewPublishingSuspended(true)

        let deferred = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:deferred",
            text: "Agents deferred.\n",
            responses: [response],
        )
        #expect(deferred == .deferred)
        #expect(await renderer.capturedWriteEvents().isEmpty)

        await renderer.setOverviewPublishingSuspended(false)
        let refreshed = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:after-deferred",
            text: "Agents refreshed.\n",
            responses: [response],
        )
        let combined = await renderer.capturedText()

        #expect(refreshed == .rendered)
        #expect(combined.components(separatedBy: "Deferred answer").count - 1 == 1)
        #expect(combined.components(separatedBy: "Response from planner").count - 1 == 1)
        #expect(combined.contains("Agents refreshed."))
    }

    @Test
    func transcriptTailGateResetsForSyntheticTurnWithoutSubmittedPrompt() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)

        await renderer.beginAssistantTranscriptTail()
        let withheld = await renderer.renderTaskGraphOverview(
            signature: "tasks:between-hidden-turns",
            markdown: "## Task graph\n\n- withheld below prior tail\n"
        )
        #expect(withheld == .rendered)
        #expect(await renderer.capturedWriteEvents().isEmpty)

        // Hidden shared-chat/planner turns have no submitted-prompt write, but
        // their generation entry points reopen the same coordinator gate.
        await renderer.beginTranscriptTurn()
        let resumed = await renderer.renderTaskGraphOverview(
            signature: "tasks:hidden-turn-current",
            markdown: "## Task graph\n\n- current hidden-turn state\n"
        )

        #expect(resumed == .rendered)
        let transcript = await renderer.capturedPlainText()
        #expect(!transcript.contains("withheld below prior tail"))
        #expect(transcript.contains("current hidden-turn state"))
    }

    /// Characterizes the mirroring epoch seam: the queue lives as stored
    /// coordinator state while `advanceMirrorEpoch` mutates it from
    /// +Overviews. Each advanced epoch must stamp subsequent notifications so
    /// a turn boundary fences stale deliveries.
    @Test
    func mirrorEpochStampsNotificationsAtEachTurnBoundary() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let epochs = EpochRecorder()
        await renderer.setOverviewMirroringHandler { _, epoch in
            await epochs.append(epoch)
        }

        _ = await renderer.renderTaskGraphOverview(
            signature: "tasks:1",
            markdown: "# Tasks v1\n",
            force: true,
            rememberSignature: true
        )
        let firstEpoch = await renderer.advanceMirrorEpoch()
        #expect(firstEpoch == 1)
        _ = await renderer.renderTaskGraphOverview(
            signature: "tasks:2",
            markdown: "# Tasks v2\n",
            force: true,
            rememberSignature: true
        )
        await renderer.waitForOverviewMirrorsToDrain()

        let recorded = await epochs.values()
        #expect(recorded == [0, 1])
    }

    /// Characterizes the terminal transcript-tail contract across streaming and
    /// overview arbitration: deferred and late automatic snapshots keep their
    /// remote projection, but cannot land below either a final response or a
    /// model question. The next submitted turn reopens live terminal progress.
    @Test(arguments: [
        "The implementation is complete.",
        "Which deployment target should I use?"
    ])
    func automaticOverviewDoesNotFollowFinalAssistantTranscriptTail(
        assistantTail: String
    ) async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            standardOutputIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let mirrorRecorder = OverviewMirrorRecorder()
        await renderer.setOverviewMirroringHandler { notification, _ in
            if case .taskGraph = notification {
                await mirrorRecorder.record(.taskGraph)
            }
        }

        // No trailing-edge timer is armed (streamingFlushDelay is nil in this
        // renderer), so assistant bytes remain pending until the final flush.
        await renderer.writeAssistantContent(assistantTail)
        let bufferedEventCount = await renderer.capturedWriteEvents().count
        #expect(bufferedEventCount == 0)

        let deferred = await renderer.renderTaskGraphOverview(
            signature: "tasks:during-stream",
            markdown: "## Task graph\n\n- deferred state\n"
        )
        #expect(deferred == .deferred)

        await renderer.beginAssistantTranscriptTail()
        await renderer.finishStreamingOutput()

        let lateSubAgent = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:late-close",
            text: "\n👥 Sub-Agents:\n   1 total\n   completed\n",
            responses: [
                .init(
                    token: "late-close-response",
                    heading: "   💬 Late worker\n",
                    markdown: "Useful delegated result."
                )
            ],
            overviewBatchID: "late-close"
        )
        #expect(lateSubAgent == .rendered)
        await renderer.waitForOverviewMirrorsToDrain()

        let sealedTranscript = await renderer.capturedPlainText()
        #expect(sealedTranscript.contains(assistantTail))
        #expect(!sealedTranscript.contains("Task graph"))
        #expect(!sealedTranscript.contains("Sub-Agents"))
        #expect(!sealedTranscript.contains("Useful delegated result."))
        #expect(await mirrorRecorder.recordedKinds() == [.taskGraph])

        // An operator-requested inspection deliberately bypasses the automatic
        // tail fence and can recover the current late-close content.
        _ = await renderer.renderSubAgentOverview(
            signature: "agents:late-close",
            text: "\n👥 Sub-Agents:\n   1 total\n   completed\n",
            responses: [
                .init(
                    token: "late-close-response",
                    heading: "   💬 Late worker\n",
                    markdown: "Useful delegated result."
                )
            ],
            force: true,
            rememberSignature: false,
            origin: .explicit,
            overviewBatchID: "late-close"
        )
        let explicitTranscript = await renderer.capturedPlainText()
        #expect(explicitTranscript.contains("Useful delegated result."))

        // A new visible prompt resets only the terminal presentation fence;
        // a fresh automatic task snapshot is renderable again.
        await renderer.writeSubmittedPrompt("next turn")
        let nextTurn = await renderer.renderTaskGraphOverview(
            signature: "tasks:next-turn",
            markdown: "## Task graph\n\n- fresh state\n"
        )
        #expect(nextTurn == .rendered)
        let nextTurnTranscript = await renderer.capturedPlainText()
        #expect(nextTurnTranscript.contains("fresh state"))
    }
}

private actor OverviewMirrorRecorder {
    private var kinds: [TerminalChatRenderCoordinator.OverviewKind] = []

    func record(_ kind: TerminalChatRenderCoordinator.OverviewKind) {
        kinds.append(kind)
    }

    func recordedKinds() -> [TerminalChatRenderCoordinator.OverviewKind] {
        kinds
    }
}

private actor ResponseMirrorRecorder {
    private var responses: [TerminalChatRenderCoordinator.SubAgentMarkdownResponse] = []

    func record(_ response: TerminalChatRenderCoordinator.SubAgentMarkdownResponse) {
        responses.append(response)
    }

    func tokens() -> [String] {
        responses.map(\.token)
    }
}

/// Records the epoch carried by each delivered mirror notification, so tests
/// can characterize the turn-boundary fencing contract of the mirror queue.
private actor EpochRecorder {
    private var recorded: [Int] = []

    func append(_ epoch: Int) {
        recorded.append(epoch)
    }

    func values() -> [Int] {
        recorded
    }
}
