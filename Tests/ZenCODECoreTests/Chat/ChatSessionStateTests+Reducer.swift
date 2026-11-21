//
//  ChatSessionStateTests+Reducer.swift
//  ZenCODE
//
//  State reducer tests for the closing of blocks, tool call previews, turns,
//  overviews, pending requests and the bounds of the log, with the block
//  scripts they replay.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension ChatSessionStateTests {
    private typealias Fixtures = ChatTestFixtures

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

    // MARK: - Tool call preview

    /// A preview is live presentation only: the reducer neither logs it nor
    /// changes its snapshot, and the block the call interrupts stays open
    /// until the call starts, so the log is the one the same turn builds
    /// without previews.
    @Test
    @ChatSessionActor
    func aToolCallPreviewChangesNeitherTheReducerSnapshotNorTheOpenBlock() async throws {
        let call = Self.toolCall(id: "call-write", name: "local.writeFile")
        let result = DirectAgentToolResult(output: "ok", summary: "ok")
        let plain = Self.reducer()
        let previewed = Self.reducer()
        for reducer in [plain, previewed] {
            await reducer.turnWillStart(Self.request("Write the notes"))
            await reducer.presentThought("Planning. ")
            await reducer.presentAssistantContent("Writing ")
        }

        let before = previewed.snapshot
        let fragments: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.writeFile"),
            .parameterStarted(name: "path"),
            .parameterText("Notes.md"),
            .parameterEnded,
            .parameterStarted(name: "content"),
            .parameterText("# Title\n"),
            .parameterEnded,
            .ended,
        ]
        for fragment in fragments {
            await previewed.presentToolCallPreview(fragment)
            #expect(previewed.snapshot == before)
        }

        for reducer in [plain, previewed] {
            await reducer.presentAssistantContent("the notes.")
            await reducer.presentToolCallStarted(call)
            await reducer.presentToolCallCompleted(call, result: result)
            await reducer.presentAssistantContent("Done.")
            await reducer.turnWillFinish()
        }
        #expect(Self.representable(previewed.snapshot.log) == Self.representable(plain.snapshot.log))
        #expect(previewed.snapshot.log.map(\.sequence) == plain.snapshot.log.map(\.sequence))
        #expect(Self.representable(previewed.snapshot.log).contains {
            $0.entry == .assistantText("Writing the notes.")
        })
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

/// Records what a host's open handler received.
private actor OpenedTargets {
    private(set) var targets: [ChatOpenTarget] = []

    func append(_ target: ChatOpenTarget) {
        targets.append(target)
    }
}
