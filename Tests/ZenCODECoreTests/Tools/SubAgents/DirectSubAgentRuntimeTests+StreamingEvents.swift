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

    /// The live detail shows the whole reasoning of a phase: every paragraph
    /// accumulates in `currentThought`, while `currentActivity` keeps only the
    /// paragraph in progress for the overview. The reasoning stays while the
    /// message that follows streams, reasoning after that message starts a new
    /// phase, and a tool call clears it: the transcript has it from then on.
    @Test
    func thoughtDeltasAccumulateTheWholeReasoningOfThePhase() async throws {
        let (runtime, backend) = try await streamingScenario(
            name: "accumulating-worker",
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-accumulated-thinking-tests")
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        await backend.waitUntilSentPromptCount(1)
        #expect(try #require(await runtime.snapshots().first).currentThought == nil)

        // CRLF and the blank-line boundary arrive in separate chunks.
        await runtime.recordEvent(.thought("First paragraph"), agentID: agentID)
        await runtime.recordEvent(.thought("\r"), agentID: agentID)
        await runtime.recordEvent(.thought("\n\r\nSecond"), agentID: agentID)
        await runtime.recordEvent(.thought(" paragraph\n\n"), agentID: agentID)
        let ended = try #require(await runtime.snapshots().first)
        // The paragraph just ended: the overview has none, the detail keeps both.
        #expect(ended.currentActivity == nil)
        #expect(ended.currentActivityKind == .thinking)
        #expect(ended.currentThought == "First paragraph\n\nSecond paragraph")

        await runtime.recordEvent(.thought("Third"), agentID: agentID)
        let growing = try #require(await runtime.snapshots().first)
        #expect(growing.currentActivity == "Third")
        #expect(growing.currentThought == "First paragraph\n\nSecond paragraph\n\nThird")

        await runtime.recordEvent(.content("The answer"), agentID: agentID)
        let writing = try #require(await runtime.snapshots().first)
        #expect(writing.currentActivityKind == .thinking)
        #expect(writing.currentThought == growing.currentThought)

        await runtime.recordEvent(.thought("Rethinking"), agentID: agentID)
        let rethinking = try #require(await runtime.snapshots().first)
        #expect(rethinking.currentThought == "Rethinking")

        await runtime.recordEvent(
            .toolCallStarted(presentedToolCall(
                id: "read-call",
                name: "local.readFile",
                argumentsObject: ["path": "/tmp/Example.swift"],
                argumentsJSON: #"{"path":"/tmp/Example.swift"}"#
            )),
            agentID: agentID
        )
        let running = try #require(await runtime.snapshots().first)
        #expect(running.currentThought == nil)

        await runtime.recordEvent(.thought("After the call"), agentID: agentID)
        #expect(try #require(await runtime.snapshots().first).currentThought == "After the call")

        await runtime.shutdown()
    }

    /// The accumulated reasoning is a function of the concatenated stream
    /// only: every split of the same text, a CRLF split between two deltas
    /// included, reaches the same text and the same buffer.
    @Test
    func accumulatedThoughtIsInvariantAcrossEveryChunkBoundary() {
        func reduce(_ chunks: [String]) -> (thought: String?, buffer: String?) {
            var buffer: String?
            var thought: String?
            for chunk in chunks {
                thought = DirectSubAgentRuntime.accumulatedThought(
                    appending: chunk,
                    to: &buffer
                )
            }
            return (thought, buffer)
        }

        for text in [
            "A\n\n",
            "A\n\nB",
            "first\r\n\r\nsecond\r\nthird",
            "alpha\r\rbeta",
            "\r\n  leading and trailing \n\n",
            "trailing\r"
        ] {
            let reference = reduce([text])
            // Unicode scalars, so a split can fall between the CR and the LF.
            let scalars = Array(text.unicodeScalars)
            for splitIndex in 0...scalars.count {
                let chunks = [
                    String(String.UnicodeScalarView(scalars[..<splitIndex])),
                    String(String.UnicodeScalarView(scalars[splitIndex...]))
                ]
                let split = reduce(chunks)
                #expect(
                    split.thought == reference.thought,
                    "thought differs for \(text.debugDescription) at \(splitIndex)"
                )
                #expect(
                    split.buffer == reference.buffer,
                    "buffer differs for \(text.debugDescription) at \(splitIndex)"
                )
            }
        }

        #expect(reduce(["first\r\n\r\nsecond\r\nthird"]).thought == "first\n\nsecond\nthird")
        #expect(reduce(["alpha\r\rbeta"]).thought == "alpha\n\nbeta")
        #expect(reduce(["\r\n  leading and trailing \n\n"]).thought == "leading and trailing")
        // A trailing CR waits for its LF: the text is complete, the CR kept.
        #expect(reduce(["trailing\r"]).thought == "trailing")
        #expect(reduce(["trailing\r"]).buffer == "trailing\r")
        #expect(reduce(["trailing\r", "\nnext"]).thought == "trailing\nnext")
        #expect(reduce([" \n", "\t"]).thought == nil)
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
