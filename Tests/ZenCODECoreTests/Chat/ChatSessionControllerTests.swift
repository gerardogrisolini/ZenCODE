//
//  ChatSessionControllerTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

/// Exercises `ChatSessionController` against a scripted `ChatSessionRuntime`,
/// a recording presenter, and a scripted interaction host. No model, network,
/// or terminal is involved: each test scripts the runtime events of a turn and
/// asserts what the controller presents, records, and refuses to write back.
@Suite
struct ChatSessionControllerTests {
    // MARK: - Presentation order

    @Test
    func presenterReceivesEventsInRuntimeOrderAndFinalBlockFollowsTheLastTool() async throws {
        try await withHarness { harness in
            await harness.runtime.append { call in
                let read = scriptedToolCall(id: "tool-read", name: "local.readFile")
                let list = scriptedToolCall(id: "tool-list", name: "local.ls")
                let output = DirectAgentToolResult(output: "ok", summary: "ok")
                await call.onEvent(.thought("Planning the reads. "))
                await call.onEvent(.content("Let me "))
                await call.onEvent(.content("check."))
                await call.onEvent(.toolCallStarted(read))
                await call.onEvent(.toolCallCompleted(read, output))
                await call.onEvent(.content("Now listing."))
                await call.onEvent(.toolCallStarted(list))
                await call.onEvent(.toolCallCompleted(list, output))
                await call.onEvent(.thought("Wrapping up."))
                await call.onEvent(.content("Final "))
                await call.onEvent(.content("answer."))
                await call.onEvent(.turnEnded(.completed))
                return DirectAgentResponse(
                    text: "Let me check.Now listing.Final answer.",
                    stopReason: "end_turn",
                    modelID: "scripted-model"
                )
            }

            let result = try await harness.controller.runTurn(harness.request("Inspect the project"))

            #expect(await harness.presenter.events == [
                .turnWillStart(prompt: "Inspect the project"),
                .thought("Planning the reads. "),
                .content("Let me "),
                .content("check."),
                .toolStarted("tool-read"),
                .toolCompleted("tool-read"),
                .toolSettled("tool-read"),
                .content("Now listing."),
                .toolStarted("tool-list"),
                .toolCompleted("tool-list"),
                .toolSettled("tool-list"),
                .thought("Wrapping up."),
                .content("Final "),
                .content("answer."),
                .turnEnded(.completed),
                .modelTurnDidReturn,
                .turnWillFinish,
            ])
            // The runtime's aggregate text is not the final block: only the
            // content after the last tool call is.
            #expect(result.response.text == "Let me check.Now listing.Final answer.")
            #expect(result.finalAssistantBlock == "Final answer.")
            #expect(result.fileChangeSummary == nil)
            #expect(result.automaticallyCompletedPlan == nil)
            #expect(harness.controller.lastFileChangeSummary == nil)

            let transcript = harness.controller.transcript
            #expect(transcript.map(\.role) == [
                .user, .assistant, .assistant, .tool, .assistant, .assistant, .tool, .assistant,
            ])
            #expect(transcript.first?.content == "Inspect the project")
            #expect(transcript.map(\.content).filter { !$0.isEmpty && $0 != "ok" }
                == ["Inspect the project", "Let me check.", "Now listing.", "Final answer."])
            #expect(transcript.last?.reasoningContent == "Wrapping up.")
        }
    }

    // MARK: - Tool call preview

    @Test
    func aToolCallPreviewReachesThePresenterInStreamOrderAndLeavesNoTraceInTheSession() async throws {
        let preview: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.writeFile"),
            .parameterStarted(name: "path"),
            .parameterText("Notes"),
            .parameterText(".md"),
            .parameterEnded,
            .parameterStarted(name: "content"),
            .parameterText("# Title\n"),
            .parameterEnded,
            .ended,
        ]

        let withPreview = try await observeWriteTurn(preview: preview)
        let withoutPreview = try await observeWriteTurn(preview: [])

        // The fragments reach the presenter as the model wrote them: after the
        // content that preceded the call and before the call itself starts.
        var expectedEvents: [RecordingChatPresenter.Event] = [
            .turnWillStart(prompt: "Write the notes"),
            .content("Writing the notes."),
        ]
        expectedEvents += preview.map { .toolPreview($0) }
        expectedEvents += [
            .toolStarted("tool-write"),
            .toolCompleted("tool-write"),
            .toolSettled("tool-write"),
            .content("Done."),
            .turnEnded(.completed),
            .modelTurnDidReturn,
            .turnWillFinish,
        ]
        #expect(withPreview.events == expectedEvents)

        // Beyond the fragments themselves the presenter sees what it sees
        // without them, and the session keeps no trace of them: neither the
        // transcript nor the history nor the session state differ.
        let withoutFragments = withPreview.events.filter {
            if case .toolPreview = $0 { false } else { true }
        }
        #expect(withoutFragments == withoutPreview.events)
        #expect(withPreview.transcript == withoutPreview.transcript)
        #expect(withPreview.transcript.map(\.role) == [.user, .assistant, .assistant, .tool, .assistant])
        #expect(!withPreview.transcript.contains { $0.content.contains("# Title") })
        #expect(withPreview.history == withoutPreview.history)
        #expect(withPreview.stateAfter == withPreview.stateBefore)
        #expect(withPreview.stateAfter == withoutPreview.stateAfter)
        #expect(withPreview.finalAssistantBlock == "Done.")
    }

    @Test
    func aToolCallPreviewReachesTheObserversBeforeThePrimaryWithoutClosingTheBlock() async throws {
        let log = ChatPresentationLog()
        try await withHarness(presentationLog: log) { harness in
            let observer = RecordingChatPresenter(name: "observer", log: log)
            harness.controller.addObserver(observer)
            await harness.runtime.append { call in
                await call.onEvent(.toolCallPreview(.toolStarted(name: "local.writeFile")))
                await call.onEvent(.toolCallPreview(.ended))
                await call.onEvent(.turnEnded(.completed))
                return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "scripted-model")
            }

            _ = try await harness.controller.runTurn(harness.request("Write"))

            let previews = log.entries.filter {
                if case .toolPreview = $0.event { true } else { false }
            }
            #expect(previews == [
                .init(presenter: "observer", event: .toolPreview(.toolStarted(name: "local.writeFile"))),
                .init(presenter: "primary", event: .toolPreview(.toolStarted(name: "local.writeFile"))),
                .init(presenter: "observer", event: .toolPreview(.ended)),
                .init(presenter: "primary", event: .toolPreview(.ended)),
            ])
        }
    }

    @Test
    func aChannelThatDoesNotRetainTheTranscriptNeverAppendsIt() async throws {
        try await withHarness(retainsTranscript: false) { harness in
            await harness.runtime.append { call in
                await call.onEvent(.content("answer"))
                return DirectAgentResponse(text: "answer", stopReason: "end_turn", modelID: "m")
            }

            let result = try await harness.controller.runTurn(harness.request("Question"))

            #expect(result.finalAssistantBlock == "answer")
            #expect(harness.controller.transcript.isEmpty)
        }
    }

    // MARK: - Observers

    @Test
    func observersPresentEveryTurnEventBeforeThePrimaryInAttachOrder() async throws {
        let log = ChatPresentationLog()
        try await withHarness(presentationLog: log) { harness in
            let first = RecordingChatPresenter(name: "first", log: log)
            let second = RecordingChatPresenter(name: "second", log: log)
            harness.controller.addObserver(first)
            harness.controller.addObserver(second)
            await harness.runtime.append { call in
                let read = scriptedToolCall(id: "tool-read", name: "local.readFile")
                await call.onEvent(.content("Reading."))
                await call.onEvent(.toolCallStarted(read))
                await call.onEvent(.toolCallCompleted(read, DirectAgentToolResult(output: "ok", summary: "ok")))
                await call.onEvent(.content("Done."))
                await call.onEvent(.turnEnded(.completed))
                return DirectAgentResponse(text: "Reading.Done.", stopReason: "end_turn", modelID: "scripted-model")
            }

            _ = try await harness.controller.runTurn(harness.request("Inspect"))

            let turnEvents: [RecordingChatPresenter.Event] = [
                .turnWillStart(prompt: "Inspect"),
                .content("Reading."),
                .toolStarted("tool-read"),
                .toolCompleted("tool-read"),
                .toolSettled("tool-read"),
                .content("Done."),
                .turnEnded(.completed),
                .modelTurnDidReturn,
                .turnWillFinish,
            ]
            // Every event reaches the observers in attach order, then the
            // primary, before the next event starts.
            #expect(log.entries == fannedOut(turnEvents, to: ["first", "second", "primary"]))
            #expect(await first.events == turnEvents)
            #expect(await second.events == turnEvents)
            #expect(await harness.presenter.events == turnEvents)
        }
    }

    @Test
    func observersAddedAndRemovedMidSessionFollowOnlyTheTurnsInBetween() async throws {
        let log = ChatPresentationLog()
        try await withHarness(presentationLog: log) { harness in
            let controller = harness.controller
            let first = RecordingChatPresenter(name: "first", log: log)
            let second = RecordingChatPresenter(name: "second", log: log)

            try await runContentTurn("one", in: harness)
            controller.addObserver(first)
            controller.addObserver(second)
            // Adding an added observer again changes nothing.
            controller.addObserver(first)
            #expect(controller.observers.map { ObjectIdentifier($0) }
                == [ObjectIdentifier(first), ObjectIdentifier(second)])
            try await runContentTurn("two", in: harness)
            controller.removeObserver(first)
            try await runContentTurn("three", in: harness)
            controller.removeObserver(second)
            // Removing an observer that is not added changes nothing.
            controller.removeObserver(first)
            #expect(controller.observers.isEmpty)
            try await runContentTurn("four", in: harness)

            #expect(log.entries
                == fannedOut(contentTurnEvents("one"), to: ["primary"])
                + fannedOut(contentTurnEvents("two"), to: ["first", "second", "primary"])
                + fannedOut(contentTurnEvents("three"), to: ["second", "primary"])
                + fannedOut(contentTurnEvents("four"), to: ["primary"]))
            #expect(await first.events == contentTurnEvents("two"))
            #expect(await second.events == contentTurnEvents("two") + contentTurnEvents("three"))
            // The observers are read at every call: the observed presenter
            // over the controller's own presenter is what the controller
            // presents on, with or without observers.
            #expect(controller.effectivePresenter(for: nil) is ChatObservedPresenter)
        }
    }

    @Test
    func observersPresentAlsoWhenTheRequestBindsItsOwnPresenter() async throws {
        let log = ChatPresentationLog()
        try await withHarness(presentationLog: log) { harness in
            let observer = RecordingChatPresenter(name: "observer", log: log)
            let perTurn = RecordingChatPresenter(name: "request", log: log)
            harness.controller.addObserver(observer)
            await harness.runtime.append { call in
                await call.onEvent(.content("bound to the request"))
                return DirectAgentResponse(text: "bound to the request", stopReason: "end_turn", modelID: "m")
            }

            _ = try await harness.controller.runTurn(harness.request("Hello", presenter: perTurn))

            let turnEvents: [RecordingChatPresenter.Event] = [
                .turnWillStart(prompt: "Hello"),
                .content("bound to the request"),
                .modelTurnDidReturn,
                .turnWillFinish,
            ]
            // The request's presenter is the primary of this turn: the
            // controller's default presenter sees nothing.
            #expect(log.entries == fannedOut(turnEvents, to: ["observer", "request"]))
            #expect(await perTurn.events == turnEvents)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func overviewReservationsAskOnlyThePrimaryAndThePublicationsCarryItsReservation() async throws {
        let log = ChatPresentationLog()
        try await withHarness(presentationLog: log) { harness in
            let observer = RecordingChatPresenter(name: "observer", log: log)
            harness.controller.addObserver(observer)

            // `/tasks` echoes its line on every presenter, but reserves the
            // publication on the primary alone.
            let outcome = await harness.controller.runTasksCommand(line: "/tasks")

            #expect(outcome == ChatCommandOutcome(notices: [.noTaskGraph]))
            #expect(log.entries == fannedOut([.submittedCommand("/tasks")], to: ["observer", "primary"]) + [
                .init(presenter: "primary", event: .taskGraphReservation(ChatOverviewPublication(revision: 1))),
            ])

            log.clear()
            await harness.presenter.setRecordsSubAgentOverviews(true)
            await observer.setRecordsSubAgentOverviews(true)
            let observed = ChatObservedPresenter(primary: harness.presenter, controller: harness.controller)
            let taskGraphPublication = await observed.reserveTaskGraphOverviewPublication()
            await observed.presentTaskGraphOverview(nil, origin: .explicit, publication: taskGraphPublication)
            let subAgentPublication = await observed.reserveSubAgentOverviewPublication()
            let overview = ChatSubAgentOverview(snapshots: [])
            await observed.presentSubAgentOverview(overview, origin: .automatic, publication: subAgentPublication)

            #expect(taskGraphPublication == ChatOverviewPublication(revision: 2))
            #expect(subAgentPublication == ChatOverviewPublication(revision: 1))
            #expect(log.entries == [
                .init(presenter: "primary", event: .taskGraphReservation(taskGraphPublication)),
            ] + fannedOut(
                [.taskGraphOverview(nil, origin: .explicit, publication: taskGraphPublication)],
                to: ["observer", "primary"]
            ) + [
                .init(presenter: "primary", event: .subAgentReservation(subAgentPublication)),
            ] + fannedOut(
                [.subAgentOverview(
                    agentIDs: [],
                    signature: overview.signature,
                    currentBatchID: overview.currentBatchID,
                    origin: .automatic,
                    publication: subAgentPublication
                )],
                to: ["observer", "primary"]
            ))
        }
    }
}

// MARK: - Fixtures

private func scriptedToolCall(id: String, name: String) -> DirectAgentToolCall {
    DirectAgentToolCall(id: id, name: name, argumentsObject: ["path": "."], argumentsJSON: "{}")
}

/// `events` as the log of a fan-out records them: every event on each of
/// `presenters`, in order, before the next event.
private func fannedOut(
    _ events: [RecordingChatPresenter.Event],
    to presenters: [String]
) -> [ChatPresentationLog.Entry] {
    events.flatMap { event in
        presenters.map { ChatPresentationLog.Entry(presenter: $0, event: event) }
    }
}

/// What a presenter records for a turn that ``runContentTurn(_:in:)`` ran.
private func contentTurnEvents(_ text: String) -> [RecordingChatPresenter.Event] {
    [.turnWillStart(prompt: text), .content(text), .modelTurnDidReturn, .turnWillFinish]
}

/// Runs a turn whose prompt is `text` and whose model streams `text` back.
@ChatSessionActor
private func runContentTurn(_ text: String, in harness: ChatControllerHarness) async throws {
    await harness.runtime.append { call in
        await call.onEvent(.content(text))
        return DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "scripted-model")
    }
    _ = try await harness.controller.runTurn(harness.request(text))
}

/// Runs `body` with a throwaway workspace and a task-local support directory,
/// so no test reads or writes the real application state.
func withHarness(
    hostCapabilities: ChatChannelCapabilities = [.toolConsent],
    hostDecisions: [ChatConsentDecision?] = [],
    retainsTranscript: Bool = true,
    presentationLog: ChatPresentationLog? = nil,
    _ body: @escaping @Sendable @ChatSessionActor (ChatControllerHarness) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("chat-session-controller-tests-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable @ChatSessionActor in
        let harness = try ChatControllerHarness(
            workspace: workspace,
            hostCapabilities: hostCapabilities,
            hostDecisions: hostDecisions,
            retainsTranscript: retainsTranscript,
            presentationLog: presentationLog
        )
        try await body(harness)
    }
}

// MARK: - Test doubles

struct ChatControllerHarness: Sendable {
    let workspace: URL
    let sessionID: String
    let runtime: ScriptedChatRuntime
    let host: ScriptedChatInteractionHost
    let authorizer: ChatToolConsentAuthorizer
    let presenter: RecordingChatPresenter
    let controller: ChatSessionController

    init(
        workspace: URL,
        hostCapabilities: ChatChannelCapabilities,
        hostDecisions: [ChatConsentDecision?],
        retainsTranscript: Bool,
        presentationLog: ChatPresentationLog?
    ) throws {
        let sessionID = "chat-session-\(UUID().uuidString.lowercased())"
        let host = ScriptedChatInteractionHost(capabilities: hostCapabilities, decisions: hostDecisions)
        let authorizer = ChatToolConsentAuthorizer(host: host)
        let runtime = ScriptedChatRuntime(
            defaultToolAuthorization: { await authorizer.authorize($0) }
        )
        let presenter = RecordingChatPresenter(name: "primary", log: presentationLog)
        self.workspace = workspace
        self.sessionID = sessionID
        self.runtime = runtime
        self.host = host
        self.authorizer = authorizer
        self.presenter = presenter
        self.controller = ChatSessionController(
            sessionID: sessionID,
            runtime: runtime,
            // Hosted models: the controller never persists a selection.
            environment: ChatSessionEnvironment(
                configuration: try AgentConfiguration(
                    hostedModelID: "scripted-model",
                    availableModels: [],
                    workingDirectory: workspace
                ),
                featureRuntime: nil
            ),
            workingDirectory: workspace,
            presenter: presenter,
            host: host,
            authorizer: authorizer,
            retainsTranscript: retainsTranscript
        )
    }

    func request(
        _ prompt: String,
        purpose: ChatTurnPurpose = .normal,
        attachments: [AgentRuntimeAttachment] = [],
        turnInstructionProvider: (@Sendable () async -> String?)? = nil,
        presenter: (any ChatSessionPresenter)? = nil
    ) -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: prompt,
            attachments: attachments,
            purpose: purpose,
            sessionConfiguration: AgentCoreSessionConfiguration(
                sessionID: sessionID,
                modelID: "scripted-model",
                workingDirectory: workspace,
                systemPrompt: nil,
                cacheKey: nil,
                history: []
            ),
            turnInstructionProvider: turnInstructionProvider,
            presenter: presenter
        )
    }
}

/// What one scripted turn left behind, for comparing a turn that streamed
/// tool-call previews with the same turn without them.
private struct WriteTurnObservation: Sendable {
    let events: [RecordingChatPresenter.Event]
    let transcript: [AgentRuntimeMessage]
    let history: [AgentRuntimeMessage]
    let stateBefore: ChatSessionState
    let stateAfter: ChatSessionState
    let finalAssistantBlock: String?
}

private final class WriteTurnObservationBox: Sendable {
    private let storage = Mutex<WriteTurnObservation?>(nil)

    func store(_ observation: WriteTurnObservation) {
        storage.withLock { $0 = observation }
    }

    var value: WriteTurnObservation? {
        storage.withLock { $0 }
    }
}

/// Runs a turn in which the model writes a file: a sentence, the `preview`
/// fragments of the write call, the call itself, then a closing sentence.
private func observeWriteTurn(
    preview: [DirectAgentToolCallPreview]
) async throws -> WriteTurnObservation {
    let box = WriteTurnObservationBox()
    try await withHarness { harness in
        await harness.runtime.append { call in
            let write = DirectAgentToolCall(
                id: "tool-write",
                name: "local.writeFile",
                argumentsObject: ["path": "Notes.md", "content": "# Title\n"],
                argumentsJSON: "{\"content\":\"# Title\\n\",\"path\":\"Notes.md\"}"
            )
            await call.onEvent(.content("Writing the notes."))
            for fragment in preview {
                await call.onEvent(.toolCallPreview(fragment))
            }
            await call.onEvent(.toolCallStarted(write))
            await call.onEvent(.toolCallCompleted(write, DirectAgentToolResult(output: "ok", summary: "ok")))
            await call.onEvent(.content("Done."))
            await call.onEvent(.turnEnded(.completed))
            return DirectAgentResponse(
                text: "Writing the notes.Done.",
                stopReason: "end_turn",
                modelID: "scripted-model"
            )
        }
        let stateBefore = harness.controller.sessionState

        let result = try await harness.controller.runTurn(harness.request("Write the notes"))

        box.store(WriteTurnObservation(
            events: await harness.presenter.events,
            transcript: harness.controller.transcript,
            history: harness.controller.history,
            stateBefore: stateBefore,
            stateAfter: harness.controller.sessionState,
            finalAssistantBlock: result.finalAssistantBlock
        ))
    }
    return try #require(box.value)
}
