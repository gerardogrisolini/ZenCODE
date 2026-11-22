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
@testable import ZenCODERuntime

@Suite("Chat session state", .serialized, .timeLimit(.minutes(2)))
struct ChatSessionStateTests {
    // MARK: - Sequence

    @Test
    func sequencesStrictlyIncreaseAcrossTurnsNoticesAndSessions() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let reducer = ChatSessionStateReducer(
                sessionID: controller.sessionID,
                workingDirectory: controller.workingDirectory,
                defaultOrigin: .local,
                state: controller.sessionState
            )
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
            let reducer = ChatSessionStateReducer(
                sessionID: controller.sessionID,
                workingDirectory: controller.workingDirectory,
                defaultOrigin: .local,
                state: controller.sessionState
            )
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
            let reducer = ChatSessionStateReducer(
                sessionID: controller.sessionID,
                workingDirectory: controller.workingDirectory,
                defaultOrigin: .acp,
                state: controller.sessionState
            )
            controller.addObserver(reducer)
            try await harness.startSession()
            let sessionID = controller.sessionID
            let workspace = controller.workingDirectory.path
            let prompter = RecordingChatPresenter(name: "acp-prompt")

            await harness.runtime.append { call in
                let read = Self.toolCall(id: "acp-read", name: "local.read")
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
                    AgentRuntimeToolCall(id: nil, name: "local.read", argumentsJSON: #"{"path":"a"}"#),
                    AgentRuntimeToolCall(id: "late", name: "local.exec", argumentsJSON: #"{"command":"make"}"#),
                ]
            ),
            // By name first, then in order.
            AgentRuntimeMessage(role: .tool, content: "body of a", toolName: "local.read"),
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
                id: "restored-tool-1-1", name: "local.read", argumentsJSON: #"{"path":"a"}"#
            )),
            .init(turn: 1, entry: .toolCallStarted(id: "late", name: "local.exec", argumentsJSON: #"{"command":"make"}"#)),
            .init(turn: 1, entry: .toolCallCompleted(
                id: "restored-tool-1-1", name: "local.read", output: "body of a", attachments: []
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
            let reducer = ChatSessionStateReducer(
                sessionID: controller.sessionID,
                workingDirectory: controller.workingDirectory,
                defaultOrigin: .local,
                state: controller.sessionState
            )
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
}
