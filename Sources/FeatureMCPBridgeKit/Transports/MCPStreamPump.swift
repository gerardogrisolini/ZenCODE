#if canImport(Darwin)
import Darwin
#endif
import Foundation

#if os(macOS)
enum MCPStreamPumpTermination: Equatable, Sendable {
    case endOfFile
    case cancelled
    case stopped
    case failure(POSIXErrorCode)
}

/// Typed per-stream policy for one pumped descriptor. Every local MCP stream
/// (stdout, stderr, diagnostic monitor) expresses its differences through these
/// handlers instead of writing its own read loop, so cancellation, EOF, policy
/// stop, and read-failure semantics stay defined in exactly one place.
struct MCPStreamPumpHandlers: Sendable {
    let onChunk: @Sendable (Data) async -> Void
    let shouldStop: @Sendable () async -> Bool
    let onEndOfFile: @Sendable () async -> Void
    let onReadFailure: @Sendable (POSIXError) async -> Void

    init(
        onChunk: @escaping @Sendable (Data) async -> Void,
        shouldStop: @escaping @Sendable () async -> Bool = { false },
        onEndOfFile: @escaping @Sendable () async -> Void = {},
        onReadFailure: @escaping @Sendable (POSIXError) async -> Void = { _ in }
    ) {
        self.onChunk = onChunk
        self.shouldStop = shouldStop
        self.onEndOfFile = onEndOfFile
        self.onReadFailure = onReadFailure
    }
}

/// One non-blocking byte pump shared by local MCP stdout, stderr, and diagnostic
/// streams. The return value deliberately keeps EOF, cancellation, policy stop,
/// and read failure separate so each adapter can preserve its prior semantics.
enum MCPStreamPump {
    /// Once an owner asks a reader to stop, consume the bytes which were already
    /// accepted by the kernel before reporting `.stopped`.  This is deliberately
    /// bounded: a descendant can retain a pipe and continuously write after the
    /// bridge itself has exited, and teardown must not wait for that peer.
    private static let finalDrainByteLimit = 65_536

    /// The single entry point used by every local MCP reader: it runs the
    /// bounded loop and routes its termination onto the stream's typed handlers.
    /// Cancellation and policy stop stay silent by contract — teardown owns those
    /// paths — while EOF and read failure are reported exactly once.
    @discardableResult
    static func drain(
        fileDescriptor: Int32,
        handlers: MCPStreamPumpHandlers
    ) async -> MCPStreamPumpTermination {
        let termination = await run(
            fileDescriptor: fileDescriptor,
            onChunk: handlers.onChunk,
            shouldStop: handlers.shouldStop
        )

        switch termination {
        case .endOfFile:
            await handlers.onEndOfFile()
        case let .failure(code):
            await handlers.onReadFailure(POSIXError(code))
        case .cancelled, .stopped:
            break
        }

        return termination
    }

    static func run(
        fileDescriptor: Int32,
        onChunk: @escaping @Sendable (Data) async -> Void,
        shouldStop: @escaping @Sendable () async -> Bool
    ) async -> MCPStreamPumpTermination {
        var rawBuffer = [UInt8](repeating: 0, count: 4096)
        var isDrainingAfterStop = false
        var drainedByteCount = 0

        while true {
            if Task.isCancelled { return .cancelled }
            if !isDrainingAfterStop, await shouldStop() {
                // Do not report a lifecycle stop ahead of a final JSON-RPC reply
                // or diagnostic which the exiting process already wrote.  A
                // non-blocking drain preserves ordering without turning teardown
                // into an unbounded wait for descendants holding the pipe open.
                isDrainingAfterStop = true
            }

            let bytesRead = Darwin.read(fileDescriptor, &rawBuffer, rawBuffer.count)
            if bytesRead > 0 {
                await onChunk(Data(rawBuffer.prefix(bytesRead)))
                if isDrainingAfterStop {
                    drainedByteCount += bytesRead
                    if drainedByteCount >= finalDrainByteLimit {
                        return .stopped
                    }
                }
                continue
            }
            if bytesRead == 0 { return .endOfFile }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if isDrainingAfterStop { return .stopped }
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)
                } catch {
                    return .cancelled
                }
                continue
            }
            return .failure(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
#endif
