//
//  RemoteTransportCoreTests+Support.swift
//  ZenCODECoreTests
//
//  Local NIO HTTP and WebSocket test servers, signals and helpers shared by
//  the RemoteTransportCore tests.
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

func writeSSEPayload(
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
    // Flush the HTTP terminator before closing so the final body chunk and
    // clean end-of-stream cannot be overtaken by the transport-level close.
    let channel = context.channel
    let flushPromise = context.eventLoop.makePromise(of: Void.self)
    context.writeAndFlush(
        LocalHTTPResponseHandler.wrapOutboundOut(.end(nil)),
        promise: flushPromise
    )
    flushPromise.futureResult.whenComplete { _ in
        channel.close(promise: nil)
    }
}

func writeHTTPResponse(
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

final class HTTPHeaderCapture: Sendable {
    private let headers = Mutex(HTTPHeaders())

    func record(_ headers: HTTPHeaders) {
        self.headers.withLock { $0 = headers }
    }

    func value() -> HTTPHeaders {
        headers.withLock { $0 }
    }
}

extension RemoteTransportCore {
    func shutdownIgnoringError() async {
        try? await shutdown()
    }
}

actor TestSignal {
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

func wait(for signal: TestSignal) async throws {
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

/// Weak holder for an internal driver actor, so a test can observe that the
/// parked run-task released it after the last public handle was dropped.
final class WeakBox<T: AnyObject & Sendable>: Sendable {
    weak let value: T?
    init(_ value: T) { self.value = value }
}

/// Polls until `box.value` becomes `nil`. The bounded deadline is only a final
/// protection: the proof is that the object is actually deallocated, never a
/// fixed sleep.
func awaitDeallocated<T: AnyObject & Sendable>(
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

final class LocalHTTPTestServer: @unchecked Sendable {
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

final class LocalHTTPResponseHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let onRequest: @Sendable (ChannelHandlerContext, HTTPRequestHead) -> Void
    private let onInactive: @Sendable () -> Void
    private var receivedHead = false
    private var requestHead: HTTPRequestHead?

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
            requestHead = head
        case .body:
            break
        case .end:
            guard let head = requestHead else {
                return
            }
            requestHead = nil
            // A response may close the channel. Wait for the complete request
            // so that close cannot race the client's remaining body writes.
            onRequest(context, head)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onInactive()
        context.fireChannelInactive()
    }
}

final class LocalWebSocketTestServer: @unchecked Sendable {
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
