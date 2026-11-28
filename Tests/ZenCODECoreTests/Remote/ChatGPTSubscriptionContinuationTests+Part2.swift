//
//  ChatGPTSubscriptionContinuationTests+Part2.swift
//  ZenCODE
//
//  Second part of the ChatGPT Subscription continuation tests: encrypted
//  reasoning replay, the Codex WebSocket handshake and pool, connection-limit
//  and rate-limit retries, and the NIO client fallback to HTTP, with their
//  private pool harness.
//

import Foundation
import Synchronization
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

extension RemoteSessionSnapshotTests {
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
    func chatGPTSubscriptionWebSocketPoolReopensExpiredIdleSocketWithCurrentRequest() async throws {
        let harness = ChatGPTSubscriptionWebSocketPoolHarness(
            maximumConnectionAge: .seconds(10)
        )
        defer { await harness.pool.shutdown() }
        let oldRequest = harness.request(authorization: "Bearer stale")
        let firstLease = try harness.acquire(
            sessionID: "session-age-boundary",
            request: oldRequest
        )
        harness.pool.release(firstLease, keepAlive: true)

        harness.advance(by: .seconds(9))
        let underBoundaryLease = try harness.acquire(
            sessionID: "session-age-boundary",
            request: harness.request(authorization: "Bearer ignored")
        )
        #expect(underBoundaryLease.isReused)
        #expect(underBoundaryLease.task === firstLease.task)
        harness.pool.release(underBoundaryLease, keepAlive: true)

        harness.advance(by: .seconds(1))
        let currentRequest = harness.request(authorization: "Bearer current")
        let renewedLease = try harness.acquire(
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
        defer { await pool.shutdown() }
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
        defer { await pool.shutdown() }
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

    /// A lease from the production acquire path, under a fallback scope that
    /// never routes to HTTP.
    func acquire(
        sessionID: String,
        request: RemoteWebSocketRequest
    ) throws -> ChatGPTSubscriptionResponsesClient.WebSocketLease {
        struct NotAcquired: Error {}
        guard case let .acquired(lease) = pool.acquire(
            sessionID: sessionID,
            request: request,
            fallbackScopeID: sessionID
        ) else {
            throw NotAcquired()
        }
        return lease
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

private extension RemoteWebSocketRequest {
    func headerValue(for name: String) -> String? {
        headers.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}
