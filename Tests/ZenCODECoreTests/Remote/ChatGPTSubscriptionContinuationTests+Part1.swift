//
//  ChatGPTSubscriptionContinuationTests+Part1.swift
//  ZenCODE
//
//  First part of the ChatGPT Subscription continuation tests: cached
//  continuations, replay fallback detection, structured backend and auth
//  failure retries, and continuations restored from a saved response ID.
//  Tests of this serialized suite run in file-name order: keep the name.
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
            ChatSessionController.toolSelectionChangedMessage(
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
}
