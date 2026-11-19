//
//  FigmaLoginNIOTransport.swift
//  ZenCODE
//
//  SwiftNIO socket layer of the Figma sign-in server, used wherever the
//  Network framework is unavailable (Linux). Routing and every security rule
//  live in `FigmaLoginFlow`; this file only binds 127.0.0.1, reads one request
//  per connection through `FigmaLoginHTTP.RequestReader` (so the request size
//  limit is the same as on macOS), and writes the flow's response.
//
//  It is compiled on every platform so the macOS test run covers it too, but
//  macOS keeps using `FigmaLoginNetworkTransport`.
//

import Foundation
import NIOCore
import NIOPosix
import Synchronization

final class FigmaLoginNIOTransport: FigmaLoginTransport {
    private struct Lifecycle: Sendable {
        var group: MultiThreadedEventLoopGroup?
        var channel: (any Channel)?
        var isStopped = false
    }

    private let lifecycle = Mutex(Lifecycle())

    init() {}

    func start(flow: FigmaLoginFlow) async throws -> UInt16 {
        // One event loop is plenty for a single browser tab; it is created
        // here, not in `init`, so a transport that never starts owns no threads.
        let group: MultiThreadedEventLoopGroup? = lifecycle.withLock { lifecycle in
            guard !lifecycle.isStopped, lifecycle.group == nil else { return nil }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            lifecycle.group = group
            return group
        }
        guard let group else {
            throw FigmaToolsError.loginFailed("the sign-in page was stopped.")
        }

        let channel: any Channel
        do {
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(FigmaLoginNIOConnectionHandler(flow: flow))
                    }
                }
                // Loopback only, never a wildcard address: the page is for this machine.
                .bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0))
                .get()
        } catch {
            stop()
            throw FigmaToolsError.loginFailed("unable to start the local sign-in page. \(error.localizedDescription)")
        }

        let isStillRunning = lifecycle.withLock { lifecycle -> Bool in
            guard !lifecycle.isStopped else { return false }
            lifecycle.channel = channel
            return true
        }
        guard isStillRunning else {
            channel.close(promise: nil)
            throw FigmaToolsError.loginFailed("the sign-in page was stopped.")
        }
        guard let port = channel.localAddress?.port, let boundPort = UInt16(exactly: port) else {
            stop()
            throw FigmaToolsError.loginFailed("the local sign-in page did not report a port.")
        }

        // A listener that dies on its own must fail the wait; after `stop()`
        // the result is already resolved and this is a no-op.
        let state = flow.state
        channel.closeFuture.whenComplete { _ in
            state.resumeResult(with: .failure(FigmaToolsError.loginFailed("the sign-in page was stopped.")))
        }
        return boundPort
    }

    func stop() {
        let (group, channel) = lifecycle.withLock { lifecycle -> (MultiThreadedEventLoopGroup?, (any Channel)?) in
            lifecycle.isStopped = true
            let taken = (lifecycle.group, lifecycle.channel)
            lifecycle.group = nil
            lifecycle.channel = nil
            return taken
        }
        // The group shutdown also closes the connections still open. A
        // response written just before is already queued on its event loop
        // and goes out first.
        channel?.close(promise: nil)
        group?.shutdownGracefully { _ in }
    }
}

/// Reads one request from a connection, hands it to the flow, writes the
/// response, and closes the connection.
private final class FigmaLoginNIOConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let flow: FigmaLoginFlow
    private var reader = FigmaLoginHTTP.RequestReader()
    private var didDecideResponse = false

    init(flow: FigmaLoginFlow) {
        self.flow = flow
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // One request per connection (`Connection: close`): ignore whatever
        // follows the request that is already being answered.
        guard !didDecideResponse else { return }
        let buffer = unwrapInboundIn(data)
        let channel = context.channel

        switch reader.append(Data(buffer.readableBytesView)) {
        case .incomplete:
            return
        case .tooLarge:
            didDecideResponse = true
            Self.send(.requestTooLarge, on: channel)
        case let .request(request):
            didDecideResponse = true
            flow.handle(request) { response in
                Self.send(response, on: channel)
            }
        }
    }

    /// Safe from any thread: `Channel` hops to its event loop for the write.
    private static func send(_ response: FigmaLoginHTTP.Response, on channel: any Channel) {
        var buffer = channel.allocator.buffer(capacity: 0)
        buffer.writeBytes(response.serialized())
        channel.writeAndFlush(buffer).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
