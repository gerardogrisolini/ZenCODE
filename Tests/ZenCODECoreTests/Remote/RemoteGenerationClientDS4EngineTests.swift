//
//  RemoteGenerationClientDS4EngineTests.swift
//  ZenCODE
//
//  End-to-end tests of the in-process DS4 generation path of
//  `RemoteGenerationClient` with `MockDS4Engine` (no library, no model).
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("RemoteGenerationClient DS4 engine", .serialized)
struct RemoteGenerationClientDS4EngineTests {
    // MARK: - Tool round trip

    @Test
    func theSystemPartCarriesTheToolsPromptWithTheSessionTools() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Plain answer."])
        let client = try await harness.makeClient()

        _ = try await client.sendPrompt(
            sessionID: "session",
            prompt: "Hello",
            attachments: [],
            onEvent: { _ in }
        )

        // The model only knows the native call format and the tool schemas
        // from the tools prompt rendered in the system part of the transcript.
        let first = try #require(harness.engine.transcripts.first)
        let carriesTools = first.contains { operation in
            switch operation {
            case let .renderedChat(text), let .message(_, text):
                text.contains(DS4ClientHarness.toolName) && text.contains("parameter")
            default:
                false
            }
        }
        #expect(carriesTools)
        await client.shutdown()
    }

    @Test
    func toolCallRoundTripExecutesTheToolAndReusesThePromptPrefix() async throws {
        let harness = try DS4ClientHarness()
        let raw = "Let me check." + DS4ClientHarness.dsml41EchoCall("hi")
        harness.mock.enqueueGeneration(["Let me check.", DS4ClientHarness.dsml41EchoCall("hi")])
        harness.mock.enqueueGeneration(["Done: ", "hi"])
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        let response = try await client.sendPrompt(
            sessionID: "session",
            prompt: "Echo hi",
            attachments: [],
            onEvent: recorder.handler
        )

        #expect(response.text.hasPrefix("Let me check."))
        #expect(response.text.hasSuffix("Done: hi"))
        #expect(!response.text.contains("DSML"))
        #expect(response.stopReason == "end_turn")
        #expect(harness.echoedArguments == [#"{"text":"hi"}"#])
        #expect(harness.openCount == 1)

        // The second round prefills only the suffix: the first prompt and the
        // tokens the first round generated are reused.
        let syncs = harness.engine.syncs
        let results = harness.engine.results
        try #require(syncs.count == 2)
        try #require(results.count == 2)
        #expect(syncs[0].cached == 0)
        #expect(syncs[1].cached == syncs[0].cached + syncs[0].suffix + results[0].tokens.count)
        let first = harness.engine.transcripts[0]
        let second = harness.engine.transcripts[1]
        #expect(Array(second.prefix(first.count)) == first)
        // The assistant turn is replayed with the ids the engine committed.
        #expect(second[first.count] == .tokens(results[0].tokens))
        #expect(!second.contains(.renderedChat(raw)))
        #expect(second[first.count + 1] == .endOfSequence)
        guard case let .message(role, observation) = second[first.count + 2] else {
            Issue.record("expected the tool observation after the assistant turn")
            return
        }
        #expect(role == "tool")
        #expect(observation.hasPrefix("Tool result 1 (fixture.echo):\n"))
        #expect(observation.contains("echo: "))
        #expect(second.last == .assistantPrefix(mode: DS4EngineABI.ThinkMode.none))

        // Snapshot: visible text and structured tool call, no native markup.
        let snapshot = try #require(await client.snapshotSession(id: "session"))
        #expect(snapshot.history.map(\.role) == [.user, .assistant, .tool, .assistant])
        let assistant = snapshot.history[1]
        #expect(!assistant.content.contains("DSML"))
        #expect(assistant.toolCalls.map(\.name) == [DS4ClientHarness.toolName])
        #expect(assistant.toolCalls.first?.argumentsJSON == #"{"text":"hi"}"#)
        #expect(snapshot.history[3].content == "Done: hi")

        let started = recorder.events.filter { if case .toolCallStarted = $0 { true } else { false } }
        let completed = recorder.events.filter { if case .toolCallCompleted = $0 { true } else { false } }
        #expect(started.count == 1)
        #expect(completed.count == 1)
        #expect(recorder.diagnostics.contains { $0.hasPrefix("DS4 prefill: 0 cached,") })
        await client.shutdown()
    }

    @Test
    func nextTurnReusesTheKVAndKeepsTheFrozenCurrentTurnMemory() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["First answer."])
        harness.mock.enqueueGeneration(["Second answer."])
        let client = try await harness.makeClient()

        _ = try await MemoryTurnContext.$currentTurnMemoryBlock.withValue("MEMORY BLOCK") {
            try await client.sendPrompt(sessionID: "session", prompt: "first", attachments: [], onEvent: { _ in })
        }
        _ = try await client.sendPrompt(sessionID: "session", prompt: "second", attachments: [], onEvent: { _ in })

        let transcripts = harness.engine.transcripts
        try #require(transcripts.count == 2)
        #expect(transcripts[0].contains(.message(role: "user", content: "first\n\nMEMORY BLOCK")))
        // The memory block stays in the first user message on the next turn,
        // so the whole first prompt is reused.
        #expect(Array(transcripts[1].prefix(transcripts[0].count)) == transcripts[0])
        #expect(transcripts[1].contains(.message(role: "user", content: "second")))
        let syncs = harness.engine.syncs
        let results = harness.engine.results
        try #require(results.count == 2)
        #expect(syncs[1].cached == syncs[0].cached + syncs[0].suffix + results[0].tokens.count)

        // History and snapshots never contain the memory block.
        let snapshot = try #require(await client.snapshotSession(id: "session"))
        #expect(snapshot.history.first?.content == "first")
        await client.shutdown()
    }

    @Test
    func thinkingIsStreamedAsThoughtAndUsesTheDeepSeek41EffortLevel() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Planning", " the answer", "</think>", "Answer"])
        let client = try await harness.makeClient(thinkingSelection: nil)
        let recorder = DS4EventRecorder()

        let response = try await client.sendPrompt(
            sessionID: "session", prompt: "Think", attachments: [], onEvent: recorder.handler
        )

        #expect(response.text == "Answer")
        #expect(recorder.thoughts == "Planning the answer")
        #expect(recorder.content == "Answer")
        let level75 = DS4EngineABI.ThinkMode.levelBase + 75
        #expect(harness.engine.generations.first?.thinkMode == level75)
        let transcript = try #require(harness.engine.transcripts.first)
        #expect(transcript[1] == .thinkPrefix(mode: level75))
        #expect(transcript.last == .assistantPrefix(mode: level75))
        let snapshot = try #require(await client.snapshotSession(id: "session"))
        #expect(snapshot.history.last?.reasoningContent == "Planning the answer")
        await client.shutdown()
    }

    // MARK: - Syntax profiles

    @Test(arguments: [DS4ToolSyntax.dsml, .dsml41, .glm, .qwen])
    func toolCallsRoundTripInEveryNativeSyntax(_ syntax: DS4ToolSyntax) async throws {
        let harness = try DS4ClientHarness(syntax: syntax)
        let call = DS4ToolCallRenderer.renderToolCalls(
            [DS4ToolCallReplay(name: DS4ClientHarness.toolName, argumentsJSON: #"{"text":"hi"}"#)],
            syntax: syntax
        )
        harness.mock.enqueueGeneration([call])
        harness.mock.enqueueGeneration(["Done"])
        let client = try await harness.makeClient()

        let response = try await client.sendPrompt(
            sessionID: "session", prompt: "Echo", attachments: [], onEvent: { _ in }
        )

        #expect(response.text.hasSuffix("Done"))
        #expect(harness.echoedArguments == [#"{"text":"hi"}"#])
        let transcripts = harness.engine.transcripts
        try #require(transcripts.count == 2)
        let first = transcripts[0]
        let second = transcripts[1]
        #expect(Array(second.prefix(first.count)) == first)
        let generatedFirst = try #require(harness.engine.results.first)
        #expect(second[first.count] == .tokens(generatedFirst.tokens))
        // GLM ends assistant turns with the next role marker, the others with EOS.
        let next = second[first.count + 1]
        if syntax.assistantTurnUsesEOS {
            #expect(next == .endOfSequence)
        } else if case let .message(role, _) = next {
            #expect(role == "tool")
        } else {
            Issue.record("GLM turn must be followed by the observation")
        }

        // System part (ds4_agent.c agent_worker_build_system_tokens).
        let systemMessage = DS4TranscriptOperation.message(
            role: "system",
            content: "\n\n" + DS4ClientHarness.systemPrompt
        )
        #expect(first[0] == .begin)
        switch syntax {
        case .dsml:
            #expect(first[1] == .thinkPrefix(mode: DS4EngineABI.ThinkMode.none))
            guard case .renderedChat = first[2] else {
                Issue.record("DSML tools prompt must be rendered chat")
                return
            }
            #expect(first[3] == systemMessage)
        case .dsml41:
            #expect(first[1] == .thinkPrefix(mode: DS4EngineABI.ThinkMode.none))
            #expect(first[2] == .message(role: "system", content: ""))
            guard case .renderedChat = first[3] else {
                Issue.record("DSML 4.1 tools prompt must be rendered chat")
                return
            }
            #expect(first[4] == systemMessage)
        case .glm:
            #expect(first[1] == .thinkPrefix(mode: DS4EngineABI.ThinkMode.none))
            guard case let .message(role, _) = first[2] else {
                Issue.record("GLM tools prompt must be a system message")
                return
            }
            #expect(role == "system")
            #expect(first[3] == systemMessage)
        case .qwen:
            // Qwen: no think prefix; no reasoning-effort text without thinking.
            guard case let .message(role, _) = first[1] else {
                Issue.record("Qwen tools prompt must be a system message")
                return
            }
            #expect(role == "system")
            #expect(first[2] == systemMessage)
        }
        await client.shutdown()
    }

    @Test
    func malformedToolCallIsReturnedAsAnObservationAndRetried() async throws {
        let harness = try DS4ClientHarness()
        let broken = "<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"fixture.echo\">\n"
            + "<｜DSML｜ parameter name=\"text\" string=\"true\">hi"
        harness.mock.enqueueGeneration([broken])
        harness.mock.enqueueGeneration(["Sorry."])
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        let response = try await client.sendPrompt(
            sessionID: "session", prompt: "Echo", attachments: [], onEvent: recorder.handler
        )

        #expect(response.text == "Sorry.")
        #expect(harness.echoedArguments.isEmpty)
        #expect(recorder.diagnostics.contains { $0.contains("could not be parsed") })
        let transcripts = harness.engine.transcripts
        try #require(transcripts.count == 2)
        let first = transcripts[0]
        let second = transcripts[1]
        #expect(Array(second.prefix(first.count)) == first)
        let generatedFirst = try #require(harness.engine.results.first)
        #expect(second[first.count] == .tokens(generatedFirst.tokens))
        #expect(second[first.count + 1] == .endOfSequence)
        guard case let .message(role, observation) = second[first.count + 2] else {
            Issue.record("expected the malformed-call observation")
            return
        }
        #expect(role == "tool")
        #expect(observation.hasPrefix("Tool error: invalid DSML tool call: "))
        #expect(observation.hasSuffix(DS4ToolSyntax.dsml41.syntaxReminder))
        let syncs = harness.engine.syncs
        #expect(syncs[1].cached == syncs[0].cached + syncs[0].suffix + generatedFirst.tokens.count)

        // The observation is private: the snapshot has no orphan tool message.
        let snapshot = try #require(await client.snapshotSession(id: "session"))
        #expect(!snapshot.history.contains { $0.role == .tool })
        await client.shutdown()
    }

    // MARK: - Compaction

    @Test
    func compactsAutomaticallyNearTheContextLimit() async throws {
        let contextSize = 4096
        let harness = try DS4ClientHarness(contextSize: contextSize)
        harness.mock.enqueueGeneration(["ok"])
        var history: [AgentRuntimeMessage] = []
        for index in 0..<24 {
            let text = "Message \(index): " + String(repeating: "detail ", count: 90)
            history.append(AgentRuntimeMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: text))
        }
        let client = try await harness.makeClient(history: history)
        let before = try #require(await client.snapshotSession(id: "session")).history.count
        let recorder = DS4EventRecorder()

        let response = try await client.sendPrompt(
            sessionID: "session", prompt: "continue", attachments: [], onEvent: recorder.handler
        )

        #expect(response.text == "ok")
        #expect(recorder.diagnostics.contains { $0.hasPrefix("DS4 context compacted:") })
        let sync = try #require(harness.engine.syncs.first)
        #expect(sync.cached + sync.suffix < contextSize * DS4CompactionPolicy.softPercent / 100)
        let snapshot = try #require(await client.snapshotSession(id: "session"))
        #expect(snapshot.history.count < before)
        #expect(snapshot.systemPrompt?.contains(AgentConversationCompactionSupport.memorySummaryHeader) == true)
        await client.shutdown()
    }

    @Test
    func throwsContextExhaustedWhenCompactionCannotMakeRoom() async throws {
        let harness = try DS4ClientHarness(contextSize: 4096)
        let client = try await harness.makeClient()

        await #expect {
            _ = try await client.sendPrompt(
                sessionID: "session",
                prompt: String(repeating: "x", count: 20_000),
                attachments: [],
                onEvent: { _ in }
            )
        } throws: { error in
            if case DS4EngineError.contextExhausted(_, let limit) = error {
                return limit == 4096
            }
            return false
        }
        #expect(harness.engine.syncs.isEmpty)
        await client.shutdown()
    }

    @Test
    func generationLimitLeavesTheCompactionReserve() async throws {
        let harness = try DS4ClientHarness(contextSize: 8192)
        harness.mock.enqueueGeneration(["one"])
        harness.mock.enqueueGeneration(["two"])
        let client = try await harness.makeClient()
        _ = try await client.sendPrompt(sessionID: "session", prompt: "a", attachments: [], onEvent: { _ in })

        let generation = try #require(harness.engine.generations.first)
        let sync = try #require(harness.engine.syncs.first)
        let reservePrompt = MockDS4Engine.tokenCount(of: DS4CompactionPolicy.reserveTranscript)
        let reserve = DS4CompactionPolicy.reserveTokens(compactionPromptTokens: reservePrompt, contextSize: 8192)
        #expect(generation.maxTokens == 8192 - (sync.cached + sync.suffix) - reserve)

        let limited = try await harness.makeClient(sessionID: "limited", maxOutputTokens: 100)
        _ = try await limited.sendPrompt(sessionID: "limited", prompt: "b", attachments: [], onEvent: { _ in })
        #expect(harness.engine.generations.last?.maxTokens == 100)
        await client.shutdown()
        await limited.shutdown()
    }

    // MARK: - System prompt reminder

    @Test
    func systemPromptReminderIsRecordedOnceAndReplayedInPlace() async throws {
        let harness = try DS4ClientHarness(contextSize: 400_000)
        harness.mock.enqueueGeneration(["one"])
        harness.mock.enqueueGeneration(["two"])
        let history = [
            AgentRuntimeMessage(role: .user, content: "hi"),
            AgentRuntimeMessage(role: .assistant, content: "hello"),
            AgentRuntimeMessage(role: .user, content: String(repeating: "x", count: 210_000)),
            AgentRuntimeMessage(role: .assistant, content: "ok"),
        ]
        let client = try await harness.makeClient(history: history)
        let recorder = DS4EventRecorder()

        _ = try await client.sendPrompt(sessionID: "session", prompt: "next", attachments: [], onEvent: recorder.handler)
        _ = try await client.sendPrompt(sessionID: "session", prompt: "again", attachments: [], onEvent: { _ in })

        let transcripts = harness.engine.transcripts
        try #require(transcripts.count == 2)
        let first = transcripts[0]
        func isReminder(_ operation: DS4TranscriptOperation) -> Bool {
            if case let .renderedChat(text) = operation {
                return text.hasPrefix("\n\n[System prompt reminder follows.]\n")
                    && text.hasSuffix("[End system prompt reminder.]\n\n")
            }
            return false
        }
        // [... user "next", reminder, system prompt, assistant prefix]
        let count = first.count
        #expect(first[count - 4] == .message(role: "user", content: "next"))
        #expect(isReminder(first[count - 3]))
        #expect(first[count - 2] == .message(role: "system", content: DS4ClientHarness.systemPrompt))
        #expect(recorder.statuses.contains("Re-injecting system prompt reminder..."))
        // The next turn keeps the reminder where it was and adds no other one.
        #expect(Array(transcripts[1].prefix(first.count)) == first)
        #expect(transcripts[1].filter(isReminder).count == 1)
        await client.shutdown()
    }

    // MARK: - Cancellation

    @Test
    func cancellationKeepsThePartialTextInHistory() async throws {
        let harness = try DS4ClientHarness(chunkDelay: .milliseconds(10))
        harness.mock.enqueueGeneration(Array(repeating: "word ", count: 400))
        harness.mock.enqueueGeneration(["after"])
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        let task = Task {
            try await client.sendPrompt(sessionID: "session", prompt: "Talk", attachments: [], onEvent: recorder.handler)
        }
        await ds4Eventually { recorder.content.count >= 20 }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let snapshot = try #require(await client.snapshotSession(id: "session"))
        let partial = try #require(snapshot.history.last)
        #expect(partial.role == .assistant)
        #expect(partial.content.hasPrefix("word word"))
        #expect(partial.content.count < 400 * 5)

        // The partial turn is replayed verbatim - with its committed token
        // ids - on the next turn.
        _ = try await client.sendPrompt(sessionID: "session", prompt: "Go on", attachments: [], onEvent: { _ in })
        let syncs = harness.engine.syncs
        try #require(syncs.count == 2)
        let partialTokens = try #require(harness.engine.results.first).tokens
        #expect(!partialTokens.isEmpty)
        #expect(harness.engine.transcripts[1].contains(.tokens(partialTokens)))
        #expect(syncs[1].cached == syncs[0].cached + syncs[0].suffix + partialTokens.count)
        await client.shutdown()
    }

    @Test
    func interruptedSyncLeavesHistoryUnchanged() async throws {
        let harness = try DS4ClientHarness(syncDelay: .seconds(30))
        let client = try await harness.makeClient()

        let task = Task {
            try await client.sendPrompt(sessionID: "session", prompt: "Hello", attachments: [], onEvent: { _ in })
        }
        await ds4Eventually { await harness.registry.activeLeaseSessionID == "session" }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let snapshot = try #require(await client.snapshotSession(id: "session"))
        #expect(snapshot.history.map(\.role) == [.user])
        #expect(harness.engine.generations.isEmpty)
        #expect(await harness.registry.isGenerationLockHeld == false)
        await client.shutdown()
    }

    // MARK: - Sub-agents

    @Test
    func subAgentOnTheSameModelSharesTheEngineAndTheFIFOLock() async throws {
        let gate = MockDS4Gate()
        let harness = try DS4ClientHarness(generationGate: gate)
        harness.mock.enqueueGeneration(["root answer"])
        harness.mock.enqueueGeneration(["child answer"])
        let root = try await harness.makeClient()
        let factory = await root.toolExecutor.subAgentRuntime.backendFactory
        let child = try #require(
            try factory(DirectSubAgentRuntime.BackendContext(
                requestedName: "child",
                requestedRole: "worker",
                profile: nil
            )) as? RemoteGenerationClient
        )
        let childGeneration = try #require(await child.ds4Generation)
        #expect(childGeneration.registry === harness.registry)
        #expect(childGeneration.manifest == harness.manifest)
        await harness.installTool(on: child)
        await child.createSession(
            id: "child-session",
            cwd: harness.base.path,
            systemPrompt: DS4ClientHarness.systemPrompt,
            allowedToolNames: [DS4ClientHarness.toolName],
            thinkingSelection: .off
        )

        let rootTask = Task {
            try await root.sendPrompt(sessionID: "session", prompt: "root", attachments: [], onEvent: { _ in })
        }
        try await harness.mock.generationStarted.wait()
        let childTask = Task {
            try await child.sendPrompt(sessionID: "child-session", prompt: "child", attachments: [], onEvent: { _ in })
        }
        // The child waits for the root's lease (FIFO generation lock).
        await ds4Eventually { await harness.registry.queuedLeaseCount == 1 }
        #expect(harness.engine.generations.map(\.sessionID) == ["session"])
        gate.open()

        #expect(try await rootTask.value.text == "root answer")
        #expect(try await childTask.value.text == "child answer")
        #expect(harness.openCount == 1)
        #expect(harness.engine.generations.map(\.sessionID) == ["session", "child-session"])

        // Shutting the child down frees only its own session.
        await child.shutdown()
        #expect(harness.mock.calls.contains(.releaseSession("child-session")))
        #expect(!harness.mock.calls.contains(.releaseSession("session")))
        #expect(!harness.mock.isClosed)
        await root.shutdown()
    }

    @Test
    func subAgentOnARemoteProviderDoesNotUseTheEngine() async throws {
        let harness = try DS4ClientHarness()
        let root = try await harness.makeClient()
        let factory = await root.toolExecutor.subAgentRuntime.backendFactory
        let remoteProvider = AgentRemoteProvider(
            name: "Ordinary remote",
            baseURL: "https://ordinary-provider.invalid/v1",
            modelID: "remote-model",
            chatEndpoint: .chatCompletions,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .apiKeyRequired
        )
        let remoteSelection = AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: remoteProvider.modelID,
            remoteProvider: remoteProvider,
            apiKey: "remote-key",
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingOptions: nil,
            thinkingSelection: nil
        )
        let child = try #require(
            try factory(DirectSubAgentRuntime.BackendContext(
                requestedName: "remote-child",
                requestedRole: "worker",
                profile: nil,
                modelBinding: nil,
                modelSelection: remoteSelection,
                modelID: remoteSelection.modelID
            )) as? RemoteGenerationClient
        )

        #expect(await child.ds4Generation == nil)
        #expect(await child.provider.id == remoteProvider.id)
        #expect(await child.apiKey == "remote-key")
        #expect(harness.openCount == 0)
        await child.shutdown()
        await root.shutdown()
    }

    // MARK: - Lifecycle, events, configuration

    @Test
    func preloadOpensTheEngineAndPublishesExactContextWindows() async throws {
        let harness = try DS4ClientHarness(contextSize: 8192)
        harness.mock.enqueueGeneration(["a", "b", "c"])
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        _ = try await client.sendPrompt(sessionID: "session", prompt: "Hi", attachments: [], onEvent: recorder.handler)

        #expect(recorder.statuses.contains("Loading DS4 model …"))
        #expect(recorder.events.contains { if case .modelLoaded = $0 { true } else { false } })
        let windows = recorder.contextWindows
        let initial = try #require(windows.first)
        #expect(initial.usedTokens == 0)
        #expect(initial.maxTokens == 8192)
        #expect(initial.isApproximate == false)
        let final = try #require(windows.last)
        let sync = try #require(harness.engine.syncs.first)
        #expect(final.usedTokens == sync.cached + sync.suffix + 3)
        #expect(final.maxTokens == 8192)
        #expect(final.isApproximate == false)
        let metrics = recorder.events.compactMap { if case let .metrics(value) = $0 { value } else { nil } }
        #expect(metrics.last?.completionTokenCount == 3)
        #expect(metrics.last?.cachedPromptTokenCount == 0)

        // A second preload neither reopens nor republishes.
        let again = DS4EventRecorder()
        _ = try await client.preloadModel(onEvent: again.handler)
        #expect(again.events.isEmpty)
        #expect(harness.openCount == 1)
        await client.shutdown()
    }

    @Test
    func liveThroughputPrecedesTheFinalSnapshotWhichCarriesTheEngineValues() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.reportedPrefillTokensPerSecond = 640
        harness.mock.reportedGenerationTokensPerSecond = 41.5
        harness.mock.enqueueGeneration(["a", "b", "c"])
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        _ = try await client.sendPrompt(sessionID: "session", prompt: "Hi", attachments: [], onEvent: recorder.handler)

        let metrics = recorder.events.compactMap { if case let .metrics(value) = $0 { value } else { nil } }
        let live = metrics.filter(\.isLiveProgress)
        for event in live {
            #expect(event.promptTokenCount == nil)
            #expect(event.completionTokenCount == nil)
            #expect(!event.replacesPreviousMetrics)
        }
        // `prefill_start` of the sync announces the whole suffix at once.
        let sync = try #require(harness.engine.syncs.first)
        let started = try #require(live.first?.throughput)
        #expect(started.phase == .prefill)
        #expect(started.processedTokens == 0)
        #expect(started.targetTokens == sync.suffix)
        #expect(started.prefillTokensPerSecond == nil)
        // The exact prefill speed of the engine switches the label to
        // generation before the first token, and every later update keeps it.
        let generationUpdates = live.compactMap(\.throughput).filter { $0.phase == .generation }
        let beforeFirstToken = try #require(generationUpdates.first)
        #expect(beforeFirstToken.prefillTokensPerSecond == 640)
        #expect(beforeFirstToken.generationTokensPerSecond == nil)
        for update in generationUpdates {
            #expect(update.prefillTokensPerSecond == 640)
            #expect(update.processedTokens == nil)
            #expect(update.targetTokens == nil)
        }
        // The consumer is drained before the final snapshot: nothing live
        // arrives after it.
        let final = try #require(metrics.last)
        #expect(!final.isLiveProgress)
        #expect(final.replacesPreviousMetrics)
        #expect(final.completionTokenCount == 3)
        let stats = await harness.mock.stats(sessionID: "session")
        #expect(stats.generatedTokens == 3)
        #expect(stats.generationTokensPerSecond == 41.5)
        #expect(
            final.throughput == DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: 640,
                generationTokensPerSecond: 41.5
            )
        )
        await client.shutdown()
    }

    @Test
    func finalThroughputWithoutAnEngineReportedPrefillSpeedOnlyCarriesTheGenerationSpeed() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.reportedGenerationTokensPerSecond = 41.5
        harness.mock.enqueueGeneration(["a", "b"])
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        _ = try await client.sendPrompt(sessionID: "session", prompt: "Hi", attachments: [], onEvent: recorder.handler)

        let metrics = recorder.events.compactMap { if case let .metrics(value) = $0 { value } else { nil } }
        let final = try #require(metrics.last)
        #expect(
            final.throughput == DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: nil,
                generationTokensPerSecond: 41.5
            )
        )
        // No exact prefill speed: nothing announces it before the first token.
        let generationUpdates = metrics.filter(\.isLiveProgress).compactMap(\.throughput).filter { $0.phase == .generation }
        #expect(generationUpdates.allSatisfy { $0.prefillTokensPerSecond == nil })
        await client.shutdown()
    }

    @Test
    func closeSessionReleasesTheEngineSession() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["ok"])
        let client = try await harness.makeClient()
        _ = try await client.sendPrompt(sessionID: "session", prompt: "Hi", attachments: [], onEvent: { _ in })

        await client.closeSession(id: "session")

        #expect(harness.mock.calls.contains(.releaseSession("session")))
        #expect(harness.mock.liveSessionIDs.isEmpty)
        #expect(!harness.mock.isClosed)
        await client.shutdown()
    }

    @Test
    func validatesWithoutAPIKeyAndUsesSamplingOverrides() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["ok"])
        let overrides = AgentGenerationParameterOverrides(temperature: 0.2, topP: 0.8, topK: 40, minP: 0.05)
        let client = try await harness.makeClient(overrides: overrides)
        try await client.validateConfiguration()
        // A DS4 provider never needs an API key, whatever its auth policy says.
        let keyless = RemoteGenerationClient(
            configuration: harness.runtimeConfiguration(),
            provider: AgentRemoteProvider(
                name: "DS4",
                baseURL: "http://127.0.0.1:8000/v1",
                modelID: "deepseek-v4-flash",
                chatEndpoint: .chatCompletions,
                providerProfileID: .openAI,
                protocolProfileID: .openAIChatCompletions,
                authPolicy: .apiKeyRequired
            ),
            apiKey: nil,
            ds4Generation: DS4LocalGeneration(manifest: harness.manifest, environment: harness.environment)
        )
        try await keyless.validateConfiguration()
        await keyless.shutdown()

        _ = try await client.sendPrompt(sessionID: "session", prompt: "Hi", attachments: [], onEvent: { _ in })

        let sampling = try #require(harness.engine.generations.first?.sampling)
        #expect(sampling == DS4SamplingParameters(temperature: 0.2, topK: 40, topP: 0.8, minP: 0.05))
        #expect(
            RemoteGenerationClient.ds4Sampling(overrides: AgentGenerationParameterOverrides(), syntax: .dsml41)
                == DS4SamplingParameters(temperature: 0.6, topK: 0, topP: 0.95, minP: 0)
        )
        #expect(
            RemoteGenerationClient.ds4Sampling(overrides: AgentGenerationParameterOverrides(), syntax: .glm)
                == DS4SamplingParameters(temperature: 1.0, topK: 0, topP: 0.95, minP: 0)
        )
        await client.shutdown()
    }

    // MARK: - Images

    @Test
    func imagesAreRemovedWithoutAVisionEncoder() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["ok"])
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        _ = try await client.sendPrompt(
            sessionID: "session",
            prompt: "Look",
            attachments: [Self.pngAttachment],
            onEvent: recorder.handler
        )

        #expect(recorder.diagnostics.contains("DS4 model has no vision encoder configured; images were ignored"))
        let snapshot = try #require(await client.snapshotSession(id: "session"))
        #expect(snapshot.history.first?.attachments.isEmpty == true)
        #expect(harness.engine.transcripts.first?.contains(.message(role: "user", content: "Look")) == true)
        await client.shutdown()
    }

    // Images with a vision encoder: `DS4VisionTests.swift`.

    // MARK: - Private keys

    @Test
    func privateKeysStayOutOfSnapshotsAndWirePayloads() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "sys"],
            ["role": "user", "content": "hello", DS4MessageKeys.userContent: "hello\n\nMEMORY"],
            [
                "role": "assistant",
                "content": "Hi",
                "tool_calls": [[
                    "id": "call_1",
                    "type": "function",
                    "function": ["name": "fixture.echo", "arguments": #"{"text":"hi"}"#],
                ]],
                DS4MessageKeys.rawAssistant: "Hi<raw>",
                DS4MessageKeys.rawTokens: [Int32]([11, 22, 33]),
                DS4MessageKeys.rawTokensModel: "41-2-mock-ds4",
                DS4MessageKeys.thinkMode: 0,
                DS4MessageKeys.toolCallReplays: [["name": "fixture.echo", "arguments": #"{"text":"hi"}"#]],
                DS4MessageKeys.toolObservation: "observation",
                DS4MessageKeys.systemReminder: true,
            ],
            ["role": "tool", "tool_call_id": "call_1", "name": "fixture.echo", "content": "out"],
        ]

        let split = RemoteGenerationClient.snapshotMessages(from: messages)
        #expect(split.systemPrompt == "sys")
        #expect(split.history.map(\.content) == ["hello", "Hi", "out"])
        #expect(split.history[1].toolCalls.map(\.name) == ["fixture.echo"])
        // The snapshot is built from the known fields only: no token ids in it.
        let encodedHistory = try? JSONEncoder().encode(split.history)
        let historyJSON = encodedHistory.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!historyJSON.isEmpty)
        #expect(!historyJSON.contains(DS4MessageKeys.prefix))
        #expect(!historyJSON.contains("41-2-mock-ds4"))

        let wire = RemoteGenerationClient.chatCompletionsWireHistoryMessages(from: messages)
        #expect(wire.allSatisfy { message in !message.keys.contains(where: DS4MessageKeys.isPrivate) })
        #expect(wire.count == messages.count)
        #expect(DS4MessageKeys.isPrivate(DS4MessageKeys.rawTokens))
        #expect(DS4MessageKeys.isPrivate(DS4MessageKeys.rawTokensModel))

        // Image stripping and compaction keep the keys of surviving messages.
        let stripped = RemoteGenerationClient.messagesStrippingImageContent(from: messages)
        #expect(stripped[2][DS4MessageKeys.rawAssistant] as? String == "Hi<raw>")
        #expect(DS4MessageKeys.rawTokenIDs(of: stripped[2]) == [11, 22, 33])
        let runtimeMessages = RemoteGenerationClient.agentRuntimeMessages(from: messages)
        let compaction = AgentConversationCompactionResult(
            messages: runtimeMessages,
            wasCompacted: true,
            originalEstimatedTokenCount: 10,
            estimatedTokenCount: 5,
            maxTokens: 100,
            compactedSystemPrompt: "sys + summary",
            keptRecentMessageCount: 2
        )
        let compacted = RemoteGenerationClient.remoteMessages(
            compactionResult: compaction,
            preservingRecentFrom: messages
        )
        #expect(compacted.first?["content"] as? String == "sys + summary")
        #expect(compacted.first?.keys.contains(where: DS4MessageKeys.isPrivate) == false)
        #expect(compacted[1][DS4MessageKeys.rawAssistant] as? String == "Hi<raw>")
        // The token ids travel with the kept message (never to the compacted summary).
        #expect(DS4MessageKeys.rawTokenIDs(of: compacted[1]) == [11, 22, 33])
        #expect(compacted[1][DS4MessageKeys.rawTokensModel] as? String == "41-2-mock-ds4")
    }

    // MARK: - Helpers

    static let pngAttachment = AgentRuntimeAttachment(
        kind: .image,
        data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]),
        contentType: "image/png",
        originalFilename: "image.png"
    )
}
