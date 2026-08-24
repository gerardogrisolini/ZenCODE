//
//  MCPClient+StreamReaders.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#endif
import Foundation
import Synchronization

#if os(macOS)
/// Detached readers for the local bridge's streams. Every reader is a thin
/// binding of one descriptor to `MCPStreamPump` handlers: the bounded loop,
/// cancellation, EOF, policy stop, and read-failure contract live in the pump,
/// while this file only expresses per-stream routing.
extension MCPClient {
    nonisolated static func readLoop(
        from handle: FileHandle,
        client: MCPClient,
        connectionID: UUID
    ) async {
        await MCPStreamPump.drain(
            fileDescriptor: handle.fileDescriptor,
            handlers: stdoutHandlers(client: client, connectionID: connectionID)
        )
    }

    nonisolated static func errorLoop(
        from handle: FileHandle,
        client: MCPClient,
        connectionID: UUID
    ) async {
        await MCPStreamPump.drain(
            fileDescriptor: handle.fileDescriptor,
            handlers: stderrHandlers(client: client, connectionID: connectionID)
        )
    }

    nonisolated static func diagnosticMonitorLoop(
        from handle: FileHandle,
        client: MCPClient,
        connectionID: UUID
    ) async {
        await MCPStreamPump.drain(
            fileDescriptor: handle.fileDescriptor,
            handlers: diagnosticHandlers(client: client, connectionID: connectionID)
        )
    }

    // MARK: - Typed per-stream handlers

    private nonisolated static func stdoutHandlers(
        client: MCPClient,
        connectionID: UUID
    ) -> MCPStreamPumpHandlers {
        MCPStreamPumpHandlers(
            onChunk: { chunk in
                await client.handleStdoutChunk(chunk, connectionID: connectionID)
            },
            shouldStop: {
                await client.shouldStopReaderAfterProcessTermination(connectionID: connectionID)
            },
            onEndOfFile: {
                await client.handleStdoutClosed(connectionID: connectionID)
            },
            onReadFailure: { error in
                await client.handleStdoutReadFailure(error, connectionID: connectionID)
            }
        )
    }

    private nonisolated static func stderrHandlers(
        client: MCPClient,
        connectionID: UUID
    ) -> MCPStreamPumpHandlers {
        // stderr EOF is intentionally silent: stdout closure and process
        // termination own connection classification.
        MCPStreamPumpHandlers(
            onChunk: { chunk in
                await client.handleStderrChunk(chunk, connectionID: connectionID)
            },
            shouldStop: {
                await client.shouldStopReaderAfterProcessTermination(connectionID: connectionID)
            },
            onReadFailure: { error in
                await client.handleStderrReadFailure(error, connectionID: connectionID)
            }
        )
    }

    private nonisolated static func diagnosticHandlers(
        client: MCPClient,
        connectionID: UUID
    ) -> MCPStreamPumpHandlers {
        let accumulator = MCPStreamLineAccumulator(byteLimit: maxDiagnosticBytes)
        return MCPStreamPumpHandlers(
            onChunk: { chunk in
                for line in accumulator.lines(appending: chunk) {
                    await client.handleDiagnosticLine(line, connectionID: connectionID)
                    // Stop forwarding as soon as this generation's monitor is
                    // retired; the pump observes the same predicate next poll.
                    if await client.shouldStopDiagnosticMonitor(connectionID: connectionID) {
                        return
                    }
                }
            },
            shouldStop: {
                await client.shouldStopDiagnosticMonitor(connectionID: connectionID)
            },
            onReadFailure: { error in
                await client.handleDiagnosticReadFailure(error, connectionID: connectionID)
            }
        )
    }
}
#endif
