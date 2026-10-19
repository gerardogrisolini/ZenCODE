import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket
import Synchronization

struct RemoteTransportEndpoint: Sendable {
    let host: String
    let port: Int
    let requestTarget: String
    let hostHeader: String
    let isSecure: Bool

    init(httpURL url: URL) throws {
        try self.init(url: url, secureSchemes: ["https"], cleartextSchemes: ["http"])
    }

    init(webSocketURL url: URL) throws {
        try self.init(url: url, secureSchemes: ["wss"], cleartextSchemes: ["ws"])
    }

    private init(url: URL, secureSchemes: Set<String>, cleartextSchemes: Set<String>) throws {
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
        let task = Task<Void, Error>(name: "Remote transport shutdown") {
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

final class RemotePendingConnection: Sendable {
    private struct State {
        var channel: (any Channel)?
        var cancelled = false
    }

    private let state = Mutex(State())

    func attach(_ channel: any Channel) {
        let shouldClose = state.withLock { state in
            state.channel = channel
            return state.cancelled
        }
        if shouldClose {
            channel.close(promise: nil)
        }
    }

    func cancel() {
        let channel = state.withLock { state in
            state.cancelled = true
            return state.channel
        }
        channel?.close(promise: nil)
    }
}

/// Sends the caller-supplied WebSocket upgrade request once the TCP/TLS
/// channel becomes active. It is removed before the NIO async frame bridge is
/// installed, so it can never receive post-upgrade WebSocket bytes.
final class RemoteWebSocketHandshakeRequestHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let requestHead: HTTPRequestHead
    private let upgradeState: RemoteWebSocketUpgradeState
    private var didWriteRequest = false
    /// Status code captured from the rejection response head, if any.
    private var rejectionStatus: Int?
    /// Accumulated rejection body for diagnostics (bounded).
    private var rejectionBody = ""
    /// Guards against unbounded body accumulation.
    private static let maxRejectionBodyBytes = 512

    init(requestHead: HTTPRequestHead, upgradeState: RemoteWebSocketUpgradeState) {
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
        context.write(Self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer()))), promise: nil)
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // On a successful upgrade the NIO upgrade handler buffers the 101
        // response and removes this handler before WebSocket framing is
        // installed. Any HTTP part that reaches us therefore declined it.
        // Capture the status code and a bounded excerpt of the response body
        // so the caller can distinguish a 401 (expired token), 403 (forbidden),
        // or 429 (rate limited) from a genuine protocol error.
        let part = Self.unwrapInboundIn(data)
        switch part {
        case .head(let head):
            rejectionStatus = Int(head.status.code)
        case .body(let byteBuffer):
            if rejectionBody.utf8.count < Self.maxRejectionBodyBytes {
                rejectionBody += String(buffer: byteBuffer)
            }
        case .end:
            failUpgradeRejected()
        @unknown default:
            upgradeState.fail(
                RemoteTransportError.protocolViolation("Unsupported HTTP response part during WebSocket upgrade")
            )
        }
        context.fireChannelRead(data)
    }

    private func failUpgradeRejected() {
        upgradeState.fail(RemoteTransportError.upgradeRejected(status: rejectionStatus ?? 0, body: rejectionBody))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upgradeState.fail(remoteTransportMappedError(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // If we already saw a rejection head but the connection closed before
        // .end, surface the diagnostic status instead of a bare .closed.
        if rejectionStatus != nil {
            failUpgradeRejected()
        } else {
            upgradeState.fail(RemoteTransportError.closed)
        }
        context.fireChannelInactive()
    }
}

final class RemoteChannelLease: Sendable {
    private struct State {
        var isClosed = false
        let channel: any Channel
    }

    private let state: Mutex<State>
    private let lifecycle: RemoteTransportLifecycle

    init(channel: any Channel, lifecycle: RemoteTransportLifecycle) {
        state = Mutex(State(channel: channel))
        self.lifecycle = lifecycle
    }

    func close() {
        let channel = state.withLock { state -> (any Channel)? in
            guard !state.isClosed else {
                return nil
            }
            state.isClosed = true
            return state.channel
        }
        guard let channel else {
            return
        }

        channel.close(promise: nil)
        Task(name: "Remote channel lease cleanup") { [lifecycle, channel] in
            await lifecycle.unregister(channel)
        }
    }

    deinit {
        close()
    }
}

final class RemoteWebSocketUpgradeState: Sendable {
    private struct State {
        var result: Result<NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Error>?
        var continuation: CheckedContinuation<
            NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
            Error
        >?
    }

    private let state = Mutex(State())

    func wait() async throws -> NIOAsyncChannel<WebSocketFrame, WebSocketFrame> {
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLock { state -> Result<
                NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Error
            >? in
                if let result = state.result {
                    return result
                }
                state.continuation = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func succeed(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        resolve(.success(channel))
    }

    func fail(_ error: Error) {
        resolve(.failure(error))
    }

    private func resolve(_ newResult: Result<NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<
            NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Error
        >? in
            guard state.result == nil else {
                return nil
            }
            state.result = newResult
            defer { state.continuation = nil }
            return state.continuation
        }
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
