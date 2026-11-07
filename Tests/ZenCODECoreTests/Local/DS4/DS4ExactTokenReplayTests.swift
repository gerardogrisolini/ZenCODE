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
//  - client: the round after a tool call replays `.tokens(ids)` with the ids
//    `generate` returned and the sync reuses the whole previous prefix; a
//    cancelled turn keeps the ids it committed;
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
}
