//
//  ZenTranscriptProjectionTests.swift
//  ZenAppSessionTests
//
//  The projection driven by a real `ChatSessionStateReducer` through its
//  public presenter methods.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

@Suite(.serialized)
struct ZenTranscriptProjectionTests {
    private let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("zen-app-projection-\(UUID().uuidString)", isDirectory: true)

    @Test("Log entries project in order with epoch ids, tool results merge into their call, the live block is no row")
    func projectsTheLog() async throws {
        let reducer = ChatSessionStateReducer(sessionID: "s", workingDirectory: workspace, defaultOrigin: .app)
        var projection = ZenTranscriptProjection()

        await reducer.presentSessionNotice(.help(commandHelp: ["/help shows this command list."]))
        await reducer.turnWillStart(request("Hello"))
        await reducer.presentThought("Planning the read")
        await reducer.presentAssistantContent("Let me read the file.")

        // Streaming: the block is outside the log, and outside the rows.
        var snapshot = await reducer.snapshot
        let epoch = snapshot.epoch
        let changed1 = projection.update(with: snapshot)
        #expect(changed1)
        var items = projection.items
        #expect(items.map(\.id) == ["\(epoch)-log-1", "\(epoch)-log-2"])
        #expect(items[1].content == .userPrompt(text: "Hello", attachments: [], origin: .app))
        #expect(items[1].turnID == 1)
        #expect(items[1].startsTurn)
        #expect(!items[0].startsTurn)
        #expect(projection.liveBlockID(for: snapshot) == "\(epoch)-live-1-0")
        #expect(projection.firstVisiblePromptTitle == "Hello")

        // A streamed token changes no row and composes nothing.
        let compositions = projection.compositionCount
        await reducer.presentAssistantContent(" More.")
        snapshot = await reducer.snapshot
        let changed2 = projection.update(with: snapshot)
        #expect(!changed2)
        #expect(projection.compositionCount == compositions)
        #expect(projection.liveBlockID(for: snapshot) == "\(epoch)-live-1-0")

        // A tool call closes the block; its result fills the call's row, with
        // the time the Core measured for it.
        let call = toolCall("call-1", "local.readFile")
        let result = DirectAgentToolResult(
            output: "contents", summary: "read 1 file", elapsed: .milliseconds(1_250)
        )
        await reducer.presentToolCallStarted(call)
        snapshot = await reducer.snapshot
        let changed3 = projection.update(with: snapshot)
        #expect(changed3)
        items = projection.items
        let started = try #require(items.last)
        #expect(started.content == .toolCall(call: call, result: nil))
        let callRowID = started.id
        #expect(projection.liveBlockID(for: snapshot) == nil)

        await reducer.presentToolCallCompleted(call, result: result)
        await reducer.presentAssistantContent("Done.")
        snapshot = await reducer.snapshot
        projection.update(with: snapshot)
        // The next block has another id: two blocks of the turn closed.
        #expect(projection.liveBlockID(for: snapshot) == "\(epoch)-live-1-2")
        await reducer.modelTurnDidReturn()
        await reducer.presentFinalResponse(DirectAgentResponse(text: "Done.", stopReason: "end_turn", modelID: "m"))
        await reducer.turnWillFinish()
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "a.txt", additions: 2, deletions: 1, status: .modified,
                isBinary: false, existedBefore: true, beforeDataBase64: nil, patch: "@@"
            ),
        ])
        await reducer.presentFileChangeSummary(summary)
        await reducer.presentSessionNotice(.sessionStarted)

        snapshot = await reducer.snapshot
        let changed4 = projection.update(with: snapshot)
        #expect(changed4)
        items = projection.items
        let contents = items.map(\.content)
        #expect(contents == [
            .notice(.help(commandHelp: ["/help shows this command list."])),
            .userPrompt(text: "Hello", attachments: [], origin: .app),
            .thought("Planning the read", isStreaming: false),
            .assistantText("Let me read the file. More.", isStreaming: false),
            .toolCall(call: call, result: result),
            .assistantText("Done.", isStreaming: false),
            .fileChangeSummary(summary),
            .notice(.sessionStarted),
        ])
        // One row per entry with an id from its epoch and sequence; the
        // completion and the turn phases add none.
        let rowSequences = snapshot.log.filter { entry in
            switch entry.kind {
            case .turnPhase, .toolCallCompleted: false
            default: true
            }
        }.map(\.sequence)
        #expect(items.filter { $0.id.hasPrefix("\(epoch)-log-") }.map(\.id) == rowSequences.map { "\(epoch)-log-\($0)" })
        #expect(items.contains { $0.id == callRowID && $0.content == .toolCall(call: call, result: result) })
        if case let .toolCall(_, rowResult)? = items.first(where: { $0.id == callRowID })?.content {
            #expect(rowResult?.elapsed == .milliseconds(1_250))
        } else {
            Issue.record("The call's row is not a tool call")
        }
        #expect(items[6].id == "\(epoch)-summary-1")
        #expect(items[6].turnID == 1)
        #expect(items[7].turnID == nil)
        #expect(items.filter(\.startsTurn).count == 1)
        #expect(projection.liveBlockID(for: snapshot) == nil)
        #expect(projection.rebuildCount == 1)
        #expect(items == ZenTranscriptProjection.items(
            for: snapshot,
            localItems: [],
            fileChangeSummaries: projection.fileChangeSummaries
        ))
        // Nothing new: no change.
        let changed5 = projection.update(with: snapshot)
        #expect(!changed5)
    }

    @Test("A result without a call id completes the oldest open call of its turn")
    func toolResultsWithoutIDMatchFIFO() async {
        let reducer = ChatSessionStateReducer(sessionID: "s", workingDirectory: workspace, defaultOrigin: .app)
        let first = toolCall("", "local.readFile")
        let second = toolCall("", "local.listFiles")
        let firstResult = DirectAgentToolResult(output: "1", summary: "first")
        let secondResult = DirectAgentToolResult(output: "2", summary: "second")
        await reducer.presentRestoredLog([
            .userPrompt(text: "Restore", attachments: [], origin: .unknown),
            .toolCallStarted(first),
            .toolCallStarted(second),
            .toolCallCompleted(first, result: firstResult),
            .toolCallCompleted(second, result: secondResult),
            .assistantText("Restored."),
        ])
        var projection = ZenTranscriptProjection()
        projection.update(with: await reducer.snapshot)
        #expect(projection.items.map(\.content) == [
            .userPrompt(text: "Restore", attachments: [], origin: .unknown),
            .toolCall(call: first, result: firstResult),
            .toolCall(call: second, result: secondResult),
            .assistantText("Restored.", isStreaming: false),
        ])
    }

    @Test("Local rows follow their anchor, keep their insertion order, and disappear with their epoch")
    func localRowsAreAnchored() async throws {
        let reducer = ChatSessionStateReducer(sessionID: "s", workingDirectory: workspace, defaultOrigin: .app)
        var projection = ZenTranscriptProjection()

        // Before anything: anchored before the first entry.
        var snapshot = await reducer.snapshot
        let first = ZenLocalTranscriptItem(anchoredIn: snapshot, content: .commandLine("/help"))
        #expect(first.anchorSequence == 0)
        await reducer.presentSessionNotice(.help(commandHelp: []))
        await reducer.turnWillStart(request("Hello"))
        snapshot = await reducer.snapshot
        let afterPrompt = ZenLocalTranscriptItem(anchoredIn: snapshot, content: .local(text: "late", isFailure: true))
        await reducer.presentAssistantContent("Answer")
        await reducer.turnWillFinish()

        snapshot = await reducer.snapshot
        let stale = ZenLocalTranscriptItem(epoch: snapshot.epoch + 1, anchorSequence: 0, content: .commandLine("/other"))
        // Inserted out of anchor order: the projection orders them.
        let locals = [afterPrompt, stale, first]
        for local in locals {
            projection.insertLocal(local)
        }
        projection.update(with: snapshot)
        var items = projection.items
        #expect(items.map(\.content) == [
            .commandLine("/help"),
            .notice(.help(commandHelp: [])),
            .userPrompt(text: "Hello", attachments: [], origin: .app),
            .local(text: "late", isFailure: true),
            .assistantText("Answer", isStreaming: false),
        ])
        #expect(items[0].id == "local-\(first.id.uuidString.lowercased())")
        #expect(items[0].turnID == nil)
        #expect(items == ZenTranscriptProjection.items(for: snapshot, localItems: locals))

        // A row anchored at the end follows everything; two rows with one
        // anchor keep their insertion order.
        let tail = ZenLocalTranscriptItem(anchoredIn: snapshot, content: .local(text: "Turn cancelled.", isFailure: false))
        let tail2 = ZenLocalTranscriptItem(anchoredIn: snapshot, content: .local(text: "second", isFailure: false))
        projection.insertLocal(tail)
        let changed6 = projection.composeIfNeeded()
        #expect(changed6)
        projection.insertLocal(tail2)
        let changed7 = projection.composeIfNeeded()
        #expect(changed7)
        #expect(projection.items.suffix(2).map(\.content) == [tail.content, tail2.content])
        await reducer.turnWillStart(request("Again"))
        await reducer.presentAssistantContent("streaming")
        snapshot = await reducer.snapshot
        projection.update(with: snapshot)
        items = projection.items
        let tailIndex = try #require(items.firstIndex { $0.content == tail.content })
        let againIndex = try #require(items.firstIndex { $0.content == .userPrompt(text: "Again", attachments: [], origin: .app) })
        #expect(tailIndex < againIndex)
        #expect(items.last?.content == .userPrompt(text: "Again", attachments: [], origin: .app))
    }

    @Test("A new epoch rebuilds: the old log, summaries, hidden prompts, and local rows are gone; ids differ")
    func epochChangeRebuilds() async {
        let reducer = ChatSessionStateReducer(sessionID: "s", workingDirectory: workspace, defaultOrigin: .app)
        var projection = ZenTranscriptProjection()
        await reducer.turnWillStart(request("Old"))
        await reducer.turnWillFinish()
        await reducer.presentFileChangeSummary(TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "x", additions: 1, deletions: 0, status: .added,
                isBinary: false, existedBefore: false, beforeDataBase64: nil, patch: nil
            ),
        ]))
        await reducer.presentSessionNotice(.sessionStarted)
        var snapshot = await reducer.snapshot
        let firstEpoch = snapshot.epoch
        projection.hidePrompt(after: snapshot.log.last?.sequence ?? 0, epoch: firstEpoch)
        projection.insertLocal(ZenLocalTranscriptItem(anchoredIn: snapshot, content: .commandLine("/sessions new")))
        projection.update(with: snapshot)
        let firstIDs = Set(projection.items.map(\.id))
        #expect(projection.fileChangeSummaries.count == 1)
        #expect(projection.rebuildCount == 1)
        #expect(projection.firstVisiblePromptTitle == "Old")

        await reducer.sessionDidChange(sessionID: "s2")
        await reducer.presentSessionNotice(.sessionStarted)
        snapshot = await reducer.snapshot
        #expect(snapshot.epoch != firstEpoch)
        let changed9 = projection.update(with: snapshot)
        #expect(changed9)
        #expect(projection.items.map(\.content) == [.notice(.sessionStarted)])
        #expect(projection.fileChangeSummaries.isEmpty)
        #expect(projection.localItems.isEmpty)
        #expect(projection.firstVisiblePromptTitle == nil)
        #expect(projection.rebuildCount == 2)
        // The rows of the new epoch never reuse an id of the old one.
        #expect(firstIDs.isDisjoint(with: projection.items.map(\.id)))

        // A late row of the old epoch is dropped at once.
        let older = ZenLocalTranscriptItem(epoch: firstEpoch, anchorSequence: 0, content: .commandLine("/old"))
        projection.insertLocal(older)
        let changed8 = projection.composeIfNeeded()
        #expect(!changed8)
        #expect(!projection.localItems.contains(older))

        // The hidden prompt of the old epoch does not hide the new one's.
        await reducer.turnWillStart(request("New"))
        snapshot = await reducer.snapshot
        projection.update(with: snapshot)
        #expect(projection.items.contains { $0.content == .userPrompt(text: "New", attachments: [], origin: .app) })
        #expect(projection.hiddenPromptSequences.isEmpty)
    }

    @Test("An empty file-change summary adds no row")
    func emptySummaryAddsNoRow() async {
        let reducer = ChatSessionStateReducer(sessionID: "s", workingDirectory: workspace, defaultOrigin: .app)
        await reducer.turnWillStart(request("Hello"))
        await reducer.turnWillFinish()
        await reducer.presentFileChangeSummary(TurnFileChangeSummary(entries: []))
        var projection = ZenTranscriptProjection()
        projection.update(with: await reducer.snapshot)
        #expect(!projection.items.contains { $0.id.contains("-summary-") })
    }

    @Test("A hidden prompt adds no row and no title; its turn still shows; the next typed prompt shows and titles")
    func hiddenPromptsAddNoRow() async throws {
        let reducer = ChatSessionStateReducer(sessionID: "s", workingDirectory: workspace, defaultOrigin: .app)
        var projection = ZenTranscriptProjection()
        var snapshot = await reducer.snapshot
        projection.update(with: snapshot)

        // The mark comes before the turn starts, as the window posts it.
        projection.hidePrompt(after: ZenLocalTranscriptItem.anchorSequence(in: snapshot), epoch: snapshot.epoch)
        await reducer.turnWillStart(request("Internal planner prompt"))
        await reducer.presentAssistantContent("Planning.")
        await reducer.turnWillFinish()
        snapshot = await reducer.snapshot
        projection.update(with: snapshot)
        #expect(projection.items.map(\.content) == [.assistantText("Planning.", isStreaming: false)])
        #expect(!projection.items.contains { $0.startsTurn })
        #expect(projection.hiddenPromptSequences.count == 1)
        #expect(projection.firstVisiblePromptTitle == nil)
        // The Core's own title comes from the hidden prompt; the window's does not.
        #expect(snapshot.summary.title == "Internal planner prompt")

        await reducer.turnWillStart(request("  Typed\nby the   operator  "))
        await reducer.turnWillFinish()
        snapshot = await reducer.snapshot
        projection.update(with: snapshot)
        let prompt = try #require(projection.items.first { $0.startsTurn })
        #expect(prompt.content == .userPrompt(text: "  Typed\nby the   operator  ", attachments: [], origin: .app))
        #expect(projection.firstVisiblePromptTitle == "Typed by the operator")

        // Two hidden turns in a row: each mark hides its own prompt.
        for index in 1...2 {
            projection.hidePrompt(after: ZenLocalTranscriptItem.anchorSequence(in: await reducer.snapshot), epoch: snapshot.epoch)
            await reducer.turnWillStart(request("Hidden \(index)"))
            await reducer.turnWillFinish()
        }
        snapshot = await reducer.snapshot
        projection.update(with: snapshot)
        #expect(projection.hiddenPromptSequences.count == 3)
        #expect(projection.items.filter(\.startsTurn).count == 1)
        #expect(projection.items == ZenTranscriptProjection.items(
            for: snapshot,
            localItems: [],
            hiddenPromptSequences: projection.hiddenPromptSequences
        ))
        #expect(projection.firstVisiblePromptTitle == "Typed by the operator")
    }

    @Test("The local echo of a typed reply starts a visible turn and titles the session; its hidden prompt stays hidden")
    func replyEchoStartsAVisibleTurn() async throws {
        let reducer = ChatSessionStateReducer(sessionID: "s", workingDirectory: workspace, defaultOrigin: .app)
        var projection = ZenTranscriptProjection()
        var snapshot = await reducer.snapshot
        projection.update(with: snapshot)
        // The echo is anchored before the reply's turn, whose prompt is hidden.
        let echo = ZenLocalTranscriptItem(
            anchoredIn: snapshot,
            content: .userPrompt(text: "Use Swift", attachments: [], origin: .app)
        )
        projection.insertLocal(echo)
        projection.hidePrompt(after: ZenLocalTranscriptItem.anchorSequence(in: snapshot), epoch: snapshot.epoch)
        await reducer.turnWillStart(request("Workflow continuation built from the reply"))
        await reducer.presentAssistantContent("Continuing.")
        await reducer.turnWillFinish()
        snapshot = await reducer.snapshot
        projection.update(with: snapshot)
        #expect(projection.items.map(\.content) == [
            .userPrompt(text: "Use Swift", attachments: [], origin: .app),
            .assistantText("Continuing.", isStreaming: false),
        ])
        let row = try #require(projection.items.first)
        #expect(row.id == "local-\(echo.id.uuidString.lowercased())")
        #expect(row.startsTurn)
        #expect(projection.firstVisiblePromptTitle == "Use Swift")
    }

    @Test("A title is one line of at most 40 characters, cut at a word")
    func titles() {
        #expect(ZenTranscriptProjection.title(fromPrompt: "  \n ") == nil)
        #expect(ZenTranscriptProjection.title(fromPrompt: "Fix\tthe\nbuild") == "Fix the build")
        let long = "Refactor the transcript projection so that every row is unique"
        let title = ZenTranscriptProjection.title(fromPrompt: long)
        #expect(title == "Refactor the transcript projection so")
        #expect((title?.count ?? 0) <= 40)
        #expect(ZenTranscriptProjection.title(fromPrompt: String(repeating: "x", count: 50)) == String(repeating: "x", count: 40))
    }

    @Test("Incremental updates equal a full rebuild at every step and reuse the projected prefix")
    func incrementalEqualsFullRebuild() async {
        let reducer = ChatSessionStateReducer(sessionID: "s", workingDirectory: workspace, defaultOrigin: .app)
        var projection = ZenTranscriptProjection()
        var locals: [ZenLocalTranscriptItem] = []

        func check() async {
            let snapshot = await reducer.snapshot
            projection.update(with: snapshot)
            let full = ZenTranscriptProjection.items(
                for: snapshot,
                localItems: locals,
                fileChangeSummaries: projection.fileChangeSummaries,
                hiddenPromptSequences: projection.hiddenPromptSequences
            )
            #expect(projection.items == full)
        }

        await check()
        for turn in 1...3 {
            if turn == 2 {
                // A turn a command built: its prompt is hidden.
                projection.hidePrompt(after: ZenLocalTranscriptItem.anchorSequence(in: await reducer.snapshot), epoch: await reducer.snapshot.epoch)
            }
            await reducer.turnWillStart(request("Prompt \(turn)"))
            await check()
            await reducer.presentThought("think \(turn)")
            await check()
            await reducer.presentAssistantContent("text \(turn)")
            await check()
            let call = toolCall("call-\(turn)", "local.writeFile")
            await reducer.presentToolCallStarted(call)
            await check()
            let local = ZenLocalTranscriptItem(anchoredIn: await reducer.snapshot, content: .commandLine("/tasks"))
            locals.append(local)
            projection.insertLocal(local)
            await check()
            await reducer.presentToolCallCompleted(call, result: DirectAgentToolResult(output: "ok", summary: "ok"))
            await check()
            await reducer.presentWorkflowNotice(.openWithoutQuestion(graphID: "g", pendingTaskCount: turn))
            await check()
            await reducer.turnWillFinish()
            await check()
            await reducer.presentFileChangeSummary(TurnFileChangeSummary(entries: [
                TurnFileChangeSummary.Entry(
                    path: "f\(turn)", additions: turn, deletions: 0, status: .added,
                    isBinary: false, existedBefore: false, beforeDataBase64: nil, patch: nil
                ),
            ]))
            await check()
            await reducer.presentSessionNotice(.nothingToSave)
            await check()
        }
        #expect(projection.rebuildCount == 1)
        #expect(projection.hiddenPromptSequences.count == 1)
        #expect(projection.fileChangeSummaries.keys.sorted() == [1, 2, 3])
        let epoch = await reducer.snapshot.epoch
        #expect(projection.items.filter { $0.id.contains("-summary-") }.map(\.id)
            == ["\(epoch)-summary-1", "\(epoch)-summary-2", "\(epoch)-summary-3"])
        #expect(projection.items.filter(\.startsTurn).map(\.content) == [
            .userPrompt(text: "Prompt 1", attachments: [], origin: .app),
            .userPrompt(text: "Prompt 3", attachments: [], origin: .app),
        ])
    }

    @Test("A moved local row keeps its id, follows the rows up to its new anchor and the local rows already there, and shows its new content")
    func movesALocalRow() async throws {
        let reducer = ChatSessionStateReducer(sessionID: "s", workingDirectory: workspace, defaultOrigin: .app)
        var projection = ZenTranscriptProjection()
        await reducer.turnWillStart(request("Hello"))
        var snapshot = await reducer.snapshot
        let card = ZenLocalTranscriptItem(anchoredIn: snapshot, content: .taskGraph(taskOverview(revision: 1)))
        let echo = ZenLocalTranscriptItem(anchoredIn: snapshot, content: .commandLine("/tasks"))
        projection.insertLocal(card)
        projection.insertLocal(echo)
        projection.update(with: snapshot)
        let cardID = "local-\(card.id.uuidString.lowercased())"
        #expect(projection.items.suffix(2).map(\.id) == [cardID, "local-\(echo.id.uuidString.lowercased())"])

        // At the same anchor: it goes after the local row added after it,
        // with its new content and its id.
        let moved = projection.moveLocal(id: card.id, to: card.anchorSequence, content: .taskGraph(taskOverview(revision: 2)))
        #expect(moved)
        let changed1 = projection.composeIfNeeded()
        #expect(changed1)
        #expect(projection.items.suffix(2).map(\.content) == [echo.content, .taskGraph(taskOverview(revision: 2))])
        #expect(projection.items.last?.id == cardID)

        // Where it is, with the same content: the rows do not change.
        projection.moveLocal(id: card.id, to: card.anchorSequence, content: .taskGraph(taskOverview(revision: 2)))
        let changed2 = projection.composeIfNeeded()
        #expect(!changed2)

        // Log rows arrive: moved to the end, it follows them, still one row.
        await reducer.presentSessionNotice(.help(commandHelp: []))
        snapshot = await reducer.snapshot
        projection.update(with: snapshot)
        #expect(projection.items.last?.content == .notice(.help(commandHelp: [])))
        projection.moveLocal(
            id: card.id,
            to: ZenLocalTranscriptItem.anchorSequence(in: snapshot),
            content: .taskGraph(taskOverview(revision: 3))
        )
        let changed3 = projection.composeIfNeeded()
        #expect(changed3)
        let items = projection.items
        #expect(items.filter { $0.id == cardID }.count == 1)
        #expect(items.last?.id == cardID)
        #expect(items.last?.content == .taskGraph(taskOverview(revision: 3)))
        #expect(items == ZenTranscriptProjection.items(for: snapshot, localItems: projection.localItems))

        // A row the projection does not hold does not move.
        let unknown = projection.moveLocal(id: UUID(), to: 0, content: .commandLine("/x"))
        #expect(!unknown)
        let changed4 = projection.composeIfNeeded()
        #expect(!changed4)
        #expect(projection.items == items)
    }

    // MARK: - Helpers

    /// A task graph without tasks at `revision`, with fixed dates.
    private func taskOverview(revision: Int) -> ChatTaskGraphOverview {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        return ChatTaskGraphOverview(
            graph: TaskGraphSnapshot(
                id: "g",
                source: .manual,
                state: .active,
                revision: revision,
                tasks: [],
                createdAt: date,
                updatedAt: date
            ),
            tasks: []
        )
    }

    private func request(_ prompt: String) -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: prompt,
            sessionConfiguration: AgentCoreSessionConfiguration(
                sessionID: "s",
                modelID: "m",
                workingDirectory: workspace,
                systemPrompt: nil,
                cacheKey: nil,
                history: []
            ),
            origin: .app
        )
    }

    private func toolCall(_ id: String, _ name: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: id, name: name, argumentsObject: [:], argumentsJSON: "{}")
    }
}
