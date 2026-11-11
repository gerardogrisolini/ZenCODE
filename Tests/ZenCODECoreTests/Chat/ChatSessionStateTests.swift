//
//  ChatSessionStateTests.swift
//  ZenCODE
//
//  The observable session state: `ChatSessionStateReducer` turns what the
//  controller presents into one ordered log per session, with its
//  projections, and `ChatPendingRequestHost` publishes the operator
//  interactions in the same snapshot. Every test runs in directories named
//  by UUIDs; nothing touches the real application state.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Chat session state", .serialized, .timeLimit(.minutes(2)))
struct ChatSessionStateTests {
    private typealias Fixtures = ChatTestFixtures

    // MARK: - Sequence

    @Test
    func sequencesStrictlyIncreaseAcrossTurnsNoticesAndSessions() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let reducer = ChatSessionStateReducer(controller: controller, defaultOrigin: .local)
            controller.addObserver(reducer)
            try await harness.startSession()

            await harness.runtime.append(Self.inspectionTurn)
            _ = try await controller.runTurn(Self.request("Inspect the project", for: controller))
            await reducer.presentSessionNotice(.modelUnchanged)
            let firstEpoch = reducer.snapshot
            #expect(firstEpoch.epoch == 0)
            #expect(firstEpoch.firstRetainedSequence == 1)
            #expect(firstEpoch.log.first?.sequence == 1)
            Self.expectStrictlyIncreasing(firstEpoch.log)
            // Consecutive: nothing was dropped.
            #expect(firstEpoch.log.map(\.sequence) == Array(1...firstEpoch.log.count))

            // A new session replaces the log; sequences go on, never reused.
            _ = try await controller.startNewSession(newSessionID: "observed-session-2")
            let afterReset = reducer.snapshot
            let lastSequence = try #require(firstEpoch.log.last?.sequence)
            #expect(afterReset.sessionID == "observed-session-2")
            #expect(afterReset.epoch == 1)
            #expect(afterReset.firstRetainedSequence == lastSequence + 1)
            #expect(afterReset.transcript.isEmpty)
            #expect(afterReset.activity.isEmpty)
            #expect(afterReset.turn.turnID == nil)
            #expect(afterReset.log.allSatisfy { $0.sequence > lastSequence })

            await harness.runtime.append { call in
                await call.onEvent(.content("Second session."))
                return DirectAgentResponse(text: "Second session.", stopReason: "end_turn", modelID: "m")
            }
            _ = try await controller.runTurn(Self.request("Hello again", for: controller))
            let secondEpoch = reducer.snapshot
            Self.expectStrictlyIncreasing(secondEpoch.log)
            #expect(secondEpoch.log.allSatisfy { $0.sequence > lastSequence })
            // Turns keep their numbering too.
            #expect(secondEpoch.turn.turnID == 2)
        }
    }

    // MARK: - Live log and transcript

    /// The transcript keeps, of every turn, the prompt with its attachments,
    /// the closed assistant blocks, and the tool calls (ID, name, arguments)
    /// with their results (output, attachments). The comparisons below are on
    /// those entries only, with turns numbered from 1 in log order, because
    /// the transcript does not keep the prompt's origin, the tool-call
    /// presentation, nor the result's summary and status, and because a
    /// reducer numbers sequences and turns across epochs.
    @Test
    func theLiveLogOfATerminalSessionEqualsTheLogRebuiltFromItsSavedTranscript() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let reducer = ChatSessionStateReducer(controller: controller, defaultOrigin: .local)
            controller.addObserver(reducer)
            try await harness.startSession()

            try await Self.runComparisonTurns(on: controller, runtime: harness.runtime) { prompt, attachments in
                Self.request(prompt, for: controller, attachments: attachments, origin: .local)
            }
            let live = reducer.snapshot
            #expect(live.epoch == 0)
            #expect(!controller.transcript.isEmpty)
            #expect(live.turn.turnID == 3)
            let expected = Self.representable(live.log)
            #expect(expected.count == 15)

            // The one transcript rebuild, into a reducer of its own.
            let rebuilt = await Self.reducerRestoring(controller.transcript)
            #expect(Self.representable(rebuilt.snapshot.log) == expected)

            // The saved session, loaded back: the controller rebuilds the log
            // once and hands it to the reducer after the session change.
            _ = await controller.saveSession(named: "observed", contextWindow: nil)
            #expect(reducer.snapshot.summary.title == "observed")
            let saved = try Self.stored("observed", in: harness)
            _ = try await controller.loadSavedSession(saved)
            let restored = reducer.snapshot
            #expect(restored.epoch == 1)
            #expect(restored.sessionID == saved.sessionID)
            #expect(Self.representable(restored.log) == expected)
            #expect(restored.log.first.map { $0.sequence > (live.log.last?.sequence ?? 0) } == true)
            // Restored prompts have no known origin; the loaded notice follows them.
            #expect(restored.log.contains { entry in
                if case .userPrompt(_, _, .unknown) = entry.kind { return true }
                return false
            })
            #expect(restored.log.last?.kind == .notice(
                .sessionLoaded(name: "observed", messageCount: saved.messageCount)
            ))
            #expect(restored.log.last?.turnID == nil)
            Self.expectCoherentProjections(restored)
        }
    }

    /// ACP keeps no transcript (`retainsTranscript: false`) and binds a
    /// presenter to each prompt. The comparison rebuilds the log from the
    /// runtime's transcript instead, the session history the runtime reports
    /// with `.sessionSnapshot`: the scripted runtime reports it in the
    /// runner's shape, one assistant message per model step carrying its
    /// reasoning, its content, and its tool calls.
    @Test
    func theLiveLogOfAnACPSessionEqualsTheLogRebuiltFromTheRuntimeTranscript() async throws {
        try await withChatHarness(retainsTranscript: false) { harness in
            let controller = harness.controller
            let reducer = ChatSessionStateReducer(controller: controller, defaultOrigin: .acp)
            controller.addObserver(reducer)
            try await harness.startSession()
            let sessionID = controller.sessionID
            let workspace = controller.workingDirectory.path
            let prompter = RecordingChatPresenter(name: "acp-prompt")

            await harness.runtime.append { call in
                let read = Self.toolCall(id: "acp-read", name: "local.readFile")
                await call.onEvent(.thought("Looking first."))
                await call.onEvent(.content("Let me read it."))
                await call.onEvent(.toolCallStarted(read))
                await call.onEvent(.toolCallCompleted(read, DirectAgentToolResult(output: "file body", summary: "read")))
                await call.onEvent(.content("It is fine."))
                await call.onEvent(.sessionSnapshot(AgentRuntimeSessionSnapshot(
                    sessionID: sessionID,
                    workingDirectoryPath: workspace,
                    systemPrompt: nil,
                    cacheKey: nil,
                    history: [
                        AgentRuntimeMessage(role: .user, content: "Check the file"),
                        AgentRuntimeMessage(
                            role: .assistant,
                            content: "Let me read it.",
                            reasoningContent: "Looking first.",
                            toolCalls: [ChatTranscriptTurn.runtimeToolCall(from: read)]
                        ),
                        AgentRuntimeMessage(
                            role: .tool,
                            content: "file body",
                            toolCallID: read.id,
                            toolName: read.name
                        ),
                        AgentRuntimeMessage(role: .assistant, content: "It is fine."),
                    ],
                    allowedToolNames: nil,
                    thinkingSelection: nil,
                    preserveThinking: false
                )))
                await call.onEvent(.turnEnded(.completed))
                return DirectAgentResponse(text: "Let me read it.It is fine.", stopReason: "end_turn", modelID: "m")
            }
            _ = try await controller.runTurn(Self.request("Check the file", for: controller, presenter: prompter))

            // The prompt's own presenter saw the turn; the reducer saw it too,
            // through the fan-out; the controller kept no transcript.
            #expect(await prompter.events.contains(.content("It is fine.")))
            #expect(await harness.presenter.events.isEmpty)
            #expect(controller.transcript.isEmpty)
            let live = reducer.snapshot
            #expect(live.log.first?.kind == .userPrompt(text: "Check the file", attachments: [], origin: .acp))
            #expect(live.summary.activeChannel == .acp)

            let rebuilt = await Self.reducerRestoring(controller.history)
            #expect(Self.representable(rebuilt.snapshot.log) == Self.representable(live.log))
            #expect(Self.representable(live.log).count == 6)
        }
    }

    /// A restored session whose tool calls have no ID (a history an editor
    /// sends, a model that names none): each result without an ID completes
    /// the oldest call without an ID still open in its turn, with its tool
    /// name when it has one, and a result whose call is in an earlier turn
    /// completes that call by its ID. The activity of the restored log then
    /// has one start and one completion per call, the completion after the
    /// start, and no call left running.
    @Test
    @ChatSessionActor
    func aRestoredSessionClosesTheToolCallsWithoutAnID() async throws {
        let transcript: [AgentRuntimeMessage] = [
            AgentRuntimeMessage(role: .user, content: "Look around"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "Looking.",
                toolCalls: [
                    AgentRuntimeToolCall(id: nil, name: "local.ls", argumentsJSON: "{}"),
                    AgentRuntimeToolCall(id: nil, name: "local.readFile", argumentsJSON: #"{"path":"a"}"#),
                    AgentRuntimeToolCall(id: "late", name: "local.exec", argumentsJSON: #"{"command":"make"}"#),
                ]
            ),
            // By name first, then in order.
            AgentRuntimeMessage(role: .tool, content: "body of a", toolName: "local.readFile"),
            AgentRuntimeMessage(role: .tool, content: "a\nb"),
            AgentRuntimeMessage(role: .user, content: "Go on"),
            AgentRuntimeMessage(role: .tool, content: "built", toolCallID: "late", toolName: "local.exec"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "",
                toolCalls: [AgentRuntimeToolCall(id: nil, name: "local.ls", argumentsJSON: "{}")]
            ),
            AgentRuntimeMessage(role: .tool, content: "c", toolName: "local.ls"),
        ]

        let reducer = await Self.reducerRestoring(transcript)
        let snapshot = reducer.snapshot

        #expect(Self.representable(snapshot.log) == [
            .init(turn: 1, entry: .prompt(text: "Look around", attachments: [])),
            .init(turn: 1, entry: .assistantText("Looking.")),
            .init(turn: 1, entry: .toolCallStarted(id: "restored-tool-1-0", name: "local.ls", argumentsJSON: "{}")),
            .init(turn: 1, entry: .toolCallStarted(
                id: "restored-tool-1-1", name: "local.readFile", argumentsJSON: #"{"path":"a"}"#
            )),
            .init(turn: 1, entry: .toolCallStarted(id: "late", name: "local.exec", argumentsJSON: #"{"command":"make"}"#)),
            .init(turn: 1, entry: .toolCallCompleted(
                id: "restored-tool-1-1", name: "local.readFile", output: "body of a", attachments: []
            )),
            .init(turn: 1, entry: .toolCallCompleted(id: "restored-tool-1-0", name: "local.ls", output: "a\nb", attachments: [])),
            .init(turn: 2, entry: .prompt(text: "Go on", attachments: [])),
            .init(turn: 2, entry: .toolCallCompleted(id: "late", name: "local.exec", output: "built", attachments: [])),
            .init(turn: 2, entry: .toolCallStarted(id: "restored-tool-6-0", name: "local.ls", argumentsJSON: "{}")),
            .init(turn: 2, entry: .toolCallCompleted(id: "restored-tool-6-0", name: "local.ls", output: "c", attachments: [])),
        ])
        Self.expectCoherentProjections(snapshot)
        // One start and one completion per call, in that order.
        var running = Set<String>()
        var completed = Set<String>()
        for entry in snapshot.activity {
            switch entry.kind {
            case let .toolCallStarted(call):
                #expect(running.insert(call.id).inserted)
            case let .toolCallCompleted(call, result):
                #expect(running.remove(call.id) != nil)
                #expect(completed.insert(call.id).inserted)
                #expect(result.status == .completed)
            default:
                Issue.record("Not an activity entry: \(entry.kind)")
            }
        }
        #expect(running.isEmpty)
        #expect(completed.count == 4)
        // The summary of a restored result is its first line.
        let summaries = snapshot.activity.compactMap { entry -> String? in
            guard case let .toolCallCompleted(_, result) = entry.kind else { return nil }
            return result.summary
        }
        #expect(summaries == ["body of a", "a", "built", "c"])
    }

    // MARK: - Projections

    @Test
    func transcriptActivityNoticesAndArtifactsAreProjectionsOfTheLog() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let reducer = ChatSessionStateReducer(controller: controller, defaultOrigin: .local)
            controller.addObserver(reducer)
            try await harness.startSession()

            try await Self.runComparisonTurns(on: controller, runtime: harness.runtime) { prompt, attachments in
                Self.request(prompt, for: controller, attachments: attachments)
            }
            await reducer.presentSessionNotice(.modelUnchanged)
            await reducer.presentWorkflowNotice(.blocked(graphID: "graph", message: "waiting"))
            await reducer.presentLiveFileArtifacts([Self.artifactTurn(number: 1, path: "a.swift")], agentID: "agent-1")
            await reducer.presentSealedFileArtifacts(Self.artifactTurn(number: 1, path: "b.swift"))

            let snapshot = reducer.snapshot
            Self.expectCoherentProjections(snapshot)
            #expect(snapshot.notices.map(\.kind) == [
                .notice(.modelUnchanged),
                .workflowNotice(.blocked(graphID: "graph", message: "waiting")),
            ])
            #expect(snapshot.fileChanges.artifactHistory.map(\.kind) == [
                .fileArtifacts(Self.artifactTurn(number: 1, path: "a.swift"), agentID: "agent-1", isSealed: false),
                .fileArtifacts(Self.artifactTurn(number: 1, path: "b.swift"), agentID: nil, isSealed: true),
            ])
            // Every completed tool call follows its start.
            var started = Set<String>()
            for entry in snapshot.activity {
                switch entry.kind {
                case let .toolCallStarted(call):
                    started.insert(call.id)
                case let .toolCallCompleted(call, _):
                    #expect(started.contains(call.id))
                default:
                    Issue.record("Unexpected activity entry \(entry.kind)")
                }
            }
        }
    }

    // MARK: - Blocks

    /// The transcript and the reducer close the same blocks for the same
    /// events: both are fed one script, and the log rebuilt from the
    /// transcript's messages equals the live one.
    @Test(arguments: BlockScript.allCases)
    @ChatSessionActor
    func theReducerClosesTheBlocksTheTranscriptCloses(_ script: BlockScript) async throws {
        let reducer = Self.reducer()
        let transcript = ChatTranscriptTurn(prompt: script.prompt, attachments: [])
        await reducer.turnWillStart(Self.request(script.prompt, purpose: script.purpose))
        for event in script.events {
            switch event {
            case let .thought(text):
                await transcript.appendThought(text)
                await reducer.presentThought(text)
            case let .content(text):
                await transcript.appendAssistantContent(text)
                await reducer.presentAssistantContent(text)
            case let .started(call):
                await transcript.appendToolCallStarted(call)
                await reducer.presentToolCallStarted(call)
            case let .completed(call, result):
                await transcript.appendToolCallCompleted(call, result: result)
                await reducer.presentToolCallCompleted(call, result: result)
            case .continueAutomatically:
                await transcript.flushAssistantMessage()
                await reducer.turnWillContinueAutomatically()
            }
        }
        let messages: [AgentRuntimeMessage]
        if let finalText = script.finalResponseText {
            if case .plan = script.purpose {
                // `finalizePlanningTurn` records the Planner response.
                await transcript.appendAssistantContent(finalText)
            }
            messages = await transcript.messages(finalResponseText: finalText)
            await reducer.presentFinalResponse(Self.response(finalText))
        } else {
            messages = await transcript.messages()
        }
        await reducer.turnWillFinish()

        let rebuilt = Self.representable(await Self.reducerRestoring(messages).snapshot.log)
        #expect(Self.representable(reducer.snapshot.log) == rebuilt)
        #expect(Self.representable(reducer.snapshot.log) == script.expected)
    }

    // MARK: - Turns

    @Test
    @ChatSessionActor
    func aTurnClosesAtItsFileChangeSummaryOrAtTheNextTurn() async throws {
        let reducer = Self.reducer()
        await reducer.turnWillStart(Self.request("One"))
        await reducer.turnWillFinish()
        await reducer.presentWorkflowNotice(.openWithoutQuestion(graphID: "g", pendingTaskCount: 1))
        await reducer.presentFileChangeSummary(TurnFileChangeSummary(entries: []))
        await reducer.presentSessionNotice(.modelUnchanged)
        #expect(reducer.snapshot.fileChanges.turnSummary == TurnFileChangeSummary(entries: []))

        // Without a summary the turn stays open until the next one starts.
        await reducer.turnWillStart(Self.request("Two", origin: .telegram))
        #expect(reducer.snapshot.fileChanges.turnSummary == nil)
        #expect(reducer.snapshot.summary.activeChannel == .telegram)
        await reducer.presentTurnEnded(.cancelled)
        await reducer.turnWillFinish()
        #expect(reducer.snapshot.turn.outcome == .cancelled)
        #expect(reducer.snapshot.summary.activeChannel == .local)
        await reducer.presentSessionNotice(.sessionStarted)
        await reducer.turnWillStart(Self.request("Three"))

        let turns = reducer.snapshot.log.map { entry in
            "\(entry.turnID.map(String.init) ?? "-"):\(Self.label(entry.kind))"
        }
        #expect(turns == [
            "1:prompt:One", "1:started", "1:finishing", "1:workflow",
            "-:notice",
            "2:prompt:Two", "2:started", "2:ended", "2:finishing", "2:notice",
            "3:prompt:Three", "3:started",
        ])
        #expect(reducer.snapshot.log[5].kind == .userPrompt(text: "Two", attachments: [], origin: .telegram))
        #expect(reducer.snapshot.summary.title == "One")
    }

    // MARK: - Overviews

    /// The snapshot follows the overviews the session observes by itself: an
    /// explicit one (`/tasks`) is shown by the channel where the command ran,
    /// and never reaches it.
    @Test
    @ChatSessionActor
    func theTaskGraphOfTheSnapshotFollowsTheAutomaticOverviewsOnly() async throws {
        let reducer = Self.reducer()
        #expect(reducer.snapshot.taskGraph == nil)

        let observed = ChatTaskGraphOverview(graph: Fixtures.taskGraph(id: "observed"), tasks: [])
        await reducer.presentTaskGraphOverview(observed, origin: .automatic, publication: nil)
        #expect(reducer.snapshot.taskGraph == observed)

        // An explicit overview, of another graph or none, leaves it as it is.
        let requested = ChatTaskGraphOverview(graph: Fixtures.taskGraph(id: "requested"), tasks: [])
        await reducer.presentTaskGraphOverview(requested, origin: .explicit, publication: nil)
        #expect(reducer.snapshot.taskGraph == observed)
        await reducer.presentTaskGraphOverview(nil, origin: .explicit, publication: nil)
        #expect(reducer.snapshot.taskGraph == observed)

        // An automatic overview without a graph clears it, and an explicit
        // one does not bring it back.
        await reducer.presentTaskGraphOverview(nil, origin: .automatic, publication: nil)
        #expect(reducer.snapshot.taskGraph == nil)
        await reducer.presentTaskGraphOverview(requested, origin: .explicit, publication: nil)
        #expect(reducer.snapshot.taskGraph == nil)
    }

    // MARK: - Pending requests

    @Test
    @ChatSessionActor
    func aPendingRequestIsPublishedUntilItIsResolvedOnce() async throws {
        let reducer = Self.reducer()
        let host = ChatPendingRequestHost(reducer: reducer, capabilities: [.singleChoice])
        let items = [ChatChoiceItem(id: "a", title: "A"), ChatChoiceItem(id: "b", title: "B")]
        let answer = Task { @ChatSessionActor in
            await host.chooseOne(title: "Pick", items: items, selectedID: "b")
        }

        let waiting = await Self.snapshot(of: reducer) { $0.pendingRequests.count == 1 }
        let request = try #require(waiting.pendingRequests.first)
        #expect(request.kind == .chooseOne(title: "Pick", items: items, selectedID: "b"))
        #expect(waiting.summary.pendingRequestCount == 1)
        #expect(host.capabilities == [.singleChoice])

        // An answer of another kind is refused and the request stays open.
        #expect(!host.resolve(request.id, answer: .text("a")))
        #expect(reducer.snapshot.pendingRequests == [request])
        #expect(host.resolve(request.id, answer: .choice("a")))
        #expect(await answer.value == "a")
        #expect(reducer.snapshot.pendingRequests.isEmpty)
        #expect(reducer.snapshot.summary.pendingRequestCount == 0)
        // It resumed once: a second answer finds nothing.
        #expect(!host.resolve(request.id, answer: .choice("b")))
    }

    @Test
    @ChatSessionActor
    func cancellingTheWaitingTaskOrTheHostRefusesTheRequests() async throws {
        let reducer = Self.reducer()
        let host = ChatPendingRequestHost(reducer: reducer, capabilities: [.textInput, .multipleChoice])

        // Cancelling the task that waits refuses its request.
        let cancelled = Task { @ChatSessionActor in await host.readLine(prompt: "Wait") }
        let waiting = await Self.snapshot(of: reducer) { $0.pendingRequests.count == 1 }
        let cancelledRequest = try #require(waiting.pendingRequests.first)
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        _ = await Self.snapshot(of: reducer) { $0.pendingRequests.isEmpty }
        #expect(!host.resolve(cancelledRequest.id, answer: .text("late")))

        // A task cancelled before it asks is refused without publishing.
        let early = Task { @ChatSessionActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await host.readLine(prompt: "Never shown")
        }
        #expect(await early.value == nil)
        #expect(reducer.snapshot.pendingRequests.isEmpty)

        // `cancelPendingRequests()` refuses every open request once.
        let first = Task { @ChatSessionActor in await host.readLine(prompt: "One") }
        let second = Task { @ChatSessionActor in await host.chooseMany(title: "Two", items: [], selectedIDs: []) }
        _ = await Self.snapshot(of: reducer) { $0.pendingRequests.count == 2 }
        host.cancelPendingRequests()
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(reducer.snapshot.pendingRequests.isEmpty)
        host.cancelPendingRequests()
    }

    @Test
    @ChatSessionActor
    func workspaceAccessIsGrantedWithoutAskingUnlessTheClientGatesIt() async throws {
        let reducer = Self.reducer()
        let host = ChatPendingRequestHost(reducer: reducer, capabilities: [])
        let request = ChatWorkspaceAccessRequest(
            workspaceURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            toolTitles: ["Files"]
        )
        #expect(await host.requestWorkspaceAccess(request))
        #expect(reducer.snapshot.pendingRequests.isEmpty)

        // Without a handler nothing can be opened; with one, it opens.
        await #expect(throws: (any Error).self) {
            try await host.openExternal(ChatOpenTarget(target: "/tmp/a", kind: .file))
        }
        let opened = OpenedTargets()
        let opener = ChatPendingRequestHost(
            reducer: reducer,
            capabilities: [.externalOpen],
            openExternal: { target in await opened.append(target) }
        )
        try await opener.openExternal(ChatOpenTarget(target: "/tmp/a", kind: .file))
        #expect(await opened.targets == [ChatOpenTarget(target: "/tmp/a", kind: .file)])
    }

    // MARK: - Bounds

    @Test
    @ChatSessionActor
    func theLogDropsItsOldestEntriesWholeAndTheProjectionsFollow() async throws {
        let budget = 4_000
        let reducer = Self.reducer(maximumLogBytes: budget)
        await reducer.turnWillStart(Self.request(String(repeating: "p", count: 300)))
        for index in 1...30 {
            await reducer.presentAssistantContent("block \(index) " + String(repeating: "x", count: 200))
            await reducer.presentToolCallStarted(Self.toolCall(id: "call-\(index)", name: "local.ls"))
            await reducer.presentSessionNotice(.operationFailed(description: "notice \(index)"))
        }

        let snapshot = reducer.snapshot
        let retained = snapshot.log.reduce(0) { $0 + $1.retainedByteCount }
        #expect(retained <= budget)
        #expect(snapshot.log.count > 1)
        // Whole entries: the log starts at the first retained sequence and
        // keeps every entry after it.
        let first = try #require(snapshot.log.first)
        #expect(first.sequence == snapshot.firstRetainedSequence)
        #expect(snapshot.firstRetainedSequence > 1)
        #expect(snapshot.log.map(\.sequence) == Array(first.sequence...(first.sequence + snapshot.log.count - 1)))
        // The prompt was dropped with the oldest entries; the projections
        // hold retained entries only.
        #expect(!snapshot.transcript.contains { Self.label($0.kind).hasPrefix("prompt") })
        Self.expectCoherentProjections(snapshot)
        #expect(snapshot.notices.allSatisfy { $0.sequence >= snapshot.firstRetainedSequence })
        // A client that saw sequence 1 knows entries are missing; one that saw
        // the entry before the first retained one can catch up.
        let lastSeen = snapshot.firstRetainedSequence - 1
        #expect(snapshot.log.filter { $0.sequence > lastSeen } == snapshot.log)
        // The title comes from the epoch's first prompt, which survives the drop.
        #expect(snapshot.summary.title != nil)

        // An entry larger than the whole budget leaves the log empty.
        await reducer.presentSessionNotice(.operationFailed(description: String(repeating: "z", count: budget)))
        #expect(reducer.snapshot.log.isEmpty)
        #expect(reducer.snapshot.firstRetainedSequence == snapshot.log.last.map { $0.sequence + 2 })
        #expect(reducer.snapshot.notices.isEmpty)
        #expect(reducer.snapshot.transcript.isEmpty)
        #expect(reducer.snapshot.activity.isEmpty)
    }
}

// MARK: - Scripts

/// One script of runtime events, fed to the transcript and to the reducer.
enum BlockScript: CaseIterable, Sendable, CustomTestStringConvertible {
    case contentThenTools
    case blankBlocks
    case reasoningOnly
    case failedTurn
    case workflowContinuation
    case planner

    enum Event: Sendable {
        case thought(String)
        case content(String)
        case started(DirectAgentToolCall)
        case completed(DirectAgentToolCall, DirectAgentToolResult)
        case continueAutomatically
    }

    private static let read = DirectAgentToolCall(
        id: "read", name: "local.readFile", argumentsObject: ["path": "a.swift"], argumentsJSON: "{}"
    )
    private static let list = DirectAgentToolCall(
        id: "list", name: "local.ls", argumentsObject: [:], argumentsJSON: "{}"
    )
    private static let result = DirectAgentToolResult(output: "ok", summary: "ok")

    var testDescription: String {
        "\(self)"
    }

    var prompt: String {
        "Prompt of \(self)"
    }

    var purpose: ChatTurnPurpose {
        switch self {
        case .workflowContinuation:
            .workflow(originalGoal: "Ship", graphID: "graph")
        case .planner:
            .plan(originalGoal: "Plan it")
        default:
            .normal
        }
    }

    var events: [Event] {
        switch self {
        case .contentThenTools:
            [
                .thought("Plan. "), .content("Reading."), .started(Self.read), .completed(Self.read, Self.result),
                .content("Listing."), .completed(Self.list, Self.result), .thought("Wrap."), .content("Final."),
            ]
        case .blankBlocks:
            [.content("  "), .started(Self.read), .thought("\n"), .completed(Self.read, Self.result), .content("Tail")]
        case .reasoningOnly:
            [.thought("Thinking only.")]
        case .failedTurn:
            [.thought("Half"), .content("Partial"), .started(Self.read)]
        case .workflowContinuation:
            [.content("Round one."), .continueAutomatically, .thought("Round two."), .continueAutomatically]
        case .planner:
            [.thought("Asking the Planner."), .started(Self.read), .completed(Self.read, Self.result)]
        }
    }

    /// The runtime's final response text; `nil` for a failed turn.
    var finalResponseText: String? {
        switch self {
        case .contentThenTools:
            "Reading.Listing.Final."
        case .blankBlocks:
            "Tail"
        case .reasoningOnly:
            "Promoted."
        case .failedTurn:
            nil
        case .workflowContinuation:
            "Round one."
        case .planner:
            "1. Do it."
        }
    }

    var expected: [ChatSessionStateTests.TurnEntry] {
        let prompt = ChatSessionStateTests.TurnEntry(turn: 1, entry: .prompt(text: prompt, attachments: []))
        let started = ChatSessionStateTests.RepresentableEntry.toolCallStarted(
            id: "read", name: "local.readFile", argumentsJSON: #"{"path":"a.swift"}"#
        )
        let completed = ChatSessionStateTests.RepresentableEntry.toolCallCompleted(
            id: "read", name: "local.readFile", output: "ok", attachments: []
        )
        let entries: [ChatSessionStateTests.RepresentableEntry]
        switch self {
        case .contentThenTools:
            entries = [
                .thought("Plan."), .assistantText("Reading."), started, completed,
                .assistantText("Listing."),
                .toolCallStarted(id: "list", name: "local.ls", argumentsJSON: "{}"),
                .toolCallCompleted(id: "list", name: "local.ls", output: "ok", attachments: []),
                .thought("Wrap."), .assistantText("Final."),
            ]
        case .blankBlocks:
            entries = [started, completed, .assistantText("  Tail")]
        case .reasoningOnly:
            entries = [.assistantText("Promoted.")]
        case .failedTurn:
            entries = [.thought("Half"), .assistantText("Partial"), started]
        case .workflowContinuation:
            entries = [.assistantText("Round one."), .thought("Round two.")]
        case .planner:
            entries = [.thought("Asking the Planner."), started, completed, .assistantText("1. Do it.")]
        }
        return [prompt] + entries.map { ChatSessionStateTests.TurnEntry(turn: 1, entry: $0) }
    }
}

// MARK: - Helpers

extension ChatSessionStateTests {
    /// An entry the transcript can represent, reduced to what it keeps.
    enum RepresentableEntry: Equatable, Sendable {
        case prompt(text: String, attachments: [AgentRuntimeAttachment])
        case assistantText(String)
        case thought(String)
        case toolCallStarted(id: String, name: String, argumentsJSON: String)
        case toolCallCompleted(id: String, name: String, output: String, attachments: [AgentRuntimeAttachment])

        init?(_ kind: ChatTurnEntry.Kind) {
            switch kind {
            case let .userPrompt(text, attachments, _):
                self = .prompt(text: text, attachments: attachments)
            case let .assistantText(text):
                self = .assistantText(text)
            case let .thought(text):
                self = .thought(text)
            case let .toolCallStarted(call):
                self = .toolCallStarted(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON)
            case let .toolCallCompleted(call, result):
                self = .toolCallCompleted(
                    id: call.id, name: call.name, output: result.output, attachments: result.attachments
                )
            default:
                return nil
            }
        }
    }

    /// A representable entry with its turn, numbered from 1 in log order.
    struct TurnEntry: Equatable, Sendable {
        let turn: Int?
        let entry: RepresentableEntry
    }

    static func representable(_ log: [ChatTurnEntry]) -> [TurnEntry] {
        var ordinals: [Int: Int] = [:]
        return log.compactMap { entry in
            guard let representable = RepresentableEntry(entry.kind) else { return nil }
            let turn = entry.turnID.map { turnID in
                if let ordinal = ordinals[turnID] { return ordinal }
                let ordinal = ordinals.count + 1
                ordinals[turnID] = ordinal
                return ordinal
            }
            return TurnEntry(turn: turn, entry: representable)
        }
    }

    /// A reducer that received `messages` as a restored session, through the
    /// one transcript rebuild.
    @ChatSessionActor
    static func reducerRestoring(_ messages: [AgentRuntimeMessage]) async -> ChatSessionStateReducer {
        let reducer = reducer()
        await reducer.presentRestoredLog(ChatTurnEntry.kinds(fromTranscript: messages))
        return reducer
    }

    static func expectStrictlyIncreasing(
        _ log: [ChatTurnEntry],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (previous, next) in zip(log, log.dropFirst()) {
            #expect(previous.sequence < next.sequence, sourceLocation: sourceLocation)
        }
    }

    /// The projections are the log filtered by kind, in log order.
    static func expectCoherentProjections(
        _ snapshot: ChatSessionSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let union = (snapshot.transcript + snapshot.activity).sorted { $0.sequence < $1.sequence }
        #expect(union == snapshot.log.filter { $0.kind.isTranscriptOrActivity }, sourceLocation: sourceLocation)
        #expect(snapshot.transcript == snapshot.log.filter { $0.kind.isTranscript }, sourceLocation: sourceLocation)
        #expect(snapshot.activity == snapshot.log.filter { $0.kind.isActivity }, sourceLocation: sourceLocation)
        #expect(
            snapshot.notices == Array(snapshot.log.filter { $0.kind.isNotice }
                .suffix(ChatSessionStateReducer.maximumNoticeCount)),
            sourceLocation: sourceLocation
        )
        #expect(
            snapshot.fileChanges.artifactHistory == snapshot.log.filter { $0.kind.isFileArtifacts },
            sourceLocation: sourceLocation
        )
        #expect(snapshot.log.first.map { $0.sequence >= snapshot.firstRetainedSequence } ?? true,
                sourceLocation: sourceLocation)
    }

    /// The first snapshot of `reducer`, the current one included, that
    /// satisfies `predicate`.
    @ChatSessionActor
    static func snapshot(
        of reducer: ChatSessionStateReducer,
        where predicate: (ChatSessionSnapshot) -> Bool
    ) async -> ChatSessionSnapshot {
        for await snapshot in reducer.snapshots() where predicate(snapshot) {
            return snapshot
        }
        Issue.record("The snapshot stream ended")
        return reducer.snapshot
    }

    static func reducer(maximumLogBytes: Int = ChatSessionController.maximumTranscriptBytes) -> ChatSessionStateReducer {
        ChatSessionStateReducer(
            sessionID: "state-session",
            workingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("chat-state-\(UUID().uuidString)", isDirectory: true),
            defaultOrigin: .local,
            state: ChatSessionState(),
            epoch: 0,
            maximumLogBytes: maximumLogBytes
        )
    }

    static func toolCall(id: String, name: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: id, name: name, argumentsObject: ["path": "."], argumentsJSON: "{}")
    }

    static func response(_ text: String) -> DirectAgentResponse {
        DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "m")
    }

    static func artifactTurn(number: UInt64, path: String) -> SessionFileArtifactHistory.Turn {
        SessionFileArtifactHistory.Turn(
            number: number,
            artifacts: [FileChangeArtifact(absolutePath: "/tmp/\(path)", displayPath: path, status: .modified)]
        )
    }

    /// A request outside any controller, for the reducer alone.
    static func request(
        _ prompt: String,
        purpose: ChatTurnPurpose = .normal,
        origin: ChatTurnOrigin? = nil
    ) -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: prompt,
            purpose: purpose,
            sessionConfiguration: AgentCoreSessionConfiguration(
                sessionID: "state-session",
                modelID: "scripted-model",
                workingDirectory: FileManager.default.temporaryDirectory,
                systemPrompt: nil,
                cacheKey: nil,
                history: []
            ),
            origin: origin
        )
    }

    /// A request for a turn of `controller`'s session.
    @ChatSessionActor
    static func request(
        _ prompt: String,
        for controller: ChatSessionController,
        attachments: [AgentRuntimeAttachment] = [],
        presenter: (any ChatSessionPresenter)? = nil,
        origin: ChatTurnOrigin? = nil
    ) -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: prompt,
            attachments: attachments,
            sessionConfiguration: AgentCoreSessionConfiguration(
                sessionID: controller.sessionID,
                modelID: "scripted-model",
                workingDirectory: controller.workingDirectory,
                systemPrompt: nil,
                cacheKey: nil,
                history: []
            ),
            presenter: presenter,
            origin: origin
        )
    }

    /// The saved session `name` as the project's store holds it.
    @ChatSessionActor
    static func stored(_ name: String, in harness: ChatManagementHarness) throws -> TerminalSavedSession {
        try #require(try TerminalSessionStore.savedSessions(for: harness.workspace).first { $0.name == name })
    }

    /// A turn with reasoning, content, and two tool calls.
    static let inspectionTurn: ScriptedChatRuntime.Script = { call in
        let read = toolCall(id: "tool-read", name: "local.readFile")
        await call.onEvent(.thought("Planning. "))
        await call.onEvent(.content("Let me check."))
        await call.onEvent(.toolCallStarted(read))
        await call.onEvent(.toolCallCompleted(read, DirectAgentToolResult(output: "ok", summary: "ok")))
        await call.onEvent(.content("Done."))
        await call.onEvent(.turnEnded(.completed))
        return DirectAgentResponse(text: "Let me check.Done.", stopReason: "end_turn", modelID: "m")
    }

    /// Three turns: tool calls with an attachment and a blank block, a turn
    /// of reasoning alone, and a failed turn with a completion that never
    /// started. 15 representable entries.
    @ChatSessionActor
    static func runComparisonTurns(
        on controller: ChatSessionController,
        runtime: ScriptedChatRuntime,
        request: @ChatSessionActor (String, [AgentRuntimeAttachment]) -> ChatTurnRequest
    ) async throws {
        let shot = AgentRuntimeAttachment(
            kind: .image,
            data: Data([1, 2, 3]),
            contentType: "image/png",
            originalFilename: "shot.png"
        )
        await runtime.append { call in
            let read = toolCall(id: "tool-read", name: "local.readFile")
            let list = DirectAgentToolCall(
                id: "tool-list", name: "local.ls", argumentsObject: ["path": "Sources", "depth": 2], argumentsJSON: "{}"
            )
            await call.onEvent(.thought("Planning the reads. "))
            await call.onEvent(.content("Let me "))
            await call.onEvent(.content("check."))
            await call.onEvent(.toolCallStarted(read))
            await call.onEvent(.toolCallCompleted(read, DirectAgentToolResult(output: "ok", summary: "ok", attachments: [shot])))
            await call.onEvent(.content("\n"))
            await call.onEvent(.toolCallStarted(list))
            await call.onEvent(.toolCallCompleted(list, DirectAgentToolResult(output: "a\nb", summary: "2 entries")))
            await call.onEvent(.thought("Wrapping up."))
            await call.onEvent(.content("Final answer."))
            await call.onEvent(.turnEnded(.completed))
            return DirectAgentResponse(text: "Let me check.Final answer.", stopReason: "end_turn", modelID: "m")
        }
        _ = try await controller.runTurn(request("Inspect the project", [shot]))

        await runtime.append { call in
            await call.onEvent(.thought("Only reasoning here."))
            await call.onEvent(.turnEnded(.completed))
            return DirectAgentResponse(text: "Promoted answer.", stopReason: "end_turn", modelID: "m")
        }
        _ = try await controller.runTurn(request("Why?", []))

        await runtime.append { call in
            let orphan = toolCall(id: "tool-orphan", name: "local.exec")
            await call.onEvent(.content("Partial"))
            await call.onEvent(.toolCallCompleted(orphan, DirectAgentToolResult(output: "denied", summary: "denied", status: .permissionDenied)))
            throw ScriptedChatRuntime.ScriptedFailure(message: "backend failed")
        }
        _ = try? await controller.runTurn(request("Run it", []))
    }

    /// A short label of an entry, for compact expectations.
    static func label(_ kind: ChatTurnEntry.Kind) -> String {
        switch kind {
        case let .userPrompt(text, _, _): "prompt:\(text)"
        case .assistantText: "text"
        case .thought: "thought"
        case .toolCallStarted: "toolStarted"
        case .toolCallCompleted: "toolCompleted"
        case .fileArtifacts: "artifacts"
        case .notice: "notice"
        case .workflowNotice: "workflow"
        case .turnPhase(.started): "started"
        case .turnPhase(.modelReturned): "modelReturned"
        case .turnPhase(.finishing): "finishing"
        case .turnPhase(.ended): "ended"
        }
    }
}

extension ChatTurnEntry.Kind {
    var isTranscriptOrActivity: Bool {
        isTranscript || isActivity
    }
}

/// Records what a host's open handler received.
private actor OpenedTargets {
    private(set) var targets: [ChatOpenTarget] = []

    func append(_ target: ChatOpenTarget) {
        targets.append(target)
    }
}
