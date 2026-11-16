//
//  RemoteTransportCoreTests+Part1.swift
//  ZenCODECoreTests
//
//  First part of the RemoteTransportCore tests: HTTP streaming heads, SSE
//  delimiters and size limits, idle, opening and request timeouts, body
//  cancellation and the redirect policy.
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

extension RemoteTransportCoreTests {
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

    @Test("SSE rejects oversized lines, events, and complete streams")
    func sseRejectsOversizedLinesEventsAndStreams() async throws {
        let server = try await LocalHTTPTestServer.start { context, request in
            context.write(
                LocalHTTPResponseHandler.wrapOutboundOut(
                    .head(HTTPResponseHead(version: .http1_1, status: .ok))
                ),
                promise: nil
            )
            let payload: String
            if request.uri.contains("line") {
                payload = "data: 123456789\n\n"
            } else if request.uri.contains("event") {
                payload = "data: 12345\ndata: 67890\n\n"
            } else {
                payload = "data: one\n\ndata: two\n\n"
            }
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

        let streamResponse = try await transport.openHTTPStream(
            RemoteHTTPStreamingRequest(url: server.url(path: "/stream"))
        )
        var streamEvents = RemoteSSEEventStream(
            body: streamResponse.body,
            maximumLineBytes: 64,
            maximumEventBytes: 64,
            maximumStreamBytes: 12
        ).makeAsyncIterator()
        await #expect(throws: RemoteSSEStreamLimitError(maximumBytes: 12)) {
            _ = try await streamEvents.next()
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
        // Scoped so the response handle (and the lifetime token it retains) is
        // released before the owned event-loop group shuts down; the run-task
        // tail of `executeThenClose` must not touch a shut-down loop.
        let storageBox: WeakBox<RemoteHTTPBodyStorage>

        do {
            let response = try await transport.openHTTPStream(
                RemoteHTTPStreamingRequest(url: server.url(path: "/sse-stall"))
            )
            storageBox = WeakBox(response.body.storage)
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

        try await awaitDeallocated(storageBox)
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
        // Teardown runs exactly once, below: a second (deferred) server.shutdown()
        // would call shutdownGracefully() on an already shut down event loop group.
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
}
