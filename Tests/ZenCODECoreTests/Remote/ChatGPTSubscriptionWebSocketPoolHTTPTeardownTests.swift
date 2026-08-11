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

        do {
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
        } catch {
            pool.closeAll()
            try? await transport.shutdown()
            await server.shutdown()
            throw error
        }

        pool.closeAll()
        try await transport.shutdown()
        await server.shutdown()
    }

    @Test("owned shutdown terminally fences a concurrent HTTP opener")
    func ownedShutdownTerminallyFencesConcurrentHTTPOpener() async throws {
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
        }
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            beforeHTTPStreamRegistration: {
                await registrationGate.arriveAndWait()
            }
        )
        let scopeID = "owned-terminal-http-race"
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

        // The owned transport must not be shut down until the pending opener
        // has been cancelled and drained; this returns with the terminal fence
        // installed even though the caller is paused before promotion.
        await pool.shutdown()
        #expect(!pool.hasPendingHTTPStream(scopeID: scopeID))
        #expect(!pool.hasActiveHTTPStream(scopeID: scopeID))

        await registrationGate.release()
        switch await opening.value {
        case .success:
            Issue.record("A stream was promoted after owned transport shutdown.")
        case let .failure(error):
            #expect(error is CancellationError)
        }

        await server.shutdown()
    }

    @Test("concurrent shutdown callers share the terminal HTTP drain")
    func concurrentShutdownCallersShareTerminalHTTPDrain() async throws {
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
        }
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            beforeHTTPStreamRegistration: { await registrationGate.arriveAndWait() }
        )
        let request = RemoteHTTPStreamingRequest(url: server.url(path: "/stream"))
        let opening = Task<Result<Void, any Error>, Never> {
            do {
                _ = try await pool.openHTTPStream(request, scopeID: "two-shutdowns")
                return .success(())
            } catch { return .failure(error) }
        }

        await registrationGate.waitUntilArrived()
        async let first: Void = pool.shutdown()
        async let second: Void = pool.shutdown()
        await (first, second)

        await registrationGate.release()
        if case .success = await opening.value {
            Issue.record("An HTTP opener survived the shared terminal shutdown.")
        }
        #expect(!pool.hasPendingHTTPStream(scopeID: "two-shutdowns"))
        #expect(!pool.hasActiveHTTPStream(scopeID: "two-shutdowns"))
        await server.shutdown()
    }

    @Test("closeAll drain completes before a following shutdown closes transport")
    func closeAllThenShutdownDrainsCancelledHTTPOpener() async throws {
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
        }
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            beforeHTTPStreamRegistration: { await registrationGate.arriveAndWait() }
        )
        let request = RemoteHTTPStreamingRequest(url: server.url(path: "/stream"))
        let opening = Task<Result<Void, any Error>, Never> {
            do {
                _ = try await pool.openHTTPStream(request, scopeID: "close-all-then-shutdown")
                return .success(())
            } catch { return .failure(error) }
        }

        await registrationGate.waitUntilArrived()
        pool.closeAll()
        await pool.shutdown()
        await registrationGate.release()

        if case .success = await opening.value {
            Issue.record("closeAll's cancelled opener escaped terminal shutdown.")
        }
        #expect(!pool.hasPendingHTTPStream(scopeID: "close-all-then-shutdown"))
        #expect(!pool.hasActiveHTTPStream(scopeID: "close-all-then-shutdown"))
        await server.shutdown()
    }

    @Test("closeAll cancels immediately and coalesced shutdown waits for its pending HTTP drain")
    func closeAllImmediatelyCancelsPendingOpenerBeforeCoalescedShutdown() async {
        let openerGate = HTTPCancellationIgnoringOpenerGate()
        let shutdownCalls = ShutdownCallHandshake()
        let transportShutdownGate = HTTPRegistrationGate()
        let shutdownObservation = HTTPTransportShutdownObservation()
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            httpStreamOpener: { _ in
                try await openerGate.open()
            },
            beforeOwnedTransportShutdown: {
                await transportShutdownGate.arriveAndWait()
                await shutdownObservation.recordTransportShutdown()
            },
            didEnterShutdown: { shutdownCalls.recordCall() }
        )
        let request = RemoteHTTPStreamingRequest(url: URL(string: "https://example.invalid/stream")!)
        let scopeID = "immediate-cancel-coalesced-shutdown"
        let opening = Task<Result<Void, any Error>, Never> {
            do {
                _ = try await pool.openHTTPStream(request, scopeID: scopeID)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        await openerGate.waitUntilOpened()
        #expect(pool.hasPendingHTTPStream(scopeID: scopeID))

        pool.closeAll()
        // The opener intentionally does not finish in response to cancellation.
        // This observation therefore proves cancellation happened synchronously
        // outside closeAll's mutex, rather than later in its drain task.
        await openerGate.waitUntilCancelled()
        #expect(!pool.hasPendingHTTPStream(scopeID: scopeID))

        let firstShutdown = Task { await pool.shutdown() }
        await shutdownCalls.waitUntilCallCount(1)
        let secondShutdown = Task { await pool.shutdown() }
        // This is a causal acknowledgement from shutdown's mutex: the second
        // caller has observed the already-published terminal task and joined
        // it, rather than merely having been scheduled near the first caller.
        await shutdownCalls.waitUntilCallCount(2)

        // The terminal task cannot reach this hook until closeAll's retired
        // opener has drained. Releasing the opener therefore establishes the
        // closeAll -> shutdown happens-before edge without timing assertions.
        await openerGate.release()
        await transportShutdownGate.waitUntilArrived()
        await transportShutdownGate.release()
        await firstShutdown.value
        await secondShutdown.value

        #expect(await shutdownObservation.transportShutdownCount() == 1)
        #expect(!pool.hasPendingHTTPStream(scopeID: scopeID))
        #expect(!pool.hasActiveHTTPStream(scopeID: scopeID))
        switch await opening.value {
        case .success:
            Issue.record("A cancellation-ignoring HTTP opener escaped closeAll then shutdown.")
        case let .failure(error):
            #expect(error is CancellationError)
        }
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

/// Keeps the opening task genuinely pending after `Task.cancel()`. This is a
/// stronger teardown fixture than a network opener whose implementation may
/// immediately throw on cancellation.
private actor HTTPCancellationIgnoringOpenerGate {
    private var hasOpened = false
    private var wasCancelled = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func open() async throws -> RemoteHTTPStreamingResponse {
        hasOpened = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { releaseWaiter = $0 }
        }, onCancel: {
            Task { await self.recordCancellation() }
        })
        throw CancellationError()
    }

    func waitUntilOpened() async {
        guard !hasOpened else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !wasCancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    private func recordCancellation() {
        guard !wasCancelled else { return }
        wasCancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor HTTPTransportShutdownObservation {
    private var count = 0

    func recordTransportShutdown() {
        count += 1
    }

    func transportShutdownCount() -> Int {
        count
    }
}

private final class ShutdownCallHandshake: Sendable {
    private struct State {
        var count = 0
        var waiters: [(minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    func recordCall() {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.count += 1
            let ready = state.waiters.filter { $0.minimumCount <= state.count }
            state.waiters.removeAll { $0.minimumCount <= state.count }
            return ready.map(\.continuation)
        }
        for waiter in ready {
            waiter.resume()
        }
    }

    func waitUntilCallCount(_ minimumCount: Int) async {
        guard !state.withLock({ $0.count >= minimumCount }) else { return }
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                guard state.count < minimumCount else { return true }
                state.waiters.append((minimumCount, continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
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
