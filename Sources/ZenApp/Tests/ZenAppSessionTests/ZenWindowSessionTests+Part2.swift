//
//  ZenWindowSessionTests+Part2.swift
//  ZenAppSessionTests
//
//  Part 2 of the window session tests over a scripted backend: closing during
//  a turn, the bounded queue, the status facts, the task-graph cards, the
//  sub-agent overview, and the artifacts sidebar.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

extension ZenWindowSessionTests {
    @Test("Closing during a turn fences it: the slot ends, and the window writes nothing after")
    func closeDuringATurn() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            await backend.waitUntilHeld()
            window.draft = "Queued"
            window.submitDraft()
            #expect(await eventually {
                window.transcript.contains { $0.content == .userPrompt(text: "Long", attachments: [], origin: .app) }
            })
            let transcript = window.transcript
            let status = window.status

            await window.close()
            #expect(window.isClosed)
            #expect(!window.isBusy)
            #expect(window.queuedLines.isEmpty)
            #expect(runtime.windows.isEmpty)
            // The slot is gone with its reservation.
            #expect(await runtime.sessionHost.incarnation(in: window.slotID) == nil)
            await backend.release()
            await waitUntil("the held turn ended") { await !backend.isHolding }
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.transcript == transcript)
            #expect(window.status.modelID == status.modelID)
            #expect(window.liveAssistantText.isEmpty)
            #expect(await backend.prompts == ["Long"])
            // A second close does nothing.
            await window.close()
            await runtime.shutdown()
        }
    }

    @Test("The queue holds 32 prompts; one more is refused with the terminal's message and keeps the draft")
    func queueIsBounded() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(ZenWindowSession.queueCapacity == 32)
            await backend.hold()
            window.draft = "Busy"
            window.submitDraft()
            await backend.waitUntilHeld()
            for index in 1...ZenWindowSession.queueCapacity {
                window.draft = "Queued \(index)"
                window.submitDraft()
            }
            #expect(window.queuedLines.count == 32)
            window.draft = "One too many"
            window.submitDraft()
            #expect(window.draft == "One too many")
            #expect(window.queuedLines.count == 32)
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE: prompt queue is full; wait for the current prompt to finish.",
                isFailure: true
            ))
            for line in window.queuedLines {
                window.removeQueuedLine(line.id)
            }
            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts == ["Busy"])
            await runtime.shutdown()
        }
    }

    @Test("The status facts are read at start and after selections and sessions, not after every line")
    func statusFactsAreReadWhenNeeded() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            #expect(window.status.modelID == "local/zen-app-model")
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            let reads = window.statusFactsReadCount
            #expect(reads >= 1)

            for line in ["Again", "/help", "/tasks"] {
                window.draft = line
                window.submitDraft()
                #expect(await window.waitUntilIdle())
            }
            #expect(window.statusFactsReadCount == reads)

            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.epoch == window.current.epoch })
            #expect(await window.waitUntilIdle())
            #expect(window.statusFactsReadCount > reads)
            #expect(window.status.modelID == "local/zen-app-model")
            await runtime.shutdown()
        }
    }

    @Test("A turn's task card follows the significant changes while the turn generates, then stays; a later turn adds its own; a new session shows none")
    func taskCardOfATurn() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            let orchestrator = await window.runner.taskOrchestrator
            let sessionID = window.current.sessionID
            try? await orchestrator.registerSession(id: sessionID, workingDirectory: workspace)

            // A significant change while the turn generates: one card, after
            // the turn's prompt.
            await backend.hold()
            window.draft = "First"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })
            _ = try await orchestrator.createTasks(
                sessionID: sessionID,
                tasks: [TaskDefinition(title: "A"), TaskDefinition(title: "B")]
            )
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 1 })
            let card = try #require(Self.taskCards(in: window.transcript).first)
            #expect(card.id.hasPrefix("local-"))
            #expect(Self.taskCount(card) == 2)
            let firstPrompt = try #require(window.transcript.firstIndex {
                $0.content == .userPrompt(text: "First", attachments: [], origin: .app)
            })
            #expect(try #require(Self.index(of: card, in: window.transcript)) > firstPrompt)

            // A row arrives, then a second change: the same card, moved after
            // the row, with the graph as it is now.
            let marker = ChatSessionNotice.help(commandHelp: ["Card marker"])
            await Self.present(marker, in: window.sessionHost, slotID: window.slotID)
            #expect(await eventually { window.transcript.contains { $0.content == .notice(marker) } })
            let markerIndex = try #require(window.transcript.firstIndex { $0.content == .notice(marker) })
            #expect(try #require(Self.index(of: card, in: window.transcript)) < markerIndex)
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "C")])
            #expect(await eventually { Self.taskCards(in: window.transcript).first.flatMap(Self.taskCount) == 3 })
            #expect(Self.taskCards(in: window.transcript).map(\.id) == [card.id])
            let movedMarkerIndex = try #require(window.transcript.firstIndex { $0.content == .notice(marker) })
            #expect(try #require(Self.index(of: card, in: window.transcript)) > movedMarkerIndex)
            #expect(window.transcript.last?.id == card.id)
            await backend.release()
            #expect(await window.waitUntilIdle())
            // The answer streamed after the card, which stays where it was.
            let answer = try #require(window.transcript.firstIndex {
                $0.content == .assistantText("Scripted answer to First", isStreaming: false)
            })
            #expect(try #require(Self.index(of: card, in: window.transcript)) < answer)

            // A change once the turn ended shows nothing.
            let settled = window.transcript
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "D")])
            #expect(await eventually { window.snapshot?.taskGraph?.graph.tasks.count == 4 })
            #expect(window.transcript == settled)

            // The next turn: no card until a change, then a card of its own;
            // the first one stays where it is, as it was.
            await backend.hold()
            window.draft = "Second"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })
            #expect(Self.taskCards(in: window.transcript).map(\.id) == [card.id])
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "E")])
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 2 })
            let cards = Self.taskCards(in: window.transcript)
            #expect(cards.first?.id == card.id)
            #expect(cards.first.flatMap(Self.taskCount) == 3)
            #expect(cards.last?.id != card.id)
            #expect(cards.last.flatMap(Self.taskCount) == 5)
            #expect(Self.index(of: card, in: window.transcript) == Self.index(of: card, in: settled))
            let secondPrompt = try #require(window.transcript.firstIndex {
                $0.content == .userPrompt(text: "Second", attachments: [], origin: .app)
            })
            #expect(try #require(Self.index(of: card, in: window.transcript)) < secondPrompt)
            #expect(try #require(cards.last.flatMap { Self.index(of: $0, in: window.transcript) }) > secondPrompt)
            await backend.release()
            #expect(await window.waitUntilIdle())
            // A card is no artifact.
            #expect(window.fileArtifacts.isEmpty)

            // A new session shows no card, nor does a change outside a turn.
            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.epoch == window.current.epoch })
            #expect(Self.taskCards(in: window.transcript).isEmpty)
            let newSessionID = window.current.sessionID
            #expect(newSessionID != sessionID)
            try? await orchestrator.registerSession(id: newSessionID, workingDirectory: workspace)
            let significant = try await orchestrator.createTasks(
                sessionID: newSessionID,
                tasks: [TaskDefinition(title: "First"), TaskDefinition(title: "Second")]
            )
            #expect(await eventually { window.snapshot?.taskGraph?.graph.id == significant.id })
            #expect(Self.taskCards(in: window.transcript).isEmpty)
            await runtime.shutdown()
        }
    }

    @Test("A graph that is not significant shows no card in a turn; /tasks adds a card that stays where it ran, which the turn's card never moves")
    func tasksCommandCard() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            let orchestrator = await window.runner.taskOrchestrator
            let sessionID = window.current.sessionID
            try? await orchestrator.registerSession(id: sessionID, workingDirectory: workspace)

            // One pending task is not significant: no card in the turn.
            await backend.hold()
            window.draft = "Busy"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })
            let graph = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "Only")])
            #expect(await eventually { window.snapshot?.taskGraph?.graph.id == graph.id })
            #expect(window.snapshot?.taskGraph?.isSignificant == false)
            #expect(Self.taskCards(in: window.transcript).isEmpty)

            // /tasks beside the turn: a card of that graph, after its echo.
            window.draft = "/tasks"
            window.submitDraft()
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 1 })
            let requested = try #require(Self.taskCards(in: window.transcript).first)
            #expect(Self.taskCount(requested) == 1)
            let echo = try #require(window.transcript.lastIndex { $0.content == .commandLine("/tasks") })
            #expect(try #require(Self.index(of: requested, in: window.transcript)) > echo)

            // A significant change: the turn's card, after the /tasks card.
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "Second")])
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 2 })
            let turnCard = try #require(Self.taskCards(in: window.transcript).last)
            #expect(turnCard.id != requested.id)
            #expect(Self.taskCount(turnCard) == 2)
            let requestedIndex = try #require(Self.index(of: requested, in: window.transcript))
            #expect(try #require(Self.index(of: turnCard, in: window.transcript)) > requestedIndex)

            // A row, then a change: the turn's card moves; the /tasks card
            // stays where it is, as it was.
            let marker = ChatSessionNotice.help(commandHelp: ["Card marker"])
            await Self.present(marker, in: window.sessionHost, slotID: window.slotID)
            #expect(await eventually { window.transcript.contains { $0.content == .notice(marker) } })
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "Third")])
            #expect(await eventually { Self.taskCards(in: window.transcript).last.flatMap(Self.taskCount) == 3 })
            let cards = Self.taskCards(in: window.transcript)
            #expect(cards.map(\.id) == [requested.id, turnCard.id])
            #expect(cards.first == requested)
            #expect(Self.index(of: requested, in: window.transcript) == requestedIndex)
            let markerIndex = try #require(window.transcript.firstIndex { $0.content == .notice(marker) })
            #expect(try #require(Self.index(of: turnCard, in: window.transcript)) > markerIndex)
            await backend.release()
            #expect(await window.waitUntilIdle())

            // /tasks once the turn ended: one more card, the last row.
            window.draft = "/tasks"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 3 })
            let last = try #require(Self.taskCards(in: window.transcript).last)
            #expect(Self.taskCount(last) == 3)
            #expect(window.transcript.last?.id == last.id)
            #expect(Self.taskCards(in: window.transcript).prefix(2).map(\.id) == [requested.id, turnCard.id])

            // Another action of /tasks shows no card.
            let beforeShow = Self.taskCards(in: window.transcript)
            window.draft = "/tasks show nope"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(Self.taskCards(in: window.transcript) == beforeShow)

            // Without a graph: no card, only the command's notice.
            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.epoch == window.current.epoch })
            window.draft = "/tasks"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.transcript.contains { $0.content == .notice(.noTaskGraph) } })
            #expect(Self.taskCards(in: window.transcript).isEmpty)
            await runtime.shutdown()
        }
    }

    @Test("/tasks in a turn shows its card once, even when the snapshot's graph is stale: the explicit overview never reaches the reducer")
    func tasksCommandInATurnShowsOneCard() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            let orchestrator = await window.runner.taskOrchestrator
            let sessionID = window.current.sessionID
            try? await orchestrator.registerSession(id: sessionID, workingDirectory: workspace)

            await backend.hold()
            window.draft = "Busy"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })

            // Without the observer the snapshot keeps its old graph (none): a
            // significant graph created now reaches no automatic overview, so
            // it shows no card of the turn.
            await window.current.controller.stopTaskGraphObserver()
            _ = try await orchestrator.createTasks(
                sessionID: sessionID,
                tasks: [TaskDefinition(title: "A"), TaskDefinition(title: "B")]
            )
            let before = ChatSessionNotice.help(commandHelp: ["Before /tasks"])
            await Self.present(before, in: window.sessionHost, slotID: window.slotID)
            #expect(await eventually { window.transcript.contains { $0.content == .notice(before) } })
            #expect(Self.taskCards(in: window.transcript).isEmpty)
            #expect(window.snapshot?.taskGraph == nil)

            // /tasks beside the turn: exactly one card, the graph it read,
            // after its echo. The snapshots reach the window in order, so the
            // row presented after the card is behind any snapshot the explicit
            // overview would have produced.
            window.draft = "/tasks"
            window.submitDraft()
            #expect(await eventually { !Self.taskCards(in: window.transcript).isEmpty })
            let after = ChatSessionNotice.help(commandHelp: ["After /tasks"])
            await Self.present(after, in: window.sessionHost, slotID: window.slotID)
            #expect(await eventually { window.transcript.contains { $0.content == .notice(after) } })
            let cards = Self.taskCards(in: window.transcript)
            #expect(cards.count == 1)
            let card = try #require(cards.first)
            #expect(Self.taskCount(card) == 2)
            let echo = try #require(window.transcript.lastIndex { $0.content == .commandLine("/tasks") })
            #expect(try #require(Self.index(of: card, in: window.transcript)) > echo)
            // The explicit overview is the presenter's: the snapshot is as it was.
            #expect(window.snapshot?.taskGraph == nil)

            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(Self.taskCards(in: window.transcript).map(\.id) == [card.id])
            #expect(window.snapshot?.taskGraph == nil)
            await runtime.shutdown()
        }
    }

    @Test("After an agent or a model switch a turn still shows its task card: the session created anew gets the observer again, as in the terminal")
    func taskCardAfterTheSessionIsCreatedAnew() async throws {
        let models = Self.defaultModels + [
            AgentSettingsModelManifest(
                id: "zen-app-model-2",
                kind: .remoteAPI,
                modelID: "local/zen-app-model-2"
            ),
        ]
        try await withRuntime(models: models) { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            let orchestrator = await window.runner.taskOrchestrator
            let sessionID = window.current.sessionID

            // An agent switch stops the backend, which ends the graph events
            // of every observer, and creates the session anew.
            window.draft = "/agents tester"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.snapshot?.selection.agent?.id == "tester" })
            #expect(window.current.sessionID == sessionID)
            try? await orchestrator.registerSession(id: sessionID, workingDirectory: workspace)
            await backend.hold()
            window.draft = "After the agent switch"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })
            _ = try await orchestrator.createTasks(
                sessionID: sessionID,
                tasks: [TaskDefinition(title: "A"), TaskDefinition(title: "B")]
            )
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 1 })
            #expect(Self.taskCards(in: window.transcript).first.flatMap(Self.taskCount) == 2)
            await backend.release()
            #expect(await window.waitUntilIdle())

            // A model switch does the same.
            let change = try await window.current.controller.selectModel(id: "zen-app-model-2")
            #expect(change.change == .sessionRecreated)
            #expect(window.current.sessionID == sessionID)
            await backend.hold()
            window.draft = "After the model switch"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "C")])
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 2 })
            #expect(Self.taskCards(in: window.transcript).last.flatMap(Self.taskCount) == 3)
            await backend.release()
            #expect(await window.waitUntilIdle())
            await runtime.shutdown()
        }
    }

    @Test("The window presenter publishes the sub-agent overview around agent.* calls")
    func subAgentOverviewReachesTheReducer() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            await backend.script(prompt: "Delegate", events: [
                .toolCallStarted(DirectAgentToolCall(
                    id: "agent-call", name: "agent.create", argumentsObject: [:], argumentsJSON: "{}"
                )),
                .toolCallCompleted(
                    DirectAgentToolCall(id: "agent-call", name: "agent.create", argumentsObject: [:], argumentsJSON: "{}"),
                    DirectAgentToolResult(output: "created", summary: "created")
                ),
            ])
            await backend.setSubAgents([
                DirectSubAgentRuntime.AgentSnapshot(
                    id: "agent-1",
                    rootSessionID: window.current.sessionID,
                    name: "Worker",
                    status: .running,
                    pending: true,
                    latestOutput: nil,
                    latestError: nil,
                    createdAt: Date(),
                    updatedAt: Date()
                ),
            ])
            window.draft = "Delegate"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.subAgents.snapshots.map(\.id) == ["agent-1"] })
            #expect(window.snapshot?.subAgents.snapshots.map(\.id) == ["agent-1"])
            #expect(window.transcript.contains {
                if case let .toolCall(call, result) = $0.content {
                    return call.name == "agent.create" && result?.output == "created"
                }
                return false
            })
            await runtime.shutdown()
        }
    }

    @Test("The end of a turn publishes the sub-agent overview: a sub-agent that ended after the last agent.* call leaves the card")
    func turnEndPublishesTheSubAgentOverview() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            // Only the end of the turn may publish the ended sub-agent.
            window.pendingSubAgentsInterval = .seconds(3600)
            let root = window.current.sessionID
            let call = DirectAgentToolCall(id: "agent-call", name: "agent.create", argumentsObject: [:], argumentsJSON: "{}")
            await backend.script(prompt: "Delegate", events: [
                .toolCallStarted(call),
                .toolCallCompleted(call, DirectAgentToolResult(output: "created", summary: "created")),
            ])
            await backend.setSubAgents([Self.overviewSubAgent(root: root, status: .running, pending: true)])
            await backend.setSubAgentsAfterNextScript([Self.overviewSubAgent(root: root, status: .standby, pending: false)])
            window.draft = "Delegate"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.subAgents.snapshots.map(\.status) == [.standby] })
            #expect(window.subAgents.snapshots.map(\.pending) == [false])
            await runtime.shutdown()
        }
    }

    @Test("A sub-agent that ends after the turn, with no tool call, leaves the card; then the window stops publishing")
    func subAgentEndingAfterTheTurnLeavesTheCard() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            window.pendingSubAgentsInterval = .milliseconds(20)
            let root = window.current.sessionID
            let call = DirectAgentToolCall(id: "agent-call", name: "agent.create", argumentsObject: [:], argumentsJSON: "{}")
            await backend.script(prompt: "Delegate", events: [
                .toolCallStarted(call),
                .toolCallCompleted(call, DirectAgentToolResult(output: "created", summary: "created")),
            ])
            await backend.setSubAgents([Self.overviewSubAgent(root: root, status: .running, pending: true)])
            window.draft = "Delegate"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.subAgents.snapshots.map(\.pending) == [true] })
            #expect(!window.isGenerating)
            #expect(window.pendingSubAgentsFollow != nil)

            // The sub-agent ends with its last answer: no tool call, no turn.
            await backend.setSubAgents([Self.overviewSubAgent(root: root, status: .standby, pending: false)])
            #expect(await eventually { window.subAgents.snapshots.map(\.status) == [.standby] })
            #expect(window.snapshot?.subAgents.snapshots.map(\.pending) == [false])
            // No sub-agent at work: the window stops publishing.
            #expect(await eventually { window.pendingSubAgentsFollow == nil })
            await runtime.shutdown()
        }
    }

    /// The sub-agent `agent-1` of the root session `root`.
    private static func overviewSubAgent(
        root: String,
        status: DirectSubAgentRuntime.Status,
        pending: Bool
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-1",
            rootSessionID: root,
            name: "Worker",
            status: status,
            pending: pending,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("/artifacts shows and hides the artifacts sidebar, beside a running turn too; with arguments it answers the core's notice")
    func artifactsTogglesTheSidebar() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(!window.isArtifactsSidebarPresented)
            #expect(window.fileArtifacts.isEmpty)

            // The toolbar and the menu toggle it directly.
            window.toggleArtifactsSidebar()
            #expect(window.isArtifactsSidebarPresented)
            window.toggleArtifactsSidebar()
            #expect(!window.isArtifactsSidebarPresented)

            // /artifacts shows it, then hides it: its echo, and no artifact notice.
            window.draft = "/artifacts"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(await window.waitUntilIdle())
            #expect(window.isArtifactsSidebarPresented)
            #expect(window.transcript.contains { $0.content == .commandLine("/artifacts") })
            window.run("/artifacts")
            #expect(await window.waitUntilIdle())
            #expect(!window.isArtifactsSidebarPresented)
            #expect(window.transcript.filter { $0.content == .commandLine("/artifacts") }.count == 2)
            #expect(!window.transcript.contains { Self.isArtifactHistoryNotice($0.content) })

            // With arguments: the core's notice, and no toggle.
            window.draft = "/artifacts all"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.contains { $0.content == .notice(.artifactsTakeNoArguments) }
            })
            #expect(window.transcript.contains { $0.content == .commandLine("/artifacts all") })
            #expect(!window.isArtifactsSidebarPresented)

            // While a turn runs, /artifacts runs beside it instead of being refused.
            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(window.isBusy)
            window.draft = "/artifacts"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(window.queuedLines.isEmpty)
            #expect(await eventually { window.isArtifactsSidebarPresented })
            #expect(!window.transcript.contains {
                if case .local(_, isFailure: true) = $0.content { return true }
                return false
            })
            await backend.release()
            #expect(await window.waitUntilIdle())

            // A new session keeps the sidebar as the operator left it.
            let firstEpoch = window.current.epoch
            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.current.epoch != firstEpoch && window.snapshot?.epoch == window.current.epoch })
            #expect(window.isArtifactsSidebarPresented)
            #expect(window.fileArtifacts.isEmpty)
            #expect(!window.transcript.contains { Self.isArtifactHistoryNotice($0.content) })
            await runtime.shutdown()
        }
    }

    /// The task-graph cards of `transcript`, in order.
    private static func taskCards(in transcript: [ZenTranscriptItem]) -> [ZenTranscriptItem] {
        transcript.filter {
            if case .taskGraph = $0.content { return true }
            return false
        }
    }

    /// The number of tasks of the card `item`; `nil` for another row.
    private static func taskCount(_ item: ZenTranscriptItem) -> Int? {
        guard case let .taskGraph(overview) = item.content else { return nil }
        return overview.graph.tasks.count
    }

    /// The index of the row with `item`'s id in `transcript`.
    private static func index(of item: ZenTranscriptItem, in transcript: [ZenTranscriptItem]) -> Int? {
        transcript.firstIndex { $0.id == item.id }
    }

    /// Presents `notice` on the reducer of `slotID`: a log row that arrives
    /// while a turn runs.
    @ChatSessionActor
    private static func present(_ notice: ChatSessionNotice, in sessionHost: ChatSessionHost, slotID: ChatSlotID) async {
        await sessionHost.reducer(in: slotID)?.presentSessionNotice(notice)
    }

    /// `true` for the notices of the shared `/artifacts`, which writes the
    /// artifact history in the transcript.
    private static func isArtifactHistoryNotice(_ content: ZenTranscriptItem.Content) -> Bool {
        guard case let .notice(notice) = content else { return false }
        switch notice {
        case .fileArtifacts, .noFileArtifacts:
            return true
        default:
            return false
        }
    }
}
