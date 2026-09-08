import Foundation
import Testing
@testable import ZenCODECore

struct ChatGPTSubscriptionReasoningStreamTests {
    @Test
    func successiveReasoningItemsKeepIdenticalPublicSummaries() async throws {
        let accumulator = ChatGPTSubscriptionGenerationClient.StreamAccumulator()
        var items: [[String: Any]] = []
        for id in ["rs_first", "rs_second"] {
            let item: [String: Any] = [
                "type": "reasoning", "id": id,
                "summary": [["type": "summary_text", "text": "Controllo. "]],
                "encrypted_content": "NOT_PUBLIC"
            ]
            let events = try await accumulator.ingest(.init([
                "type": "response.output_item.done", "item": item
            ]))
            #expect(thoughts(events) == "Controllo. ")
            items.append(item)
        }
        let completed = try await accumulator.ingest(.init([
            "type": "response.completed", "response": ["output": items]
        ]))
        #expect(thoughts(completed).isEmpty)
        let result = try await accumulator.result()
        #expect(result.reasoningText == "Controllo. Controllo. ")
    }

    @Test
    func publicSummaryPartsStreamImmediatelyAndReconcileByIdentity() async throws {
        let accumulator = ChatGPTSubscriptionGenerationClient.StreamAccumulator()
        let fixtures: [([String: Any], String)] = [
            (["type": "response.reasoning_summary_part.added", "item_id": "rs_1", "summary_index": 0,
              "part": ["type": "summary_text", "text": "Uno "]], "Uno "),
            (["type": "response.reasoning_summary_text.delta", "item_id": "rs_1", "summary_index": 0,
              "delta": " "], " "),
            (["type": "response.reasoning_summary_text.done", "item_id": "rs_1", "summary_index": 0,
              "text": "Uno  due"], "due"),
            (["type": "response.reasoning_summary_part.done", "item_id": "rs_1", "summary_index": 0,
              "part": ["type": "summary_text", "text": "Uno  due"]], ""),
            (["type": "response.reasoning_summary_part.done", "item_id": "rs_1", "summary_index": 1,
              "part": ["type": "summary_text", "text": "Uno  due"]], "Uno  due"),
            (["type": "response.output_item.done", "item": [
                "type": "reasoning", "id": "rs_1", "summary": [
                    ["type": "summary_text", "text": "Uno  due"],
                    ["type": "summary_text", "text": "Uno  due"]
                ], "encrypted_content": "NOT_PUBLIC"
            ]], ""),
            (["type": "response.reasoning_summary_text.delta", "item_id": "rs_2", "summary_index": 0,
              "delta": "Tre"], "Tre"),
            (["type": "response.reasoning_summary_text.done", "item_id": "rs_2", "summary_index": 0,
              "text": "Tre!"], "!"),
            (["type": "response.output_item.done", "item": [
                "type": "reasoning", "id": "rs_2", "summary": [["type": "summary_text", "text": "Tre!"]]
            ]], "")
        ]
        for (fixture, expected) in fixtures {
            let events = try await accumulator.ingest(.init(fixture))
            #expect(thoughts(events) == expected)
        }
        let result = try await accumulator.result()
        #expect(result.reasoningText == "Uno  dueUno  dueTre!")
    }

    @Test(arguments: ["response.reasoning_summary_text.delta", "reasoning_summary_delta"])
    func unkeyedDeltaReconcilesWithIdentifiedSnapshotOnce(eventType: String) async throws {
        let accumulator = ChatGPTSubscriptionGenerationClient.StreamAccumulator()
        let deltaEvents = try await accumulator.ingest(.init(["type": eventType, "delta": "Pensiero"]))
        #expect(thoughts(deltaEvents) == "Pensiero")
        for (id, expected) in [("rs_1", "!"), ("rs_2", "Pensiero!")] {
            let events = try await accumulator.ingest(.init([
                "type": "response.output_item.done", "item": [
                    "type": "reasoning", "id": id,
                    "summary": [["type": "summary_text", "text": "Pensiero!"]]
                ]
            ]))
            #expect(thoughts(events) == expected)
        }
    }

    @Test
    func encryptedReasoningAndCommentaryAreNotPublicThoughts() async throws {
        let accumulator = ChatGPTSubscriptionGenerationClient.StreamAccumulator()
        for fixture: [String: Any] in [
            ["type": "response.output_item.done", "item": [
                "type": "reasoning", "id": "rs_secret", "summary": [], "encrypted_content": "NOT_PUBLIC"
            ]],
            ["type": "response.output_text.delta", "delta": "Commentary"],
            ["type": "response.output_item.done", "item": [
                "type": "message", "role": "assistant", "phase": "commentary",
                "content": [["type": "output_text", "text": "Commentary"]]
            ]]
        ] {
            let events = try await accumulator.ingest(.init(fixture))
            #expect(thoughts(events).isEmpty)
        }
        let result = try await accumulator.result()
        #expect(result.reasoningText.isEmpty)
    }

    @Test(arguments: ["text", "nestedDelta"])
    func legacySummaryPayloadShapesPreserveTextAndWhitespace(shape: String) async throws {
        let accumulator = ChatGPTSubscriptionGenerationClient.StreamAccumulator()
        for chunk in ["Pensiero", " \n", "successivo"] {
            var fixture: [String: Any] = [
                "type": "response.reasoning_summary_text.delta",
                "item_id": "rs_legacy", "summary_index": 1
            ]
            if shape == "text" {
                fixture["text"] = chunk
            } else {
                fixture["delta"] = ["text": chunk]
            }
            let events = try await accumulator.ingest(.init(fixture))
            #expect(thoughts(events) == chunk)
        }
        let done = try await accumulator.ingest(.init([
            "type": "response.reasoning_summary_text.done",
            "item_id": "rs_legacy", "summary_index": 1,
            "text": "Pensiero \nsuccessivo!"
        ]))
        #expect(thoughts(done) == "!")
        let result = try await accumulator.result()
        #expect(result.reasoningText == "Pensiero \nsuccessivo!")
    }

    @Test(arguments: ["rs_raw", "rs_other", ""])
    func rawReasoningCannotConsumePublicSummary(rawItemID: String) async throws {
        let accumulator = ChatGPTSubscriptionGenerationClient.StreamAccumulator()
        var raw: [String: Any] = ["type": "response.reasoning_text.delta", "delta": "Pensiero"]
        if !rawItemID.isEmpty { raw["item_id"] = rawItemID }
        let rawEvents = try await accumulator.ingest(.init(raw))
        #expect(thoughts(rawEvents) == "Pensiero")
        let item: [String: Any] = [
            "type": "reasoning", "id": "rs_other",
            "summary": [["type": "summary_text", "text": "Pensiero!"]]
        ]
        let summaryEvents = try await accumulator.ingest(.init([
            "type": "response.output_item.done", "item": item
        ]))
        #expect(thoughts(summaryEvents) == "Pensiero!")
        let repeated = try await accumulator.ingest(.init([
            "type": "response.completed", "response": ["output": [item]]
        ]))
        #expect(thoughts(repeated).isEmpty)
        let result = try await accumulator.result()
        #expect(result.reasoningText == "PensieroPensiero!")
    }

    @Test(arguments: ["response.reasoning_summary_text.delta", "reasoning_summary_delta"])
    func identifiedSummaryDeltaCannotConsumeAnotherItemsSummary(eventType: String) async throws {
        let accumulator = ChatGPTSubscriptionGenerationClient.StreamAccumulator()
        let delta = try await accumulator.ingest(.init([
            "type": eventType, "item_id": "rs_first", "delta": "Pensiero"
        ]))
        #expect(thoughts(delta) == "Pensiero")
        for (id, expected) in [("rs_other", "Pensiero!"), ("rs_first", "!")] {
            let events = try await accumulator.ingest(.init([
                "type": "response.output_item.done", "item": [
                    "type": "reasoning", "id": id,
                    "summary": [["type": "summary_text", "text": "Pensiero!"]]
                ]
            ]))
            #expect(thoughts(events) == expected)
        }
    }

    private func thoughts(_ events: [DirectAgentEvent]) -> String {
        events.compactMap { event in
            if case let .thought(text) = event { return text }
            return nil
        }.joined()
    }
}
