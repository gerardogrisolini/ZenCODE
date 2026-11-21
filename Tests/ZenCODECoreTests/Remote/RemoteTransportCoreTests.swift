//
//  RemoteTransportCoreTests.swift
//  ZenCODECoreTests
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("RemoteTransportCore", .serialized)
struct RemoteTransportCoreTests {
    @Test("ChatGPT HTTP canonical backend retry budget is bounded")
    func chatGPTHTTPFallbackBoundsCanonicalBackendRetries() async throws {
        let message = """
        An error occurred while processing your request. You can retry your request, or contact us through our help center at help.openai.com if the error persists. Please include the request ID bounded-http-retry in your message.
        """
        let failureJSON = try JSONValue(jsonObject: [
            "type": "response.done",
            "response": [
                "status": "failed",
                "error": [
                    "type": "server_error",
                    "code": "server_error",
                    "message": message
                ]
            ]
        ]).jsonData(outputFormatting: [.withoutEscapingSlashes])
        let payload = "data: \(String(decoding: failureJSON, as: UTF8.self))\n\n"
        let requestCount = Mutex(0)
        let server = try await LocalHTTPTestServer.start { context, _ in
            requestCount.withLock { $0 += 1 }
            writeSSEPayload(payload, to: context)
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let pool = ChatGPTSubscriptionWebSocketPool(
            transport: transport,
            heartbeatIntervalNanoseconds: UInt64.max
        )
        let sessionID = "chatgpt-http-bounded-retry"
        _ = pool.activateHTTPFallback(scopeID: sessionID)
        let retrySleepAttempts = Mutex<[Int]>([])
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: CodexAgentCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3_600),
                accountID: "test-account"
            ),
            baseURL: server.url(path: "/backend-api"),
            webSocketPool: pool,
            retrySleep: { attempt in
                retrySleepAttempts.withLock { $0.append(attempt) }
            }
        )

        do {
            do {
                _ = try await client.streamEvents(
                    input: .array([]),
                    model: "gpt-5.5",
                    instructions: "System prompt",
                    reasoningEffort: nil,
                    textVerbosity: "medium",
                    sessionID: sessionID
                ) { object in
                    if let errorMessage = ChatGPTSubscriptionGenerationClient
                        .responseErrorMessage(from: object) {
                        throw ChatGPTSubscriptionGenerationError.responseFailed(
                            errorMessage
                        )
                    }
                }
                Issue.record("An exhausted HTTP retry budget unexpectedly completed.")
            } catch let error as ChatGPTSubscriptionResponsesClient
                .RetryableBackendFailure {
                #expect(error.message == message)
            }

            #expect(
                requestCount.withLock { $0 }
                    == ChatGPTSubscriptionResponsesClient.maxRetries + 1
            )
            #expect(
                retrySleepAttempts.withLock { $0 }
                    == Array(0..<ChatGPTSubscriptionResponsesClient.maxRetries)
            )
        } catch {
            await pool.shutdown()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        await pool.shutdown()
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("ChatGPT HTTP does not replay canonical failure after output")
    func chatGPTHTTPFallbackDoesNotReplayAfterUnsafeOutput() async throws {
        let message = """
        An error occurred while processing your request. You can retry your request, or contact us through our help center at help.openai.com if the error persists. Please include the request ID unsafe-http-retry in your message.
        """
        let failureJSON = try JSONValue(jsonObject: [
            "type": "error",
            "error": [
                "type": "server_error",
                "code": "server_error",
                "message": message
            ]
        ]).jsonData(outputFormatting: [.withoutEscapingSlashes])
        let payload = """
        data: {"type":"response.output_text.delta","delta":"partial"}

        data: \(String(decoding: failureJSON, as: UTF8.self))


        """
        let requestCount = Mutex(0)
        let server = try await LocalHTTPTestServer.start { context, _ in
            requestCount.withLock { $0 += 1 }
            writeSSEPayload(payload, to: context)
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let pool = ChatGPTSubscriptionWebSocketPool(
            transport: transport,
            heartbeatIntervalNanoseconds: UInt64.max
        )
        let sessionID = "chatgpt-http-unsafe-retry"
        _ = pool.activateHTTPFallback(scopeID: sessionID)
        let retrySleepAttempts = Mutex<[Int]>([])
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: CodexAgentCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3_600),
                accountID: "test-account"
            ),
            baseURL: server.url(path: "/backend-api"),
            webSocketPool: pool,
            retrySleep: { attempt in
                retrySleepAttempts.withLock { $0.append(attempt) }
            }
        )

        do {
            do {
                _ = try await client.streamEvents(
                    input: .array([]),
                    model: "gpt-5.5",
                    instructions: "System prompt",
                    reasoningEffort: nil,
                    textVerbosity: "medium",
                    sessionID: sessionID
                ) { object in
                    if let errorMessage = ChatGPTSubscriptionGenerationClient
                        .responseErrorMessage(from: object) {
                        throw ChatGPTSubscriptionGenerationError.responseFailed(
                            errorMessage
                        )
                    }
                }
                Issue.record("A replay-unsafe HTTP stream unexpectedly completed.")
            } catch let failure as ChatGPTSubscriptionResponsesClient
                .ReplayUnsafeStreamFailure {
                guard let error = failure.underlying
                    as? ChatGPTSubscriptionResponsesClient.RetryableBackendFailure else {
                    Issue.record("Expected a wrapped canonical backend error.")
                    await pool.shutdown()
                    await transport.shutdownIgnoringError()
                    await server.shutdown()
                    return
                }
                #expect(error.message == message)
            }

            #expect(requestCount.withLock { $0 } == 1)
            #expect(retrySleepAttempts.withLock { $0 }.isEmpty)
        } catch {
            await pool.shutdown()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        await pool.shutdown()
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("ChatGPT HTTP does not retry a callback-originated failure")
    func chatGPTHTTPFallbackDoesNotRetryCallbackFailure() async throws {
        let message = """
        An error occurred while processing your request. You can retry your request, or contact us through our help center at help.openai.com if the error persists. Please include the request ID callback-error in your message.
        """
        let payload = """
        data: {"type":"response.created","response":{"id":"resp_callback"}}


        """
        let requestCount = Mutex(0)
        let server = try await LocalHTTPTestServer.start { context, _ in
            requestCount.withLock { $0 += 1 }
            writeSSEPayload(payload, to: context)
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let pool = ChatGPTSubscriptionWebSocketPool(
            transport: transport,
            heartbeatIntervalNanoseconds: UInt64.max
        )
        let sessionID = "chatgpt-http-callback-error"
        _ = pool.activateHTTPFallback(scopeID: sessionID)
        let retrySleepAttempts = Mutex<[Int]>([])
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: CodexAgentCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3_600),
                accountID: "test-account"
            ),
            baseURL: server.url(path: "/backend-api"),
            webSocketPool: pool,
            retrySleep: { attempt in
                retrySleepAttempts.withLock { $0.append(attempt) }
            }
        )

        do {
            do {
                _ = try await client.streamEvents(
                    input: .array([]),
                    model: "gpt-5.5",
                    instructions: "System prompt",
                    reasoningEffort: nil,
                    textVerbosity: "medium",
                    sessionID: sessionID
                ) { _ in
                    throw ChatGPTSubscriptionGenerationError.responseFailed(message)
                }
                Issue.record("A callback-originated error unexpectedly completed.")
            } catch let error as ChatGPTSubscriptionGenerationError {
                guard case let .responseFailed(output) = error else {
                    Issue.record("Expected callback responseFailed, got \(error).")
                    await pool.shutdown()
                    await transport.shutdownIgnoringError()
                    await server.shutdown()
                    return
                }
                #expect(output == message)
            }

            #expect(requestCount.withLock { $0 } == 1)
            #expect(retrySleepAttempts.withLock { $0 }.isEmpty)
        } catch {
            await pool.shutdown()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        await pool.shutdown()
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("ChatGPT HTTP fallback rejects DONE without a terminal response event")
    func chatGPTHTTPFallbackRejectsNonTerminalDone() async throws {
        let server = try await LocalHTTPTestServer.start { context, _ in
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/event-stream")
            context.write(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .head(
                        HTTPResponseHead(
                            version: .http1_1,
                            status: .ok,
                            headers: headers
                        )
                    )
                ),
                promise: nil
            )
            var body = context.channel.allocator.buffer(capacity: 256)
            body.writeString(
                """
                data: {"type":"response.output_text.delta","delta":"partial"}

                data: [DONE]


                """
            )
            // Deliberately keep the HTTP response open after [DONE]. The client
            // must stop parsing at the marker and reject the missing terminal
            // response event instead of waiting for EOF or committing partial
            // output.
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .body(.byteBuffer(body))
                ),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let pool = ChatGPTSubscriptionWebSocketPool(
            transport: transport,
            heartbeatIntervalNanoseconds: UInt64.max
        )
        let sessionID = "chatgpt-http-nonterminal-done"
        _ = pool.activateHTTPFallback(scopeID: sessionID)
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: CodexAgentCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3_600),
                accountID: "test-account"
            ),
            baseURL: server.url(path: "/backend-api"),
            webSocketPool: pool,
            retrySleep: { _ in }
        )

        do {
            let rejected = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        _ = try await client.streamEvents(
                            input: .array([]),
                            model: "gpt-5.5",
                            instructions: "System prompt",
                            reasoningEffort: nil,
                            textVerbosity: "medium",
                            sessionID: sessionID
                        ) { _ in }
                        return false
                    } catch let failure as ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure {
                        if let error = failure.underlying
                            as? ChatGPTSubscriptionGenerationError,
                           case .invalidResponse = error {
                            #expect(
                                !ChatGPTSubscriptionGenerationClient
                                    .isRetryableStreamInterruption(failure)
                            )
                            return true
                        }
                        throw failure
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw RemoteTransportError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            #expect(rejected)
        } catch {
            await pool.shutdown()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        await pool.shutdown()
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("Closing a ChatGPT fallback scope cancels its active HTTP stream")
    func closingChatGPTFallbackScopeCancelsActiveHTTPStream() async throws {
        let server = try await LocalHTTPTestServer.start { context, _ in
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/event-stream")
            // Send only the head so the client parks waiting for an SSE event.
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .head(
                        HTTPResponseHead(
                            version: .http1_1,
                            status: .ok,
                            headers: headers
                        )
                    )
                ),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let pool = ChatGPTSubscriptionWebSocketPool(
            transport: transport,
            heartbeatIntervalNanoseconds: UInt64.max
        )
        let scopeID = "chatgpt-active-http-scope"
        _ = pool.activateHTTPFallback(scopeID: scopeID)
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: CodexAgentCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3_600),
                accountID: "test-account"
            ),
            baseURL: server.url(path: "/backend-api"),
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
                sessionID: "transport-active-http",
                fallbackScopeID: scopeID
            ) { _ in }
        }

        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !pool.hasActiveHTTPStream(scopeID: scopeID),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(pool.hasActiveHTTPStream(scopeID: scopeID))

            pool.closeHTTPFallbackScope(scopeID: scopeID)
            let failedPromptly = try await withThrowingTaskGroup(of: Bool.self) {
                group in
                group.addTask {
                    do {
                        _ = try await streamTask.value
                        return false
                    } catch {
                        return true
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw RemoteTransportError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }

            #expect(failedPromptly)
            #expect(!pool.hasActiveHTTPStream(scopeID: scopeID))
            #expect(pool.isHTTPFallbackScopeClosed(scopeID: scopeID))
        } catch {
            streamTask.cancel()
            await pool.shutdown()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        await pool.shutdown()
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("Closing a ChatGPT fallback scope cancels HTTP before response headers")
    func closingChatGPTFallbackScopeCancelsPendingHTTPOpen() async throws {
        let server = try await LocalHTTPTestServer.start { _, _ in
            // Deliberately never send a response head.
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let pool = ChatGPTSubscriptionWebSocketPool(
            transport: transport,
            heartbeatIntervalNanoseconds: UInt64.max
        )
        let scopeID = "chatgpt-pending-http-scope"
        _ = pool.activateHTTPFallback(scopeID: scopeID)
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: CodexAgentCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3_600),
                accountID: "test-account"
            ),
            baseURL: server.url(path: "/backend-api"),
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
                sessionID: "transport-pending-http",
                fallbackScopeID: scopeID
            ) { _ in }
        }

        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !pool.hasPendingHTTPStream(scopeID: scopeID),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(pool.hasPendingHTTPStream(scopeID: scopeID))

            pool.closeHTTPFallbackScope(scopeID: scopeID)
            let failedPromptly = try await withThrowingTaskGroup(of: Bool.self) {
                group in
                group.addTask {
                    do {
                        _ = try await streamTask.value
                        return false
                    } catch {
                        return true
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw RemoteTransportError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }

            #expect(failedPromptly)
            #expect(!pool.hasPendingHTTPStream(scopeID: scopeID))
            #expect(pool.isHTTPFallbackScopeClosed(scopeID: scopeID))
        } catch {
            streamTask.cancel()
            await pool.shutdown()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        await pool.shutdown()
        try await transport.shutdown()
        await server.shutdown()
    }
}
