//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import os
@testable import ZenCODECore
import Testing

#if os(macOS)
extension RemoteSessionSnapshotTests {
    @Test
    func chatGPTSubscriptionWebSocketPayloadKeepsCachedContinuationWireSafe() throws {
        let catalog = remoteXcodeToolCatalog()
        let messages = catalog.wireMessages(from: remoteXcodeHistoryMessages())
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_previous_xcode",
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
            sessionID: "session-chatgpt-xcode-ws",
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

        #expect(payload.previousResponseID == "resp_previous_xcode")
        #expect(cachedPayload["previous_response_id"] as? String == "resp_previous_xcode")
        #expect(cachedInput.count == 1)
        #expect((cachedInput.first?["type"] as? String) == "function_call_output")
        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(JSONValue(jsonObject: cachedPayload).prettyPrinted().contains("xcode.BuildProject") == false)
    }

    @Test
    func chatGPTSubscriptionSSERequestSendsWireSafeXcodeToolNamesAndRestoresLocalCall() async throws {
        let response = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"id":"item_xcode","type":"function_call","call_id":"call_xcode","name":"tool_xcode_BuildProject","arguments":"{\\"scheme\\":\\"App\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_xcode","output":[]}}

        """
        let sessionID = "session-chatgpt-xcode-sse"
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let webSocketPool = ChatGPTSubscriptionWebSocketPool()
        webSocketPool.activateSSEFallback(sessionID: sessionID)
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials(),
            baseURL: URL(string: "https://unit.test/backend-api")!,
            urlSession: urlSession,
            webSocketPool: webSocketPool
        )
        let catalog = remoteXcodeToolCatalog()
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: catalog.wireMessages(from: remoteXcodeHistoryMessages()),
            continuation: nil
        )
        let capturedEvents = CapturedSubscriptionEvents()

        let completion = try await client.streamEvents(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: sessionID,
            toolPayloads: JSONValue.acpValue(from: catalog.responsesToolPayloads),
            maxOutputTokens: nil
        ) { object in
            capturedEvents.append(object)
        }
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                $0["name"] as? String
            }
        )
        let input = try #require(body["input"] as? [[String: Any]])
        let historyFunctionCall = try #require(input.first {
            $0["type"] as? String == "function_call"
                && $0["call_id"] as? String == "call_previous_xcode"
        })
        let remoteToolCalls = try subscriptionToolCalls(from: capturedEvents.all())
        let localToolCalls = remoteToolCalls.map(catalog.localToolCall)

        #expect(completion.responseID == "resp_xcode")
        #expect(request.request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("xcode.BuildProject"))
        #expect(historyFunctionCall["name"] as? String == "tool_xcode_BuildProject")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("xcode.BuildProject") == false)
        #expect(localToolCalls.map(\.name) == ["xcode.BuildProject"])
        #expect(localToolCalls.first?.argumentsObject["scheme"] as? String == "App")
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
        #expect(result.maxTokens == policyMaxTokens)
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
    func chatGPTSubscriptionDoesNotPreflightCompactWhenEstimatedPayloadExceedsUsableContext() throws {
        let maxTokens = 50_000
        let maxOutputTokens = 1_000
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
        let preflightResult = ChatGPTSubscriptionGenerationClient.compactedMessagesForEstimatedContextIfNeeded(
            messages,
            estimatedContextTokens: estimatedContextTokens,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens
        )

        #expect(estimatedContextTokens > AgentConversationCompactionPolicy.triggerTokenCount(for: policyMaxTokens))
        #expect(preflightResult == nil)
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
#endif
