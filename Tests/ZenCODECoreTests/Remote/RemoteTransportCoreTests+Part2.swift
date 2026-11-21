//
//  RemoteTransportCoreTests+Part2.swift
//  ZenCODECoreTests
//
//  Second part of the RemoteTransportCore tests: WebSocket frames, peer
//  resets and upgrade rejections, release of parked HTTP and WebSocket
//  drivers, truncated bodies and the first ChatGPT HTTP fallback cases.
//  Tests of this serialized suite run in file-name order: keep the name.
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

extension RemoteTransportCoreTests {
    @Test("WebSocket supports text, binary, ping/pong and close frames")
    func webSocketFramesRoundTripThroughNIO() async throws {
        let server = try await LocalWebSocketTestServer.start()
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let socket = try await transport.connectWebSocket(
                RemoteWebSocketRequest(
                    url: server.url(path: "/frames"),
                    headers: [RemoteHTTPHeader(name: "x-transport-test", value: "websocket")]
                )
            )

            try await socket.send(.text("hello"))
            #expect(try await socket.receive() == .text("hello", final: true))

            let binary = Data([0x00, 0xFF, 0x10])
            try await socket.send(.binary(binary))
            #expect(try await socket.receive() == .binary(binary, final: true))

            let pingPayload = Data("probe".utf8)
            try await socket.send(.ping(pingPayload))
            #expect(try await socket.receive() == .pong(pingPayload))

            try await socket.send(.close(code: 1000, reason: "done"))
            #expect(try await socket.receive() == .close(code: 1000, reason: "done"))
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("A WebSocket peer reset surfaces as a recoverable transport failure")
    func webSocketPeerResetIsRecoverable() async throws {
        let server = try await LocalWebSocketTestServer.start(
            resetOnText: "reset-connection"
        )
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let socket = try await transport.connectWebSocket(
                RemoteWebSocketRequest(url: server.url(path: "/reset"))
            )
            try await socket.send(.text("reset-connection"))

            do {
                _ = try await withThrowingTaskGroup(
                    of: RemoteWebSocketFrame?.self
                ) { group in
                    group.addTask {
                        try await socket.receive()
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(2))
                        throw RemoteTransportError.timeout
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? nil
                }
                Issue.record(
                    "The reset WebSocket unexpectedly returned a frame or clean EOF."
                )
            } catch let error as RemoteTransportError {
                if case .connectionFailure = error {
                    // Expected: the TCP reset is mapped into a recoverable error.
                } else {
                    Issue.record("Expected connectionFailure, got \(error).")
                }
            }

            do {
                try await socket.send(.text("after-reset"))
                Issue.record(
                    "A send on the reset WebSocket unexpectedly succeeded."
                )
            } catch let error as RemoteTransportError {
                #expect(error == .closed)
            }
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("WebSocket upgrade rejection surfaces the HTTP status and body")
    func webSocketUpgradeRejectionIncludesStatusAndBody() async throws {
        let server = try await LocalHTTPTestServer.start { context, _ in
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/json")
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .head(
                        HTTPResponseHead(
                            version: .http1_1,
                            status: .unauthorized,
                            headers: headers
                        )
                    )
                ),
                promise: nil
            )
            var body = context.channel.allocator.buffer(capacity: 64)
            body.writeString(#"{"error":"invalid_token"}"#)
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
                promise: nil
            )
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.end(nil)),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let wsURL = URL(
                string: server.url(path: "/reject")
                    .absoluteString.replacingOccurrences(of: "http://", with: "ws://")
            )!
            _ = try await transport.connectWebSocket(
                RemoteWebSocketRequest(url: wsURL)
            )
            Issue.record("Expected an upgrade rejection error")
        } catch let error as RemoteTransportError {
            guard case let .upgradeRejected(status, body) = error else {
                Issue.record("Expected upgradeRejected, got \(error)")
                return
            }
            #expect(status == 401)
            #expect(body.contains("invalid_token"))
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            Issue.record("Expected RemoteTransportError, got \(error)")
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("Releasing an abandoned HTTP/SSE stream tears down its parked driver")
    func httpStreamAbandonmentReleasesParkedDriver() async throws {
        // The server keeps the body open; the consumer reads one event and then
        // stops. The run-task is parked in `nextRequest()` waiting for the next
        // read request, which is fed by the consumer (not by the NIO iterator),
        // so nothing but the lifetime token can resume it. Dropping every handle
        // copy must release the driver the run-task retains.
        let server = try await LocalHTTPTestServer.start { context, _ in
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/event-stream")
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
            var body = context.channel.allocator.buffer(capacity: 64)
            body.writeString("data: hello\n\n")
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        let storageBox: WeakBox<RemoteHTTPBodyStorage>
        do {
            storageBox = try await {
                let response = try await transport.openHTTPStream(
                    RemoteHTTPStreamingRequest(url: server.url(path: "/abandon"))
                )
                var events = response.body.sseEvents().makeAsyncIterator()
                let event = try await events.next()
                #expect(event?.data == "hello")
                // Returning releases `response` and `events`, dropping the last
                // lifetime token copies while the run-task is still parked.
                return WeakBox(response.body.storage)
            }()
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await awaitDeallocated(storageBox)
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("A truncated Content-Length body surfaces as an error, never a clean EOF")
    func httpTruncatedContentLengthSurfacesError() async throws {
        let payload = "data: partial\n\n"
        let actualBytes = payload.utf8.count
        let server = try await LocalHTTPTestServer.start { context, _ in
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/event-stream")
            // Declare one byte more than is sent, then close without `.end`.
            headers.add(
                name: "content-length",
                value: String(actualBytes + 1)
            )
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
            var body = context.channel.allocator.buffer(capacity: actualBytes)
            body.writeString(payload)
            let channel = context.channel
            let flushPromise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
                promise: flushPromise
            )
            // Close only after the body is flushed. Closing immediately after
            // `writeAndFlush` can race the write and make this test exercise a
            // connection closed before the response instead of a truncation.
            flushPromise.futureResult.whenComplete { _ in
                channel.close(promise: nil)
            }
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let response = try await transport.openHTTPStream(
                RemoteHTTPStreamingRequest(url: server.url(path: "/truncate"))
            )
            var events = response.body.sseEvents().makeAsyncIterator()
            let first = try await events.next()
            #expect(first?.data == "partial")
            do {
                _ = try await events.next()
                Issue.record(
                    "A truncated Content-Length body returned a value instead of erroring."
                )
            } catch let error as RemoteTransportError {
                // The NIO framing error must surface as a transport error and
                // never as `nil` (which would mask the truncation).
                #expect(error != .closed)
            }
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("Releasing an abandoned WebSocket connection tears down its parked driver")
    func webSocketAbandonmentReleasesParkedDriver() async throws {
        // After upgrade the read/write loops park in their queue waiters waiting
        // for consumer requests, which are not fed by the NIO iterator. Dropping
        // the connection must release the driver the run-task retains.
        let server = try await LocalWebSocketTestServer.start()
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        let driverBox: WeakBox<RemoteWebSocketDriver>
        do {
            driverBox = try await {
                let connection = try await transport.connectWebSocket(
                    RemoteWebSocketRequest(url: server.url(path: "/abandon"))
                )
                // Returning releases `connection`, dropping the lifetime token
                // while both loops are parked in their queue waiters.
                return WeakBox(await connection.driver)
            }()
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await awaitDeallocated(driverBox)
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("Cancelling a parked WebSocket receive reports cancellation and closes the channel")
    func webSocketCancellationResumesParkedReceive() async throws {
        let server = try await LocalWebSocketTestServer.start()
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        let driverBox: WeakBox<RemoteWebSocketDriver>
        do {
            let connection = try await transport.connectWebSocket(
                RemoteWebSocketRequest(url: server.url(path: "/cancel"))
            )
            driverBox = WeakBox(await connection.driver)
            let receiveTask = Task { _ = try await connection.receive() }
            await Task.yield()
            receiveTask.cancel()

            do {
                _ = try await receiveTask.value
                Issue.record("The cancelled WebSocket receive unexpectedly completed.")
            } catch is CancellationError {
                // Expected: the parked receive resumes with cancellation.
            }
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        // Handle release drives teardown asynchronously; shutting the owning
        // group down before the driver is gone schedules on a dead event loop.
        try await awaitDeallocated(driverBox)
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("ChatGPT session fallback streams Responses events over HTTP")
    func chatGPTSessionFallbackStreamsResponsesOverHTTP() async throws {
        let payload = """
        data: {"type":"response.created","response":{"id":"resp_http_fallback"}}

        data: {"type":"response.output_text.delta","delta":"ok"}

        data: {"type":"response.completed","response":{"id":"resp_http_fallback","status":"completed"}}


        """
        let server = try await LocalHTTPTestServer.start { context, _ in
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/event-stream")
            // The tail is deliberately truncated after the terminal event. A
            // correct client returns immediately after processing completed and
            // never observes this later framing failure.
            headers.add(
                name: "content-length",
                value: String(payload.utf8.count + 1)
            )
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
            var body = context.channel.allocator.buffer(capacity: payload.utf8.count)
            body.writeString(payload)
            let channel = context.channel
            let flushPromise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .body(.byteBuffer(body))
                ),
                promise: flushPromise
            )
            flushPromise.futureResult.whenComplete { _ in
                channel.close(promise: nil)
            }
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let pool = ChatGPTSubscriptionWebSocketPool(
            transport: transport,
            heartbeatIntervalNanoseconds: UInt64.max
        )
        let sessionID = "chatgpt-http-fallback"
        _ = pool.activateHTTPFallback(scopeID: sessionID)
        let eventTypes = Mutex<[String]>([])

        do {
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
            let completion = try await client.streamEvents(
                input: .array([]),
                model: "gpt-5.5",
                instructions: "System prompt",
                reasoningEffort: nil,
                textVerbosity: "medium",
                sessionID: sessionID
            ) { object in
                if let type = object["type"] as? String {
                    eventTypes.withLock { $0.append(type) }
                }
            }

            #expect(completion.responseID == "resp_http_fallback")
            #expect(!completion.didActivateHTTPFallback)
            #expect(eventTypes.withLock { $0 } == [
                "response.created",
                "response.output_text.delta",
                "response.completed"
            ])
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

    @Test("ChatGPT HTTP fallback retries a canonical backend failure")
    func chatGPTHTTPFallbackRetriesCanonicalBackendFailure() async throws {
        let message = """
        An error occurred while processing your request. You can retry your request, or contact us through our help center at help.openai.com if the error persists. Please include the request ID 037b6141-1e24-4874-9032-ba40b471127c in your message.
        """
        let failureJSON = try JSONValue(jsonObject: [
            "type": "error",
            "error": [
                "type": "server_error",
                "code": "server_error",
                "message": message
            ]
        ]).jsonData(outputFormatting: [.withoutEscapingSlashes])
        let failurePayload = "data: \(String(decoding: failureJSON, as: UTF8.self))\n\n"
        let completionPayload = """
        data: {"type":"response.created","response":{"id":"resp_http_retry"}}

        data: {"type":"response.completed","response":{"id":"resp_http_retry","status":"completed"}}


        """
        let requestCount = Mutex(0)
        let server = try await LocalHTTPTestServer.start { context, _ in
            let attempt = requestCount.withLock { count in
                count += 1
                return count
            }
            let payload = attempt == 1 ? failurePayload : completionPayload
            writeSSEPayload(payload, to: context)
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let pool = ChatGPTSubscriptionWebSocketPool(
            transport: transport,
            heartbeatIntervalNanoseconds: UInt64.max
        )
        let sessionID = "chatgpt-http-retry"
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
            let completion = try await client.streamEvents(
                input: .array([]),
                model: "gpt-5.5",
                instructions: "System prompt",
                reasoningEffort: nil,
                textVerbosity: "medium",
                sessionID: sessionID
            ) { object in
                if let errorMessage = ChatGPTSubscriptionGenerationClient
                    .responseErrorMessage(from: object) {
                    throw ChatGPTSubscriptionGenerationError.responseFailed(errorMessage)
                }
            }

            #expect(completion.responseID == "resp_http_retry")
            #expect(requestCount.withLock { $0 } == 2)
            #expect(retrySleepAttempts.withLock { $0 } == [0])
            #expect(pool.usesHTTPFallback(scopeID: sessionID))
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
}
