//
//  RemoteTransportCore.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

/// Shared cross-platform SwiftNIO transport for remote generation clients.
///
/// The default initializer borrows `NIOSingletons.posixEventLoopGroup`, whose
/// lifetime is the process and therefore is intentionally never shut down by
/// this type. `init(owningEventLoopThreads:)` is for an explicitly-owned
/// application scope or deterministic tests; call `shutdown()` exactly once at
/// the end of that scope. Neither initializer creates an event-loop group per
/// HTTP request or WebSocket connection.
public final class RemoteTransportCore: Sendable {
    private let eventLoopGroup: any EventLoopGroup
    private let ownsEventLoopGroup: Bool
    private let lifecycle = RemoteTransportLifecycle()

    /// Uses the process-wide POSIX event-loop group shared by all transport
    /// instances in the process.
    public init() {
        eventLoopGroup = NIOSingletons.posixEventLoopGroup
        ownsEventLoopGroup = false
    }

    /// Creates one event-loop group owned by this long-lived transport scope.
    /// This is chiefly useful for an embedding application boundary and local
    /// tests. It must be paired with `shutdown()`.
    public init(owningEventLoopThreads: Int) {
        eventLoopGroup = MultiThreadedEventLoopGroup(
            numberOfThreads: max(1, owningEventLoopThreads)
        )
        ownsEventLoopGroup = true
    }

    /// Opens an HTTP/1.1 streaming response.
    ///
    /// This returns only after the status and headers arrive. Reading the body
    /// is pull-driven through `NIOAsyncChannel` high/low-watermark backpressure;
    /// cancellation or dropping the body closes the corresponding channel.
    public func openHTTPStream(
        _ request: RemoteHTTPStreamingRequest
    ) async throws -> RemoteHTTPStreamingResponse {
        do {
            if let timeout = request.timeout {
                return try await Self.withTimeout(timeout) { [self] in
                    try await openHTTPStreamWithoutTimeout(request)
                }
            }
            return try await openHTTPStreamWithoutTimeout(request)
        } catch {
            throw remoteTransportMappedError(error)
        }
    }

    /// Connects and upgrades an RFC 6455 WebSocket. The returned actor exposes
    /// text, binary, ping, pong and close frames directly.
    public func connectWebSocket(
        _ request: RemoteWebSocketRequest
    ) async throws -> RemoteWebSocketConnection {
        do {
            if let timeout = request.timeout {
                return try await Self.withTimeout(timeout) { [self] in
                    try await connectWebSocketWithoutTimeout(request)
                }
            }
            return try await connectWebSocketWithoutTimeout(request)
        } catch {
            throw remoteTransportMappedError(error)
        }
    }

    /// Closes active HTTP/WebSocket channels. For an explicitly-owned event-loop
    /// group this also shuts down its threads; for the default shared group only
    /// the transport's channels are closed. The operation is idempotent and
    /// concurrent callers await the same shutdown work.
    public func shutdown() async throws {
        try await lifecycle.shutdown(
            eventLoopGroup: ownsEventLoopGroup ? eventLoopGroup : nil
        )
    }

    private func openHTTPStreamWithoutTimeout(
        _ request: RemoteHTTPStreamingRequest
    ) async throws -> RemoteHTTPStreamingResponse {
        let endpoint = try RemoteTransportEndpoint(httpURL: request.url)
        let pendingConnection = RemotePendingConnection()

        return try await withTaskCancellationHandler {
            let asyncChannel = try await makeHTTPChannel(
                endpoint: endpoint,
                tls: request.tls,
                pendingConnection: pendingConnection
            )
            let channel = asyncChannel.channel

            do {
                try await lifecycle.register(channel)
                let lease = RemoteChannelLease(
                    channel: channel,
                    lifecycle: lifecycle
                )
                pendingConnection.attach(channel)

                do {
                    try await writeHTTP(
                        request,
                        endpoint: endpoint,
                        to: asyncChannel
                    )
                    let bodyStorage = RemoteHTTPBodyStorage(
                        inbound: asyncChannel.inbound,
                        lease: lease
                    )
                    let head = try await bodyStorage.receiveHead()
                    return RemoteHTTPStreamingResponse(
                        status: Int(head.status.code),
                        headers: RemoteHTTPHeaders(
                            head.headers.map {
                                RemoteHTTPHeader(name: $0.name, value: $0.value)
                            }
                        ),
                        body: RemoteHTTPBody(storage: bodyStorage)
                    )
                } catch {
                    lease.close()
                    throw error
                }
            } catch {
                channel.close(promise: nil)
                throw error
            }
        } onCancel: {
            pendingConnection.cancel()
        }
    }

    private func connectWebSocketWithoutTimeout(
        _ request: RemoteWebSocketRequest
    ) async throws -> RemoteWebSocketConnection {
        let endpoint = try RemoteTransportEndpoint(webSocketURL: request.url)
        guard request.maximumFrameSize > 0,
              request.maximumFrameSize <= Int(UInt32.max) else {
            throw RemoteTransportError.invalidWebSocketFrameSize(
                request.maximumFrameSize
            )
        }
        try Self.validateWebSocketHeaders(request.headers)

        let pendingConnection = RemotePendingConnection()
        let upgradeState = RemoteWebSocketUpgradeState()

        return try await withTaskCancellationHandler {
            let bootstrap = ClientBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    pendingConnection.attach(channel)
                    return channel.eventLoop.makeCompletedFuture {
                        if endpoint.isSecure {
                            try channel.pipeline.syncOperations.addHandler(
                                try Self.makeTLSHandler(
                                    serverHostname: request.tls.serverName
                                        ?? endpoint.host,
                                    tls: request.tls
                                )
                            )
                        }

                        let requestHandler =
                            RemoteWebSocketHandshakeRequestHandler(
                                requestHead: HTTPRequestHead(
                                    version: .http1_1,
                                    method: .GET,
                                    uri: endpoint.requestTarget,
                                    headers: try Self.makeHTTPHeaders(
                                        request.headers,
                                        hostHeader: endpoint.hostHeader
                                    )
                                ),
                                upgradeState: upgradeState
                            )
                        let upgrader = NIOWebSocketClientUpgrader(
                            maxFrameSize: request.maximumFrameSize,
                            upgradePipelineHandler: { channel, _ in
                                channel.pipeline.removeHandler(requestHandler)
                                    .flatMap { _ in
                                        do {
                                            let asyncChannel = try NIOAsyncChannel<
                                                WebSocketFrame,
                                                WebSocketFrame
                                            >(
                                                wrappingChannelSynchronously: channel,
                                                configuration: .init(
                                                    backPressureStrategy: .init(
                                                        lowWatermark: 1,
                                                        highWatermark: 4
                                                    )
                                                )
                                            )
                                            upgradeState.succeed(asyncChannel)
                                            return channel.eventLoop.makeSucceededFuture(())
                                        } catch {
                                            upgradeState.fail(error)
                                            return channel.eventLoop.makeFailedFuture(error)
                                        }
                                    }
                            }
                        )
                        let upgradeConfiguration:
                            NIOHTTPClientUpgradeSendableConfiguration = (
                                upgraders: [upgrader],
                                // This callback is invoked for a successful
                                // HTTP upgrade after its HTTP handlers are
                                // removed. `upgradePipelineHandler` resolves
                                // `upgradeState` once WebSocket framing is ready.
                                completionHandler: { _ in }
                            )
                        try channel.pipeline.syncOperations.addHTTPClientHandlers(
                            withClientUpgrade: upgradeConfiguration
                        )
                        try channel.pipeline.syncOperations.addHandler(
                            requestHandler
                        )
                    }
                }

            let channel = try await bootstrap.connect(
                host: endpoint.host,
                port: endpoint.port
            ).get()

            do {
                try await lifecycle.register(channel)
                let lease = RemoteChannelLease(
                    channel: channel,
                    lifecycle: lifecycle
                )
                pendingConnection.attach(channel)
                do {
                    let asyncChannel = try await upgradeState.wait()
                    return RemoteWebSocketConnection(
                        inbound: asyncChannel.inbound,
                        outbound: asyncChannel.outbound,
                        allocator: channel.allocator,
                        lease: lease
                    )
                } catch {
                    lease.close()
                    throw error
                }
            } catch {
                channel.close(promise: nil)
                throw error
            }
        } onCancel: {
            pendingConnection.cancel()
            upgradeState.fail(CancellationError())
        }
    }

    private func makeHTTPChannel(
        endpoint: RemoteTransportEndpoint,
        tls: RemoteTransportTLSConfiguration,
        pendingConnection: RemotePendingConnection
    ) async throws -> NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart> {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelInitializer { channel in
                pendingConnection.attach(channel)
                return channel.eventLoop.makeCompletedFuture {
                    if endpoint.isSecure {
                        try channel.pipeline.syncOperations.addHandler(
                            try Self.makeTLSHandler(
                                serverHostname: tls.serverName ?? endpoint.host,
                                tls: tls
                            )
                        )
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                }
            }

        let channel = try await bootstrap.connect(
            host: endpoint.host,
            port: endpoint.port
        ).get()
        pendingConnection.attach(channel)

        return try await channel.eventLoop.submit {
            try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(
                wrappingChannelSynchronously: channel,
                configuration: .init(
                    backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4)
                )
            )
        }.get()
    }

    private func writeHTTP(
        _ request: RemoteHTTPStreamingRequest,
        endpoint: RemoteTransportEndpoint,
        to channel: NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>
    ) async throws {
        let method = request.method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !method.isEmpty,
              !method.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw RemoteTransportError.invalidHTTPMethod(request.method)
        }

        var headers = try Self.makeHTTPHeaders(
            request.headers,
            hostHeader: endpoint.hostHeader
        )
        if let body = request.body,
           headers["content-length"].isEmpty {
            headers.add(name: "Content-Length", value: String(body.count))
        }
        // The first substrate intentionally does not pool HTTP/1.1 channels.
        // A future transport pool can retain this API without changing callers.
        if headers["connection"].isEmpty {
            headers.add(name: "Connection", value: "close")
        }

        let head = HTTPRequestHead(
            version: .http1_1,
            method: HTTPMethod(rawValue: method.uppercased()),
            uri: endpoint.requestTarget,
            headers: headers
        )
        try await channel.outbound.write(.head(head))
        if let body = request.body {
            var buffer = channel.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            try await channel.outbound.write(.body(.byteBuffer(buffer)))
        }
        try await channel.outbound.write(.end(nil))
    }

    private static func makeTLSHandler(
        serverHostname: String,
        tls: RemoteTransportTLSConfiguration
    ) throws -> NIOSSLClientHandler {
        var configuration = TLSConfiguration.makeClientConfiguration()
        // Make the secure default explicit: full certificate-chain and hostname
        // verification, platform trust roots, and the supplied hostname used for
        // both TLS SNI and certificate matching.
        configuration.certificateVerification = .fullVerification
        configuration.trustRoots = .default
        if !tls.additionalTrustRootPEMs.isEmpty {
            let certificates = try tls.additionalTrustRootPEMs.map {
                try NIOSSLCertificate(bytes: Array($0), format: .pem)
            }
            configuration.additionalTrustRoots = [.certificates(certificates)]
        }
        let context = try NIOSSLContext(configuration: configuration)
        return try NIOSSLClientHandler(
            context: context,
            serverHostname: serverHostname
        )
    }

    private static func makeHTTPHeaders(
        _ source: [RemoteHTTPHeader],
        hostHeader: String
    ) throws -> HTTPHeaders {
        var headers = HTTPHeaders()
        var hasHost = false
        for header in source {
            let name = header.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !name.isEmpty,
                  !name.contains(where: { $0 == "\r" || $0 == "\n" }),
                  !header.value.contains(where: { $0 == "\r" || $0 == "\n" })
            else {
                throw RemoteTransportError.invalidHeader(header.name)
            }
            if name.caseInsensitiveCompare("host") == .orderedSame {
                hasHost = true
            }
            headers.add(name: name, value: header.value)
        }
        if !hasHost {
            headers.add(name: "Host", value: hostHeader)
        }
        return headers
    }

    private static func validateWebSocketHeaders(
        _ headers: [RemoteHTTPHeader]
    ) throws {
        let reserved = Set([
            "connection",
            "upgrade",
            "sec-websocket-key",
            "sec-websocket-version"
        ])
        for header in headers {
            if reserved.contains(header.name.lowercased()) {
                throw RemoteTransportError.invalidHeader(header.name)
            }
        }
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard timeout > .zero else {
            throw RemoteTransportError.timeout
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RemoteTransportError.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw RemoteTransportError.timeout
            }
            return value
        }
    }
}

/// Convenient alternate spelling for consumers that want the implementation
/// choice to be visible at their composition root.
public typealias RemoteNIOTransport = RemoteTransportCore

private struct RemoteTransportEndpoint: Sendable {
    let host: String
    let port: Int
    let requestTarget: String
    let hostHeader: String
    let isSecure: Bool

    init(httpURL url: URL) throws {
        try self.init(
            url: url,
            secureSchemes: ["https"],
            cleartextSchemes: ["http"]
        )
    }

    init(webSocketURL url: URL) throws {
        try self.init(
            url: url,
            secureSchemes: ["wss"],
            cleartextSchemes: ["ws"]
        )
    }

    private init(
        url: URL,
        secureSchemes: Set<String>,
        cleartextSchemes: Set<String>
    ) throws {
        guard let scheme = url.scheme?.lowercased() else {
            throw RemoteTransportError.invalidURL(url.absoluteString)
        }
        guard secureSchemes.contains(scheme) || cleartextSchemes.contains(scheme)
        else {
            throw RemoteTransportError.unsupportedScheme(scheme)
        }
        guard let host = url.host?.nilIfBlank else {
            throw RemoteTransportError.invalidURL(url.absoluteString)
        }
        guard url.user == nil, url.password == nil else {
            throw RemoteTransportError.invalidURL(url.absoluteString)
        }

        let isSecure = secureSchemes.contains(scheme)
        let defaultPort = isSecure ? 443 : 80
        let port = url.port ?? defaultPort
        guard (1...65_535).contains(port) else {
            throw RemoteTransportError.invalidURL(url.absoluteString)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath.nilIfBlank ?? "/"
        let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
        self.host = host
        self.port = port
        requestTarget = path + query
        let printableHost = host.contains(":") ? "[\(host)]" : host
        hostHeader = port == defaultPort ? printableHost : "\(printableHost):\(port)"
        self.isSecure = isSecure
    }
}

actor RemoteTransportLifecycle {
    private enum State {
        case active
        case shuttingDown
        case shutDown
    }

    private var state: State = .active
    private var channels: [ObjectIdentifier: any Channel] = [:]
    private var shutdownTask: Task<Void, Error>?

    func register(_ channel: any Channel) throws {
        guard case .active = state else {
            channel.close(promise: nil)
            throw RemoteTransportError.shutdown
        }
        channels[ObjectIdentifier(channel)] = channel
    }

    func unregister(_ channel: any Channel) {
        channels.removeValue(forKey: ObjectIdentifier(channel))
    }

    func shutdown(eventLoopGroup: (any EventLoopGroup)?) async throws {
        if let shutdownTask {
            return try await shutdownTask.value
        }

        guard case .active = state else {
            if case .shutDown = state {
                return
            }
            return
        }
        state = .shuttingDown
        let channelsToClose = Array(channels.values)
        channels.removeAll()
        let task = Task<Void, Error> {
            for channel in channelsToClose {
                _ = try? await channel.close().get()
            }
            if let eventLoopGroup {
                try await eventLoopGroup.shutdownGracefully()
            }
        }
        shutdownTask = task
        do {
            try await task.value
            state = .shutDown
        } catch {
            state = .shutDown
            throw error
        }
    }
}

private final class RemotePendingConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: (any Channel)?
    private var cancelled = false

    func attach(_ channel: any Channel) {
        lock.lock()
        self.channel = channel
        let shouldClose = cancelled
        lock.unlock()
        if shouldClose {
            channel.close(promise: nil)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let channel = self.channel
        lock.unlock()
        channel?.close(promise: nil)
    }
}

/// Sends the caller-supplied WebSocket upgrade request once the TCP/TLS
/// channel becomes active. It is removed before the NIO async frame bridge is
/// installed, so it can never receive post-upgrade WebSocket bytes.
private final class RemoteWebSocketHandshakeRequestHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let requestHead: HTTPRequestHead
    private let upgradeState: RemoteWebSocketUpgradeState
    private var didWriteRequest = false

    init(
        requestHead: HTTPRequestHead,
        upgradeState: RemoteWebSocketUpgradeState
    ) {
        self.requestHead = requestHead
        self.upgradeState = upgradeState
    }

    func channelActive(context: ChannelHandlerContext) {
        guard !didWriteRequest else {
            context.fireChannelActive()
            return
        }
        didWriteRequest = true
        context.write(Self.wrapOutboundOut(.head(requestHead)), promise: nil)
        context.write(
            Self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer()))),
            promise: nil
        )
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // On a successful upgrade the NIO upgrade handler buffers the 101
        // response and removes this handler before WebSocket framing is
        // installed. Any HTTP part that reaches us therefore declined it.
        upgradeState.fail(RemoteTransportError.upgradeRejected)
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upgradeState.fail(remoteTransportMappedError(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        upgradeState.fail(RemoteTransportError.closed)
        context.fireChannelInactive()
    }
}

final class RemoteChannelLease: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false
    private let channel: any Channel
    private let lifecycle: RemoteTransportLifecycle

    fileprivate init(channel: any Channel, lifecycle: RemoteTransportLifecycle) {
        self.channel = channel
        self.lifecycle = lifecycle
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()

        channel.close(promise: nil)
        Task { [lifecycle, channel] in
            await lifecycle.unregister(channel)
        }
    }

    deinit {
        close()
    }
}

private final class RemoteWebSocketUpgradeState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<
        NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        Error
    >?
    private var continuation: CheckedContinuation<
        NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        Error
    >?

    func wait() async throws -> NIOAsyncChannel<WebSocketFrame, WebSocketFrame> {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func succeed(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        resolve(.success(channel))
    }

    func fail(_ error: Error) {
        resolve(.failure(error))
    }

    private func resolve(
        _ newResult: Result<NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Error>
    ) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: newResult)
    }
}

func remoteTransportMappedError(_ error: Error) -> Error {
    if error is CancellationError || Task.isCancelled {
        return CancellationError()
    }
    if let error = error as? RemoteTransportError {
        return error
    }
    let description = String(describing: error)
    let lowercased = description.lowercased()
    if lowercased.contains("tls") || lowercased.contains("ssl")
        || lowercased.contains("certificate") {
        return RemoteTransportError.tlsFailure(description)
    }
    return RemoteTransportError.connectionFailure(description)
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
