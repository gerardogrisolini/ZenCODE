//
//  ZenCODECommandLineRunnerTests+HeadlessRunner.swift
//  ZenCODE
//
//  Tests for the headless and JSONL session runners driven by a controlled
//  session runner, with the configuration and record decoding helpers they
//  use.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
import Synchronization
import Testing
import ToolCore

extension ZenCODECommandLineRunnerTests {
    @Test
    func jsonlRunnerFramesEachRecordInOneSinkCallAndEscapesMultilineText() async throws {
        let output = Mutex<[Data]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(
                text: "first line\nsecond line",
                stopReason: "stop",
                modelID: "test-model"
            ),
            events: [.content("first line\nsecond line"), .turnEnded(.completed)]
        )
        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: true),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            jsonlSink: { data in output.withLock { $0.append(data) } }
        )

        let writes = output.withLock { $0 }
        #expect(writes.count == 3)
        #expect(writes.allSatisfy { $0.last == 0x0A })
        #expect(writes.allSatisfy { data in data.dropLast().allSatisfy { $0 != 0x0A } })
        let records = try decodeRecords(writes)
        #expect(records.map { $0.objectValue?["type"]?.stringValue } == [
            "run.started", "message.completed", "run.completed"
        ])
        #expect(records[1].objectValue?["text"]?.stringValue == "first line\nsecond line")
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func failedToolEventIsNonTerminalAndRunStillCompletes() async throws {
        let output = Mutex<[Data]>([])
        let toolCall = DirectAgentToolCall(
            id: "tool-1",
            name: "local.read",
            argumentsObject: ["path": "/private/input"],
            argumentsJSON: "{\"path\":\"/private/input\"}"
        )
        let toolResult = DirectAgentToolResult(
            output: "private failure detail",
            summary: "private summary",
            status: .failed
        )
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "recovered", stopReason: "stop", modelID: "test"),
            events: [
                .toolCallStarted(toolCall),
                .toolCallCompleted(toolCall, toolResult),
                .turnEnded(.completed)
            ]
        )

        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: true),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            jsonlSink: { data in output.withLock { $0.append(data) } }
        )

        let records = try decodeRecords(output.withLock { $0 })
        #expect(records.map { $0.objectValue?["type"]?.stringValue } == [
            "run.started", "tool.started", "tool.completed", "message.completed", "run.completed"
        ])
        #expect(records[2].objectValue?["status"]?.stringValue == "failed")
        #expect(!records.contains { $0.objectValue?["type"]?.stringValue == "error" })
        let wire = output.withLock { String(decoding: Data($0.joined()), as: UTF8.self) }
        #expect(!wire.contains("private failure detail"))
        #expect(!wire.contains("private summary"))
    }

    @Test
    func emptyJSONLResponseClosesOnceAndEmitsOneTerminalError() async throws {
        let output = Mutex<[Data]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: " \n ", stopReason: "stop", modelID: "test")
        )

        await #expect(throws: ZenCODEHeadlessRunnerError.self) {
            try await ZenCODEHeadlessRunner.runTurn(
                configuration: makeHeadlessConfiguration(jsonl: true),
                prompt: "hello",
                sessionRunner: runner,
                sessionConfiguration: makeSessionConfiguration(),
                jsonlSink: { data in output.withLock { $0.append(data) } }
            )
        }

        let records = try decodeRecords(output.withLock { $0 })
        #expect(records.map { $0.objectValue?["type"]?.stringValue } == ["run.started", "error"])
        #expect(records[1].objectValue?["category"]?.stringValue == "runtime")
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func teardownFailureEmitsNoSuccessAndDoesNotCloseTwice() async throws {
        let output = Mutex<[Data]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "would succeed", stopReason: "stop", modelID: "test"),
            failure: .close
        )

        await #expect(throws: ControlledHeadlessSessionRunner.Failure.self) {
            try await ZenCODEHeadlessRunner.runTurn(
                configuration: makeHeadlessConfiguration(jsonl: true),
                prompt: "hello",
                sessionRunner: runner,
                sessionConfiguration: makeSessionConfiguration(),
                jsonlSink: { data in output.withLock { $0.append(data) } }
            )
        }

        let records = try decodeRecords(output.withLock { $0 })
        #expect(records.map { $0.objectValue?["type"]?.stringValue } == ["run.started", "error"])
        #expect(records[1].objectValue?["category"]?.stringValue == "runtime")
        #expect(records[1].objectValue?["message"]?.stringValue == "The session could not be finalized cleanly.")
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func legacyHeadlessRunnerStillWritesOnlyFinalTextWithOneTrailingNewline() async throws {
        let textOutput = Mutex<[String]>([])
        let jsonlOutput = Mutex<[Data]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "legacy\ntext", stopReason: "stop", modelID: "test"),
            events: [.status("hidden"), .content("hidden stream"), .turnEnded(.completed)]
        )

        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: false),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            jsonlSink: { data in jsonlOutput.withLock { $0.append(data) } },
            textSink: { text in textOutput.withLock { $0.append(text) } }
        )

        #expect(jsonlOutput.withLock { $0.isEmpty })
        #expect(textOutput.withLock { $0 } == ["legacy\ntext\n"])
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func legacyHeadlessPreservesSuccessWhenTeardownFails() async throws {
        let textOutput = Mutex<[String]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "legacy output", stopReason: "stop", modelID: "test"),
            failure: .close
        )

        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: false),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            textSink: { text in textOutput.withLock { $0.append(text) } }
        )

        #expect(textOutput.withLock { $0 } == ["legacy output\n"])
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func headlessTurnInstallsTheSelectedPromptSkillsWhenItCreatesTheSession() async throws {
        let skill = PromptSkill(
            canonicalName: "review",
            title: "Review",
            summary: "Review changes.",
            promptBody: "Review the changes.",
            sourceHash: "review-hash"
        )
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "done", stopReason: "stop", modelID: "test")
        )

        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: false),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            promptSkills: [skill],
            textSink: { _ in }
        )

        #expect(await runner.promptSkillsAtCreation() == [skill])
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func mailDeliveryCaptureReceivesTheSameJSONLRecordsAsStandardOutput() async throws {
        func runJSONLTurn(into sink: @escaping ZenCODEHeadlessJSONLWriter.Sink) async throws {
            try await ZenCODEHeadlessRunner.runTurn(
                configuration: makeHeadlessConfiguration(jsonl: true),
                prompt: "hello",
                sessionRunner: ControlledHeadlessSessionRunner(
                    response: DirectAgentResponse(text: "first\nsecond", stopReason: "stop", modelID: "test"),
                    events: [.content("first\nsecond"), .turnEnded(.completed)]
                ),
                sessionConfiguration: makeSessionConfiguration(),
                jsonlSink: sink,
                textSink: { _ in Issue.record("JSONL mode must not write text") }
            )
        }
        let reference = Mutex<[Data]>([])
        try await runJSONLTurn { data in reference.withLock { $0.append(data) } }
        let output = ZenCronCapturedOutput()
        try await runJSONLTurn { data in output.append(data) }

        // Each run has its own run_id; everything else is byte-identical.
        func normalized(_ writes: [Data]) throws -> [String] {
            let runID = try #require(
                try decodeRecords(writes).first?.objectValue?["run_id"]?.stringValue
            )
            return writes.map {
                String(decoding: $0, as: UTF8.self).replacingOccurrences(of: runID, with: "<run>")
            }
        }
        let chunks = output.chunks
        #expect(chunks.allSatisfy { $0.stream == .standardOutput })
        #expect(try normalized(chunks.map(\.data)) == normalized(reference.withLock { $0 }))
        #expect(try decodeRecords(chunks.map(\.data)).map { $0.objectValue?["type"]?.stringValue } == [
            "run.started", "message.completed", "run.completed"
        ])
    }

    func makeHeadlessConfiguration(jsonl: Bool) throws -> AgentConfiguration {
        try AgentConfiguration(
            hostedModelID: "test-model",
            runMode: .headless,
            jsonl: jsonl,
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }

    private func makeSessionConfiguration() -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: "headless-test-session",
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: []
        )
    }

    private func decodeRecords(_ writes: [Data]) throws -> [JSONValue] {
        try writes.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
    }
}

private actor ControlledHeadlessSessionRunner: ZenCODEHeadlessSessionRunning {
    enum Failure: Error, Equatable {
        case create
        case send
        case close
    }

    private let response: DirectAgentResponse
    private let events: [DirectAgentEvent]
    private let failure: Failure?
    private var calls: [String] = []
    private var createdPromptSkills: [PromptSkill]?

    init(
        response: DirectAgentResponse,
        events: [DirectAgentEvent] = [],
        failure: Failure? = nil
    ) {
        self.response = response
        self.events = events
        self.failure = failure
    }

    func headlessCreateSession(
        configuration _: AgentCoreSessionConfiguration,
        promptSkills: [PromptSkill]
    ) async throws {
        calls.append("create")
        createdPromptSkills = promptSkills
        if failure == .create { throw Failure.create }
    }

    func sendPrompt(
        configuration _: AgentCoreSessionConfiguration,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        authorizeTool _: AgentToolAuthorizationHandler?,
        onToolWillExecute _: (@Sendable (DirectAgentToolCall) async -> Void)?,
        toolProviders _: [AgentToolProvider],
        turnInstruction _: String?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        calls.append("send")
        if failure == .send { throw Failure.send }
        for event in events {
            await onEvent(event)
        }
        return response
    }

    nonisolated let taskOrchestrator = SessionTaskOrchestrator()

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        []
    }

    func closeSubAgent(id _: String) async -> Bool {
        false
    }

    func taskGraphSnapshot(
        sessionID _: String,
        graphID _: String?
    ) async throws -> TaskGraphSnapshot? {
        nil
    }

    func removeTaskGraph(id _: String, sessionID _: String) async throws -> TaskGraphSnapshot {
        throw Failure.send
    }

    func snapshotSession(id _: String) async -> AgentRuntimeSessionSnapshot? {
        nil
    }

    func currentSessionGeneration(
        for _: String
    ) -> AgentCoreSessionRunner.SessionGeneration? {
        nil
    }

    func replaceSessionHistory(
        id _: String,
        history _: [AgentRuntimeMessage],
        expectedSessionGeneration _: AgentCoreSessionRunner.SessionGeneration
    ) async -> Bool {
        false
    }

    func headlessCloseSession(id _: String) async throws {
        calls.append("close")
        if failure == .close { throw Failure.close }
    }

    func headlessShutdown() async {
        calls.append("shutdown")
    }

    func lifecycle() -> [String] {
        calls
    }

    func promptSkillsAtCreation() -> [PromptSkill]? {
        createdPromptSkills
    }
}
