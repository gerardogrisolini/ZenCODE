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
    func chatGPTSubscriptionContinuationKeepsFullInputForBaseRequest() throws {
        let messages = chatGPTContinuationMessages()
        let fullPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_previous",
                messageCount: 3,
                instructions: "System prompt"
            )
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt"
        )

        #expect(payload.input.count == fullPayload.input.count)
        #expect(payload.cachedWebSocketInput?.count == 1)
        #expect(payload.previousResponseID == "resp_previous")
        #expect(body["previous_response_id"] == nil)
        #expect((body["input"] as? [Any])?.count == fullPayload.input.count)
    }

    @Test
    func chatGPTSubscriptionWebSocketUsesContinuationOnlyWhenCached() throws {
        let messages = chatGPTContinuationMessages()
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_previous",
                messageCount: 3,
                instructions: "System prompt"
            )
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt"
        )
        let freshPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: false
        )
        let cachedPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: true
        )

        #expect(freshPayload["previous_response_id"] == nil)
        #expect((freshPayload["input"] as? [Any])?.count == payload.input.count)
        #expect(cachedPayload["previous_response_id"] as? String == "resp_previous")
        #expect((cachedPayload["input"] as? [Any])?.count == payload.cachedWebSocketInput?.count)
        #expect(cachedPayload["type"] as? String == "response.create")
    }

    @Test
    func chatGPTSubscriptionFreshWebSocketCanUseContinuationDeltaWhenAllowed() throws {
        let messages = chatGPTContinuationMessages()
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_previous",
                messageCount: 3,
                instructions: "System prompt",
                allowsFreshTransport: true
            )
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt"
        )
        let freshPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: true
        )

        #expect(freshPayload["previous_response_id"] as? String == "resp_previous")
        #expect((freshPayload["input"] as? [Any])?.count == payload.cachedWebSocketInput?.count)
        #expect((freshPayload["input"] as? [Any])?.count == 1)
    }

    @Test
    func chatGPTSubscriptionContinuationUnavailableErrorAsksForCompaction() throws {
        let errors = [
            ChatGPTSubscriptionGenerationError.responseFailed(
                "Previous response id resp_saved could not be found."
            ),
            ChatGPTSubscriptionGenerationError.responseFailed(
                "Unsupported parameter: previous_response_id"
            )
        ]

        for backendError in errors {
            let error = try #require(
                ChatGPTSubscriptionGenerationClient.continuationUnavailableError(
                    from: backendError
                )
            )
            guard case let .continuationUnavailable(detail) = error else {
                Issue.record("Expected a continuation unavailable error.")
                return
            }
            #expect(!detail.isEmpty)
            #expect(
                error.localizedDescription.contains(
                    "ZenCODE did not replay the full conversation"
                )
            )
            #expect(
                error.localizedDescription.contains(
                    "Compact the session and retry"
                )
            )
        }
    }

    @Test
    func chatGPTSubscriptionContinuationUnavailableErrorIgnoresUnrelatedFailures() {
        let error = ChatGPTSubscriptionGenerationError.responseFailed(
            "ChatGPT Subscription request failed because the service is overloaded."
        )

        #expect(
            ChatGPTSubscriptionGenerationClient.continuationUnavailableError(
                from: error
            ) == nil
        )
    }

    @Test
    func chatGPTSubscriptionManualFreshReplayDropsUnavailablePreviousResponseID() throws {
        let messages = chatGPTContinuationMessages()
        let continuation = ChatGPTSubscriptionContinuationState(
            responseID: "resp_missing",
            messageCount: 3,
            instructions: "System prompt",
            allowsFreshTransport: true
        )
        let continuationPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: continuation
        )
        let backendError = ChatGPTSubscriptionGenerationError.responseFailed(
            "Previous response with id 'resp_missing' not found."
        )
        let unavailable = try #require(
            ChatGPTSubscriptionGenerationClient.continuationUnavailableError(
                from: backendError
            )
        )
        guard case .continuationUnavailable = unavailable else {
            Issue.record("Expected a continuation-unavailable error.")
            return
        }

        let fallbackPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: nil
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: fallbackPayload.input),
            model: "gpt-5.5",
            instructions: fallbackPayload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt"
        )
        let fallbackWebSocketPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: fallbackPayload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: fallbackPayload.previousResponseID,
            useCachedContinuation: true
        )

        #expect(continuationPayload.previousResponseID == "resp_missing")
        #expect(continuationPayload.cachedWebSocketInput != nil)
        #expect(fallbackPayload.previousResponseID == nil)
        #expect(fallbackPayload.cachedWebSocketInput == nil)
        #expect(fallbackWebSocketPayload["previous_response_id"] == nil)
        #expect((fallbackWebSocketPayload["input"] as? [Any])?.count == fallbackPayload.input.count)
        #expect((fallbackWebSocketPayload["input"] as? [Any])?.count == continuationPayload.input.count)
    }

    @Test
    func chatGPTSubscriptionRestoresContinuationFromSavedResponseID() throws {
        let history = [
            AgentRuntimeMessage(role: .user, content: "First prompt"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "First answer",
                providerResponseID: "resp_saved"
            )
        ]
        var messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: history,
            allowedToolNames: []
        )
        let continuation = try #require(
            ChatGPTSubscriptionGenerationClient.restoredContinuation(from: messages)
        )
        messages.append(
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "Next prompt",
                attachments: []
            )
        )
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: continuation
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt"
        )
        let resumedPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: continuation.allowsFreshTransport
        )

        #expect(continuation.responseID == "resp_saved")
        #expect(continuation.messageCount == 3)
        #expect(continuation.instructions == "System prompt")
        #expect(continuation.allowsFreshTransport)
        #expect(payload.previousResponseID == "resp_saved")
        #expect(payload.cachedWebSocketInput?.count == 1)
        #expect(resumedPayload["previous_response_id"] as? String == "resp_saved")
        #expect((resumedPayload["input"] as? [Any])?.count == 1)
    }

    @Test
    func chatGPTSubscriptionToolSelectionNoticeDisablesRestoredContinuation() throws {
        let history = [
            AgentRuntimeMessage(role: .user, content: "First prompt"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "First answer",
                providerResponseID: "resp_before_tools"
            ),
            TerminalChat.toolSelectionChangedMessage(
                previousAllowedToolNames: ["local.exec"],
                currentAllowedToolNames: []
            )
        ]
        var messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: history,
            allowedToolNames: []
        )
        let continuation = try #require(
            ChatGPTSubscriptionGenerationClient.restoredContinuation(from: messages)
        )
        messages.append(
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "Next prompt",
                attachments: []
            )
        )
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: continuation
        )

        #expect(continuation.responseID == "resp_before_tools")
        #expect(payload.previousResponseID == nil)
        #expect(payload.cachedWebSocketInput == nil)
        #expect(payload.instructions?.contains("Tool selection changed during this session.") == true)
    }

    @Test
    func chatGPTSubscriptionConnectionScopeSeparatesTransportSessionIdentities() throws {
        func configuration(
            connectionScopeID: String?
        ) -> ChatGPTSubscriptionGenerationClient.RequestConfiguration {
            ChatGPTSubscriptionGenerationClient.RequestConfiguration(
                modelID: "gpt-5.5",
                workingDirectory: "/tmp/project",
                systemPrompt: "System prompt",
                sessionKey: "session-main",
                connectionScopeID: connectionScopeID,
                history: [],
                allowedToolNames: ["local.exec"],
                thinkingSelection: nil,
                appMode: false
            )
        }

        let parentIdentity = ChatGPTSubscriptionGenerationClient.SessionIdentity(
            configuration: configuration(connectionScopeID: nil)
        )
        let subAgentIdentity = ChatGPTSubscriptionGenerationClient.SessionIdentity(
            configuration: configuration(connectionScopeID: "sub-agent-connection")
        )

        #expect(parentIdentity != subAgentIdentity)
        #expect(parentIdentity.connectionScopeID == nil)
        #expect(subAgentIdentity.connectionScopeID == "sub-agent-connection")
        #expect(
            ChatGPTSubscriptionGenerationClient.SessionIdentity(
                storageKey: parentIdentity.storageKey
            ) == parentIdentity
        )
        #expect(
            ChatGPTSubscriptionGenerationClient.SessionIdentity(
                storageKey: subAgentIdentity.storageKey
            ) == subAgentIdentity
        )
    }

    @Test
    func chatGPTSubscriptionFullReplayDropsPlainReasoningTextFallback() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "System prompt"],
            ["role": "user", "content": "First prompt"],
            [
                "role": "assistant",
                "content": "Visible answer",
                "reasoning_content": "hidden thought"
            ],
            ["role": "user", "content": "Second prompt"]
        ]
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: nil
        )
        let genericPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let genericReasoningItem = try #require(
            genericPayload.input.compactMap { $0 as? [String: Any] }
                .first { $0["type"] as? String == "reasoning" }
        )
        let genericContent = try #require(
            genericReasoningItem["content"] as? [[String: Any]]
        )

        #expect(genericContent.first?["type"] as? String == "reasoning_text")
        #expect(genericContent.first?["text"] as? String == "hidden thought")
        #expect(
            payload.input.compactMap { $0 as? [String: Any] }
                .contains { $0["type"] as? String == "reasoning" } == false
        )
    }

    @Test
    func chatGPTSubscriptionReplayStripsReasoningContentWhenEncrypted() throws {
        let reasoningItems: [[String: Any]] = [
            [
                "type": "reasoning",
                "id": "rs_1",
                "summary": [],
                "encrypted_content": "encrypted-state",
                "content": [
                    [
                        "type": "reasoning_text",
                        "text": "hidden thought"
                    ]
                ]
            ]
        ]
        let reasoningData = try JSONValue(jsonObject: reasoningItems).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )
        let messages: [[String: Any]] = [
            ["role": "system", "content": "System prompt"],
            ["role": "user", "content": "First prompt"],
            [
                "role": "assistant",
                "content": "Visible answer",
                "reasoning_items": String(decoding: reasoningData, as: UTF8.self)
            ],
            ["role": "user", "content": "Second prompt"]
        ]
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: nil
        )
        let reasoningItem = try #require(
            payload.input.compactMap { $0 as? [String: Any] }
                .first { $0["type"] as? String == "reasoning" }
        )

        #expect(reasoningItem["id"] == nil)
        #expect(reasoningItem["encrypted_content"] as? String == "encrypted-state")
        #expect(reasoningItem["summary"] != nil)
        #expect(reasoningItem["content"] == nil)
    }

    @Test
    func chatGPTSubscriptionAccumulatorKeepsPlainReasoningItemsForReplay() async throws {
        let accumulator = ChatGPTSubscriptionGenerationClient.StreamAccumulator()
        _ = try await accumulator.ingest(
            ChatGPTSubscriptionGenerationClient.StreamAccumulatorObject([
                "type": "response.output_item.done",
                "output_index": 0,
                "item": [
                    "type": "reasoning",
                    "id": "rs_plain",
                    "summary": [],
                    "content": [
                        [
                            "type": "reasoning_text",
                            "text": "plain thought"
                        ]
                    ]
                ]
            ])
        )
        let result = try await accumulator.result(
            toolCatalog: ChatGPTSubscriptionGenerationClient.StreamAccumulatorToolCatalog(
                RemoteToolWireCatalog(descriptors: [])
            )
        )
        let storedItems = RemoteGenerationClient.responsesReasoningItems(
            from: result.reasoningItemsJSON
        )
        let storedItem = try #require(storedItems.first)
        let content = try #require(storedItem["content"] as? [[String: Any]])

        #expect(storedItems.count == 1)
        #expect(storedItem["id"] as? String == "rs_plain")
        #expect(content.first?["text"] as? String == "plain thought")
    }

    @Test
    func chatGPTSubscriptionWebSocketHasNoDefaultResponseIdleTimeout() {
        #expect(ChatGPTSubscriptionResponsesClient.webSocketIdleTimeoutNanoseconds == nil)
    }

    @Test
    func chatGPTSubscriptionTreatsDisconnectedSocketAsRetryableTransportError() {
        let posixError = POSIXError(.ENOTCONN)
        let nsPosixError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOTCONN.rawValue)
        )
        let localizedSocketError = NSError(
            domain: "UnitTest",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The operation couldn’t be completed. Socket is not connected"
            ]
        )

        #expect(ChatGPTSubscriptionResponsesClient.isRetryableTransportError(posixError))
        #expect(ChatGPTSubscriptionResponsesClient.isRetryableTransportError(nsPosixError))
        #expect(ChatGPTSubscriptionResponsesClient.isRetryableTransportError(localizedSocketError))
        #expect(!ChatGPTSubscriptionResponsesClient.isRetryableTransportError(URLError(.badServerResponse)))
        #expect(ChatGPTSubscriptionResponsesClient.shouldRetryTransportError(posixError, attempt: 0))
        #expect(
            ChatGPTSubscriptionResponsesClient.shouldRetryTransportError(
                nsPosixError,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries - 1
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.shouldRetryTransportError(
                localizedSocketError,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryTransportError(
                posixError,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryTransportError(
                URLError(.badServerResponse),
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryTransportError(
                ChatGPTSubscriptionGenerationError.cancelled,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryTransportError(
                CancellationError(),
                attempt: 0
            )
        )
        #expect(ChatGPTSubscriptionResponsesClient.isCancellationError(URLError(.cancelled)))
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryTransportError(
                URLError(.cancelled),
                attempt: 0
            )
        )
    }

    @Test
    func chatGPTSubscriptionTextDeltasAreBufferedUntilFinalSnapshot() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "response.output_text.delta",
                "delta": "Confermi che proceda?"
            ],
            [
                "type": "response.output_text.delta",
                "delta": "Confermi che proceda?\n\nFile modificati: nessuno."
            ],
            [
                "type": "response.completed",
                "response": [
                    "output_text": "Confermi che proceda?\n\nFile modificati: nessuno."
                ]
            ]
        ])

        #expect(result.text == "Confermi che proceda?\n\nFile modificati: nessuno.")
        #expect(result.contentText == result.text)
    }

    @Test
    func chatGPTSubscriptionUnderscoreTextDeltasAreBufferedUntilFinalSnapshot() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "response_output_text_delta",
                "delta": "Prima parte. "
            ],
            [
                "type": "response_output_text_delta",
                "delta": "Seconda parte."
            ],
            [
                "type": "response_completed",
                "response": [
                    "output_text": "Prima parte. Seconda parte."
                ]
            ]
        ])

        #expect(result.text == "Prima parte. Seconda parte.")
        #expect(result.contentText == result.text)
    }

    @Test
    func chatGPTSubscriptionCorrectedDeltaSnapshotReplacesBufferedDraft() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "response_output_text_delta",
                "delta": "Corego le ultime indentazioni accidentali evidenziate dal diff, poi rilancio swift build."
            ],
            [
                "type": "response_output_text_delta",
                "delta": "Correggo le ultime indentazioni accidentali evidenziate dal diff, poi rilancio swift build."
            ],
            [
                "type": "response_completed"
            ]
        ])

        #expect(result.text == "Correggo le ultime indentazioni accidentali evidenziate dal diff, poi rilancio swift build.")
        #expect(result.contentText.isEmpty)
    }

    @Test
    func chatGPTSubscriptionCorrectedFinalSnapshotReplacesBufferedDraft() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "response_output_text_delta",
                "delta": "Corego le ultime indentazioni accidentali evidenziate dal diff."
            ],
            [
                "type": "response_completed",
                "response": [
                    "output_text": "Correggo le ultime indentazioni accidentali evidenziate dal diff."
                ]
            ]
        ])

        #expect(result.text == "Correggo le ultime indentazioni accidentali evidenziate dal diff.")
        #expect(result.contentText == result.text)
        #expect(!result.contentText.contains("Corego"))
    }

    @Test
    func chatGPTSubscriptionCompletedSnapshotExtendsExistingContent() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "response.output_text.delta",
                "delta": "Confermi che proceda?"
            ],
            [
                "type": "response.completed",
                "response": [
                    "output_text": "Confermi che proceda?\n\nFile modificati: nessuno."
                ]
            ]
        ])

        #expect(result.text == "Confermi che proceda?\n\nFile modificati: nessuno.")
        #expect(result.contentText == result.text)
    }

    @Test
    func chatGPTSubscriptionContentSnapshotExtendsBufferedContent() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "response.output_text.delta",
                "delta": "Prima "
            ],
            [
                "type": "response.content_part.done",
                "part": [
                    "type": "output_text",
                    "text": "parte."
                ]
            ],
            [
                "type": "response.completed"
            ]
        ])

        #expect(result.text == "Prima parte.")
        #expect(result.contentText.isEmpty)
    }

    @Test
    func chatGPTSubscriptionPreservesRefusalStopReasonAfterCompleted() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "response.refusal.done",
                "refusal": "Non posso aiutare con questa richiesta."
            ],
            [
                "type": "response.completed",
                "response": ["output": []]
            ]
        ])

        #expect(result.text == "Non posso aiutare con questa richiesta.")
        #expect(result.stopReason == "refusal")
    }

    @Test
    func chatGPTSubscriptionReasoningItemContentStreamsThought() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "response.output_item.done",
                "output_index": 0,
                "item": [
                    "type": "reasoning",
                    "id": "rs_plain",
                    "summary": [],
                    "content": [
                        [
                            "type": "reasoning_text",
                            "text": "plain thought"
                        ]
                    ]
                ]
            ],
            [
                "type": "response.completed",
                "response": ["output": []]
            ]
        ])

        #expect(result.thoughtText == "plain thought")
        #expect(result.reasoningText == "plain thought")
    }

    @Test
    func chatGPTSubscriptionLegacyReasoningDeltaStreamsThought() async throws {
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects([
            [
                "type": "reasoning_content_delta",
                "delta": "legacy thought"
            ],
            [
                "type": "response.completed",
                "response": ["output": []]
            ]
        ])

        #expect(result.thoughtText == "legacy thought")
        #expect(result.reasoningText == "legacy thought")
    }

    @Test
    func chatCompletionDeltaContentPartsAreParsedAsContent() {
        let events = RemoteGenerationClient.parseChatCompletionStreamEvent([
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
        let events = RemoteGenerationClient.parseResponsesStreamEvent([
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
    func streamResponsesDoesNotDuplicateOutputItemSnapshotAfterDelta() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"Visible answer"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-output-item-message-dedup",
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
    func streamResponsesDoesNotDuplicateMultipartOutputItemSnapshotAfterDeltas() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"Visible "}

        data: {"type":"response.output_text.delta","delta":"answer"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"Visible "},{"type":"output_text","text":"answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession
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
    func chatGPTSubscriptionRequestBodySendsWireSafeXcodeToolNames() throws {
        let catalog = remoteXcodeToolCatalog()
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: catalog.wireMessages(from: remoteXcodeHistoryMessages()),
            continuation: nil
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt-xcode",
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
                && $0["call_id"] as? String == "call_previous_xcode"
        })

        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("xcode.BuildProject"))
        #expect(historyFunctionCall["name"] as? String == "tool_xcode_BuildProject")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("xcode.BuildProject") == false)
    }

    @Test
    func chatGPTSubscriptionClientUsesInjectedMCPRuntimeForActiveTools() async throws {
        let client = ChatGPTSubscriptionGenerationClient(
            configuration: remoteStreamingConfiguration(),
            mcpRuntime: await borrowedXcodeMCPRuntime()
        )

        await client.createSession(
            id: "session-chatgpt-xcode-tools",
            cwd: "/tmp/project",
            allowedToolNames: ["xcode."]
        )
        let descriptors = await client.activeToolDescriptors()

        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
    }

    @Test
    func chatGPTSubscriptionPromptCacheKeyIsContentAddressed() throws {
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
        let sameContentDifferentSession = ChatGPTSubscriptionRequestBuilder.promptCacheKey(
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

        #expect(key.hasPrefix("pck_"))
        #expect(key.count == 28)
        #expect(key == sameContentDifferentSession)
        #expect(key != differentInstructions)
        #expect(emptyPrefix == "session-fallback")
    }

    @Test
    func chatGPTSubscriptionRequestBodyUsesContentAddressedPromptCacheKey() throws {
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: .array([]),
            model: "gpt-5.5",
            instructions: "System prompt",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "session-chatgpt"
        )
        let cacheKey = try #require(body["prompt_cache_key"] as? String)

        #expect(cacheKey.hasPrefix("pck_"))
        #expect(cacheKey != "session-chatgpt")
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
#endif
