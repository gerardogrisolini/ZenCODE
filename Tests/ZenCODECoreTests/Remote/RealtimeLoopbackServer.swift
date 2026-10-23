//
//  RealtimeLoopbackServer.swift
//  ZenCODECoreTests
//
//  A scripted loopback WebSocket peer for the OpenAI realtime tests. Each
//  upgraded connection exposes the client's text frames as decoded JSON events
//  and lets the test push provider events back.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization

struct RealtimeLoopbackTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)." }
}

/// FIFO with a timed `next`. Values arrive from NIO or test tasks; a waiter is
/// resumed exactly once: with a value, with `nil` once closed, or by its
/// timeout.
final class RealtimeTestQueue<Element: Sendable>: Sendable {
    /// Outer `nil` means the wait timed out; `.some(nil)` means closed.
    private typealias Delivery = Element??

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Delivery, Never>
    }

    private struct State {
        var buffered: [Element] = []
        var waiter: Waiter?
        var isClosed = false
        var nextWaiterID: UInt64 = 0
    }

    private let state = Mutex(State())

    func append(_ element: Element) {
        let waiter = state.withLock { state -> Waiter? in
            guard !state.isClosed else {
                return nil
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.buffered.append(element)
            return nil
        }
        waiter?.continuation.resume(returning: .some(.some(element)))
    }

    func close() {
        let waiter = state.withLock { state -> Waiter? in
            state.isClosed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.continuation.resume(returning: .some(nil))
    }

    var bufferedCount: Int {
        state.withLock { $0.buffered.count }
    }

    /// Returns the next element, `nil` once closed and drained, or throws on
    /// timeout.
    func next(timeout: Duration = .seconds(5), what: String = "event") async throws -> Element? {
        let delivery: Delivery = await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> Delivery in
                if !state.buffered.isEmpty {
                    return .some(state.buffered.removeFirst())
                }
                if state.isClosed {
                    return .some(nil)
                }
                state.nextWaiterID &+= 1
                let id = state.nextWaiterID
                state.waiter = Waiter(id: id, continuation: continuation)
                Task {
                    try? await Task.sleep(for: timeout)
                    self.expire(waiterID: id)
                }
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
        guard let delivery else {
            throw RealtimeLoopbackTimeout(what: what)
        }
        return delivery
    }

    private func expire(waiterID: UInt64) {
        let waiter = state.withLock { state -> Waiter? in
            guard let waiter = state.waiter, waiter.id == waiterID else {
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.continuation.resume(returning: nil)
    }
}

/// One upgraded client connection.
final class RealtimeLoopbackConnection: Sendable {
    let requestHead: HTTPRequestHead
    private let channel: any Channel
    private let inbox: RealtimeTestQueue<String>

    init(requestHead: HTTPRequestHead, channel: any Channel, inbox: RealtimeTestQueue<String>) {
        self.requestHead = requestHead
        self.channel = channel
        self.inbox = inbox
    }

    var unreadEventCount: Int {
        inbox.bufferedCount
    }

    /// Sends one provider event as a text frame.
    func send(_ event: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(
            WebSocketFrame(fin: true, opcode: .text, data: buffer)
        ).get()
    }

    /// The next client event, decoded.
    func nextEvent(timeout: Duration = .seconds(5)) async throws -> [String: Any] {
        guard let text = try await inbox.next(timeout: timeout, what: "a client event") else {
            throw RealtimeLoopbackTimeout(what: "a client event (connection closed)")
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw RealtimeLoopbackTimeout(what: "a JSON object client event")
        }
        return object
    }

    /// Skips client events until one of `type` arrives. Audio appends are
    /// skipped silently; any other skipped type is returned for inspection.
    func nextEvent(
        ofType type: String,
        timeout: Duration = .seconds(5)
    ) async throws -> (event: [String: Any], skippedTypes: [String]) {
        var skipped: [String] = []
        while true {
            let event = try await nextEvent(timeout: timeout)
            let eventType = event["type"] as? String ?? ""
            if eventType == type {
                return (event, skipped)
            }
            if eventType != "input_audio_buffer.append" {
                skipped.append(eventType)
            }
        }
    }

    /// Waits for the client to close, or returns `false` when the connection
    /// is still open after `timeout` with no further client events.
    func expectNoClientEvent(within timeout: Duration) async -> Bool {
        do {
            _ = try await nextEvent(timeout: timeout)
            return false
        } catch {
            return true
        }
    }

    func close() async {
        _ = try? await channel.close().get()
    }

    /// Performs the realtime handshake: `session.created`, waits for the
    /// client's `session.update`, then acknowledges it.
    @discardableResult
    func completeHandshake() async throws -> [String: Any] {
        try await send(["type": "session.created", "session": ["id": "sess_test"]])
        let update = try await nextEvent(ofType: "session.update").event
        try await send(["type": "session.updated", "session": update["session"] ?? [:]])
        return update
    }
}

final class RealtimeLoopbackServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let serverChannel: any Channel
    private let connections: RealtimeTestQueue<RealtimeLoopbackConnection>

    private init(
        group: MultiThreadedEventLoopGroup,
        serverChannel: any Channel,
        connections: RealtimeTestQueue<RealtimeLoopbackConnection>
    ) {
        self.group = group
        self.serverChannel = serverChannel
        self.connections = connections
    }

    static func start() async throws -> RealtimeLoopbackServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connections = RealtimeTestQueue<RealtimeLoopbackConnection>()
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 16 * 1_024 * 1_024,
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, head in
                let inbox = RealtimeTestQueue<String>()
                let connection = RealtimeLoopbackConnection(
                    requestHead: head,
                    channel: channel,
                    inbox: inbox
                )
                return channel.pipeline.addHandler(
                    RealtimeLoopbackHandler(inbox: inbox)
                ).map {
                    connections.append(connection)
                }
            }
        )
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                    )
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return RealtimeLoopbackServer(group: group, serverChannel: channel, connections: connections)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func url(model: String = "gpt-realtime-2.1") -> URL {
        URL(string: "ws://127.0.0.1:\(serverChannel.localAddress!.port!)/v1/realtime?model=\(model)")!
    }

    /// `http://127.0.0.1:<port>/v1`, a provider base URL for this server.
    var baseURL: String {
        "http://127.0.0.1:\(serverChannel.localAddress!.port!)/v1"
    }

    func nextConnection(timeout: Duration = .seconds(5)) async throws -> RealtimeLoopbackConnection {
        guard let connection = try await connections.next(timeout: timeout, what: "a WebSocket connection") else {
            throw RealtimeLoopbackTimeout(what: "a WebSocket connection (server closed)")
        }
        return connection
    }

    /// `true` when no client connected within `timeout`.
    func expectNoConnection(within timeout: Duration) async -> Bool {
        do {
            _ = try await connections.next(timeout: timeout)
            return false
        } catch {
            return true
        }
    }

    func shutdown() async {
        connections.close()
        _ = try? await serverChannel.close().get()
        try? await group.shutdownGracefully()
    }
}

private final class RealtimeLoopbackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let inbox: RealtimeTestQueue<String>

    init(inbox: RealtimeTestQueue<String>) {
        self.inbox = inbox
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        let payload = frame.unmaskedData
        switch frame.opcode {
        case .text:
            inbox.append(payload.getString(at: payload.readerIndex, length: payload.readableBytes) ?? "")
        case .ping:
            context.writeAndFlush(
                Self.wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: payload)),
                promise: nil
            )
        case .connectionClose:
            let channel = context.channel
            context.writeAndFlush(
                Self.wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload))
            ).whenComplete { _ in
                channel.close(promise: nil)
            }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        inbox.close()
        context.fireChannelInactive()
    }
}
