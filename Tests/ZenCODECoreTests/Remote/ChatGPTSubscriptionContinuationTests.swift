//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

extension RemoteSessionSnapshotTests {
    @Test
    func chatGPTSubscriptionNIOClientDefersUnsafeTransportRecoveryToGenerationClient() async {
        let task = ChatGPTSubscriptionTestWebSocketTask(
            receiveOutcomes: [
                .success(
                    .text(
                        #"{"type":"response.output_text.delta","delta":"partial"}"#
                    )
                ),
                .failure(RemoteTransportError.closed)
            ]
        )
        let factoryCount = Mutex(0)
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            webSocketTaskFactory: { _ in
                factoryCount.withLock { $0 += 1 }
                return task
            }
        )
        defer { await pool.shutdown() }
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials(),
            baseURL: URL(string: "https://example.invalid/backend-api")!,
            webSocketPool: pool,
            retrySleep: { _ in }
        )

        do {
            _ = try await client.streamEvents(
                input: .array([]),
                model: "gpt-5.5",
                instructions: "System prompt",
                reasoningEffort: nil,
                textVerbosity: "medium",
                sessionID: "unsafe-event"
            ) { _ in }
            Issue.record("A replay-unsafe stream unexpectedly completed.")
        } catch let failure as ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure {
            #expect((failure.underlying as? RemoteTransportError) == .closed)
            #expect(
                ChatGPTSubscriptionGenerationClient.shouldRetryStreamInterruption(
                    failure,
                    completedRetries: 0
                )
            )
        } catch {
            Issue.record("Expected a replay-unsafe stream failure, got \(error).")
        }

        #expect(factoryCount.withLock { $0 } == 1)
        #expect(
            ChatGPTSubscriptionResponsesClient.isReplayUnsafeStreamEvent([
                "type": "response.reasoning_summary_text.delta"
            ])
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.isReplayUnsafeStreamEvent([
                "type": "response.refusal.delta"
            ])
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.isReplayUnsafeStreamEvent([
                "type": "response.completed"
            ])
        )
    }

    @Test(arguments: [
        // Text deltas are buffered until the final snapshot.
        ChatGPTSubscriptionStreamReconciliationCase(
            events: [
                #"{"type":"response.output_text.delta","delta":"Confermi che proceda?"}"#,
                #"{"type":"response.output_text.delta","delta":"Confermi che proceda?\n\nFile modificati: nessuno."}"#,
                #"{"type":"response.completed","response":{"output_text":"Confermi che proceda?\n\nFile modificati: nessuno."}}"#
            ],
            text: "Confermi che proceda?\n\nFile modificati: nessuno.",
            contentText: "Confermi che proceda?\n\nFile modificati: nessuno."
        ),
        // Repeated identical deltas are kept, not deduplicated.
        ChatGPTSubscriptionStreamReconciliationCase(
            events: [
                #"{"type":"response.output_text.delta","delta":"ha"}"#,
                #"{"type":"response.output_text.delta","delta":"ha"}"#
            ],
            text: "haha",
            contentText: ""
        ),
        // A corrected delta snapshot replaces the buffered draft.
        ChatGPTSubscriptionStreamReconciliationCase(
            events: [
                #"{"type":"response_output_text_delta","delta":"Corego le ultime indentazioni accidentali evidenziate dal diff, poi rilancio swift build."}"#,
                #"{"type":"response_output_text_delta","delta":"Correggo le ultime indentazioni accidentali evidenziate dal diff, poi rilancio swift build."}"#,
                #"{"type":"response_completed"}"#
            ],
            text: "Correggo le ultime indentazioni accidentali evidenziate dal diff, poi rilancio swift build.",
            contentText: ""
        ),
        // The completed snapshot extends the streamed content.
        ChatGPTSubscriptionStreamReconciliationCase(
            events: [
                #"{"type":"response.output_text.delta","delta":"Confermi che proceda?"}"#,
                #"{"type":"response.completed","response":{"output_text":"Confermi che proceda?\n\nFile modificati: nessuno."}}"#
            ],
            text: "Confermi che proceda?\n\nFile modificati: nessuno.",
            contentText: "Confermi che proceda?\n\nFile modificati: nessuno."
        ),
        // A content-part snapshot extends the buffered content.
        ChatGPTSubscriptionStreamReconciliationCase(
            events: [
                #"{"type":"response.output_text.delta","delta":"Prima "}"#,
                #"{"type":"response.content_part.done","part":{"type":"output_text","text":"parte."}}"#,
                #"{"type":"response.completed"}"#
            ],
            text: "Prima parte.",
            contentText: ""
        ),
        // The refusal stop reason survives `response.completed`.
        ChatGPTSubscriptionStreamReconciliationCase(
            events: [
                #"{"type":"response.refusal.done","refusal":"Non posso aiutare con questa richiesta."}"#,
                #"{"type":"response.completed","response":{"output":[]}}"#
            ],
            text: "Non posso aiutare con questa richiesta.",
            stopReason: "refusal"
        ),
        // The legacy reasoning delta streams a thought.
        ChatGPTSubscriptionStreamReconciliationCase(
            events: [
                #"{"type":"reasoning_content_delta","delta":"legacy thought"}"#,
                #"{"type":"response.completed","response":{"output":[]}}"#
            ],
            thoughtText: "legacy thought",
            reasoningText: "legacy thought"
        )
    ])
    func chatGPTSubscriptionTextDeltasAreBufferedUntilFinalSnapshot(
        _ testCase: ChatGPTSubscriptionStreamReconciliationCase
    ) async throws {
        let objects = try testCase.events.map { event in
            try #require(
                JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any]
            )
        }
        let accumulator = ChatGPTSubscriptionGenerationClient.StreamAccumulator()
        var streamedContentText = ""
        var streamedThoughtText = ""
        for object in objects {
            for event in try await accumulator.ingest(
                ChatGPTSubscriptionGenerationClient.StreamAccumulatorObject(object)
            ) {
                switch event {
                case let .content(delta):
                    streamedContentText.append(delta)
                case let .thought(delta):
                    streamedThoughtText.append(delta)
                default:
                    break
                }
            }
        }
        let result = try await accumulator.result()

        if let text = testCase.text {
            #expect(result.text == text)
        }
        if let contentText = testCase.contentText {
            #expect(streamedContentText == contentText)
        }
        if let thoughtText = testCase.thoughtText {
            #expect(streamedThoughtText == thoughtText)
        }
        if let reasoningText = testCase.reasoningText {
            #expect(result.reasoningText == reasoningText)
        }
        if let stopReason = testCase.stopReason {
            #expect(result.stopReason == stopReason)
        }
    }

    @Test
    func chatCompletionDeltaContentPartsAreParsedAsContent() {
        let events = ChatCompletionsStreamParser.parse([
            "choices": [
                [
                    "delta": [
                        "content": [
                            ["type": "text", "text": "Hello "],
                            ["type": "text", "text": "world"]
                        ],
                        "reasoning_content": "thinking..."
                    ]
                ]
            ]
        ])
        var contentText = ""
        var reasoningText = ""
        for event in events {
            switch event {
            case let .content(delta):
                contentText += delta
            case let .reasoning(delta):
                reasoningText += delta
            default:
                continue
            }
        }
        #expect(contentText == "Hello world")
        #expect(reasoningText == "thinking...")
    }

    @Test
    func responsesContentPartDeltaIsParsedAsContent() {
        let events = ResponsesStreamParser.parse([
            "type": "response.content_part.delta",
            "delta": [
                "type": "output_text_delta",
                "content": "Visible answer"
            ]
        ])
        var contentText = ""
        for event in events {
            if case let .content(delta) = event {
                contentText += delta
            }
        }

        #expect(contentText == "Visible answer")
    }

    @Test
    func streamResponsesDoesNotDuplicateMultipartOutputItemSnapshotAfterDeltas() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"Visible "}

        data: {"type":"response.output_text.delta","delta":"answer"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"Visible "},{"type":"output_text","text":"answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8)
        )
        defer {
            fixture.beginShutdown()
        }
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-output-item-multipart-message-dedup",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { event in
                capturedEvents.append(event)
            }
        )

        #expect(result.text == "Visible answer")
        #expect(capturedEvents.contentText() == "Visible answer")
    }

    @Test
    func chatGPTSubscriptionContinuationUsesToolOutputDelta() throws {
        let messages = chatGPTContinuationMessagesWithToolOutput()
        let fullPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_tool_call",
                messageCount: 3,
                instructions: "System prompt"
            )
        )
        let cachedInput = try #require(payload.cachedWebSocketInput)
        let cachedObject = try #require(cachedInput.first as? [String: Any])

        #expect(payload.input.count == fullPayload.input.count)
        #expect(cachedInput.count == 1)
        #expect(cachedObject["type"] as? String == "function_call_output")
        #expect(cachedObject["call_id"] as? String == "call_memory")
        #expect(payload.previousResponseID == "resp_tool_call")
    }

    @Test
    func chatGPTSubscriptionRequestBodySendsWireSafeFeatureToolNames() throws {
        let catalog = remoteFeatureToolCatalog()
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: catalog.wireMessages(from: remoteFeatureHistoryMessages()),
            continuation: nil
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt-fixture",
            toolPayloads: JSONValue.acpValue(from: catalog.responsesToolPayloads)
        )
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                $0["name"] as? String
            }
        )
        let input = try #require(body["input"] as? [[String: Any]])
        let historyFunctionCall = try #require(input.first {
            $0["type"] as? String == "function_call"
                && $0["call_id"] as? String == "call_previous_fixture"
        })

        #expect(toolNames == ["tool_local_exec", "tool_fixture_Build"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("fixture.Build"))
        #expect(historyFunctionCall["name"] as? String == "tool_fixture_Build")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("fixture.Build") == false)
    }

    @Test
    func chatGPTSubscriptionPromptCacheKeyIsSessionScoped() throws {
        let tools = JSONValue.acpValue(from: [
            [
                "type": "function",
                "name": "tool_local_exec",
                "parameters": ["type": "object"]
            ] as [String: Any]
        ])
        let key = ChatGPTSubscriptionRequestBuilder.promptCacheKey(
            instructions: "System prompt",
            toolPayloads: tools,
            fallbackSessionID: "session-a"
        )
        let differentSession = ChatGPTSubscriptionRequestBuilder.promptCacheKey(
            instructions: "System prompt",
            toolPayloads: tools,
            fallbackSessionID: "session-b"
        )
        let differentInstructions = ChatGPTSubscriptionRequestBuilder.promptCacheKey(
            instructions: "Another prompt",
            toolPayloads: tools,
            fallbackSessionID: "session-a"
        )
        let emptyPrefix = ChatGPTSubscriptionRequestBuilder.promptCacheKey(
            instructions: nil,
            toolPayloads: .array([]),
            fallbackSessionID: "session-fallback"
        )

        #expect(key == "session-a")
        #expect(differentSession == "session-b")
        #expect(differentInstructions == "session-a")
        #expect(emptyPrefix == "session-fallback")
    }

    @Test
    func chatGPTSubscriptionRequestBodyOmitsUnsupportedMaxOutputTokens() throws {
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: .array([]),
            model: "gpt-5.5",
            instructions: "System prompt",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt",
            maxOutputTokens: 128
        )

        #expect(body["max_output_tokens"] == nil)
    }

    @Test
    func chatGPTSubscriptionReplayDropsSummaryOnlyReasoningAndDeduplicates() throws {
        let input: [Any] = [
            [
                "type": "reasoning",
                "id": "rs_summary",
                "summary": [["type": "summary_text", "text": "a summary"]]
            ] as [String: Any],
            [
                "type": "reasoning",
                "id": "rs_enc",
                "encrypted_content": "blob",
                "summary": []
            ] as [String: Any],
            [
                "type": "reasoning",
                "id": "rs_enc",
                "encrypted_content": "blob",
                "summary": []
            ] as [String: Any]
        ]
        let sanitized = ChatGPTSubscriptionRequestBuilder.chatGPTInputPayload(from: input)
            .compactMap { $0 as? [String: Any] }

        #expect(sanitized.count == 1)
        #expect(sanitized.first?["encrypted_content"] as? String == "blob")
        #expect(sanitized.first?["id"] == nil)
    }
}

extension ChatGPTSubscriptionWebSocketMessage {
    var jsonObject: [String: Any]? {
        guard case let .text(text) = self,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return nil
        }
        return object
    }
}

/// One ChatGPT Subscription stream: JSON event objects and the expected
/// accumulator result (`nil` fields are not checked).
struct ChatGPTSubscriptionStreamReconciliationCase: Sendable {
    let events: [String]
    var text: String?
    var contentText: String?
    var thoughtText: String?
    var reasoningText: String?
    var stopReason: String?
}
