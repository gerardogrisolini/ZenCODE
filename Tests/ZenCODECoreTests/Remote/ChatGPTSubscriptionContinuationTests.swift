//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

extension RemoteSessionSnapshotTests {
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
    func chatGPTSubscriptionContinuationUnavailableErrorIsDetectedForReplayFallback() throws {
        let errors = [
            ChatGPTSubscriptionGenerationError.responseFailed(
                "Previous response id resp_saved could not be found."
            ),
            ChatGPTSubscriptionGenerationError.responseFailed(
                "Unsupported parameter: previous_response_id"
            ),
            ChatGPTSubscriptionGenerationError.responseFailed(
                "Invalid response_id provided."
            ),
            ChatGPTSubscriptionGenerationError.responseFailed(
                "Response with id 'resp_missing' has expired."
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
                    "could not be replayed automatically"
                )
            )
        }

        let diagnostic = ChatGPTSubscriptionGenerationClient
            .continuationReplayFallbackDiagnostic()
        #expect(diagnostic.contains("full conversation replay"))
    }

    @Test
    func chatGPTSubscriptionStructuredBackendFailuresRetryThenFallBackToHTTP() throws {
        let message = """
        An error occurred while processing your request. You can retry your request, or contact us through our help center at help.openai.com if the error persists. Please include the request ID 2500a4a9-690b-4951-beb3-602a7d5893d8 in your message.
        """
        let overloadedMessage =
            "Our servers are currently overloaded. Please try again later."
        let canonicalObject: [String: Any] = [
            "type": "error",
            "error": [
                "type": "server_error",
                "code": "server_error",
                "message": message
            ],
            "sequence_number": 2
        ]
        let nonCanonicalObject: [String: Any] = [
            "type": "error",
            "error": [
                "type": "invalid_request_error",
                "code": "invalid_request_error",
                "message": message
            ]
        ]
        let overloadedObject: [String: Any] = [
            "type": "response.failed",
            "response": [
                "status": "failed",
                "error": [
                    "code": "server_is_overloaded",
                    "message": overloadedMessage
                ]
            ]
        ]
        let genericFailedObject: [String: Any] = [
            "type": "response.failed",
            "response": [
                "status": "failed",
                "error": [
                    "message": message
                ]
            ]
        ]
        let invalidRequestFailedObject: [String: Any] = [
            "type": "response.failed",
            "response": [
                "status": "failed",
                "error": [
                    "code": "invalid_request_error",
                    "message": "The request payload is invalid."
                ]
            ]
        ]
        let explicitlyRetryableTypedObject: [String: Any] = [
            "type": "error",
            "error": [
                "type": "invalid_request_error",
                "code": "websocket_connection_limit_reached",
                "message": ChatGPTSubscriptionResponsesClient
                    .webSocketConnectionLimitErrorMessage
            ]
        ]
        let rateLimitedObject: [String: Any] = [
            "type": "response.failed",
            "response": [
                "status": "failed",
                "error": [
                    "type": "invalid_request_error",
                    "code": "rate_limit_exceeded",
                    "message": "Rate limit reached. Please try again in 11.054s."
                ]
            ]
        ]
        let slowDownObject: [String: Any] = [
            "type": "error",
            "error": [
                "code": "slow_down",
                "message": overloadedMessage
            ]
        ]
        let wrappedServerFailure: [String: Any] = [
            "type": "error",
            "status_code": 502,
            "error": [
                "type": "upstream_error",
                "message": "Temporary upstream failure."
            ]
        ]
        let retryableError = try #require(
            ChatGPTSubscriptionResponsesClient.retryableBackendFailure(
                from: canonicalObject
            )
        )
        let overloadedError = try #require(
            ChatGPTSubscriptionResponsesClient.retryableBackendFailure(
                from: overloadedObject
            )
        )
        let genericFailedError = try #require(
            ChatGPTSubscriptionResponsesClient.retryableBackendFailure(
                from: genericFailedObject
            )
        )
        let explicitlyRetryableTypedError = try #require(
            ChatGPTSubscriptionResponsesClient.retryableBackendFailure(
                from: explicitlyRetryableTypedObject
            )
        )
        let rateLimitedError = try #require(
            ChatGPTSubscriptionResponsesClient.retryableBackendFailure(
                from: rateLimitedObject
            )
        )
        let callbackError = ChatGPTSubscriptionGenerationError.responseFailed(message)
        let replayUnsafeError = ChatGPTSubscriptionResponsesClient
            .ReplayUnsafeStreamFailure(underlying: retryableError)
        let unrelatedError = ChatGPTSubscriptionGenerationError.responseFailed(
            "The model produced an invalid tool call."
        )
        let incompleteGenericError = ChatGPTSubscriptionGenerationError.responseFailed(
            "An error occurred while processing your request. You can retry your request."
        )

        #expect(
            ChatGPTSubscriptionGenerationClient.responseErrorMessage(
                from: canonicalObject
            ) == message
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.retryableBackendFailure(
                from: nonCanonicalObject
            ) == nil
        )
        #expect(overloadedError.localizedDescription == overloadedMessage)
        #expect(genericFailedError.localizedDescription == message)
        #expect(
            explicitlyRetryableTypedError.localizedDescription
                == ChatGPTSubscriptionResponsesClient
                    .webSocketConnectionLimitErrorMessage
        )
        #expect(rateLimitedError.retryDelayNanoseconds == 11_054_000_000)
        #expect(
            ChatGPTSubscriptionResponsesClient.retryDelayNanoseconds(
                from: "Rate limit reached. Please try again in 250 milliseconds.",
                errorCode: "rate_limit_exceeded"
            ) == 250_000_000
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.retryDelayNanoseconds(
                from: "Rate limit reached. Please try again later.",
                errorCode: "rate_limit_exceeded"
            ) == nil
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.retryDelayNanoseconds(
                from: "Please try again in 18446744073.709551616s.",
                errorCode: "rate_limit_exceeded"
            ) == nil
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.retryableBackendFailure(
                from: invalidRequestFailedObject
            ) == nil
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.retryableBackendFailure(
                from: slowDownObject
            )?.localizedDescription == overloadedMessage
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.retryableBackendFailure(
                from: wrappedServerFailure
            )?.localizedDescription == "Temporary upstream failure."
        )
        #expect(replayUnsafeError.localizedDescription == message)
        #expect(
            !ChatGPTSubscriptionGenerationClient.isRetryableStreamInterruption(
                retryableError
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.shouldRetryHTTPFailure(
                retryableError,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryHTTPFailure(
                retryableError,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryHTTPFailure(
                replayUnsafeError,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryHTTPFailure(
                RemoteTransportError.closed,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryHTTPFailure(
                callbackError,
                attempt: 0
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.shouldRetryWebSocketFailure(
                retryableError,
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                retryableError,
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                retryableError,
                receivedReplayUnsafeEvent: false,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                retryableError,
                receivedReplayUnsafeEvent: true,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                callbackError,
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionGenerationClient.isRetryableStreamInterruption(
                unrelatedError
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                unrelatedError,
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                incompleteGenericError,
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
    }

    @Test
    func chatGPTSubscriptionUpgradeRejectedAuthFailureIsRetryable() {
        let unauthorized = RemoteTransportError.upgradeRejected(
            status: 401,
            body: #"{"error":"invalid_token"}"#
        )
        let forbidden = RemoteTransportError.upgradeRejected(
            status: 403,
            body: #"{"error":"forbidden"}"#
        )
        let rateLimited = RemoteTransportError.upgradeRejected(
            status: 429,
            body: #"{"error":"rate_limit"}"#
        )
        let upgradeRequired = RemoteTransportError.upgradeRejected(
            status: 426,
            body: #"{"error":"use_http"}"#
        )
        let badRequest = RemoteTransportError.upgradeRejected(
            status: 400,
            body: #"{"error":"bad_request"}"#
        )
        let notFound = RemoteTransportError.upgradeRejected(
            status: 404,
            body: #"{"error":"not_found"}"#
        )

        #expect(
            ChatGPTSubscriptionResponsesClient.isRetryableTransportError(unauthorized)
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.isRetryableTransportError(forbidden)
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.isRetryableTransportError(rateLimited)
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.isRetryableTransportError(badRequest)
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.isRetryableTransportError(notFound)
        )

        #expect(
            ChatGPTSubscriptionGenerationClient.isAuthenticationFailure(unauthorized)
        )
        #expect(
            ChatGPTSubscriptionGenerationClient.isAuthenticationFailure(forbidden)
        )
        #expect(
            !ChatGPTSubscriptionGenerationClient.isAuthenticationFailure(rateLimited)
        )
        #expect(
            !ChatGPTSubscriptionGenerationClient.isRetryableStreamInterruption(
                rateLimited
            )
        )
        #expect(
            !ChatGPTSubscriptionGenerationClient.isAuthenticationFailure(badRequest)
        )
        #expect(
            ChatGPTSubscriptionGenerationClient.isAuthenticationFailure(
                ChatGPTSubscriptionGenerationError.http(
                    status: 401,
                    output: #"{"error":"invalid_token"}"#
                )
            )
        )
        #expect(
            !ChatGPTSubscriptionGenerationClient.isAuthenticationFailure(
                ChatGPTSubscriptionGenerationError.http(
                    status: 429,
                    output: #"{"error":"rate_limit"}"#
                )
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                unauthorized,
                receivedReplayUnsafeEvent: false,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryWebSocketFailure(
                unauthorized,
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.shouldRetryWebSocketFailure(
                rateLimited,
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                rateLimited,
                receivedReplayUnsafeEvent: false,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                upgradeRequired,
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
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
        let result = try await accumulator.result()
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
    func chatGPTSubscriptionWebSocketUsesCodexHandshakeHeaders() {
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials()
        )

        let request = client.webSocketRequest(
            sessionID: "session-chatgpt",
            threadID: "logical-session"
        )

        #expect(
            request.headerValue(for: "session-id") == "session-chatgpt"
        )
        #expect(
            request.headerValue(for: "thread-id") == "logical-session"
        )
        #expect(request.headerValue(for: "session_id") == nil)
        #expect(
            request.headerValue(for: "OpenAI-Beta")
                == "responses_websockets=2026-02-06"
        )
        #expect(
            request.headerValue(for: "x-client-request-id")
                == "logical-session"
        )
    }

    @Test
    func chatGPTSubscriptionWebSocketPoolReopensExpiredIdleSocketWithCurrentRequest() {
        let harness = ChatGPTSubscriptionWebSocketPoolHarness(
            maximumConnectionAge: .seconds(10)
        )
        let oldRequest = harness.request(authorization: "Bearer stale")
        let firstLease = harness.pool.acquire(
            sessionID: "session-age-boundary",
            request: oldRequest
        )
        harness.pool.release(firstLease, keepAlive: true)

        harness.advance(by: .seconds(9))
        let underBoundaryLease = harness.pool.acquire(
            sessionID: "session-age-boundary",
            request: harness.request(authorization: "Bearer ignored")
        )
        #expect(underBoundaryLease.isReused)
        #expect(underBoundaryLease.task === firstLease.task)
        harness.pool.release(underBoundaryLease, keepAlive: true)

        harness.advance(by: .seconds(1))
        let currentRequest = harness.request(authorization: "Bearer current")
        let renewedLease = harness.pool.acquire(
            sessionID: "session-age-boundary",
            request: currentRequest
        )

        #expect(!renewedLease.isReused)
        #expect(renewedLease.task !== firstLease.task)
        #expect(harness.closeCount(for: firstLease.task) == 1)
        #expect(harness.createdRequests().count == 2)
        #expect(
            harness.createdRequests().last?.headerValue(
                for: "Authorization"
            ) == "Bearer current"
        )

        harness.pool.release(renewedLease, keepAlive: false)
        #expect(harness.closeCount(for: renewedLease.task) == 1)
    }

    @Test
    func chatGPTSubscriptionRetriesOnlyCanonicalWebSocketConnectionLimit() {
        let canonicalMessage = ChatGPTSubscriptionResponsesClient
            .webSocketConnectionLimitErrorMessage
        let canonicalError = ChatGPTSubscriptionGenerationError.responseFailed(
            canonicalMessage
        )
        let caseVariant = ChatGPTSubscriptionGenerationError.responseFailed(
            canonicalMessage.uppercased()
        )
        let prefixedError = ChatGPTSubscriptionGenerationError.responseFailed(
            "Backend detail: \(canonicalMessage)"
        )
        let whitespacePaddedError = ChatGPTSubscriptionGenerationError.responseFailed(
            " \(canonicalMessage)"
        )
        let unrelatedApplicationError = ChatGPTSubscriptionGenerationError.responseFailed(
            "The response could not be completed."
        )
        let genericErrorWithCanonicalText = NSError(
            domain: "UnitTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: canonicalMessage]
        )

        #expect(
            ChatGPTSubscriptionResponsesClient
                .isWebSocketConnectionLimitMessage(canonicalMessage)
        )
        #expect(
            ChatGPTSubscriptionResponsesClient
                .isWebSocketConnectionLimitError(canonicalError)
        )
        #expect(
            ChatGPTSubscriptionResponsesClient
                .isRetryableTransportError(caseVariant)
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient
                .isRetryableTransportError(prefixedError)
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient
                .isRetryableTransportError(whitespacePaddedError)
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient
                .isRetryableTransportError(unrelatedApplicationError)
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient
                .isRetryableTransportError(genericErrorWithCanonicalText)
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.shouldRetryWebSocketFailure(
                canonicalError,
                receivedReplayUnsafeEvent: false,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries - 1
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryWebSocketFailure(
                canonicalError,
                receivedReplayUnsafeEvent: false,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryWebSocketFailure(
                canonicalError,
                receivedReplayUnsafeEvent: true,
                attempt: 0
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                canonicalError,
                receivedReplayUnsafeEvent: false,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries - 1
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.shouldActivateHTTPFallback(
                canonicalError,
                receivedReplayUnsafeEvent: false,
                attempt: ChatGPTSubscriptionResponsesClient.maxRetries
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.shouldRetryWebSocketFailure(
                CancellationError(),
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
    }

    @Test
    func chatGPTSubscriptionNIOClientHonorsRateLimitRetryDelay() async throws {
        let rateLimitedResponse = try JSONValue(jsonObject: [
            "type": "response.failed",
            "response": [
                "status": "failed",
                "error": [
                    "code": "rate_limit_exceeded",
                    "message": "Rate limit reached. Please try again in 11.054s."
                ]
            ]
        ]).jsonData(outputFormatting: [.withoutEscapingSlashes])
        let firstTask = ChatGPTSubscriptionTestWebSocketTask(
            receiveOutcomes: [
                .success(.text(String(decoding: rateLimitedResponse, as: UTF8.self)))
            ]
        )
        let secondTask = ChatGPTSubscriptionTestWebSocketTask(
            receiveOutcomes: [
                .success(
                    .text(
                        #"{"type":"response.completed","response":{"id":"resp_after_rate_limit","status":"completed"}}"#
                    )
                )
            ]
        )
        let pendingTasks = Mutex([firstTask, secondTask])
        let localBackoffAttempts = Mutex<[Int]>([])
        let providerRetryDelays = Mutex<[UInt64]>([])
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            webSocketTaskFactory: { _ in
                pendingTasks.withLock { $0.removeFirst() }
            }
        )
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials(),
            baseURL: URL(string: "https://example.invalid/backend-api")!,
            webSocketPool: pool,
            retrySleep: { attempt in
                localBackoffAttempts.withLock { $0.append(attempt) }
            },
            retryDelaySleep: { delay in
                providerRetryDelays.withLock { $0.append(delay) }
            }
        )

        let completion = try await client.streamEvents(
            input: .array([]),
            model: "gpt-5.5",
            instructions: "System prompt",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "rate-limit-transport",
            fallbackScopeID: "rate-limit-logical-session"
        ) { _ in }

        #expect(completion.responseID == "resp_after_rate_limit")
        #expect(localBackoffAttempts.withLock { $0 }.isEmpty)
        #expect(providerRetryDelays.withLock { $0 } == [11_054_000_000])
        #expect(firstTask.cancelCount == 1)
        #expect(secondTask.cancelCount == 0)
    }

    @Test
    func chatGPTSubscriptionNIOClientFallsBackAndRetriesGenericRequestFailureOverHTTP() async throws {
        let message = """
        An error occurred while processing your request. You can retry your request, or contact us through our help center at help.openai.com if the error persists. Please include the request ID 2500a4a9-690b-4951-beb3-602a7d5893d8 in your message.
        """
        let failedResponse = try JSONValue(jsonObject: [
            "type": "response.failed",
            "response": [
                "status": "failed",
                "error": [
                    "message": message
                ]
            ],
            "sequence_number": 2
        ]).jsonData(outputFormatting: [.withoutEscapingSlashes])
        let webSocketTasks = (0...ChatGPTSubscriptionResponsesClient.maxRetries).map { _ in
            ChatGPTSubscriptionTestWebSocketTask(
                receiveOutcomes: [
                    .success(.text(String(decoding: failedResponse, as: UTF8.self)))
                ]
            )
        }
        let pendingWebSocketTasks = Mutex(webSocketTasks)
        let factoryCount = Mutex(0)
        let capturedRequests = Mutex<[RemoteWebSocketRequest]>([])
        let capturedHTTPBodies = Mutex<[JSONValue]>([])
        let httpFallbackSessionIDs = Mutex<[String]>([])
        let retrySleepAttempts = Mutex<[Int]>([])
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            webSocketTaskFactory: { request in
                factoryCount.withLock { $0 += 1 }
                capturedRequests.withLock { $0.append(request) }
                return pendingWebSocketTasks.withLock { $0.removeFirst() }
            }
        )
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials(),
            baseURL: URL(string: "https://example.invalid/backend-api")!,
            webSocketPool: pool,
            retrySleep: { attempt in
                retrySleepAttempts.withLock { $0.append(attempt) }
            },
            httpFallbackOverride: { body, sessionID in
                let attempt = capturedHTTPBodies.withLock { bodies in
                    bodies.append(body)
                    return bodies.count
                }
                httpFallbackSessionIDs.withLock { $0.append(sessionID) }
                if attempt == 1 {
                    throw ChatGPTSubscriptionResponsesClient.RetryableBackendFailure(
                        message: message
                    )
                }
                return ChatGPTSubscriptionResponsesClient.StreamCompletion(
                    responseID: "resp_http_fallback"
                )
            }
        )

        let completion = try await client.streamEvents(
            input: JSONValue.acpValue(from: [["marker": "full-replay"]]),
            model: "gpt-5.5",
            instructions: "System prompt",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "transport-session-a",
            threadID: "logical-session",
            fallbackScopeID: "logical-session",
            cachedWebSocketInput: JSONValue.acpValue(
                from: [["marker": "continuation-delta"]]
            ),
            previousResponseID: "resp_previous",
            allowsFreshWebSocketContinuation: true
        ) { object in
            if let errorMessage = ChatGPTSubscriptionGenerationClient
                .responseErrorMessage(from: object) {
                throw ChatGPTSubscriptionGenerationError.responseFailed(errorMessage)
            }
        }

        let nextCompletion = try await client.streamEvents(
            input: .array([]),
            model: "gpt-5.5",
            instructions: "System prompt",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "transport-session-b",
            threadID: "logical-session",
            fallbackScopeID: "logical-session"
        ) { _ in }

        let request = try #require(capturedRequests.withLock { $0.first })
        let webSocketPayload = try #require(
            webSocketTasks.first?.sentMessages.first?.jsonObject
        )
        let retryWebSocketPayload = try #require(
            webSocketTasks.dropFirst().first?.sentMessages.first?.jsonObject
        )
        let firstHTTPBodyValue = try #require(
            capturedHTTPBodies.withLock { $0.first }
        )
        let firstHTTPBody = try #require(
            firstHTTPBodyValue.acpJSONObject as? [String: Any]
        )
        let webSocketInput = try #require(webSocketPayload["input"] as? [[String: Any]])
        let httpInput = try #require(firstHTTPBody["input"] as? [[String: Any]])
        #expect(completion.responseID == "resp_http_fallback")
        #expect(completion.didActivateHTTPFallback)
        #expect(nextCompletion.responseID == "resp_http_fallback")
        #expect(!nextCompletion.didActivateHTTPFallback)
        #expect(factoryCount.withLock { $0 } == webSocketTasks.count)
        #expect(httpFallbackSessionIDs.withLock { $0 } == [
            "transport-session-a",
            "transport-session-a",
            "transport-session-b"
        ])
        #expect(capturedHTTPBodies.withLock { $0.count } == 3)
        #expect(
            retrySleepAttempts.withLock { $0 }
                == Array(0..<ChatGPTSubscriptionResponsesClient.maxRetries) + [0]
        )
        #expect(request.headerValue(for: "session-id") == "transport-session-a")
        #expect(request.headerValue(for: "thread-id") == "logical-session")
        #expect(request.headerValue(for: "x-client-request-id") == "logical-session")
        #expect(webSocketPayload["previous_response_id"] as? String == "resp_previous")
        #expect(webSocketInput.first?["marker"] as? String == "continuation-delta")
        #expect(retryWebSocketPayload["previous_response_id"] == nil)
        #expect(
            (retryWebSocketPayload["input"] as? [[String: Any]])?.first?["marker"]
                as? String == "full-replay"
        )
        #expect(firstHTTPBody["previous_response_id"] == nil)
        #expect(httpInput.first?["marker"] as? String == "full-replay")
        #expect(webSocketTasks.allSatisfy { $0.cancelCount == 1 })

        pool.closeSession(sessionID: "transport-session-a")
        #expect(pool.usesHTTPFallback(scopeID: "logical-session"))
        pool.closeAll()
        #expect(pool.usesHTTPFallback(scopeID: "logical-session"))
        pool.clearHTTPFallback(scopeID: "logical-session")
        #expect(!pool.usesHTTPFallback(scopeID: "logical-session"))
    }

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
        defer { pool.closeAll() }
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
        let result = try await ChatGPTSubscriptionGenerationClient.testIngestStreamObjects(objects)

        if let text = testCase.text {
            #expect(result.text == text)
        }
        if let contentText = testCase.contentText {
            #expect(result.contentText == contentText)
        }
        if let thoughtText = testCase.thoughtText {
            #expect(result.thoughtText == thoughtText)
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

private final class ChatGPTSubscriptionWebSocketPoolHarness: @unchecked Sendable {
    let pool: ChatGPTSubscriptionWebSocketPool

    private let state: ChatGPTSubscriptionWebSocketPoolHarnessState

    init(maximumConnectionAge: Duration) {
        let state = ChatGPTSubscriptionWebSocketPoolHarnessState()

        self.state = state
        self.pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            maximumConnectionAge: maximumConnectionAge,
            monotonicClock: {
                state.clock.withLock { $0 }
            },
            webSocketTaskFactory: { request in
                state.requests.withLock { $0.append(request) }
                return ChatGPTSubscriptionTestWebSocketTask()
            },
            closeWebSocketTask: { task in
                state.closeCounts.withLock {
                    $0[ObjectIdentifier(task), default: 0] += 1
                }
                task.cancel(
                    with: ChatGPTSubscriptionWebSocketCloseCode.normalClosure,
                    reason: nil
                )
            }
        )
    }

    deinit {
        pool.closeAll()
    }

    func request(authorization: String? = nil) -> RemoteWebSocketRequest {
        var headers: [RemoteHTTPHeader] = []
        if let authorization {
            headers.append(
                RemoteHTTPHeader(name: "Authorization", value: authorization)
            )
        }
        return RemoteWebSocketRequest(
            url: URL(string: "wss://example.invalid/responses")!,
            headers: headers
        )
    }

    func advance(by duration: Duration) {
        state.clock.withLock {
            $0 = $0.advanced(by: duration)
        }
    }

    func createdRequests() -> [RemoteWebSocketRequest] {
        state.requests.withLock { $0 }
    }

    func closeCount(
        for task: any ChatGPTSubscriptionWebSocketTask
    ) -> Int {
        state.closeCounts.withLock { $0[ObjectIdentifier(task), default: 0] }
    }
}

private final class ChatGPTSubscriptionWebSocketPoolHarnessState: @unchecked Sendable {
    let clock = Mutex(ContinuousClock.now)
    let requests = Mutex<[RemoteWebSocketRequest]>([])
    let closeCounts = Mutex<[ObjectIdentifier: Int]>([:])
}

/// Deterministic adapter double shared by all ChatGPT WebSocket tests. It has
/// no Foundation/WebKit/Network dependency, so exactly the same tests compile
/// on macOS and Linux.
final class ChatGPTSubscriptionTestWebSocketTask:
    ChatGPTSubscriptionWebSocketTask,
    @unchecked Sendable
{
    private struct State {
        var taskState: ChatGPTSubscriptionWebSocketTaskState = .suspended
        var closeCode: UInt16?
        var sendOutcomes: [Result<Void, Error>]
        var receiveOutcomes: [
            Result<ChatGPTSubscriptionWebSocketMessage, Error>
        ]
        var pingOutcomes: [Result<Void, Error>]
        var receiveWaiter: CheckedContinuation<
            ChatGPTSubscriptionWebSocketMessage,
            Error
        >?
        var sendWaiter: CheckedContinuation<Void, Never>?
        var sentMessages: [ChatGPTSubscriptionWebSocketMessage] = []
        var cancelCount = 0
        var resumeCount = 0
    }

    private let stateStorage: Mutex<State>

    init(
        sendOutcomes: [Result<Void, Error>] = [],
        receiveOutcomes: [Result<ChatGPTSubscriptionWebSocketMessage, Error>] = [],
        pingOutcomes: [Result<Void, Error>] = []
    ) {
        stateStorage = Mutex(
            State(
                sendOutcomes: sendOutcomes,
                receiveOutcomes: receiveOutcomes,
                pingOutcomes: pingOutcomes
            )
        )
    }

    var closeCode: UInt16? {
        stateStorage.withLock(\.closeCode)
    }

    var state: ChatGPTSubscriptionWebSocketTaskState {
        stateStorage.withLock(\.taskState)
    }

    var sentMessages: [ChatGPTSubscriptionWebSocketMessage] {
        stateStorage.withLock(\.sentMessages)
    }

    var cancelCount: Int {
        stateStorage.withLock(\.cancelCount)
    }

    func resume() {
        stateStorage.withLock { state in
            state.resumeCount += 1
            guard state.taskState == .suspended else {
                return
            }
            state.taskState = .running
        }
    }

    func send(_ message: ChatGPTSubscriptionWebSocketMessage) async throws {
        let outcome = stateStorage.withLock { state -> (
            Result<Void, Error>,
            CheckedContinuation<Void, Never>?
        ) in
            state.sentMessages.append(message)
            let result = state.sendOutcomes.isEmpty
                ? Result<Void, Error>.success(())
                : state.sendOutcomes.removeFirst()
            let waiter = state.sendWaiter
            state.sendWaiter = nil
            return (result, waiter)
        }
        outcome.1?.resume()
        try outcome.0.get()
    }

    func receive() async throws -> ChatGPTSubscriptionWebSocketMessage {
        if let result = stateStorage.withLock({ state in
            state.receiveOutcomes.isEmpty ? nil : state.receiveOutcomes.removeFirst()
        }) {
            return try result.get()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<
                    ChatGPTSubscriptionWebSocketMessage,
                    Error
                >) in
                let result = stateStorage.withLock {
                    state -> Result<ChatGPTSubscriptionWebSocketMessage, Error>? in
                    if !state.receiveOutcomes.isEmpty {
                        return state.receiveOutcomes.removeFirst()
                    }
                    if state.taskState == .canceling || state.taskState == .completed {
                        return .failure(CancellationError())
                    }
                    state.receiveWaiter = continuation
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancel(
                with: ChatGPTSubscriptionWebSocketCloseCode.goingAway,
                reason: nil
            )
        }
    }

    func sendPing() async throws {
        let result = stateStorage.withLock { state -> Result<Void, Error> in
            guard !state.pingOutcomes.isEmpty else {
                return .success(())
            }
            return state.pingOutcomes.removeFirst()
        }
        try result.get()
    }

    func sendHeartbeatPing() async throws {
        try await sendPing()
    }

    func cancel(with closeCode: UInt16?, reason _: Data?) {
        let waiter = stateStorage.withLock {
            state -> CheckedContinuation<ChatGPTSubscriptionWebSocketMessage, Error>? in
            state.cancelCount += 1
            state.closeCode = closeCode
            state.taskState = .canceling
            let waiter = state.receiveWaiter
            state.receiveWaiter = nil
            return waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    func waitForSend() async {
        if !stateStorage.withLock(\.sentMessages).isEmpty {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResume = stateStorage.withLock { state -> Bool in
                if !state.sentMessages.isEmpty {
                    return true
                }
                state.sendWaiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private extension RemoteWebSocketRequest {
    func headerValue(for name: String) -> String? {
        headers.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

private extension ChatGPTSubscriptionWebSocketMessage {
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
