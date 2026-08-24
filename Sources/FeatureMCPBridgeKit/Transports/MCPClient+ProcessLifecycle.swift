//
//  MCPClient+ProcessLifecycle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#endif
import Foundation
import FeatureKit

#if os(macOS)
/// Termination of the local bridge generation: drain the pumped readers exactly
/// once, then clear writer/reader/handle state deterministically before the exit
/// is classified and pending requests are failed.
extension MCPClient {
    func handleProcessTermination(_ terminatedProcess: Process) {
        guard let activeConnectionID else {
            return
        }
        Task(name: "MCP local process termination forwarding") { [weak self] in
            await self?.handleProcessTermination(
                terminatedProcess,
                connectionID: activeConnectionID
            )
        }
    }

    func handleProcessTermination(
        _ terminatedProcess: Process,
        connectionID: UUID
    ) async {
        guard activeConnectionID == connectionID,
              process === terminatedProcess else {
            return
        }

        // A local bridge can write its final JSON-RPC response and exit in the
        // same scheduler turn. Drain both non-blocking pipe readers before
        // classifying the exit, otherwise the termination handler can resume a
        // still-pending request with `.serverExited` ahead of that final reply.
        terminatingConnectionID = connectionID
        let readTask = readLoopTask
        let errorTask = errorLoopTask
        let diagnosticMonitor = stopDiagnosticMonitor()
        await readTask?.value
        await errorTask?.value
        await diagnosticMonitor.task?.value
        diagnosticMonitor.outputHandle?.closeFile()

        // Explicit disconnect can run while awaiting the detached readers.
        // Its cleanup owns the state in that case.
        guard activeConnectionID == connectionID,
              process === terminatedProcess else {
            return
        }

        let detectedError = terminalBridgeError ?? exitError(for: terminatedProcess)
        terminalBridgeError = detectedError
        let currentInputHandle = inputHandle
        let currentOutputHandle = outputHandle
        let currentErrorHandle = errorHandle
        // This path owns the writer exactly like disconnect() does. Detach it
        // from the actor BEFORE anything else can observe the torn-down state, so
        // a later connect() can never inherit this generation's writer and a
        // concurrent disconnect() cannot tear it down a second time.
        let currentWriter = writer
        writer = nil
        activeConnectionID = nil
        terminatingConnectionID = nil
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        readLoopTask = nil
        errorLoopTask = nil
        terminatedProcess.terminationHandler = nil
        // Stop accepting jobs, cancel the consumer, then tear it down under a
        // DEADLINE before closing stdin. The bridge process is already gone, but
        // a descendant may have inherited the read end and may never drain it, so
        // an in-flight frame can stay on `EAGAIN` indefinitely; an unbounded join
        // here would make a spontaneous exit hang teardown forever.
        // `shutdown()` guarantees on return that the descriptor is detached and
        // that no job continuation is left suspended, which is exactly what
        // closing (and thereby freeing for reuse) the FD requires.
        await currentWriter?.shutdown()
        currentInputHandle?.closeFile()
        currentOutputHandle?.closeFile()
        currentErrorHandle?.closeFile()
        importantLog("MCP bridge terminated with error: \(detectedError.localizedDescription)")
        log("process terminated with error: \(detectedError.localizedDescription)")
        resumeAllPending(with: detectedError)
    }
}
#endif
