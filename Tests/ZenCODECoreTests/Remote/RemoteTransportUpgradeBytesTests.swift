import Foundation
import Crypto
import NIOCore
import NIOPosix
import Testing
@testable import ZenCODECore

@Suite("WebSocket coalesced upgrade")
struct RemoteTransportUpgradeBytesTests {
    @Test("101 and first WebSocket frame in one TCP write are preserved")
    func preservesCoalescedFrame() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server: any Channel
        do {
            server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in channel.pipeline.addHandler(CoalescedUpgradeHandler()) }
                .bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        do {
            let port = try #require(server.localAddress?.port)
            let socket = try await transport.connectWebSocket(.init(url: URL(string: "ws://127.0.0.1:\(port)/")!, timeout: .seconds(2)))
            let frame = try await withThrowingTaskGroup(of: RemoteWebSocketFrame?.self) { tasks in
                tasks.addTask { try await socket.receive() }
                tasks.addTask { try await Task.sleep(for: .seconds(2)); throw RemoteTransportError.timeout }
                defer { tasks.cancelAll() }
                return try await tasks.next() ?? nil
            }
            #expect(frame == .text("ready", final: true))
            try await socket.close()
        } catch {
            try? await transport.shutdown()
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
        try await transport.shutdown()
        try await server.close().get()
        try await group.shutdownGracefully()
    }
}
// Mutable state is confined to the child channel's event loop; never accessed by the test task.
private final class CoalescedUpgradeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var request = ""
    private var sent = false
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !sent else { return }
        var buffer = unwrapInboundIn(data)
        request += buffer.readString(length: buffer.readableBytes) ?? ""
        guard request.utf8.count < 16384 else { context.close(promise: nil); return }
        guard request.contains("\r\n\r\n"), let key = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") })?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) else { return }
        sent = true
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        var output = context.channel.allocator.buffer(capacity: 256)
        output.writeString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n")
        output.writeBytes([0x81, 0x05]); output.writeString("ready")
        context.writeAndFlush(wrapOutboundOut(output), promise: nil)
    }
}
