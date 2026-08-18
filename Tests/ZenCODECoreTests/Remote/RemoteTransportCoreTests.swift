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

@Suite("RemoteTransportCore", .serialized)
struct RemoteTransportCoreTests {
    @Test("HTTP exposes status and headers before parsing incremental SSE")
    func httpStreamingSSEExposesHeadBeforeBody() async throws {
        let server = try await LocalHTTPTestServer.start { context, _ in
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/event-stream")
            headers.add(name: "x-transport-test", value: "head-ready")
            context.write(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .head(
                        HTTPResponseHead(
                            version: .http1_1,
                            status: .accepted,
                            headers: headers
                        )
                    )
                ),
                promise: nil
            )
            var body = context.channel.allocator.buffer(capacity: 128)
            body.writeString(
                "event: token\nid: evt-1\nretry: 25\ndata: alpha\ndata: beta\n\n"
            )
            context.write(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .body(.byteBuffer(body))
                ),
                promise: nil
            )
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.end(nil)),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let response = try await transport.openHTTPStream(
                RemoteHTTPStreamingRequest(
                    url: server.url(path: "/sse"),
                    headers: [RemoteHTTPHeader(name: "accept", value: "text/event-stream")]
                )
            )
            #expect(response.status == 202)
            #expect(response.headers.firstValue(for: "X-Transport-Test") == "head-ready")

            var events = response.body.sseEvents().makeAsyncIterator()
            let event = try await events.next()
            #expect(event == RemoteSSEEvent(
                event: "token",
                data: "alpha\nbeta",
                id: "evt-1",
                retryMilliseconds: 25
            ))
            #expect(try await events.next() == nil)
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("SSE accepts bare CR delimiters, including across chunks")
    func sseAcceptsBareCRDelimiters() async throws {
        let server = try await LocalHTTPTestServer.start { context, _ in
            context.write(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .head(HTTPResponseHead(version: .http1_1, status: .ok))
                ),
                promise: nil
            )
            for fragment in ["event: token\rdata: alpha\r", "\rdata: beta\r\r"] {
                var body = context.channel.allocator.buffer(capacity: fragment.utf8.count)
                body.writeString(fragment)
                context.write(
                    LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
                    promise: nil
                )
            }
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.end(nil)),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        defer {
            Task {
                try? await transport.shutdown()
                await server.shutdown()
            }
        }
        let response = try await transport.openHTTPStream(
            RemoteHTTPStreamingRequest(url: server.url(path: "/bare-cr"))
        )
        var events = response.body.sseEvents().makeAsyncIterator()

        #expect(try await events.next() == RemoteSSEEvent(
            event: "token",
            data: "alpha",
            id: nil,
            retryMilliseconds: nil
        ))
        #expect(try await events.next()?.data == "beta")
        #expect(try await events.next() == nil)
    }

    @Test("SSE rejects oversized lines and events with bounded parser errors")
    func sseRejectsOversizedLinesAndEvents() async throws {
        let server = try await LocalHTTPTestServer.start { context, request in
            context.write(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .head(HTTPResponseHead(version: .http1_1, status: .ok))
                ),
                promise: nil
            )
            let payload = request.uri.contains("line")
                ? "data: 123456789\n\n"
                : "data: 12345\ndata: 67890\n\n"
            var body = context.channel.allocator.buffer(capacity: payload.utf8.count)
            body.writeString(payload)
            context.write(
                LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
                promise: nil
            )
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.end(nil)),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        defer {
            Task {
                try? await transport.shutdown()
                await server.shutdown()
            }
        }

        let lineResponse = try await transport.openHTTPStream(
            RemoteHTTPStreamingRequest(url: server.url(path: "/line"))
        )
        var lineEvents = RemoteSSEEventStream(
            body: lineResponse.body,
            maximumLineBytes: 8,
            maximumEventBytes: 64
        ).makeAsyncIterator()
        await #expect(throws: RemoteSSEParsingError.lineLimitExceeded(maximumBytes: 8)) {
            _ = try await lineEvents.next()
        }

        let eventResponse = try await transport.openHTTPStream(
            RemoteHTTPStreamingRequest(url: server.url(path: "/event"))
        )
        var eventEvents = RemoteSSEEventStream(
            body: eventResponse.body,
            maximumLineBytes: 64,
            maximumEventBytes: 10
        ).makeAsyncIterator()
        await #expect(throws: RemoteSSEParsingError.eventLimitExceeded(maximumBytes: 10)) {
            _ = try await eventEvents.next()
        }
    }

    @Test("SSE idle timeout aborts a stalled post-head body")
    func sseIdleTimeoutAbortsStalledStream() async throws {
        let inactive = TestSignal()
        let server = try await LocalHTTPTestServer.start(
            onInactive: {
                Task { await inactive.signal() }
            }
        ) { context, _ in
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
            // Send one event, then deliberately stall: no further bytes and
            // no close. The idle watchdog must abort the parked read.
            var body = context.channel.allocator.buffer(capacity: 64)
            body.writeString("data: first\n\n")
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let response = try await transport.openHTTPStream(
                RemoteHTTPStreamingRequest(url: server.url(path: "/sse-stall"))
            )
            var events = response.body.sseEvents(
                idleTimeoutNanoseconds: 200_000_000
            ).makeAsyncIterator()
            let first = try await events.next()
            #expect(first?.data == "first")

            do {
                _ = try await events.next()
                Issue.record("The stalled SSE body unexpectedly delivered an event.")
            } catch let error as RemoteSSEIdleTimeoutError {
                #expect(error.timeoutNanoseconds == 200_000_000)
            }
            // The watchdog must have torn the channel down: the server
            // observes the close without relying on a server-side timeout.
            try await wait(for: inactive)
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("SSE idle timeout can be disabled with nil")
    func sseIdleTimeoutNilDisablesWatchdog() async throws {
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
            body.writeString("data: only\n\n")
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let response = try await transport.openHTTPStream(
                RemoteHTTPStreamingRequest(url: server.url(path: "/sse-open"))
            )
            // nil disables the watchdog: the parked read stays cancellable
            // (nothing throws here within the test window).
            let events = response.body.sseEvents(idleTimeoutNanoseconds: nil)
            var iterator = events.makeAsyncIterator()
            let event = try await iterator.next()
            #expect(event?.data == "only")
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("HTTP body cancellation closes the in-flight loopback channel")
    func httpBodyCancellationClosesConnection() async throws {
        let inactive = TestSignal()
        let server = try await LocalHTTPTestServer.start(
            onInactive: {
                Task { await inactive.signal() }
            }
        ) { context, _ in
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
            // Deliberately keep the body open. The client cancellation must
            // close the socket rather than relying on a server timeout.
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let response = try await transport.openHTTPStream(
                RemoteHTTPStreamingRequest(url: server.url(path: "/cancel"))
            )
            let readTask = Task { () throws -> Void in
                var iterator = response.body.makeAsyncIterator()
                _ = try await iterator.next()
            }
            await Task.yield()
            readTask.cancel()

            do {
                try await readTask.value
                Issue.record("The cancelled HTTP body read unexpectedly completed.")
            } catch {
                #expect(error is CancellationError)
            }
            try await wait(for: inactive)
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("HTTP opening timeout is surfaced as a stable transport error")
    func httpOpeningTimeout() async throws {
        let server = try await LocalHTTPTestServer.start { _, _ in
            // Leave the request unanswered until the client deadline wins.
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            do {
                _ = try await transport.openHTTPStream(
                    RemoteHTTPStreamingRequest(
                        url: server.url(path: "/timeout"),
                        timeout: .milliseconds(100)
                    )
                )
                Issue.record("The HTTP opening timeout unexpectedly succeeded.")
            } catch let error as RemoteTransportError {
                #expect(error == .timeout)
            }
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("HTTP request timeout covers a stalled response body")
    func httpRequestTimeoutCoversStalledBody() async throws {
        let server = try await LocalHTTPTestServer.start { context, _ in
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .head(HTTPResponseHead(version: .http1_1, status: .ok))
                ),
                promise: nil
            )
            // Keep the body open after a successful head. `sendRequest` must
            // still honor its deadline while collecting this body.
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            do {
                _ = try await transport.sendRequest(
                    RemoteHTTPStreamingRequest(
                        url: server.url(path: "/stalled-body"),
                        timeout: .milliseconds(100)
                    )
                )
                Issue.record("The stalled HTTP response body unexpectedly completed.")
            } catch let error as RemoteTransportError {
                #expect(error == .timeout)
            }
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("HTTP request follows bounded redirects and strips credentials cross-origin")
    func httpRequestRedirectStripsSensitiveHeadersAcrossOrigins() async throws {
        let receivedHeaders = HTTPHeaderCapture()
        let destination = try await LocalHTTPTestServer.start { context, head in
            receivedHeaders.record(head.headers)
            writeHTTPResponse("redirected", status: .ok, to: context)
        }
        let origin = try await LocalHTTPTestServer.start { context, _ in
            var headers = HTTPHeaders()
            headers.add(name: "location", value: destination.url(path: "/final").absoluteString)
            headers.add(name: "content-length", value: "0")
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .head(HTTPResponseHead(version: .http1_1, status: .found, headers: headers))
                ),
                promise: nil
            )
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.end(nil)),
                promise: nil
            )
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let response = try await transport.sendRequest(
                RemoteHTTPStreamingRequest(
                    url: origin.url(path: "/redirect"),
                    headers: [
                        RemoteHTTPHeader(name: "Authorization", value: "Bearer secret"),
                        RemoteHTTPHeader(name: "Cookie", value: "session=secret"),
                        RemoteHTTPHeader(name: "Proxy-Authorization", value: "Basic secret"),
                        RemoteHTTPHeader(name: "X-API-Key", value: "key-secret"),
                        RemoteHTTPHeader(name: "X-Retained", value: "yes")
                    ]
                )
            )
            #expect(response.status == 200)
            #expect(response.body == Data("redirected".utf8))
            let headers = receivedHeaders.value()
            #expect(headers["authorization"].isEmpty)
            #expect(headers["cookie"].isEmpty)
            #expect(headers["proxy-authorization"].isEmpty)
            #expect(headers["x-api-key"].isEmpty)
            #expect(headers.first(name: "x-retained") == "yes")
        } catch {
            await transport.shutdownIgnoringError()
            await origin.shutdown()
            await destination.shutdown()
            throw error
        }

        try await transport.shutdown()
        await origin.shutdown()
        await destination.shutdown()
    }

    @Test("HTTP same-origin redirects retain x-api-key case-insensitively")
    func httpRedirectRetainsAPIKeyWithinSameOrigin() throws {
        let source = try #require(URL(string: "https://api.anthropic.com/v1/messages"))
        let destination = try #require(URL(string: "https://API.ANTHROPIC.COM/v1/messages/next"))
        let request = RemoteHTTPStreamingRequest(
            url: source,
            headers: [RemoteHTTPHeader(name: "X-API-Key", value: "same-origin-key")]
        )

        let redirect = try RemoteTransportCore.redirectRequest(
            request,
            to: destination,
            status: 302
        )

        #expect(RemoteHTTPHeaders(redirect.headers).firstValue(for: "x-api-key") == "same-origin-key")
    }

    @Test("Collected HTTP responses enforce a global body budget")
    func httpCollectedResponseRejectsOversizedBody() async throws {
        let server = try await LocalHTTPTestServer.start { context, _ in
            writeHTTPResponse("seventeen-bytes!!", status: .ok, to: context)
        }
        let transport = RemoteTransportCore(
            owningEventLoopThreads: 1,
            maximumCollectedResponseBodyBytes: 16
        )
        defer {
            Task {
                try? await transport.shutdown()
                await server.shutdown()
            }
        }

        await #expect(throws: RemoteTransportError.self) {
            _ = try await transport.sendRequest(
                RemoteHTTPStreamingRequest(url: server.url(path: "/oversized"))
            )
        }
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("HTTP redirects never resend bodies across origins")
    func httpRedirectRejectsCrossOriginBodyReplay() throws {
        let request = RemoteHTTPStreamingRequest(
            url: try #require(URL(string: "https://auth.example.com/token")),
            method: "POST",
            headers: [RemoteHTTPHeader(name: "content-type", value: "application/x-www-form-urlencoded")],
            body: Data("code=secret&code_verifier=verifier".utf8)
        )
        let destination = try #require(URL(string: "https://attacker.example/collect"))

        for status in [301, 302, 303, 307, 308] {
            #expect(throws: RemoteTransportError.self) {
                _ = try RemoteTransportCore.redirectRequest(
                    request,
                    to: destination,
                    status: status
                )
            }
        }
    }

    @Test("HTTP redirects reject HTTPS downgrades")
    func httpRedirectRejectsHTTPSDowngrade() throws {
        let request = RemoteHTTPStreamingRequest(
            url: try #require(URL(string: "https://auth.example.com/token"))
        )
        let destination = try #require(URL(string: "http://auth.example.com/token"))

        #expect(throws: RemoteTransportError.self) {
            _ = try RemoteTransportCore.redirectRequest(
                request,
                to: destination,
                status: 302
            )
        }
    }

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

    @Test("WebSocket send completes while a receive is already parked")
    func webSocketSendProceedsWhileReceiveIsPending() async throws {
        let serverReady = TestSignal()
        let server = try await LocalWebSocketTestServer.start(
            onWebSocketReady: {
                Task { await serverReady.signal() }
            }
        )
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let socket = try await transport.connectWebSocket(
                RemoteWebSocketRequest(
                    url: server.url(path: "/frames"),
                    headers: [RemoteHTTPHeader(name: "x-transport-test", value: "websocket")]
                )
            )
            // `handlerAdded` is a concrete server-side edge: the echo handler
            // is installed before the client starts its parked receive.
            try await wait(for: serverReady)

            // Mirror the ChatGPT driver: a reader parks on receive() first,
            // then a ping is sent on an otherwise idle connection. The ping
            // frame must be written while the receive is still awaiting.
            let receiveTask = Task {
                try await socket.receive()
            }
            defer { receiveTask.cancel() }

            // Do not infer this from elapsed time. The driver reports that the
            // receive request has left its queue for the read loop; this idle
            // fixture cannot complete it before the ping is written.
            try await awaitWebSocketReceiveParked(socket.driver)
            let pingPayload = Data("readiness".utf8)
            try await socket.send(.ping(pingPayload))

            let received = try await withThrowingTaskGroup(
                of: RemoteWebSocketFrame?.self
            ) { group in
                group.addTask {
                    try await receiveTask.value
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw RemoteTransportError.timeout
                }
                defer { group.cancelAll() }
                while let frame = try await group.next() {
                    if frame != nil {
                        return frame
                    }
                }
                return nil
            }
            #expect(received == .pong(Data("readiness".utf8)))

            try await socket.close()
        } catch {
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
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
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
                promise: nil
            )
            // Close the socket mid-body to truncate the declared length.
            context.close(promise: nil)
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

        do {
            let connection = try await transport.connectWebSocket(
                RemoteWebSocketRequest(url: server.url(path: "/cancel"))
            )
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
            context.writeAndFlush(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .body(.byteBuffer(body))
                ),
                promise: nil
            )
            context.close(promise: nil)
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
            pool.closeAll()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        pool.closeAll()
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
            pool.closeAll()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        pool.closeAll()
        try await transport.shutdown()
        await server.shutdown()
    }

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
            pool.closeAll()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        pool.closeAll()
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
                    pool.closeAll()
                    await transport.shutdownIgnoringError()
                    await server.shutdown()
                    return
                }
                #expect(error.message == message)
            }

            #expect(requestCount.withLock { $0 } == 1)
            #expect(retrySleepAttempts.withLock { $0 }.isEmpty)
        } catch {
            pool.closeAll()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        pool.closeAll()
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
                    pool.closeAll()
                    await transport.shutdownIgnoringError()
                    await server.shutdown()
                    return
                }
                #expect(output == message)
            }

            #expect(requestCount.withLock { $0 } == 1)
            #expect(retrySleepAttempts.withLock { $0 }.isEmpty)
        } catch {
            pool.closeAll()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        pool.closeAll()
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
            pool.closeAll()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        pool.closeAll()
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
            pool.closeAll()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        pool.closeAll()
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
            pool.closeAll()
            await transport.shutdownIgnoringError()
            await server.shutdown()
            throw error
        }

        pool.closeAll()
        try await transport.shutdown()
        await server.shutdown()
    }
}

private func writeSSEPayload(
    _ payload: String,
    to context: ChannelHandlerContext
) {
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "text/event-stream")
    headers.add(name: "content-length", value: String(payload.utf8.count))
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
    context.write(
        LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
        promise: nil
    )
    // Send the HTTP response terminator before closing the channel so the
    // client's body reader observes a clean end-of-stream instead of a
    // transport-level close that can race ahead of the final body chunk.
    context.writeAndFlush(
        LocalHTTPResponseHandler.wrapOutboundOut(.end(nil)),
        promise: nil
    )
    context.close(promise: nil)
}

private func writeHTTPResponse(
    _ payload: String,
    status: HTTPResponseStatus,
    to context: ChannelHandlerContext
) {
    var headers = HTTPHeaders()
    headers.add(name: "content-length", value: String(payload.utf8.count))
    context.write(
        LocalHTTPResponseHandler.wrapOutboundOut(
            .head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))
        ),
        promise: nil
    )
    var body = context.channel.allocator.buffer(capacity: payload.utf8.count)
    body.writeString(payload)
    context.write(
        LocalHTTPResponseHandler.wrapOutboundOut(.body(.byteBuffer(body))),
        promise: nil
    )
    context.writeAndFlush(
        LocalHTTPResponseHandler.wrapOutboundOut(.end(nil)),
        promise: nil
    )
}

private final class HTTPHeaderCapture: Sendable {
    private let headers = Mutex(HTTPHeaders())

    func record(_ headers: HTTPHeaders) {
        self.headers.withLock { $0 = headers }
    }

    func value() -> HTTPHeaders {
        headers.withLock { $0 }
    }
}

private extension RemoteTransportCore {
    func shutdownIgnoringError() async {
        try? await shutdown()
    }
}

private actor TestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !signaled else {
            return
        }
        signaled = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !signaled else {
            return
        }
        await withCheckedContinuation { continuation in
            if signaled {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private func wait(for signal: TestSignal) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await signal.wait()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw RemoteTransportError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw RemoteTransportError.timeout
        }
        return result
    }
}

/// Waits for the actual driver state instead of treating a scheduler delay as
/// proof that `receive()` reached the inbound stream. The deadline is only a
/// failure bound; the observed parked state is the synchronization edge.
private func awaitWebSocketReceiveParked(
    _ driver: RemoteWebSocketDriver,
    timeout: Duration = .seconds(5)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await driver.hasParkedReceiveForTesting() {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    guard await driver.hasParkedReceiveForTesting() else {
        throw RemoteTransportError.timeout
    }
}

/// Weak holder for an internal driver actor, so a test can observe that the
/// parked run-task released it after the last public handle was dropped.
private final class WeakBox<T: AnyObject & Sendable>: Sendable {
    weak let value: T?
    init(_ value: T) { self.value = value }
}

/// Polls until `box.value` becomes `nil`. The bounded deadline is only a final
/// protection: the proof is that the object is actually deallocated, never a
/// fixed sleep.
private func awaitDeallocated<T: AnyObject & Sendable>(
    _ box: WeakBox<T>,
    timeout: Duration = .seconds(5)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if box.value == nil {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("The driver was not deallocated within \(timeout.components.seconds) seconds.")
}

private final class LocalHTTPTestServer: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let channel: any Channel

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel) {
        self.group = group
        self.channel = channel
    }

    static func start(
        onInactive: @escaping @Sendable () -> Void = {},
        onRequest: @escaping @Sendable (
            ChannelHandlerContext,
            HTTPRequestHead
        ) -> Void
    ) async throws -> LocalHTTPTestServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(
                    ChannelOptions.backlog,
                    value: 16
                )
                .serverChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: 1
                )
                .childChannelOption(ChannelOptions.autoRead, value: true)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations
                            .configureHTTPServerPipeline(
                                withPipeliningAssistance: false
                            )
                        try channel.pipeline.syncOperations.addHandler(
                            LocalHTTPResponseHandler(
                                onRequest: onRequest,
                                onInactive: onInactive
                            )
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return LocalHTTPTestServer(group: group, channel: channel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func shutdown() async {
        _ = try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    private var port: Int {
        channel.localAddress!.port!
    }
}

private final class LocalHTTPResponseHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let onRequest: @Sendable (ChannelHandlerContext, HTTPRequestHead) -> Void
    private let onInactive: @Sendable () -> Void
    private var receivedHead = false

    init(
        onRequest: @escaping @Sendable (ChannelHandlerContext, HTTPRequestHead) -> Void,
        onInactive: @escaping @Sendable () -> Void
    ) {
        self.onRequest = onRequest
        self.onInactive = onInactive
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case let .head(head):
            guard !receivedHead else {
                return
            }
            receivedHead = true
            onRequest(context, head)
        case .body, .end:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onInactive()
        context.fireChannelInactive()
    }
}

private final class LocalWebSocketTestServer: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let channel: any Channel

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel) {
        self.group = group
        self.channel = channel
    }

    static func start(
        resetOnText: String? = nil,
        onWebSocketReady: (@Sendable () -> Void)? = nil
    ) async throws -> LocalWebSocketTestServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1_024 * 1_024,
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(
                    LocalWebSocketEchoHandler(
                        resetOnText: resetOnText,
                        onHandlerAdded: onWebSocketReady
                    )
                )
            }
        )

        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: 1
                )
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: (
                            upgraders: [upgrader],
                            completionHandler: { _ in }
                        )
                    )
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return LocalWebSocketTestServer(group: group, channel: channel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func url(path: String) -> URL {
        URL(string: "ws://127.0.0.1:\(port)\(path)")!
    }

    func shutdown() async {
        _ = try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    private var port: Int {
        channel.localAddress!.port!
    }
}

private final class LocalWebSocketEchoHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let resetOnText: String?
    private let onHandlerAdded: (@Sendable () -> Void)?

    init(
        resetOnText: String?,
        onHandlerAdded: (@Sendable () -> Void)? = nil
    ) {
        self.resetOnText = resetOnText
        self.onHandlerAdded = onHandlerAdded
    }

    func handlerAdded(context: ChannelHandlerContext) {
        onHandlerAdded?()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = Self.unwrapInboundIn(data)
        if let key = frame.maskKey {
            frame.data.webSocketUnmask(key)
        }

        if frame.opcode == .text,
           let resetOnText,
           frame.data.getString(
               at: frame.data.readerIndex,
               length: frame.data.readableBytes
           ) == resetOnText {
            // SO_LINGER(0) makes close emit a TCP RST instead of a graceful FIN,
            // reproducing Wi-Fi loss / peer reset rather than an RFC 6455 close.
            if let socket = context.channel as? SocketOptionProvider {
                let channel = context.channel
                socket.setSoLinger(linger(l_onoff: 1, l_linger: 0))
                    .whenComplete { _ in
                        channel.close(promise: nil)
                    }
            } else {
                context.close(promise: nil)
            }
            return
        }

        let response: WebSocketFrame
        switch frame.opcode {
        case .text, .binary, .continuation:
            response = WebSocketFrame(
                fin: frame.fin,
                opcode: frame.opcode,
                data: frame.data
            )
        case .ping:
            response = WebSocketFrame(
                fin: true,
                opcode: .pong,
                data: frame.data
            )
        case .connectionClose:
            response = WebSocketFrame(
                fin: true,
                opcode: .connectionClose,
                data: frame.data
            )
        case .pong:
            return
        default:
            return
        }
        context.writeAndFlush(Self.wrapOutboundOut(response), promise: nil)
    }
}
