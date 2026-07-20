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
    func chatGPTSubscriptionClosedSocketErrorsAreRetryableTransportFailures() {
        let abortedSocket = POSIXError(.ECONNABORTED)
        let closedSocketError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOTCONN.rawValue),
            userInfo: [NSLocalizedDescriptionKey: "Socket is not connected"]
        )
        let closedMessageError = NSError(
            domain: "NWErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Socket is closed"]
        )

        #expect(
            ChatGPTSubscriptionResponsesClient.isRetryableTransportError(
                abortedSocket
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.isRetryableTransportError(
                closedSocketError
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.isRetryableTransportError(
                closedMessageError
            )
        )
    }

    @Test
    func chatGPTSubscriptionStreamInterruptionRetryMatchesOnlyTransportFailures() {
        let transportError = URLError(.networkConnectionLost)
        let cancellation = CancellationError()
        let applicationError = ChatGPTSubscriptionGenerationError.responseFailed(
            "The model produced an invalid tool call."
        )

        #expect(
            ChatGPTSubscriptionGenerationClient.isRetryableStreamInterruption(
                transportError
            )
        )
        #expect(
            !ChatGPTSubscriptionGenerationClient.isRetryableStreamInterruption(
                cancellation
            )
        )
        #expect(
            !ChatGPTSubscriptionGenerationClient.isRetryableStreamInterruption(
                applicationError
            )
        )
        #expect(
            ChatGPTSubscriptionGenerationClient.streamInterruptionRetryDiagnostic()
                .contains("full conversation replay")
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

        // Both the subscription builder and the generic Responses payload drop
        // loose reasoning text from previous rounds: replaying it would only
        // inflate billed input tokens on every turn.
        #expect(
            genericPayload.input.compactMap { $0 as? [String: Any] }
                .contains { $0["type"] as? String == "reasoning" } == false
        )
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
    func chatGPTSubscriptionWebSocketUsesCodexHandshakeHeaders() {
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials()
        )

        let request = client.webSocketRequest(sessionID: "session-chatgpt")

        #expect(
            request.headerValue(for: "session-id") == "session-chatgpt"
        )
        #expect(request.headerValue(for: "session_id") == nil)
        #expect(
            request.headerValue(for: "OpenAI-Beta")
                == "responses_websockets=2026-02-06"
        )
        #expect(
            request.headerValue(for: "x-client-request-id")
                == "session-chatgpt"
        )
    }

    @Test
    func chatGPTSubscriptionWebSocketHasNoDefaultResponseIdleTimeout() {
        #expect(ChatGPTSubscriptionResponsesClient.webSocketIdleTimeoutNanoseconds == nil)
    }

    @Test
    func chatGPTSubscriptionWebSocketPoolUsesDocumentedLifetimeDefaults() {
        #expect(
            ChatGPTSubscriptionWebSocketPool.defaultHeartbeatIntervalNanoseconds
                == 30 * 1_000_000_000
        )
        #expect(
            ChatGPTSubscriptionWebSocketPool.serverMaximumConnectionAge
                == .seconds(60 * 60)
        )
        #expect(
            ChatGPTSubscriptionWebSocketPool.defaultMaximumConnectionAge
                == .seconds(55 * 60)
        )
        #expect(
            ChatGPTSubscriptionWebSocketPool.defaultMaximumConnectionAge
                < ChatGPTSubscriptionWebSocketPool.serverMaximumConnectionAge
        )
    }

    @Test
    func chatGPTSubscriptionWebSocketReadinessRetriesDisconnectedPing() async throws {
        let pingCount = Mutex(0)

        try await ChatGPTSubscriptionWebSocketPool.waitUntilReady(
            maximumAttempts: 3,
            retryDelayNanoseconds: 1,
            sleep: { _ in },
            ping: {
                let count = pingCount.withLock { value in
                    value += 1
                    return value
                }
                if count < 3 {
                    throw POSIXError(.ENOTCONN)
                }
            }
        )

        #expect(pingCount.withLock { $0 } == 3)
    }

    @Test
    func chatGPTSubscriptionWebSocketPoolExpiresAtExactLifetimeBoundary() {
        let openedAt = ContinuousClock.now
        let maximumConnectionAge: Duration = .seconds(10)

        #expect(
            !ChatGPTSubscriptionWebSocketPool.hasReachedMaximumConnectionAge(
                openedAt: openedAt,
                now: openedAt.advanced(by: .seconds(9)),
                maximumConnectionAge: maximumConnectionAge
            )
        )
        #expect(
            ChatGPTSubscriptionWebSocketPool.hasReachedMaximumConnectionAge(
                openedAt: openedAt,
                now: openedAt.advanced(by: maximumConnectionAge),
                maximumConnectionAge: maximumConnectionAge
            )
        )
        #expect(
            ChatGPTSubscriptionWebSocketPool.hasReachedMaximumConnectionAge(
                openedAt: openedAt,
                now: openedAt.advanced(by: .seconds(11)),
                maximumConnectionAge: maximumConnectionAge
            )
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
    func chatGPTSubscriptionWebSocketPoolClosesExpiredBusySocketOnReleaseAfterClockJump() {
        let harness = ChatGPTSubscriptionWebSocketPoolHarness(
            maximumConnectionAge: .seconds(10)
        )
        let firstLease = harness.pool.acquire(
            sessionID: "session-release-expiry",
            request: harness.request()
        )

        // A machine suspension or delayed scheduler callback is represented by
        // one large monotonic-clock advance; release must still retire it.
        harness.advance(by: .seconds(60 * 60))
        harness.pool.release(firstLease, keepAlive: true)

        #expect(harness.closeCount(for: firstLease.task) == 1)
        let renewedLease = harness.pool.acquire(
            sessionID: "session-release-expiry",
            request: harness.request()
        )
        #expect(!renewedLease.isReused)
        #expect(renewedLease.task !== firstLease.task)

        harness.pool.release(renewedLease, keepAlive: false)
    }

    @Test
    func chatGPTSubscriptionWebSocketPoolKeepsSessionLifetimesIndependent() {
        let harness = ChatGPTSubscriptionWebSocketPoolHarness(
            maximumConnectionAge: .seconds(10)
        )
        let firstSessionLease = harness.pool.acquire(
            sessionID: "session-old",
            request: harness.request()
        )
        harness.pool.release(firstSessionLease, keepAlive: true)

        harness.advance(by: .seconds(5))
        let secondSessionLease = harness.pool.acquire(
            sessionID: "session-young",
            request: harness.request()
        )
        harness.pool.release(secondSessionLease, keepAlive: true)

        harness.advance(by: .seconds(5))
        let renewedFirstSessionLease = harness.pool.acquire(
            sessionID: "session-old",
            request: harness.request()
        )
        let reusedSecondSessionLease = harness.pool.acquire(
            sessionID: "session-young",
            request: harness.request()
        )

        #expect(!renewedFirstSessionLease.isReused)
        #expect(renewedFirstSessionLease.task !== firstSessionLease.task)
        #expect(reusedSecondSessionLease.isReused)
        #expect(reusedSecondSessionLease.task === secondSessionLease.task)

        harness.pool.release(renewedFirstSessionLease, keepAlive: false)
        harness.pool.release(reusedSecondSessionLease, keepAlive: false)
    }

    @Test
    func chatGPTSubscriptionWebSocketPoolNeverInterruptsExpiredActiveResponse() {
        let harness = ChatGPTSubscriptionWebSocketPoolHarness(
            maximumConnectionAge: .seconds(10)
        )
        let activeLease = harness.pool.acquire(
            sessionID: "session-active-expiry",
            request: harness.request()
        )
        harness.advance(by: .seconds(10))

        let concurrentLease = harness.pool.acquire(
            sessionID: "session-active-expiry",
            request: harness.request()
        )

        #expect(!concurrentLease.isCached)
        #expect(!concurrentLease.isReused)
        #expect(concurrentLease.task !== activeLease.task)
        #expect(harness.closeCount(for: activeLease.task) == 0)

        harness.pool.release(activeLease, keepAlive: true)
        harness.pool.release(concurrentLease, keepAlive: true)
        #expect(harness.closeCount(for: activeLease.task) == 1)
        #expect(harness.closeCount(for: concurrentLease.task) == 1)
    }

    @Test
    func chatGPTSubscriptionWebSocketPoolIgnoresLateReleaseAfterReuse() {
        let harness = ChatGPTSubscriptionWebSocketPoolHarness(
            maximumConnectionAge: .seconds(10)
        )
        let firstLease = harness.pool.acquire(
            sessionID: "session-late-release",
            request: harness.request()
        )
        harness.pool.release(firstLease, keepAlive: true)

        let activeReusedLease = harness.pool.acquire(
            sessionID: "session-late-release",
            request: harness.request()
        )
        harness.pool.release(firstLease, keepAlive: true)
        let concurrentLease = harness.pool.acquire(
            sessionID: "session-late-release",
            request: harness.request()
        )

        #expect(activeReusedLease.isReused)
        #expect(!concurrentLease.isCached)
        #expect(concurrentLease.task !== activeReusedLease.task)

        harness.pool.release(activeReusedLease, keepAlive: false)
        harness.pool.release(concurrentLease, keepAlive: false)
    }

    @Test
    func chatGPTSubscriptionIdleWebSocketHeartbeatRepeatsUntilFailure() async {
        struct PingFailure: Error {}

        let pingCount = Mutex(0)
        let failureCount = Mutex(0)
        let expirationCount = Mutex(0)

        await ChatGPTSubscriptionWebSocketPool.runHeartbeat(
            intervalNanoseconds: 1,
            sleep: { _ in },
            ping: {
                let count = pingCount.withLock { count in
                    count += 1
                    return count
                }
                if count == 3 {
                    throw PingFailure()
                }
            },
            onExpiration: {
                expirationCount.withLock { $0 += 1 }
            },
            onFailure: { _ in
                failureCount.withLock { $0 += 1 }
            }
        )

        #expect(pingCount.withLock { $0 } == 3)
        #expect(failureCount.withLock { $0 } == 1)
        #expect(expirationCount.withLock { $0 } == 0)
        #expect(
            ChatGPTSubscriptionWebSocketPool.defaultHeartbeatIntervalNanoseconds
                == 30 * 1_000_000_000
        )
    }

    @Test
    func chatGPTSubscriptionHeartbeatPingsBeforeRetiringAtLifetime() async {
        let clock = Mutex(ContinuousClock.now)
        let openedAt = clock.withLock { $0 }
        let pingCount = Mutex(0)
        let expirationCount = Mutex(0)
        let failureCount = Mutex(0)
        let maximumConnectionAge: Duration = .seconds(10)

        await ChatGPTSubscriptionWebSocketPool.runHeartbeat(
            intervalNanoseconds: 1,
            sleep: { _ in
                clock.withLock {
                    $0 = $0.advanced(by: .seconds(5))
                }
            },
            shouldRetire: {
                let now = clock.withLock { $0 }
                return ChatGPTSubscriptionWebSocketPool
                    .hasReachedMaximumConnectionAge(
                        openedAt: openedAt,
                        now: now,
                        maximumConnectionAge: maximumConnectionAge
                    )
            },
            ping: {
                pingCount.withLock { $0 += 1 }
            },
            onExpiration: {
                expirationCount.withLock { $0 += 1 }
            },
            onFailure: { _ in
                failureCount.withLock { $0 += 1 }
            }
        )

        #expect(pingCount.withLock { $0 } == 1)
        #expect(expirationCount.withLock { $0 } == 1)
        #expect(failureCount.withLock { $0 } == 0)
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
        #expect(
            ChatGPTSubscriptionResponsesClient.isRetryableTransportError(
                RemoteTransportError.closed
            )
        )
        #expect(
            ChatGPTSubscriptionResponsesClient.isRetryableTransportError(
                RemoteTransportError.timeout
            )
        )
        #expect(
            !ChatGPTSubscriptionResponsesClient.isRetryableTransportError(
                RemoteTransportError.tlsFailure("test")
            )
        )
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
            !ChatGPTSubscriptionResponsesClient.shouldRetryWebSocketFailure(
                CancellationError(),
                receivedReplayUnsafeEvent: false,
                attempt: 0
            )
        )
    }

    @Test
    func chatGPTSubscriptionNIOClientRetriesSentContinuationAsFullReplay() async throws {
        let firstTask = ChatGPTSubscriptionTestWebSocketTask(
            sendOutcomes: [.failure(RemoteTransportError.closed)]
        )
        let secondTask = ChatGPTSubscriptionTestWebSocketTask(
            receiveOutcomes: [
                .success(
                    .text(
                        #"{"type":"response.completed","response":{"id":"resp_fresh","status":"completed"}}"#
                    )
                )
            ]
        )
        let pendingTasks = Mutex([firstTask, secondTask])
        let factoryCount = Mutex(0)
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            webSocketTaskFactory: { _ in
                factoryCount.withLock { $0 += 1 }
                return pendingTasks.withLock { $0.removeFirst() }
            }
        )
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials(),
            baseURL: URL(string: "https://example.invalid/backend-api")!,
            webSocketPool: pool,
            retrySleep: { _ in }
        )
        let cachedInput = JSONValue.acpValue(from: [
            ["role": "user", "content": "cached turn"] as [String: Any]
        ])

        let completion = try await client.streamEvents(
            input: .array([]),
            model: "gpt-5.5",
            instructions: "System prompt",
            reasoningEffort: nil,
            textVerbosity: "medium",
            sessionID: "retry-continuation",
            cachedWebSocketInput: cachedInput,
            previousResponseID: "resp_previous",
            allowsFreshWebSocketContinuation: true
        ) { _ in }

        let firstPayload = try #require(firstTask.sentMessages.first?.jsonObject)
        let secondPayload = try #require(secondTask.sentMessages.first?.jsonObject)
        #expect(completion.responseID == "resp_fresh")
        #expect(factoryCount.withLock { $0 } == 2)
        #expect(firstPayload["previous_response_id"] as? String == "resp_previous")
        #expect(secondPayload["previous_response_id"] == nil)
        #expect((secondPayload["input"] as? [Any])?.isEmpty == true)
    }

    @Test
    func chatGPTSubscriptionNIOClientDoesNotReplayAfterUnsafeStreamEvent() async {
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
            Issue.record("A replay-unsafe stream unexpectedly retried.")
        } catch let error as RemoteTransportError {
            #expect(error == .closed)
        } catch {
            Issue.record("Expected RemoteTransportError.closed, got \(error).")
        }

        #expect(factoryCount.withLock { $0 } == 1)
    }

    @Test
    func chatGPTSubscriptionNIOClientCancellationClosesActiveLease() async {
        let task = ChatGPTSubscriptionTestWebSocketTask()
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            webSocketTaskFactory: { _ in task }
        )
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials(),
            baseURL: URL(string: "https://example.invalid/backend-api")!,
            webSocketPool: pool,
            retrySleep: { _ in }
        )
        let streamTask = Task {
            try await client.streamEvents(
                input: .array([]),
                model: "gpt-5.5",
                instructions: "System prompt",
                reasoningEffort: nil,
                textVerbosity: "medium",
                sessionID: "cancel-active-lease"
            ) { _ in }
        }

        await task.waitForSend()
        streamTask.cancel()
        do {
            _ = try await streamTask.value
            Issue.record("A cancelled WebSocket stream unexpectedly completed.")
        } catch is CancellationError {
            // Expected: cancellation closes the NIO adapter and releases lease.
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        #expect(task.cancelCount > 0)
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
    func streamResponsesDoesNotDuplicateOutputItemSnapshotAfterDelta() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"Visible answer"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let fixture = try await RemoteNIOStreamingFixture.start(
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
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
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
        let fixture = try await RemoteNIOStreamingFixture.start(
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
private final class ChatGPTSubscriptionTestWebSocketTask:
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

    func enqueueReceive(
        _ result: Result<ChatGPTSubscriptionWebSocketMessage, Error>
    ) {
        let waiter = stateStorage.withLock {
            state -> CheckedContinuation<ChatGPTSubscriptionWebSocketMessage, Error>? in
            if let waiter = state.receiveWaiter {
                state.receiveWaiter = nil
                return waiter
            }
            state.receiveOutcomes.append(result)
            return nil
        }
        waiter?.resume(with: result)
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
