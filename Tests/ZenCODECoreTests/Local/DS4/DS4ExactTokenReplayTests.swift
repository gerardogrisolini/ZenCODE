//
//  DS4ExactTokenReplayTests.swift
//  ZenCODE
//
//  The turns the engine generates are replayed with the exact token ids it
//  committed (`DS4TranscriptOperation.tokens`), not with a new tokenization of
//  their text: a different BPE split would end the common prefix with the live
//  KV before its end and a model with recurrent state would rebuild the whole
//  prompt ("DS4 prefill: 0 cached"). Mock engine only: no library, no model.
//
//  - client: the round after a tool call (and after a malformed call) replays
//    `.tokens(ids)` with the ids `generate` returned and the sync reuses the
//    whole previous prefix; another model identity falls back to the text;
//  - private keys: `ds4_raw_tokens` / `ds4_raw_tokens_model` live in the
//    messages, never in snapshots;
//  - checkpoint trailer: round trip of the ids, trailers written before them
//    still decode.
//

import Foundation
import Testing
@testable import ZenCODECore

/// What a stored message of a client session says about its generated tokens
/// (a `Sendable` copy of the private keys; the messages themselves cannot
/// leave the client's isolation).
private struct DS4StoredTurn: Sendable {
    let role: String
    let rawAssistant: String?
    let rawTokens: [Int32]?
    let rawTokensModel: String?
    let toolObservation: String?
    let hasToolCalls: Bool
}

extension RemoteGenerationClient {
    fileprivate func ds4StoredTurns(sessionID: String) -> [DS4StoredTurn] {
        guard let lease = sessionLease(for: sessionID), let session = currentSession(for: lease) else {
            return []
        }
        return session.messages.map { message in
            DS4StoredTurn(
                role: DS4TranscriptRenderer.role(of: message),
                rawAssistant: message[DS4MessageKeys.rawAssistant] as? String,
                rawTokens: DS4MessageKeys.rawTokenIDs(of: message),
                rawTokensModel: message[DS4MessageKeys.rawTokensModel] as? String,
                toolObservation: message[DS4MessageKeys.toolObservation] as? String,
                hasToolCalls: message["tool_calls"] != nil
            )
        }
    }

    /// Records that the ids of the last assistant message came from `model`.
    fileprivate func ds4SetLastAssistantTokensModel(_ model: String, sessionID: String) {
        guard let lease = sessionLease(for: sessionID) else {
            return
        }
        mutateSession(for: lease) { session in
            guard let index = session.messages.lastIndex(where: { DS4TranscriptRenderer.role(of: $0) == "assistant" }) else {
                return
            }
            session.messages[index][DS4MessageKeys.rawTokensModel] = model
        }
    }
}

@Suite("DS4 exact token replay", .serialized)
struct DS4ExactTokenReplayTests {
    private static let dsmlCall = DS4ClientHarness.dsml41EchoCall("hi")

    private func turns(of client: RemoteGenerationClient) async -> [DS4StoredTurn] {
        await client.ds4StoredTurns(sessionID: "session")
    }

    private func lastAssistant(in turns: [DS4StoredTurn]) throws -> DS4StoredTurn {
        try #require(turns.last { $0.role == "assistant" })
    }

    // MARK: - Client

    @Test
    func theRoundAfterAToolCallReplaysTheCommittedIDsAndReusesThePreviousPrefix() async throws {
        let harness = try DS4ClientHarness()
        // The ids the model sampled: they need not match any tokenization of the text.
        let sampled: [Int32] = [701, 702]
        harness.mock.enqueueGeneration(MockDS4Engine.ScriptedGeneration(
            chunks: ["Let me check.", Self.dsmlCall], tokens: sampled
        ))
        harness.mock.enqueueGeneration(["Done."])
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        _ = try await client.sendPrompt(
            sessionID: "session", prompt: "Echo hi", attachments: [], onEvent: recorder.handler
        )

        let results = harness.engine.results
        try #require(results.count == 2)
        #expect(results[0].tokens == sampled)
        let transcripts = harness.engine.transcripts
        try #require(transcripts.count == 2)
        let first = transcripts[0]
        let second = transcripts[1]
        #expect(Array(second.prefix(first.count)) == first)
        // Prefix + the turn as ids + EOS + the observation; the text is not tokenized again.
        #expect(second[first.count] == .tokens(sampled))
        #expect(second[first.count + 1] == .endOfSequence)
        #expect(!second.contains(.renderedChat("Let me check." + Self.dsmlCall)))

        // The whole previous state is reused: its prompt and the generated tokens.
        let syncs = harness.engine.syncs
        try #require(syncs.count == 2)
        #expect(syncs[0].cached == 0)
        #expect(syncs[1].cached == MockDS4Engine.tokenCount(of: first) + sampled.count)
        #expect(syncs[1].cached > 0)
        #expect(syncs[1].suffix == MockDS4Engine.tokenCount(of: second) - syncs[1].cached)
        let prefills = recorder.diagnostics.filter { $0.hasPrefix("DS4 prefill:") }
        #expect(prefills == [
            "DS4 prefill: 0 cached, \(syncs[0].suffix) tokens to evaluate",
            "DS4 prefill: \(syncs[1].cached) cached, \(syncs[1].suffix) tokens to evaluate",
        ])

        // The ids and the model that produced them are private keys of the message.
        let assistant = try #require(await turns(of: client).first { $0.role == "assistant" && $0.hasToolCalls })
        #expect(assistant.rawTokens == sampled)
        #expect(assistant.rawTokensModel == harness.engine.info.tokenIdentity)
        await client.shutdown()
    }

    @Test
    func aDifferentModelIdentityFallsBackToTheRawText() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["First answer."])
        harness.mock.enqueueGeneration(["Second answer."])
        let client = try await harness.makeClient()
        _ = try await client.sendPrompt(sessionID: "session", prompt: "first", attachments: [], onEvent: { _ in })
        let produced = try #require(harness.engine.results.first).tokens
        #expect(!produced.isEmpty)

        // The ids were produced by another model (the session was loaded or
        // switched to a different model): this engine must not replay them.
        await client.ds4SetLastAssistantTokensModel("99-4-another-model", sessionID: "session")
        _ = try await client.sendPrompt(sessionID: "session", prompt: "second", attachments: [], onEvent: { _ in })

        let transcripts = harness.engine.transcripts
        try #require(transcripts.count == 2)
        let first = transcripts[0]
        let second = transcripts[1]
        #expect(second[first.count] == .renderedChat("First answer."))
        #expect(!second.contains(.tokens(produced)))
        // Only the previous prompt is shared: the text is tokenized again.
        let syncs = harness.engine.syncs
        #expect(syncs[1].cached == MockDS4Engine.tokenCount(of: first))
        await client.shutdown()
    }

    @Test
    func turnsWithoutStoredIDsKeepReplayingTheirText() async throws {
        // A session restored without ids (an old snapshot): the text fallback.
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Next."])
        let history = [
            AgentRuntimeMessage(role: .user, content: "hi"),
            AgentRuntimeMessage(role: .assistant, content: "hello"),
        ]
        let client = try await harness.makeClient(history: history)

        _ = try await client.sendPrompt(sessionID: "session", prompt: "again", attachments: [], onEvent: { _ in })

        let transcript = try #require(harness.engine.transcripts.first)
        #expect(transcript.contains(.renderedChat("hello")))
        #expect(!transcript.contains { if case .tokens = $0 { true } else { false } })
        await client.shutdown()
    }

    @Test
    func theMalformedCallTurnKeepsItsCommittedIDs() async throws {
        let harness = try DS4ClientHarness()
        let broken = "<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"fixture.echo\">\n"
            + "<｜DSML｜ parameter name=\"text\" string=\"true\">hi"
        harness.mock.enqueueGeneration(MockDS4Engine.ScriptedGeneration(chunks: [broken], tokens: [31]))
        harness.mock.enqueueGeneration(["Sorry."])
        let client = try await harness.makeClient()

        _ = try await client.sendPrompt(sessionID: "session", prompt: "Echo", attachments: [], onEvent: { _ in })

        let turn = try #require(await turns(of: client).first {
            $0.role == "assistant" && $0.toolObservation != nil
        })
        #expect(turn.rawTokens == [31])
        #expect(turn.rawAssistant == broken)
        let transcripts = harness.engine.transcripts
        try #require(transcripts.count == 2)
        #expect(transcripts[1].contains(.tokens([31])))
        await client.shutdown()
    }

    @Test
    func theCancelledTurnKeepsTheIDsItCommitted() async throws {
        let harness = try DS4ClientHarness(chunkDelay: .milliseconds(10))
        harness.mock.enqueueGeneration(Array(repeating: "word ", count: 400))
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

        let partial = try lastAssistant(in: await turns(of: client))
        let ids = try #require(partial.rawTokens)
        let raw = try #require(partial.rawAssistant)
        // One mock token per chunk: as many ids as emitted chunks of text.
        #expect(ids.count == raw.count / 5)
        let generated = try #require(harness.engine.results.first)
        #expect(ids == generated.tokens)
        #expect(partial.rawTokensModel == harness.engine.info.tokenIdentity)
        await client.shutdown()
    }

    // MARK: - Types

    @Test
    func tokensCountAsManyTokensAsTheyHaveIDs() {
        #expect(MockDS4Engine.tokenCount(of: .tokens([1, 2, 3])) == 3)
        #expect(MockDS4Engine.tokenCount(of: .tokens([])) == 0)
        #expect(MockDS4Engine.tokenCount(of: [.begin, .tokens([4, 5]), .endOfSequence]) == 4)
        #expect(MockDS4Engine.render([.tokens([4, 5])]) == "<tokens:4,5>")
    }

    @Test
    func theTokenIdentityNamesTheModelAndItsQuantization() {
        let info = DS4EngineInfo(
            modelName: "Qwen3.8-Flash-Next", modelID: 7, routedQuantBits: 2, hasVision: false,
            toolSyntaxID: DS4EngineABI.ToolSyntax.qwen, mtpDraftTokens: 1, contextSize: 4096
        )
        #expect(info.tokenIdentity == "7-2-Qwen3.8-Flash-Next")
    }

    @Test
    func theTurnStoresIDsOnlyTogetherWithTheirModel() {
        func turn(tokens: [Int32], model: String?, raw: String = "x") -> DS4AssistantTurn {
            DS4AssistantTurn(
                rawText: raw, thinkMode: 0, toolCallReplays: [], toolObservation: nil, contextSize: 100,
                tokens: tokens, tokensModel: model
            )
        }
        var message: [String: Any] = [:]
        turn(tokens: [1, 2], model: "m").apply(to: &message)
        #expect(message[DS4MessageKeys.rawTokens] as? [Int32] == [1, 2])
        #expect(message[DS4MessageKeys.rawTokensModel] as? String == "m")

        var withoutModel: [String: Any] = [:]
        turn(tokens: [1, 2], model: nil).apply(to: &withoutModel)
        #expect(withoutModel[DS4MessageKeys.rawTokens] == nil)
        var withoutTokens: [String: Any] = [:]
        turn(tokens: [], model: "m").apply(to: &withoutTokens)
        #expect(withoutTokens[DS4MessageKeys.rawTokens] == nil)
        #expect(withoutTokens[DS4MessageKeys.rawTokensModel] == nil)

        // Tokens keep an otherwise empty turn in the history: they are in the KV.
        #expect(turn(tokens: [1], model: "m", raw: "").requiresHistoryEntry)
        #expect(!turn(tokens: [], model: "m", raw: "").requiresHistoryEntry)
    }

    @Test
    func storedIDsAreReadBackWhateverTheIntegerWidth() {
        #expect(DS4MessageKeys.rawTokenIDs(of: [DS4MessageKeys.rawTokens: [Int32]([1, 2])]) == [1, 2])
        #expect(DS4MessageKeys.rawTokenIDs(of: [DS4MessageKeys.rawTokens: [3, 4]]) == [3, 4])
        #expect(DS4MessageKeys.rawTokenIDs(of: [DS4MessageKeys.rawTokens: [Int32]()]) == nil)
        #expect(DS4MessageKeys.rawTokenIDs(of: [DS4MessageKeys.rawTokens: [Int(Int32.max) + 1]]) == nil)
        #expect(DS4MessageKeys.rawTokenIDs(of: [DS4MessageKeys.rawTokens: "1,2"]) == nil)
        #expect(DS4MessageKeys.rawTokenIDs(of: [:]) == nil)
    }

    // MARK: - Checkpoint trailer

    private static var assistantMessage: [String: Any] {
        [
            "role": "assistant",
            "content": "Answer.",
            DS4MessageKeys.rawAssistant: "Reasoning</think>Answer.",
            DS4MessageKeys.rawTokens: [Int32]([151_644, 872, 0, 2_147_483_647]),
            DS4MessageKeys.rawTokensModel: "41-2-mock-ds4",
            DS4MessageKeys.thinkMode: 1,
        ]
    }

    @Test
    func theTrailerRoundTripsTheIDsAndReattachesThemToTheRestoredMessages() throws {
        let live: [[String: Any]] = [
            ["role": "user", "content": "first", DS4MessageKeys.userContent: "first\n\nMEMORY"],
            Self.assistantMessage,
        ]
        let trailer = DS4CheckpointTrailer.capture(from: live)
        #expect(trailer.messages[1].ds4.rawTokens == [151_644, 872, 0, 2_147_483_647])
        #expect(trailer.messages[1].ds4.rawTokensModel == "41-2-mock-ds4")
        #expect(trailer.messages[0].ds4.rawTokens == nil)

        let data = try trailer.encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"ds4_raw_tokens\":[151644,872,0,2147483647]"))
        #expect(json.contains("\"ds4_raw_tokens_model\":\"41-2-mock-ds4\""))
        let decoded = try #require(DS4CheckpointTrailer.decode(data))
        #expect(decoded == trailer)

        // A new process: only the visible messages exist.
        var restored: [[String: Any]] = [
            ["role": "user", "content": "first"],
            ["role": "assistant", "content": "Answer."],
        ]
        #expect(decoded.apply(to: &restored) == 2)
        #expect(DS4MessageKeys.rawTokenIDs(of: restored[1]) == [151_644, 872, 0, 2_147_483_647])
        #expect(restored[1][DS4MessageKeys.rawTokensModel] as? String == "41-2-mock-ds4")
        #expect(restored[1][DS4MessageKeys.rawAssistant] as? String == "Reasoning</think>Answer.")
        // And the renderer replays them for that model only.
        let context = DS4TranscriptRenderer.Context(
            syntax: .dsml41, thinkMode: DS4EngineABI.ThinkMode.high, toolsPrompt: "", preserveThinking: false,
            tokenIdentity: "41-2-mock-ds4"
        )
        #expect(DS4TranscriptRenderer.assistantOperations(for: restored[1], context: context).contains(
            .tokens([151_644, 872, 0, 2_147_483_647])
        ))
    }

    @Test
    func aTrailerWithoutTokensStillDecodesAndReplaysTheText() throws {
        // Written before the token members existed (version 1, no ids).
        let message: [String: Any] = ["role": "assistant", "content": "Answer."]
        let fingerprint = DS4CheckpointTrailer.fingerprint(of: message)
        let legacy = """
        {"format":"zencode-ds4-session","messages":[{"ds4":{"ds4_raw_assistant":"Reasoning</think>Answer.",\
        "ds4_think_mode":1},"fingerprint":"\(fingerprint)","index":0,"role":"assistant"}],"version":1}
        """
        let trailer = try #require(DS4CheckpointTrailer.decode(Data(legacy.utf8)))

        #expect(trailer.version == 1)
        #expect(trailer.messages.count == 1)
        #expect(trailer.messages[0].ds4.rawAssistant == "Reasoning</think>Answer.")
        #expect(trailer.messages[0].ds4.rawTokens == nil)
        #expect(trailer.messages[0].ds4.rawTokensModel == nil)
        var restored: [[String: Any]] = [message]
        #expect(trailer.apply(to: &restored) == 1)
        #expect(restored[0][DS4MessageKeys.rawTokens] == nil)
        let context = DS4TranscriptRenderer.Context(
            syntax: .dsml41, thinkMode: DS4EngineABI.ThinkMode.none, toolsPrompt: "", preserveThinking: false,
            tokenIdentity: "41-2-mock-ds4"
        )
        #expect(DS4TranscriptRenderer.assistantOperations(for: restored[0], context: context).contains(
            .renderedChat("Reasoning</think>Answer.")
        ))
        // Encoding it again keeps the members absent instead of writing nulls.
        let reencoded = try #require(String(data: try trailer.encoded(), encoding: .utf8))
        #expect(!reencoded.contains("ds4_raw_tokens"))
    }

    @Test
    func idsWithoutTheirModelAreNotCaptured() {
        var message = Self.assistantMessage
        message.removeValue(forKey: DS4MessageKeys.rawTokensModel)

        let trailer = DS4CheckpointTrailer.capture(from: [message])

        #expect(trailer.messages.count == 1)
        #expect(trailer.messages[0].ds4.rawAssistant != nil)
        #expect(trailer.messages[0].ds4.rawTokens == nil)
        #expect(trailer.messages[0].ds4.rawTokensModel == nil)
    }
}
