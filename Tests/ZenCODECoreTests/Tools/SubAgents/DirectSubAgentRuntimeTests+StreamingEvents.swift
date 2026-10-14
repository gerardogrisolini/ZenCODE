import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {

    @Test
    func thoughtDeltasRenderOnlyTheirLatestParagraphIncrementally() async throws {
        let (runtime, backend) = try await streamingScenario(
            name: "thinking-worker",
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-thinking-tests")
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        await backend.waitUntilSentPromptCount(1)

        let waitingSnapshot = try #require(await runtime.snapshots().first)
        #expect(waitingSnapshot.currentActivity == nil)
        #expect(waitingSnapshot.currentActivityKind == nil)
        #expect(
            TerminalChat.renderSubAgentOverview([waitingSnapshot])
                .contains(TerminalChat.thinkingPlaceholder)
        )

        await runtime.recordEvent(.thought("Considering the "), agentID: agentID)
        let firstSnapshot = try #require(await runtime.snapshots().first)
        let firstSignature = TerminalChat.subAgentOverviewSignature([firstSnapshot])
        #expect(firstSnapshot.currentActivity == "Considering the")
        #expect(firstSnapshot.currentActivityKind == .thinking)

        await runtime.recordEvent(.thought("available evidence"), agentID: agentID)
        let updatedSnapshot = try #require(await runtime.snapshots().first)
        #expect(updatedSnapshot.currentActivity == "Considering the available evidence")
        #expect(TerminalChat.subAgentOverviewSignature([updatedSnapshot]) != firstSignature)

        // CRLF and the blank-line boundary deliberately arrive in separate
        // chunks. The next paragraph replaces, rather than appends to, the
        // paragraph currently visible in the overview rewrite slot.
        await runtime.recordEvent(.thought("\r"), agentID: agentID)
        await runtime.recordEvent(.thought("\n\r\nNext paragraph"), agentID: agentID)
        await runtime.recordEvent(.thought(" continues"), agentID: agentID)
        let latestSnapshot = try #require(await runtime.snapshots().first)

        #expect(latestSnapshot.currentActivity == "Next paragraph continues")
        #expect(latestSnapshot.currentActivityKind == .thinking)
        let overview = TerminalChat.renderSubAgentOverview([latestSnapshot])
        let overviewRows = TerminalANSIText.stripANSI(overview)
            .components(separatedBy: "\n")
        #expect(overviewRows.contains { $0.contains(TerminalChat.thinkingPlaceholder) })
        #expect(overviewRows.contains { $0.contains("Next paragraph continues") })
        #expect(!overviewRows.contains { $0.contains("🤔 Next paragraph continues") })
        #expect(!overview.contains("Considering the available evidence"))

        await runtime.shutdown()
    }

    /// A CR that ends one delta and an LF that opens the next form a single
    /// line ending, not a paragraph boundary.
    @Test
    func thoughtParagraphSurvivesACRLFSplitAcrossDeltas() async throws {
        var buffer: String?
        #expect(
            DirectSubAgentRuntime.latestThoughtParagraph(
                appending: "first line\r",
                to: &buffer
            ) == "first line"
        )
        #expect(
            DirectSubAgentRuntime.latestThoughtParagraph(
                appending: "\nsecond line",
                to: &buffer
            ) == "first line\nsecond line"
        )

        // The same text delivered in one delta must reduce identically.
        var single: String?
        #expect(
            DirectSubAgentRuntime.latestThoughtParagraph(
                appending: "first line\r\nsecond line",
                to: &single
            ) == "first line\nsecond line"
        )

        // A lone CR followed by another CR is a real blank line and therefore a
        // paragraph boundary even when the deltas are split around it.
        var split: String?
        _ = DirectSubAgentRuntime.latestThoughtParagraph(appending: "old\r", to: &split)
        #expect(
            DirectSubAgentRuntime.latestThoughtParagraph(
                appending: "\rfresh",
                to: &split
            ) == "fresh"
        )
    }

    /// The visible paragraph is a function of the concatenated stream only, so
    /// every chunking of the same text - including a single delta that closes a
    /// paragraph, such as "A\n\n" - reaches the same state.
    @Test
    func thoughtParagraphIsInvariantAcrossEveryChunkBoundary() async throws {
        func reduce(_ chunks: [String]) -> (paragraph: String?, buffer: String?) {
            var buffer: String?
            var paragraph: String?
            for chunk in chunks {
                paragraph = DirectSubAgentRuntime.latestThoughtParagraph(
                    appending: chunk,
                    to: &buffer
                )
            }
            return (paragraph, buffer)
        }

        for text in [
            "A\n\n",
            "A\n\nB",
            "first\r\n\r\nsecond\r\nthird",
            "alpha\n \t \nbeta",
            "trailing\r"
        ] {
            let reference = reduce([text])
            let characters = Array(text)
            for splitIndex in 0...characters.count {
                let chunks = [
                    String(characters[..<splitIndex]),
                    String(characters[splitIndex...])
                ]
                let split = reduce(chunks)
                #expect(
                    split.paragraph == reference.paragraph,
                    "paragraph differs for \(text.debugDescription) at \(splitIndex)"
                )
                #expect(
                    split.buffer == reference.buffer,
                    "buffer differs for \(text.debugDescription) at \(splitIndex)"
                )
            }
        }

        // A single delta that closes the paragraph leaves nothing in progress,
        // so the overview falls back to the placeholder instead of keeping a
        // paragraph the model already finished.
        #expect(reduce(["A\n\n"]).paragraph == nil)
        #expect(reduce(["A", "\n\n"]).paragraph == nil)
    }

    /// Reasoning is model-authored text printed straight into the terminal, so
    /// CSI, OSC and BEL payloads must not survive into a rendered row.
    @Test
    func thoughtParagraphIsNeutralizedAgainstTerminalControls() async throws {
        let (runtime, backend) = try await streamingScenario(
            name: "control-worker",
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-control-tests")
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        await backend.waitUntilSentPromptCount(1)

        await runtime.recordEvent(
            .thought("before\u{1B}[2J\u{1B}]0;title\u{7}\u{7}after"),
            agentID: agentID
        )
        let snapshot = try #require(await runtime.snapshots().first)
        let rendered = TerminalChat.renderSubAgentOverview([snapshot])
        let activityRow = try #require(
            TerminalANSIText.stripANSI(rendered)
                .components(separatedBy: "\n")
                .first { $0.contains("before") }
        )

        #expect(!rendered.contains("\u{7}"))
        #expect(!rendered.contains("\u{1B}[2J"))
        #expect(!rendered.contains("\u{1B}]0;"))
        // Whatever survives is inert text: the escape introducers are gone, so
        // the payload cannot move the cursor or clear the rows the section owns.
        #expect(
            !activityRow.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
        )
        #expect(activityRow.contains("before"))
        #expect(activityRow.contains("after"))

        await runtime.shutdown()
    }

    /// A completed turn clears the private paragraph buffer, so reasoning from
    /// the next turn cannot be appended to the paragraph of the previous one.
    @Test
    func completionClearsThePendingThoughtParagraphBuffer() async throws {
        let (runtime, backend) = try await streamingScenario(
            name: "completion-worker",
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-completion-tests")
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        await backend.waitUntilSentPromptCount(1)

        await runtime.recordEvent(.thought("stale paragraph"), agentID: agentID)
        await runtime.recordCompletion(
            DirectAgentResponse(
                text: "Done.",
                stopReason: "stop",
                modelID: "test-model"
            ),
            agentID: agentID
        )
        let completedSnapshot = try #require(await runtime.snapshots().first)
        #expect(completedSnapshot.currentActivity == nil)
        #expect(completedSnapshot.currentActivityKind == nil)

        await runtime.recordEvent(.thought(" fresh paragraph"), agentID: agentID)
        let resumedSnapshot = try #require(await runtime.snapshots().first)
        #expect(resumedSnapshot.currentActivity == "fresh paragraph")
        #expect(resumedSnapshot.currentActivityKind == .thinking)

        await runtime.shutdown()
    }

    /// Generation metrics accumulate within a turn and start over on the next
    /// one, matching the status bar's semantics for the root session.
    @Test
    func generationMetricsMergeWithinTurnAndResetOnTheNextTurn() async throws {
        let (runtime, backend) = try await streamingScenario(
            name: "metrics-worker",
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-metrics-tests")
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        await backend.waitUntilSentPromptCount(1)

        let idleSnapshot = try #require(await runtime.snapshots().first)
        #expect(idleSnapshot.latestMetrics == nil)
        let idleSignature = TerminalChat.subAgentOverviewSignature([idleSnapshot])

        // Prefill arrives first.
        await runtime.recordEvent(
            .metrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: 1_200,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: nil,
                )
            ),
            agentID: agentID
        )
        // Generation follows and must not erase the prefill counters.
        await runtime.recordEvent(
            .metrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: nil,
                    completionTokenCount: 42,
                )
            ),
            agentID: agentID
        )

        let mergedSnapshot = try #require(await runtime.snapshots().first)
        let merged = try #require(mergedSnapshot.latestMetrics)
        #expect(merged.cachedPromptTokenCount == 800)
        #expect(merged.promptTokenCount == 1_200)
        #expect(merged.completionTokenCount == 42)
        let mergedSignature = TerminalChat.subAgentOverviewSignature([mergedSnapshot])
        #expect(mergedSignature != idleSignature)

        // A second turn starts. The previous counters stay visible until the
        // new turn reports its own.
        try await runtime.queuePrompt("Second turn", for: agentID)
        _ = await runtime.startNextTurnForTesting(agentID: agentID)
        let startedSnapshot = try #require(await runtime.snapshots().first)
        #expect(startedSnapshot.latestMetrics?.completionTokenCount == 42)

        await runtime.recordEvent(
            .metrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: nil,
                    completionTokenCount: 7,
                )
            ),
            agentID: agentID
        )
        let secondTurnSnapshot = try #require(await runtime.snapshots().first)
        let secondTurn = try #require(secondTurnSnapshot.latestMetrics)
        #expect(secondTurn.completionTokenCount == 7)
        // Nothing is inherited across the turn boundary.
        #expect(secondTurn.promptTokenCount == nil)
        #expect(secondTurn.cachedPromptTokenCount == nil)

        await runtime.shutdown()
    }

    /// Assistant content that literally starts with the thinking marker is
    /// still a message: the typed kind, not the text, selects the affordance.
    @Test
    func contentStartingWithTheThinkingMarkerIsRenderedAsAMessage() async throws {
        let (runtime, backend) = try await streamingScenario(
            name: "marker-worker",
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-marker-tests")
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        await backend.waitUntilSentPromptCount(1)

        await runtime.recordEvent(.content("🤔 thinking\u{2026} about the API"), agentID: agentID)
        await runtime.recordEvent(
            .toolCallStarted(
                presentedToolCall(
                    id: "grep-call",
                    name: "search.grep",
                    argumentsObject: ["pattern": "needle"],
                    argumentsJSON: #"{"pattern":"needle"}"#
                )
            ),
            agentID: agentID
        )
        let snapshot = try #require(await runtime.snapshots().first)
        #expect(snapshot.currentActivityKind == .content)
        let rendered = TerminalChat.renderSubAgentOverview([snapshot])

        #expect(rendered.contains("💬 🤔 thinking\u{2026} about the API"))

        await runtime.shutdown()
    }

    @Test
    func contentDeltasPublishOnceAtTheToolBoundaryUsingCompactTarget() async throws {
        let (runtime, backend) = try await streamingScenario(
            name: "tool-worker",
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-content-tests")
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        await backend.waitUntilSentPromptCount(1)

        await runtime.recordEvent(.thought("private reasoning"), agentID: agentID)
        let thinkingSnapshot = try #require(await runtime.snapshots().first)
        let thinkingSignature = TerminalChat.subAgentOverviewSignature([thinkingSnapshot])

        await runtime.recordEvent(.content("I’ll inspect "), agentID: agentID)
        await runtime.recordEvent(.content("the matching files."), agentID: agentID)
        let streamingSnapshot = try #require(await runtime.snapshots().first)
        #expect(streamingSnapshot.currentActivity == "private reasoning")
        #expect(streamingSnapshot.currentActivityKind == .thinking)
        #expect(
            TerminalChat.subAgentOverviewSignature([streamingSnapshot])
                == thinkingSignature
        )

        let toolCall = presentedToolCall(
            id: "grep-call",
            name: "search.grep",
            argumentsObject: ["pattern": "needle"],
            argumentsJSON: #"{"pattern":"needle"}"#
        )
        await runtime.recordEvent(.toolCallStarted(toolCall), agentID: agentID)
        let startedSnapshot = try #require(await runtime.snapshots().first)
        let startedSignature = TerminalChat.subAgentOverviewSignature([startedSnapshot])

        #expect(startedSnapshot.currentActivity == "I’ll inspect the matching files.")
        #expect(startedSnapshot.currentActivityKind == .content)
        #expect(startedSnapshot.currentActivityRevision == 1)
        #expect(startedSnapshot.currentToolName == "search.grep")
        #expect(startedSnapshot.currentToolTarget == "needle")
        #expect(startedSignature != thinkingSignature)
        let mirroredBlocks = TerminalChat.subAgentPartialResponses([startedSnapshot])
        #expect(mirroredBlocks.count == 1)
        #expect(mirroredBlocks.first?.markdown == "I’ll inspect the matching files.")
        #expect(mirroredBlocks.first?.heading == "💬 tool-worker:")

        await runtime.recordEvent(
            .toolCallCompleted(
                toolCall,
                DirectAgentToolResult(output: "match", summary: "1 match")
            ),
            agentID: agentID
        )
        let completedSnapshot = try #require(await runtime.snapshots().first)
        #expect(
            TerminalChat.subAgentOverviewSignature([completedSnapshot])
                == startedSignature
        )

        await runtime.recordEvent(.thought("more private reasoning"), agentID: agentID)
        await runtime.recordEvent(.content("Final "), agentID: agentID)
        await runtime.recordEvent(.content("answer."), agentID: agentID)
        await runtime.recordCompletion(
            DirectAgentResponse(
                text: "I’ll inspect the matching files. Final answer.",
                stopReason: "stop",
                modelID: "test-model"
            ),
            agentID: agentID
        )
        let finalSnapshot = try #require(await runtime.snapshots().first)
        #expect(finalSnapshot.latestContentPreview == "Final answer.")
        #expect(finalSnapshot.latestOutput == "I’ll inspect the matching files. Final answer.")
        #expect(finalSnapshot.latestOutputRevision == 1)
        #expect(finalSnapshot.currentActivity == nil)
        #expect(finalSnapshot.currentActivityKind == nil)
        #expect(finalSnapshot.currentToolName == nil)

        await runtime.shutdown()
    }

    @Test
    func delegatedToolLifecycleForwardsLosslessEventsOnly() async throws {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        let recorder = DirectSubAgentToolEventRecorder()
        await runtime.updateSubAgentToolEventHandler { event in
            await recorder.record(event)
        }

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("tool-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Inspect the implementation")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tool-events"),
            parentAllowedToolNames: nil
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        await backend.waitUntilSentPromptCount(1)
        #expect(await backend.hasSubAgentToolEventHandler())

        await runtime.recordEvent(.thought("private reasoning"), agentID: agentID)
        let toolCall = presentedToolCall(
            id: "edit-call",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Example.swift",
                "old": "old",
                "new": "new"
            ],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated")
        await runtime.recordEvent(.toolCallStarted(toolCall), agentID: agentID)
        await runtime.recordEvent(
            .toolCallCompleted(toolCall, result),
            agentID: agentID
        )

        let events = await recorder.snapshot()
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.agentID == agentID })
        #expect(events.allSatisfy { $0.agentName == "tool-worker" })
        #expect(events.allSatisfy { $0.toolCall.id == toolCall.id })
        if events.count == 2 {
            if case .started = events[0].lifecycle {
                // Expected lifecycle.
            } else {
                Issue.record("First delegated tool event was not started")
            }
            if case let .completed(completedResult) = events[1].lifecycle {
                #expect(completedResult.summary == result.summary)
                #expect(completedResult.output == result.output)
            } else {
                Issue.record("Second delegated tool event was not completed")
            }
        }

        await runtime.shutdown()
    }
}

private actor DirectSubAgentToolEventRecorder {
    private var events: [DirectSubAgentToolEvent] = []

    func record(_ event: DirectSubAgentToolEvent) {
        events.append(event)
    }

    func snapshot() -> [DirectSubAgentToolEvent] {
        events
    }
}

/// Leaves the first prompt blocked so each streaming test controls its events.
/// The caller waits for prompt entry and owns the existing shutdown boundary.
private func streamingScenario(
    name: String,
    workingDirectory: URL
) async throws -> (DirectSubAgentRuntime, CapturingSubAgentRuntimeBackend) {
    let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
    let runtime = makeDirectSubAgentRuntime(backend: backend)
    _ = try await runtime.createAgents(
        arguments: [
            "name": .string(name),
            "profile": .string("Developer"),
            "prompt": .string("Investigate the issue")
        ],
        workingDirectory: workingDirectory,
        parentAllowedToolNames: nil
    )
    return (runtime, backend)
}

private extension DirectSubAgentRuntime {
    /// Starts the next queued turn on the actor itself, so the non-Sendable
    /// `AgentWork` never crosses an isolation boundary.
    func startNextTurnForTesting(agentID: String) {
        _ = nextWork(for: agentID)
    }
}
