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

/// One non-blocking byte pump shared by local MCP stdout, stderr, and diagnostic
/// streams. The return value deliberately keeps EOF, cancellation, policy stop,
/// and read failure separate so each adapter can preserve its prior semantics.
enum MCPStreamPump {
    /// Once an owner asks a reader to stop, consume the bytes which were already
    /// accepted by the kernel before reporting `.stopped`.  This is deliberately
    /// bounded: a descendant can retain a pipe and continuously write after the
    /// bridge itself has exited, and teardown must not wait for that peer.
    private static let finalDrainByteLimit = 65_536

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
