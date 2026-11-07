import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing
@testable import ZenCODECore

@Suite("ChatGPTSubscriptionWebSocketPool HTTP teardown", .serialized)
struct ChatGPTSubscriptionWebSocketPoolHTTPTeardownTests {
    @Test("owned pool shutdown tears down an open HTTP stream and its transport")
    func ownedPoolShutdownTearsDownOpenHTTPStream() async throws {
        let server = try await HTTPTeardownTestServer.start { context in
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/event-stream")
            context.writeAndFlush(
                HTTPTeardownResponseHandler.wrapOutboundOut(
                    .head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))
                ),
                promise: nil
            )
        }
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max
        )
        let scopeID = "owned-http-shutdown"
        let request = RemoteHTTPStreamingRequest(url: server.url(path: "/stream"))

        do {
            _ = try await pool.openHTTPStream(request, scopeID: scopeID)
            #expect(pool.hasActiveHTTPStream(scopeID: scopeID))

            await pool.shutdown()

            #expect(!pool.hasPendingHTTPStream(scopeID: scopeID))
            #expect(!pool.hasActiveHTTPStream(scopeID: scopeID))
        } catch {
            pool.closeAll()
            await server.shutdown()
            throw error
        }

        await server.shutdown()
    }

    @Test("closeAll fences an HTTP opener that completed before active registration")
    func closeAllFencesCompletedHTTPOpener() async throws {
        let registrationGate = HTTPRegistrationGate()
        let server = try await HTTPTeardownTestServer.start { context in
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/event-stream")
            context.writeAndFlush(
                HTTPTeardownResponseHandler.wrapOutboundOut(
                    .head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))
                ),
                promise: nil
            )
            // Keep the body open: teardown must cancel the response itself.
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let pool = ChatGPTSubscriptionWebSocketPool(
            transport: transport,
            heartbeatIntervalNanoseconds: UInt64.max,
            beforeHTTPStreamRegistration: {
                await registrationGate.arriveAndWait()
            }
        )
        let scopeID = "http-teardown-race"
        let request = RemoteHTTPStreamingRequest(url: server.url(path: "/stream"))

        let opening = Task<Result<Void, any Error>, Never> {
            do {
                _ = try await pool.openHTTPStream(request, scopeID: scopeID)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        await registrationGate.waitUntilArrived()
        #expect(pool.hasPendingHTTPStream(scopeID: scopeID))

        pool.closeAll()
        await registrationGate.release()

        switch await opening.value {
        case .success:
            Issue.record("A stream opened before closeAll was registered after teardown.")
        case let .failure(error):
            #expect(error is CancellationError)
        }
        #expect(!pool.hasPendingHTTPStream(scopeID: scopeID))
        #expect(!pool.hasActiveHTTPStream(scopeID: scopeID))

        pool.closeAll()
        try await transport.shutdown()
        await server.shutdown()
    }
}

private actor HTTPRegistrationGate {
    private var hasArrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        hasArrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilArrived() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class HTTPTeardownTestServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel) {
        self.group = group
        self.channel = channel
    }

    static func start(
        onRequest: @escaping @Sendable (ChannelHandlerContext) -> Void
    ) async throws -> HTTPTeardownTestServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                            withPipeliningAssistance: false
                        )
                        try channel.pipeline.syncOperations.addHandler(
                            HTTPTeardownResponseHandler(onRequest: onRequest)
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return HTTPTeardownTestServer(group: group, channel: channel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(channel.localAddress!.port!)\(path)")!
    }

    func shutdown() async {
        _ = try? await channel.close().get()
        try? await group.shutdownGracefully()
    }
}

private final class HTTPTeardownResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let onRequest: @Sendable (ChannelHandlerContext) -> Void
    private let receivedHead = Mutex(false)

    init(onRequest: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        self.onRequest = onRequest
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head = Self.unwrapInboundIn(data) else { return }
        let shouldHandle = receivedHead.withLock { receivedHead in
            guard !receivedHead else { return false }
            receivedHead = true
            return true
        }
        guard shouldHandle else { return }
        onRequest(context)
    }
}
