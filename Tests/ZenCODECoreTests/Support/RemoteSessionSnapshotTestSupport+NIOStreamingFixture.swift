//
//  RemoteSessionSnapshotTestSupport+NIOStreamingFixture.swift
//  ZenCODE
//
//  Loopback NIO HTTP streaming fixture of the remote session tests, with its
//  scripted response handling.
//

import FeatureMCPBridgeKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// Deterministic loopback HTTP fixture for the NIO generation-provider tests.
///
/// Provider clients exercise `RemoteTransportCore` over a real NIO socket.
/// It retains full request-header order (including duplicates) alongside a
/// convenient `URLRequest` projection for existing payload assertions.
final class RemoteNIOStreamingFixture: @unchecked Sendable {
    let transport: RemoteTransportCore
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let script: RemoteNIOStreamingScript
    private let shutdownState = Mutex(false)

    private init(
        transport: RemoteTransportCore,
        group: MultiThreadedEventLoopGroup,
        channel: any Channel,
        script: RemoteNIOStreamingScript
    ) {
        self.transport = transport
        self.group = group
        self.channel = channel
        self.script = script
    }

    deinit {
        beginShutdown()
    }

    static func start(
        responseBody: Data,
        responseSequence: [Data] = [],
        responseStatus: Int = 200,
        responseHeaders: [RemoteHTTPHeader] = [
            RemoteHTTPHeader(name: "content-type", value: "text/event-stream")
        ],
        bodyChunks: [Data]? = nil,
        failuresBeforeHead: Int = 0,
        closeAfterHead: Bool = false
    ) async throws -> RemoteNIOStreamingFixture {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let script = RemoteNIOStreamingScript(
            responseBody: responseBody,
            responseSequence: responseSequence,
            responseStatus: responseStatus,
            responseHeaders: responseHeaders,
            bodyChunks: bodyChunks,
            failuresBeforeHead: failuresBeforeHead,
            closeAfterHead: closeAfterHead
        )
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: 1
                )
                .childChannelOption(ChannelOptions.autoRead, value: true)
                .childChannelInitializer { channel in
                    script.registerChild(channel)
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                            withPipeliningAssistance: false
                        )
                        try channel.pipeline.syncOperations.addHandler(
                            RemoteNIOStreamingRequestHandler(script: script)
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return RemoteNIOStreamingFixture(
                transport: RemoteTransportCore(),
                group: group,
                channel: channel,
                script: script
            )
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    var baseURL: URL {
        url(path: "/v1")
    }

    var messagesURL: URL {
        url(path: "/v1/messages")
    }

    func capturedRequests() -> [CapturedRemoteRequest] {
        script.capturedRequests()
    }

    func shutdown() async {
        guard claimShutdown() else {
            return
        }
        try? await transport.shutdown()
        script.closeChildChannels()
        _ = try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    func beginShutdown() {
        guard claimShutdown() else {
            return
        }
        script.closeChildChannels()
        channel.close(promise: nil)
        group.shutdownGracefully(queue: .global()) { _ in }
    }

    private func claimShutdown() -> Bool {
        shutdownState.withLock { isShuttingDown in
            guard !isShuttingDown else {
                return false
            }
            isShuttingDown = true
            return true
        }
    }

    private func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private var port: Int {
        channel.localAddress!.port!
    }
}

private final class RemoteNIOStreamingScript: @unchecked Sendable {
    private let lock = NSLock()
    private let responseBody: Data
    private var responseSequence: [Data]
    private let responseStatus: Int
    private let responseHeaders: [RemoteHTTPHeader]
    private let bodyChunks: [Data]?
    private let closeAfterHead: Bool
    private var failuresBeforeHead: Int
    private var requests: [CapturedRemoteRequest] = []
    private var childChannels: [ObjectIdentifier: any Channel] = [:]

    init(
        responseBody: Data,
        responseSequence: [Data],
        responseStatus: Int,
        responseHeaders: [RemoteHTTPHeader],
        bodyChunks: [Data]?,
        failuresBeforeHead: Int,
        closeAfterHead: Bool
    ) {
        self.responseBody = responseBody
        self.responseSequence = responseSequence
        self.responseStatus = responseStatus
        self.responseHeaders = responseHeaders
        self.bodyChunks = bodyChunks
        self.failuresBeforeHead = max(0, failuresBeforeHead)
        self.closeAfterHead = closeAfterHead
    }

    func receive(
        head: HTTPRequestHead,
        body: Data
    ) -> RemoteNIOStreamingFixtureAction {
        let headerEntries = head.headers.map {
            RemoteHTTPHeader(name: $0.name, value: $0.value)
        }
        var request = URLRequest(
            url: URL(string: "http://fixture.invalid\(head.uri)")!
        )
        request.httpMethod = head.method.rawValue
        for header in headerEntries {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        request.httpBody = body

        lock.lock()
        requests.append(
            CapturedRemoteRequest(
                request: request,
                body: body,
                headerEntries: headerEntries
            )
        )
        if failuresBeforeHead > 0 {
            failuresBeforeHead -= 1
            lock.unlock()
            return .closeBeforeHead
        }
        let selectedBody = responseSequence.isEmpty ? responseBody : responseSequence.removeFirst()
        let response = RemoteNIOStreamingFixtureResponse(
            status: responseStatus,
            headers: responseHeaders,
            bodyChunks: bodyChunks ?? [selectedBody],
            closeAfterHead: closeAfterHead
        )
        lock.unlock()
        return .respond(response)
    }

    func capturedRequests() -> [CapturedRemoteRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func registerChild(_ channel: any Channel) {
        lock.lock()
        childChannels[ObjectIdentifier(channel)] = channel
        lock.unlock()
    }

    func closeChildChannels() {
        lock.lock()
        let channels = Array(childChannels.values)
        childChannels.removeAll()
        lock.unlock()
        for channel in channels {
            channel.close(promise: nil)
        }
    }
}

private enum RemoteNIOStreamingFixtureAction {
    case closeBeforeHead
    case respond(RemoteNIOStreamingFixtureResponse)
}

private struct RemoteNIOStreamingFixtureResponse {
    let status: Int
    let headers: [RemoteHTTPHeader]
    let bodyChunks: [Data]
    let closeAfterHead: Bool
}

private final class RemoteNIOStreamingRequestHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let script: RemoteNIOStreamingScript
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(script: RemoteNIOStreamingScript) {
        self.script = script
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case let .head(head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
        case var .body(buffer):
            if var requestBody {
                requestBody.writeBuffer(&buffer)
                self.requestBody = requestBody
            }
        case .end:
            guard let requestHead else {
                context.close(promise: nil)
                return
            }
            let body = requestBody.map { Data($0.readableBytesView) } ?? Data()
            switch script.receive(head: requestHead, body: body) {
            case .closeBeforeHead:
                context.close(promise: nil)
            case let .respond(response):
                write(response: response, context: context)
            }
        }
    }

    private func write(
        response: RemoteNIOStreamingFixtureResponse,
        context: ChannelHandlerContext
    ) {
        var headers = HTTPHeaders()
        for header in response.headers {
            headers.add(name: header.name, value: header.value)
        }
        if response.closeAfterHead, headers["content-length"].isEmpty {
            let advertisedLength = response.bodyChunks.reduce(0) { partial, chunk in
                partial + chunk.count
            } + 1
            headers.add(name: "content-length", value: String(advertisedLength))
        }
        context.write(
            Self.wrapOutboundOut(
                .head(
                    HTTPResponseHead(
                        version: .http1_1,
                        status: HTTPResponseStatus(statusCode: response.status),
                        headers: headers
                    )
                )
            ),
            promise: nil
        )
        for chunk in response.bodyChunks where !chunk.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            context.write(
                Self.wrapOutboundOut(.body(.byteBuffer(buffer))),
                promise: nil
            )
        }
        if response.closeAfterHead {
            context.flush()
            context.close(promise: nil)
        } else {
            context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
