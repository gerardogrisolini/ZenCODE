//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

extension RemoteSessionSnapshotTests {
    @Test
    func chatGPTSubscriptionSSERequestUsesSharedNIOTransportValue() throws {
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials()
        )
        let request = try client.request(
            for: ["model": "gpt-5.5"],
            sessionID: "sse-nio-session",
            threadID: "logical-session"
        )

        #expect(request.method == "POST")
        #expect(request.timeout == .seconds(600))
        #expect(request.headers.first {
            $0.name.caseInsensitiveCompare("Accept") == .orderedSame
        }?.value == "text/event-stream")
        #expect(request.headers.first {
            $0.name.caseInsensitiveCompare("session-id") == .orderedSame
        }?.value == "sse-nio-session")
        #expect(request.headers.first {
            $0.name.caseInsensitiveCompare("thread-id") == .orderedSame
        }?.value == "logical-session")
        #expect(request.headers.first {
            $0.name.caseInsensitiveCompare("x-client-request-id") == .orderedSame
        }?.value == "logical-session")
        #expect(request.headers.contains {
            $0.name.caseInsensitiveCompare("session_id") == .orderedSame
        } == false)
        #expect(request.headers.contains {
            $0.name.caseInsensitiveCompare("OpenAI-Beta") == .orderedSame
        } == false)
        #expect(request.body != nil)
    }

    @Test
    func chatGPTSubscriptionWebSocketPayloadKeepsCachedContinuationWireSafe() throws {
        let catalog = remoteFeatureToolCatalog()
        let messages = catalog.wireMessages(from: remoteFeatureHistoryMessages())
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_previous_fixture",
                messageCount: messages.count - 1,
                instructions: "System prompt"
            )
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt-fixture-ws",
            toolPayloads: JSONValue.acpValue(from: catalog.responsesToolPayloads)
        )
        let cachedPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: true
        )
        let cachedInput = try #require(cachedPayload["input"] as? [[String: Any]])
        let toolNames = Set(
            ((cachedPayload["tools"] as? [[String: Any]]) ?? []).compactMap {
                $0["name"] as? String
            }
        )

        #expect(payload.previousResponseID == "resp_previous_fixture")
        #expect(cachedPayload["previous_response_id"] as? String == "resp_previous_fixture")
        #expect(cachedInput.count == 1)
        #expect((cachedInput.first?["type"] as? String) == "function_call_output")
        #expect(toolNames == ["tool_local_exec", "tool_fixture_Build"])
        #expect(JSONValue(jsonObject: cachedPayload).prettyPrinted().contains("fixture.Build") == false)
    }

    @Test
    func subscriptionToolCallsCoalesceSplitItemAndCallIdentifiers() throws {
        // Reproduces a backend variant where the streamed `output_item.added`
        // event only carries the `call_id` (empty arguments) while the argument
        // delta/done events key off the response `item_id` without an
        // `output_index`, resolving to a different accumulator slot. This used
        // to yield two tool calls (an empty first one) sharing the same
        // `call_id`, duplicating the tool in the UI and making the provider
        // reject the replayed request.
        let objects: [[String: Any]] = [
            [
                "type": "response.output_item.added",
                "output_index": 0,
                "item": [
                    "type": "function_call",
                    "call_id": "call_1",
                    "name": "tool_local_exec",
                    "arguments": ""
                ]
            ],
            [
                "type": "response.function_call_arguments.delta",
                "item_id": "fc_1",
                "delta": "{\"command\":\"ls\"}"
            ],
            [
                "type": "response.function_call_arguments.done",
                "item_id": "fc_1",
                "arguments": "{\"command\":\"ls\"}"
            ],
            [
                "type": "response.completed",
                "response": [
                    "id": "resp_1",
                    "output": [
                        [
                            "type": "function_call",
                            "id": "fc_1",
                            "call_id": "call_1",
                            "name": "tool_local_exec",
                            "arguments": "{\"command\":\"ls\"}"
                        ]
                    ]
                ]
            ]
        ]

        let toolCalls = try subscriptionToolCalls(from: objects)

        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == "call_1")
        #expect(toolCalls.first?.name == "tool_local_exec")
        #expect(toolCalls.first?.argumentsObject["command"] as? String == "ls")
        #expect(Set(toolCalls.map(\.id)).count == toolCalls.count)
    }

    @Test
    func chatGPTSubscriptionContextEstimateIncludesInstructionsAndTools() throws {
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: chatGPTContinuationMessages(),
            continuation: nil
        )
        let toolPayloads = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "Run a shell command.",
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                )
            ]
        ).responsesToolPayloads

        let inputOnlyEstimate = try #require(
            ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: nil,
                input: payload.input,
                toolPayloads: []
            )
        )
        let withInstructionsEstimate = try #require(
            ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: payload.instructions,
                input: payload.input,
                toolPayloads: []
            )
        )
        let withToolsEstimate = try #require(
            ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: payload.instructions,
                input: payload.input,
                toolPayloads: toolPayloads
            )
        )

        #expect(withInstructionsEstimate > inputOnlyEstimate)
        #expect(withToolsEstimate > withInstructionsEstimate)
    }

    @Test
    func chatGPTSubscriptionBuffersRepeatedOutputTextDeltasWithoutDroppingThem() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "response.output_text.delta",
                "delta": "ha"
            ],
            [
                "type": "response.output_text.delta",
                "delta": "ha"
            ]
        ])

        #expect(result.text == "haha")
        #expect(result.contentText == "")
    }

    @Test
    func chatGPTSubscriptionCompactionReservesContextAndDropsContinuation() throws {
        let maxTokens = 30_000
        let maxOutputTokens = 1_000
        let policyMaxTokens = try #require(
            ChatGPTSubscriptionGenerationClient.compactionPolicyMaxTokens(
                for: maxTokens,
                maxOutputTokens: maxOutputTokens
            )
        )
        let triggerTokens = AgentConversationCompactionPolicy.triggerTokenCount(
            for: policyMaxTokens
        )
        let usableTokens = maxTokens - max(
            maxOutputTokens,
            ChatGPTSubscriptionGenerationClient.compactionReserveTokenCount
        )
        let priorMessages = chatGPTCompactionMessages()
        let messages = priorMessages + [
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "current prompt after cached response",
                attachments: []
            )
        ]
        let staleContinuation = ChatGPTSubscriptionContinuationState(
            responseID: "resp_before_compaction",
            messageCount: priorMessages.count,
            instructions: "System prompt"
        )
        let preCompactionPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: staleContinuation
        )

        let result = ChatGPTSubscriptionGenerationClient.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens
        )
        let compactedMessages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: messages
        )
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: compactedMessages,
            continuation: staleContinuation
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-after-compaction"
        )
        let cachedPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: true
        )

        #expect(triggerTokens <= usableTokens)
        #expect(preCompactionPayload.previousResponseID == "resp_before_compaction")
        #expect(preCompactionPayload.cachedWebSocketInput != nil)
        #expect(result.wasCompacted)
        // The reported window stays the model's real context window; the
        // reserved output is applied to the compaction target instead.
        #expect(result.maxTokens == maxTokens)
        #expect(policyMaxTokens == usableTokens)
        #expect(
            result.estimatedTokenCount
                <= AgentConversationCompactionPolicy.targetTokenCount(for: policyMaxTokens)
        )
        #expect(result.estimatedTokenCount + (maxTokens - usableTokens) <= maxTokens)
        #expect(compactedMessages.count < messages.count)
        #expect(
            result.compactedSystemPrompt?.contains(
                AgentConversationCompactionSupport.memorySummaryHeader
            ) == true
        )
        #expect(payload.previousResponseID == nil)
        #expect(payload.cachedWebSocketInput == nil)
        #expect(cachedPayload["previous_response_id"] == nil)
        #expect((cachedPayload["input"] as? [Any])?.count == payload.input.count)
    }

    @Test
    func chatGPTSubscriptionPreflightCompactsWhenEstimatedPayloadExceedsUsableContext() throws {
        let maxTokens = 50_000
        let maxOutputTokens = 1_000
        let messages = chatGPTPreflightCompactionMessages()
        let normalResult = ChatGPTSubscriptionGenerationClient.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens
        )
        let requestPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: nil
        )
        let toolPayloads = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: String(repeating: "large tool description ", count: 4_000),
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                )
            ]
        ).responsesToolPayloads
        let estimatedContextTokens = try #require(
            ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: requestPayload.instructions,
                input: requestPayload.input,
                toolPayloads: toolPayloads
            )
        )
        let policyMaxTokens = try #require(
            ChatGPTSubscriptionGenerationClient.compactionPolicyMaxTokens(
                for: maxTokens,
                maxOutputTokens: maxOutputTokens
            )
        )
        let requestEstimate = ChatGPTSubscriptionGenerationClient.requestEstimate(
            instructions: requestPayload.instructions,
            fullHistoryInput: requestPayload.input,
            toolPayloads: toolPayloads
        )
        let overhead = SubscriptionCompactionSupport.requestOverhead(
            estimate: requestEstimate,
            messages: messages
        )
        let preflightResult = ChatGPTSubscriptionGenerationClient.compactedMessagesForEstimatedContextIfNeeded(
            messages,
            estimate: requestEstimate,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens
        )

        #expect(normalResult.wasCompacted == false)
        #expect(estimatedContextTokens > AgentConversationCompactionPolicy.triggerTokenCount(for: policyMaxTokens))
        #expect(preflightResult?.wasCompacted == true)
        let compacted = try #require(preflightResult)
        #expect(compacted.estimatedTokenCount < compacted.originalEstimatedTokenCount)
        // The compacted conversation has to fit next to the tool catalogue and
        // the reserved output, which is the whole point of the preflight. The
        // conversation is charged at the provider's own rate, not at the plain
        // estimator's.
        #expect(
            Int(
                Double(compacted.estimatedTokenCount)
                    * overhead.conversationInflationFactor
            )
                + overhead.staticOverheadTokens
                + ChatGPTSubscriptionGenerationClient.compactionReserveTokenCount
                <= maxTokens
        )
    }

    @Test
    func chatGPTSubscriptionPreflightReportsAnUnsatisfiableBudgetInsteadOfLooping() throws {
        // A tool catalogue this large leaves no room for any conversation once
        // the reserved output is subtracted. Compaction must refuse explicitly
        // rather than "succeed" against a floored, unreachable target.
        let maxTokens = 50_000
        let messages = chatGPTPreflightCompactionMessages()
        let requestPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: nil
        )
        let toolPayloads = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: String(repeating: "large tool description ", count: 7_000),
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                )
            ]
        ).responsesToolPayloads
        let requestEstimate = ChatGPTSubscriptionGenerationClient.requestEstimate(
            instructions: requestPayload.instructions,
            fullHistoryInput: requestPayload.input,
            toolPayloads: toolPayloads
        )

        let outcome = SubscriptionCompactionSupport.preflightCompaction(
            messages,
            estimate: requestEstimate,
            maxTokens: maxTokens,
            maxOutputTokens: 1_000,
            reserveTokenCount: ChatGPTSubscriptionGenerationClient.compactionReserveTokenCount
        )

        guard case let .unsatisfiableBudget(
            contextWindowTokens,
            reservedOutputTokens,
            overheadTokens
        ) = outcome else {
            Issue.record("Expected an unsatisfiable preflight budget, got \(outcome).")
            return
        }
        #expect(contextWindowTokens == maxTokens)
        #expect(reservedOutputTokens + overheadTokens >= maxTokens)
        // No result means the loop stops here: the request is sent as-is and
        // the provider outcome is surfaced.
        #expect(
            ChatGPTSubscriptionGenerationClient.compactedMessagesForEstimatedContextIfNeeded(
                messages,
                estimate: requestEstimate,
                maxTokens: maxTokens,
                maxOutputTokens: 1_000
            ) == nil
        )
        #expect(
            ChatGPTSubscriptionGenerationClient.unsatisfiableBudgetDiagnostic(
                contextWindowTokens: contextWindowTokens,
                maxOutputTokens: reservedOutputTokens,
                overheadTokens: overheadTokens
            ).contains("cannot fit")
        )
    }

    @Test
    func chatGPTSubscriptionContextLimitRetryRemovesASubstantialPartOfTheHistory() {
        let maxTokens = 200_000
        let maxOutputTokens = 8_000
        let messages = chatGPTPreflightCompactionMessages()
        let rawTokenCount = AgentConversationCompactionSupport.estimatedTokenCount(
            for: RemoteGenerationClient.agentRuntimeMessages(from: messages)
        )
        // The rejected prompt is far below the window, so a manual force
        // retains at most floor(raw * 0.9); the context-limit retry must still
        // cut to 50% to make materially more room.
        let forced = ChatGPTSubscriptionGenerationClient.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            force: true
        )
        let retry = ChatGPTSubscriptionGenerationClient.compactedMessagesForContextLimitRetry(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            overhead: SubscriptionCompactionSupport.RequestOverhead(
                staticOverheadTokens: 60_000,
                conversationInflationFactor: 1.0
            )
        )

        #expect(forced.wasCompacted)
        #expect(
            forced.estimatedTokenCount
                <= Int((Double(rawTokenCount) * 0.9).rounded(.down))
        )
        #expect(retry.wasCompacted)
        #expect(
            Double(retry.estimatedTokenCount)
                <= Double(rawTokenCount)
                    * AgentConversationCompactionPolicy.contextLimitRetryRetentionFraction
        )
        #expect(retry.estimatedTokenCount < forced.estimatedTokenCount)
        #expect(
            retry.keptRecentMessageCount
                >= AgentConversationCompactionPolicy.minimumRecentMessageCount
        )
        #expect(retry.maxTokens == maxTokens)
    }

    @Test
    func chatGPTFreshContinuationPreflightUsesFullUnicodeHistoryNotDelta() throws {
        // A fresh continuation puts only the last turn on the WebSocket, but a
        // compaction/retry resets that continuation and replays the *entire*
        // history. Unicode plus JSON escapes make the full provider estimate
        // materially larger than the shared runtime estimate; measuring the
        // delta would therefore miss the preflight entirely.
        var messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: [],
            allowedToolNames: []
        )
        let unicodePayload = String(repeating: "\\\"🙂 e\u{301}\n", count: 300)
        for index in 0..<120 {
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: index.isMultiple(of: 2) ? "user" : "assistant",
                    content: "history \(index) \(unicodePayload)",
                    attachments: []
                )
            )
        }
        let continuation = ChatGPTSubscriptionContinuationState(
            responseID: "resp_fresh_continuation",
            messageCount: messages.count - 1,
            instructions: "System prompt",
            allowsFreshTransport: true
        )
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: continuation
        )
        let cachedDelta = try #require(payload.cachedWebSocketInput)
        let toolPayloads = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "Run a command.",
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}}}"#
                )
            ]
        ).responsesToolPayloads
        let fullEstimate = ChatGPTSubscriptionGenerationClient.requestEstimate(
            instructions: payload.instructions,
            fullHistoryInput: payload.input,
            toolPayloads: toolPayloads
        )
        // This deliberately models the historical bug: using the fresh
        // continuation delta to size a compaction that will replay full history.
        let deltaEstimate = ChatGPTSubscriptionGenerationClient.requestEstimate(
            instructions: payload.instructions,
            fullHistoryInput: cachedDelta,
            toolPayloads: toolPayloads
        )
        let maxTokens = 100_000

        #expect(payload.previousResponseID == "resp_fresh_continuation")
        #expect(cachedDelta.count < payload.input.count)
        #expect(fullEstimate.totalTokens > deltaEstimate.totalTokens * 10)

        let fullOutcome = SubscriptionCompactionSupport.preflightCompaction(
            messages,
            estimate: fullEstimate,
            maxTokens: maxTokens,
            maxOutputTokens: 1_000,
            reserveTokenCount: ChatGPTSubscriptionGenerationClient.compactionReserveTokenCount
        )
        let deltaOutcome = SubscriptionCompactionSupport.preflightCompaction(
            messages,
            estimate: deltaEstimate,
            maxTokens: maxTokens,
            maxOutputTokens: 1_000,
            reserveTokenCount: ChatGPTSubscriptionGenerationClient.compactionReserveTokenCount
        )

        guard case let .compacted(fullResult) = fullOutcome else {
            Issue.record("The full-history estimate must compact a fresh continuation: \(fullOutcome).")
            return
        }
        #expect(fullResult.estimatedTokenCount < fullResult.originalEstimatedTokenCount)
        if case .notNeeded = deltaOutcome {
            // Expected: this is precisely why the runtime must never select it.
        } else {
            Issue.record("The continuation delta unexpectedly represented the full-history preflight: \(deltaOutcome).")
        }
    }

    @Test
    func chatGPTSubscriptionContextLimitErrorDetectionRecognizesCommonMessages() {
        let contextLengthError = NSError(
            domain: "ChatGPTSubscriptionTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "context_length_exceeded"]
        )
        let promptTooLongError = NSError(
            domain: "ChatGPTSubscriptionTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Prompt is too long for this model."]
        )
        let rateLimitError = NSError(
            domain: "ChatGPTSubscriptionTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "rate limit exceeded"]
        )

        #expect(ChatGPTSubscriptionGenerationClient.isContextLimitError(contextLengthError))
        #expect(ChatGPTSubscriptionGenerationClient.isContextLimitError(promptTooLongError))
        #expect(!ChatGPTSubscriptionGenerationClient.isContextLimitError(rateLimitError))
    }
}
