//
//  RemoteTransportCoreTests.swift
//  ZenCODECoreTests
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing
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

    @Test("WebSocket send completes while a receive is already parked")
    func webSocketSendProceedsWhileReceiveIsPending() async throws {
        let server = try await LocalWebSocketTestServer.start()
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)

        do {
            let socket = try await transport.connectWebSocket(
                RemoteWebSocketRequest(
                    url: server.url(path: "/frames"),
                    headers: [RemoteHTTPHeader(name: "x-transport-test", value: "websocket")]
                )
            )

            // Mirror the ChatGPT driver: a reader parks on receive() first,
            // then a ping is sent on an otherwise idle connection. The ping
            // frame must be written while the receive is still awaiting.
            let received = try await withThrowingTaskGroup(
                of: RemoteWebSocketFrame?.self
            ) { group in
                group.addTask {
                    try await socket.receive()
                }
                group.addTask {
                    // Give the receive a moment to park on the inbound stream.
                    try await Task.sleep(for: .milliseconds(100))
                    let pingPayload = Data("readiness".utf8)
                    try await socket.send(.ping(pingPayload))
                    return nil
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

    static func start() async throws -> LocalWebSocketTestServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1_024 * 1_024,
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(LocalWebSocketEchoHandler())
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

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = Self.unwrapInboundIn(data)
        if let key = frame.maskKey {
            frame.data.webSocketUnmask(key)
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
