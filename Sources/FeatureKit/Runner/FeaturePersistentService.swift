//
//  FeaturePersistentService.swift
//  ZenCODE
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Server-side implementation of the private JSON-lines protocol used by
/// opt-in session-scoped feature processes.
///
/// This is deliberately separate from `--list-tools` and `--invoke`: those
/// commands remain one-shot and keep their existing wire formats for manual
/// callers and every feature that does not opt in to persistence.
public enum FeaturePersistentService {
    private static let maximumRequestFrameBytes = 16 * 1024 * 1024

    /// Serves requests serially from standard input until EOF or a shutdown
    /// frame. Serial execution protects stateful feature integrations (notably
    /// MCP clients) and ensures one response frame corresponds to one request.
    public static func run(
        handler: @escaping (FeaturePersistentRequest) async throws -> Data,
        shutdown: @escaping () async -> Void = {}
    ) async {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        setNonBlocking(FileHandle.standardInput.fileDescriptor)

        var lineBuffer = Data()
        var scratch = [UInt8](repeating: 0, count: 16_384)
        let inputDescriptor = FileHandle.standardInput.fileDescriptor

        while !Task.isCancelled {
            let bytesRead = scratch.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return 0
                }
                return read(inputDescriptor, baseAddress, rawBuffer.count)
            }

            if bytesRead > 0 {
                lineBuffer.append(contentsOf: scratch[0 ..< bytesRead])
                guard lineBuffer.count <= maximumRequestFrameBytes else {
                    await shutdown()
                    return
                }

                while let newline = lineBuffer.firstIndex(of: 0x0A) {
                    let frame = lineBuffer.subdata(in: lineBuffer.startIndex ..< newline)
                    lineBuffer.removeSubrange(lineBuffer.startIndex ... newline)
                    guard !frame.isEmpty else {
                        continue
                    }
                    await handle(frame: frame, handler: handler, shutdown: shutdown)
                    // A shutdown request is acknowledged by `handle`, then the
                    // protocol has no more useful work to do on this connection.
                    if let request = try? JSONDecoder().decode(
                        FeaturePersistentRequest.self,
                        from: frame
                    ), request.operation == .shutdown {
                        return
                    }
                }
                continue
            }

            if bytesRead == 0 {
                await shutdown()
                return
            }

            let capturedErrno = errno
            if capturedErrno == EINTR {
                continue
            }
            if capturedErrno == EAGAIN || capturedErrno == EWOULDBLOCK {
                do {
                    // This loop can remain idle for an entire agent session, so
                    // keep polling responsive without waking hundreds of times
                    // per second when no request is pending.
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    await shutdown()
                    return
                }
                continue
            }

            await shutdown()
            return
        }

        await shutdown()
        #else
        _ = handler
        await shutdown()
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private static func handle(
        frame: Data,
        handler: @escaping (FeaturePersistentRequest) async throws -> Data,
        shutdown: @escaping () async -> Void
    ) async {
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(FeaturePersistentRequest.self, from: frame) else {
            return
        }

        if request.operation == .shutdown {
            // Complete feature-owned cleanup (for example, disconnecting an MCP
            // bridge) before acknowledging shutdown. Once the parent receives
            // the acknowledgement it may terminate this process immediately.
            await shutdown()
            try? FeatureProcessProtocol.emitJSON(
                FeaturePersistentResponse(id: request.id, responseData: Data())
            )
            return
        }

        do {
            let responseData = try await handler(request)
            try FeatureProcessProtocol.emitJSON(
                FeaturePersistentResponse(id: request.id, responseData: responseData)
            )
        } catch {
            try? FeatureProcessProtocol.emitJSON(
                FeaturePersistentResponse(
                    id: request.id,
                    responseData: nil,
                    error: error.localizedDescription
                )
            )
        }
    }

    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            return
        }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }
    #endif
}
