import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import Synchronization

/// Shared cross-platform SwiftNIO transport for remote generation clients.
///
/// The default initializer borrows `NIOSingletons.posixEventLoopGroup`, whose
/// lifetime is the process and therefore is intentionally never shut down by
/// this type. `init(owningEventLoopThreads:)` is for an explicitly-owned
/// application scope or deterministic tests; call `shutdown()` exactly once at
/// the end of that scope. Neither initializer creates an event-loop group per
/// HTTP request or WebSocket connection.
public final class RemoteTransportCore: Sendable {
    public static let defaultMaximumCollectedResponseBodyBytes = 16 * 1_024 * 1_024
    private let eventLoopGroup: any EventLoopGroup
    private let ownsEventLoopGroup: Bool
    private let maximumCollectedResponseBodyBytes: Int
    private let lifecycle = RemoteTransportLifecycle()

    /// Uses the process-wide POSIX event-loop group shared by all transport
    /// instances in the process.
    public init(maximumCollectedResponseBodyBytes: Int = RemoteTransportCore.defaultMaximumCollectedResponseBodyBytes) {
        eventLoopGroup = NIOSingletons.posixEventLoopGroup
        ownsEventLoopGroup = false
        self.maximumCollectedResponseBodyBytes = max(1, maximumCollectedResponseBodyBytes)
    }

    /// Creates one event-loop group owned by this long-lived transport scope.
    /// This is chiefly useful for an embedding application boundary and local
    /// tests. It must be paired with `shutdown()`.
    public init(
        owningEventLoopThreads: Int,
        maximumCollectedResponseBodyBytes: Int = RemoteTransportCore.defaultMaximumCollectedResponseBodyBytes
    ) {
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: max(1, owningEventLoopThreads))
        ownsEventLoopGroup = true
        self.maximumCollectedResponseBodyBytes = max(1, maximumCollectedResponseBodyBytes)
    }

    /// Opens an HTTP/1.1 streaming response.
    ///
    /// This returns only after the status and headers arrive. Reading the body
    /// is pull-driven through `NIOAsyncChannel` high/low-watermark backpressure;
    /// cancellation or dropping the body closes the corresponding channel.
    public func openHTTPStream(
        _ request: RemoteHTTPStreamingRequest
    ) async throws -> RemoteHTTPStreamingResponse {
        try await performRequest(timeout: request.timeout) { [self] in
            try await openHTTPStreamWithoutTimeout(request)
        }
    }

    /// Connects and upgrades an RFC 6455 WebSocket. The returned actor exposes
    /// text, binary, ping, pong and close frames directly.
    public func connectWebSocket(
        _ request: RemoteWebSocketRequest
    ) async throws -> RemoteWebSocketConnection {
        try await performRequest(timeout: request.timeout) { [self] in
            try await connectWebSocketWithoutTimeout(request)
        }
    }

    /// Closes active HTTP/WebSocket channels. For an explicitly-owned event-loop
    /// group this also shuts down its threads; for the default shared group only
    /// the transport's channels are closed. The operation is idempotent and
    /// concurrent callers await the same shutdown work.
    public func shutdown() async throws {
        try await lifecycle.shutdown(eventLoopGroup: ownsEventLoopGroup ? eventLoopGroup : nil)
    }

    /// Single request/response helper: opens an HTTP stream and collects the
    /// entire response body before returning. Intended for non-streaming JSON
    /// exchanges such as OAuth token endpoints.
    public func sendRequest(
        _ request: RemoteHTTPStreamingRequest
    ) async throws -> (status: Int, headers: RemoteHTTPHeaders, body: Data) {
        try await performRequest(timeout: request.timeout) { [self] in
            try await sendRequestWithoutTimeout(request)
        }
    }

    private func performRequest<Value: Sendable>(
        timeout: Duration?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            if let timeout {
                return try await Self.withTimeout(timeout, operation: operation)
            }
            return try await operation()
        } catch {
            throw remoteTransportMappedError(error)
        }
    }

    /// Non-streaming HTTP requests own the deadline until their complete body
    /// has been consumed. This deliberately does not use `openHTTPStream`,
    /// whose timeout covers only opening a pull-driven streaming response.
    private func sendRequestWithoutTimeout(
        _ initialRequest: RemoteHTTPStreamingRequest
    ) async throws -> (status: Int, headers: RemoteHTTPHeaders, body: Data) {
        var request = initialRequest
        var redirectCount = 0

        while true {
            let response = try await openHTTPStreamWithoutTimeout(request)
            var body = Data()
            for try await chunk in response.body {
                guard chunk.count <= maximumCollectedResponseBodyBytes - body.count else {
                    throw RemoteTransportError.protocolViolation(
                        "HTTP response body exceeds the \(maximumCollectedResponseBodyBytes)-byte limit."
                    )
                }
                body.append(chunk)
            }

            guard Self.isRedirect(response.status) else {
                return (response.status, response.headers, body)
            }
            guard redirectCount < Self.maximumHTTPRedirects,
                  let location = response.headers.firstValue(for: "location"),
                  let url = URL(string: location, relativeTo: request.url)?
                    .absoluteURL else {
                throw RemoteTransportError.protocolViolation("Invalid or excessive HTTP redirect.")
            }

            redirectCount += 1
            request = try Self.redirectRequest(request, to: url, status: response.status)
        }
    }

    private static let maximumHTTPRedirects = 5

    private static func isRedirect(_ status: Int) -> Bool {
        switch status {
        case 301, 302, 303, 307, 308:
            true
        default:
            false
        }
    }

    static func redirectRequest(
        _ request: RemoteHTTPStreamingRequest,
        to url: URL,
        status: Int
    ) throws -> RemoteHTTPStreamingRequest {
        let changesOrigin = !sameOrigin(request.url, url)
        if isHTTPSDowngrade(from: request.url, to: url) {
            throw RemoteTransportError.protocolViolation("Refusing an HTTPS to HTTP redirect.")
        }
        if changesOrigin, request.body != nil {
            throw RemoteTransportError.protocolViolation("Refusing to resend an HTTP request body across origins.")
        }
        let rewritesToGET = status == 303 ||
            ((status == 301 || status == 302) &&
                !["GET", "HEAD"].contains(request.method.uppercased()))
        let headers = request.headers.filter { header in
            let name = header.name.lowercased()
            if name == "host" {
                return false
            }
            if changesOrigin && ["authorization", "cookie", "proxy-authorization", "x-api-key"].contains(name) {
                return false
            }
            if rewritesToGET && ["content-length", "content-type", "transfer-encoding"].contains(name) {
                return false
            }
            return true
        }
        return RemoteHTTPStreamingRequest(
            url: url,
            method: rewritesToGET ? "GET" : request.method,
            headers: headers,
            body: rewritesToGET ? nil : request.body,
            timeout: nil,
            tls: request.tls
        )
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsEndpoint = try? RemoteTransportEndpoint(httpURL: lhs),
              let rhsEndpoint = try? RemoteTransportEndpoint(httpURL: rhs) else {
            return false
        }
        return lhsEndpoint.isSecure == rhsEndpoint.isSecure &&
            lhsEndpoint.host.caseInsensitiveCompare(rhsEndpoint.host) == .orderedSame &&
            lhsEndpoint.port == rhsEndpoint.port
    }

    private static func isHTTPSDowngrade(from source: URL, to destination: URL) -> Bool {
        source.scheme?.lowercased() == "https" && destination.scheme?.lowercased() == "http"
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
                let lease = RemoteChannelLease(channel: channel, lifecycle: lifecycle)
                pendingConnection.attach(channel)

                do {
                    let bodyStorage = RemoteHTTPBodyStorage(lease: lease)
                    let lifetime = RemoteTransportLifetimeToken(lease: lease)
                    // The run-task captures the driver strongly (it must drive
                    // NIO for the channel's whole life) and the token weakly, so
                    // the token can be released by the public handle without the
                    // task forming a retain cycle back to it. The token cancels
                    // this task and abandons the driver when the last handle is
                    // released, which is what unblocks `nextRequest()`.
                    let runTask = Task<Void, Never>(name: "Remote transport background task") { [weak lifetime] in
                        do {
                            try await asyncChannel.executeThenClose(isolation: bodyStorage) { inbound, outbound in
                                try await self.writeHTTP(
                                    request,
                                    endpoint: endpoint,
                                    outbound: outbound,
                                    allocator: channel.allocator
                                )
                                try await bodyStorage.run(inbound: inbound)
                            }
                        } catch {
                            await bodyStorage.fail(error)
                        }
                        lifetime?.runDidFinish()
                    }
                    lifetime.install(runTask: runTask) { [weak bodyStorage] in
                        await bodyStorage?.abandon()
                    }
                    do {
                        let head = try await bodyStorage.receiveHead()
                        return RemoteHTTPStreamingResponse(
                            status: head.status,
                            headers: RemoteHTTPHeaders(head.headers),
                            body: RemoteHTTPBody(storage: bodyStorage, lifetime: lifetime)
                        )
                    } catch {
                        lifetime.invalidate()
                        lease.close()
                        throw error
                    }
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
            throw RemoteTransportError.invalidWebSocketFrameSize(request.maximumFrameSize)
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
                                    headers: try Self.makeHTTPHeaders(request.headers, hostHeader: endpoint.hostHeader)
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
                                                    backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4)
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
                            leftOverBytesStrategy: .forwardBytes,
                            withClientUpgrade: upgradeConfiguration
                        )
                        try channel.pipeline.syncOperations.addHandler(requestHandler)
                    }
                }

            let channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()

            do {
                try await lifecycle.register(channel)
                let lease = RemoteChannelLease(channel: channel, lifecycle: lifecycle)
                pendingConnection.attach(channel)
                do {
                    let asyncChannel = try await upgradeState.wait()
                    let driver = RemoteWebSocketDriver(allocator: channel.allocator, lease: lease)
                    let lifetime = RemoteTransportLifetimeToken(lease: lease)
                    let runTask = Task<Void, Never>(name: "Remote transport background task") { [weak lifetime] in
                        do {
                            try await asyncChannel.executeThenClose(isolation: driver) { inbound, outbound in
                                try await driver.run(inbound: inbound, outbound: outbound)
                            }
                        } catch {
                            await driver.fail(error)
                        }
                        lifetime?.runDidFinish()
                    }
                    lifetime.install(runTask: runTask) { [weak driver] in
                        await driver?.abandon()
                    }
                    return RemoteWebSocketConnection(driver: driver, lifetime: lifetime)
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
                            try Self.makeTLSHandler(serverHostname: tls.serverName ?? endpoint.host, tls: tls)
                        )
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                }
            }

        let channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        pendingConnection.attach(channel)

        return try await channel.eventLoop.submit {
            try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(
                wrappingChannelSynchronously: channel,
                configuration: .init(backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4))
            )
        }.get()
    }

    private func writeHTTP(
        _ request: RemoteHTTPStreamingRequest,
        endpoint: RemoteTransportEndpoint,
        outbound: NIOAsyncChannelOutboundWriter<HTTPClientRequestPart>,
        allocator: ByteBufferAllocator
    ) async throws {
        let method = request.method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !method.isEmpty,
              !method.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw RemoteTransportError.invalidHTTPMethod(request.method)
        }

        var headers = try Self.makeHTTPHeaders(request.headers, hostHeader: endpoint.hostHeader)
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
        try await outbound.write(.head(head))
        if let body = request.body {
            var buffer = allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            try await outbound.write(.body(.byteBuffer(buffer)))
        }
        try await outbound.write(.end(nil))
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
        return try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
    }

    private static func makeHTTPHeaders(
        _ source: [RemoteHTTPHeader],
        hostHeader: String
    ) throws -> HTTPHeaders {
        var headers = HTTPHeaders()
        var hasHost = false
        for header in source {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func validateWebSocketHeaders(_ headers: [RemoteHTTPHeader]) throws {
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
            group.addTask(name: "Remote transport operation") {
                try await operation()
            }
            group.addTask(name: "Remote transport timeout") {
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
