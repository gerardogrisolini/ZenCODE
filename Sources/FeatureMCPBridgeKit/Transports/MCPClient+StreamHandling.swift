//
//  MCPClient+StreamHandling.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#endif
import Foundation
import FeatureKit
import Synchronization
import ToolCore

#if os(macOS)
extension MCPClient {
    private static let maxDiagnosticBytes = 65_536

    nonisolated static func readLoop(from handle: FileHandle, client: MCPClient) async {
        await runReadLoop(from: handle, client: client, connectionID: nil)
    }

    nonisolated static func readLoop(
        from handle: FileHandle,
        client: MCPClient,
        connectionID: UUID
    ) async {
        await runReadLoop(from: handle, client: client, connectionID: connectionID)
    }

    private nonisolated static func runReadLoop(
        from handle: FileHandle,
        client: MCPClient,
        connectionID: UUID?
    ) async {
        let termination = await MCPStreamPump.run(
            fileDescriptor: handle.fileDescriptor,
            onChunk: { chunk in
                if let connectionID {
                    await client.handleStdoutChunk(chunk, connectionID: connectionID)
                } else {
                    await client.handleStdoutChunk(chunk)
                }
            },
            shouldStop: {
                guard let connectionID else { return false }
                return await client.shouldStopReaderAfterProcessTermination(connectionID: connectionID)
            }
        )
        switch termination {
        case .endOfFile:
            if let connectionID {
                await client.handleStdoutClosed(connectionID: connectionID)
            } else {
                await client.handleStdoutClosed()
            }
        case let .failure(code):
            let error = POSIXError(code)
            if let connectionID {
                await client.handleStdoutReadFailure(error, connectionID: connectionID)
            } else {
                await client.handleStdoutReadFailure(error)
            }
        case .cancelled, .stopped:
            return
        }
    }

    nonisolated static func errorLoop(from handle: FileHandle, client: MCPClient) async {
        await runErrorLoop(from: handle, client: client, connectionID: nil)
    }

    nonisolated static func errorLoop(
        from handle: FileHandle,
        client: MCPClient,
        connectionID: UUID
    ) async {
        await runErrorLoop(from: handle, client: client, connectionID: connectionID)
    }

    private nonisolated static func runErrorLoop(
        from handle: FileHandle,
        client: MCPClient,
        connectionID: UUID?
    ) async {
        let termination = await MCPStreamPump.run(
            fileDescriptor: handle.fileDescriptor,
            onChunk: { chunk in
                if let connectionID {
                    await client.handleStderrChunk(chunk, connectionID: connectionID)
                } else {
                    await client.handleStderrChunk(chunk)
                }
            },
            shouldStop: {
                guard let connectionID else { return false }
                return await client.shouldStopReaderAfterProcessTermination(connectionID: connectionID)
            }
        )
        if case let .failure(code) = termination {
            let error = POSIXError(code)
            if let connectionID {
                await client.handleStderrReadFailure(error, connectionID: connectionID)
            } else {
                await client.handleStderrReadFailure(error)
            }
        }
    }

    nonisolated static func diagnosticMonitorLoop(
        from handle: FileHandle,
        client: MCPClient,
        connectionID: UUID
    ) async {
        let lineBuffer = Mutex(Data())
        let termination = await MCPStreamPump.run(
            fileDescriptor: handle.fileDescriptor,
            onChunk: { chunk in
                let lines: [String] = lineBuffer.withLock { lineBuffer in
                    lineBuffer.append(chunk)
                    // Diagnostic commands are untrusted peers too. Preserve only
                    // a bounded tail when they emit a never-terminated line.
                    if lineBuffer.count > Self.maxDiagnosticBytes {
                        lineBuffer = Data(lineBuffer.suffix(Self.maxDiagnosticBytes))
                    }
                    var lines: [String] = []
                    while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                        let lineData = lineBuffer.subdata(in: lineBuffer.startIndex ..< newlineIndex)
                        lineBuffer.removeSubrange(lineBuffer.startIndex ... newlineIndex)
                        if let line = String(data: lineData, encoding: .utf8) {
                            lines.append(line)
                        }
                    }
                    return lines
                }
                for line in lines {
                    await client.handleDiagnosticLine(line, connectionID: connectionID)
                    if await client.shouldStopDiagnosticMonitor(connectionID: connectionID) {
                        return
                    }
                }
            },
            shouldStop: {
                await client.shouldStopDiagnosticMonitor(connectionID: connectionID)
            }
        )
        if case let .failure(code) = termination {
            await client.handleDiagnosticReadFailure(POSIXError(code), connectionID: connectionID)
        }
    }

    func handleStdoutChunk(_ chunk: Data) {
        log("stdout <- \(chunk.count) bytes")
        append(chunk)
    }

    func handleStdoutReadFailure(_ error: Error) {
        log("stdout read failed: \(error.localizedDescription)")
        guard terminatingConnectionID == nil else {
            return
        }
        resumeAllPending(with: error)
    }

    func handleStdoutChunk(_ chunk: Data, connectionID: UUID) {
        guard activeConnectionID == connectionID else {
            return
        }
        handleStdoutChunk(chunk)
    }

    func handleStdoutReadFailure(_ error: Error, connectionID: UUID) {
        guard activeConnectionID == connectionID else {
            return
        }
        handleStdoutReadFailure(error)
    }

    func handleStdoutClosed() {
        log("stdout closed")
        guard terminatingConnectionID == nil else {
            return
        }
        if let terminalBridgeError {
            resumeAllPending(with: terminalBridgeError)
            return
        }

        let stderrMessage = currentStderrMessage()
        if let error = classifiedPolicyError(
            kind: .stdoutClosed,
            message: stderrMessage,
            hasStderrOutput: !stderrMessage.isEmpty
        ) {
            applyClassifiedPolicyError(error)
            resumeAllPending(with: error)
            return
        }

        resumeAllPending(with: MCPClientError.connectionClosed)
    }

    func handleStdoutClosed(connectionID: UUID) {
        guard activeConnectionID == connectionID,
              terminatingConnectionID != connectionID else {
            return
        }

        // EOF can arrive before Process invokes its termination handler. Let
        // that handler own the final drain and pending-response failure so a
        // reply written immediately before exit cannot lose to
        // `.connectionClosed`.
        guard let process else {
            handleStdoutClosed()
            return
        }

        let wasRunning = process.isRunning
        terminatingConnectionID = connectionID
        if wasRunning {
            terminalBridgeError = terminalBridgeError ?? .connectionClosed
            FeatureProcessTreeSupervisor.send(
                SIGKILL,
                to: process,
                processGroupLeader: FeatureProcessTreeSupervisor.isProcessGroupLeader(process)
            )
        }
    }

    func handleStderrChunk(_ chunk: Data) {
        appendDiagnostic(chunk, to: &stderrBuffer)
        if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
            log("stderr <- \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            log("stderr <- \(chunk.count) bytes")
        }

        guard terminalBridgeError == nil else {
            return
        }

        let stderrMessage = currentStderrMessage()
        guard let detectedError = classifiedPolicyError(
            kind: .stderr,
            message: stderrMessage,
            hasStderrOutput: !stderrMessage.isEmpty
        ) else {
            return
        }

        importantLog("Detected local MCP transport policy error from stderr: \(stderrMessage)")
        applyClassifiedPolicyError(detectedError)
        resumeAllPending(with: detectedError)
    }

    func handleStderrChunk(_ chunk: Data, connectionID: UUID) {
        guard activeConnectionID == connectionID else {
            return
        }
        handleStderrChunk(chunk)
    }

    func handleStderrReadFailure(_ error: Error) {
        appendDiagnostic(Data(error.localizedDescription.utf8), to: &stderrBuffer)
        log("stderr read failed: \(error.localizedDescription)")
    }

    func handleStderrReadFailure(_ error: Error, connectionID: UUID) {
        guard activeConnectionID == connectionID else {
            return
        }
        handleStderrReadFailure(error)
    }

    func shouldStopReaderAfterProcessTermination(connectionID: UUID) -> Bool {
        activeConnectionID != connectionID || terminatingConnectionID == connectionID
    }

    func shouldStopDiagnosticMonitor(connectionID: UUID) -> Bool {
        activeConnectionID != connectionID
            || diagnosticMonitorConnectionID != connectionID
            || terminatingConnectionID == connectionID
    }

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

    func append(_ chunk: Data) {
        // `buffer` only contains incomplete frames. Refuse a peer that exceeds
        // its residual-frame budget rather than repeatedly reallocating memory.
        guard chunk.count <= MCPTransportCodec.maxFrameBytes,
              buffer.count <= MCPTransportCodec.maxFrameBytes - chunk.count else {
            handleMalformedTransport(.frameTooLarge(limit: MCPTransportCodec.maxFrameBytes))
            return
        }
        buffer.append(chunk)

        if let error = classifiedPolicyError(
            kind: .stdout,
            message: String(data: buffer, encoding: .utf8) ?? ""
        ) {
            applyClassifiedPolicyError(error)
            resumeAllPending(with: error)
            buffer.removeAll(keepingCapacity: false)
            return
        }

        var parsedMessageCount = 0
        parseLoop: while true {
            switch MCPTransportCodec.nextMessage(from: &buffer) {
            case let .message(body):
                guard !body.isEmpty else {
                    continue
                }
                parsedMessageCount += 1
                handleMessage(body)
            case .needMoreData:
                break parseLoop
            case let .malformed(error):
                handleMalformedTransport(error)
                return
            }
        }

        if parsedMessageCount == 0, !buffer.isEmpty {
            logBufferedPrefixIfNeeded()
        }

    }

    func nextMessageBody() -> Data? {
        MCPTransportCodec.nextMessageBody(from: &buffer)
    }

    private func appendDiagnostic(_ chunk: Data, to buffer: inout Data) {
        guard chunk.count < Self.maxDiagnosticBytes else {
            buffer = Data(chunk.suffix(Self.maxDiagnosticBytes))
            return
        }
        let overflow = buffer.count.addingReportingOverflow(chunk.count)
        if overflow.overflow || overflow.partialValue > Self.maxDiagnosticBytes {
            let bytesToRemove = min(
                buffer.count,
                overflow.overflow
                    ? buffer.count
                    : overflow.partialValue - Self.maxDiagnosticBytes
            )
            buffer.removeFirst(bytesToRemove)
        }
        buffer.append(chunk)
    }

    private func handleMalformedTransport(_ error: MCPTransportCodecError) {
        let clientError = MCPClientError.malformedTransport(error.localizedDescription)
        buffer.removeAll(keepingCapacity: false)
        terminalBridgeError = clientError
        resumeAllPending(with: clientError)
        // Framing cannot be safely re-synchronized. Always close the local
        // transport; this is intentionally independent of optional policy hooks.
        terminateLocalProcessAfterPolicyError(clientError)
    }

    func handleMessage(_ body: Data) {
        log("message <- \(String(data: body, encoding: .utf8) ?? "<non-utf8>")")
        guard let message = try? JSONDecoder().decode(MCPIncomingMessage.self, from: body) else {
            if let error = classifiedPolicyError(
                kind: .invalidMessage,
                message: String(data: body, encoding: .utf8) ?? ""
            ) {
                applyClassifiedPolicyError(error)
                resumeAllPending(with: error)
            }
            log("Failed to decode incoming MCP message")
            return
        }

        guard let id = message.id else {
            if handleUnroutedPolicyMessage(message) {
                return
            }
            return
        }

        guard case let .int(requestID) = id else {
            if handleUnroutedPolicyMessage(message) {
                return
            }
            resumeAllPending(with: MCPClientError.unsupportedMessageID)
            return
        }

        let method = pendingRequestMethods.removeValue(forKey: requestID)
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            if handleUnroutedPolicyMessage(message) {
                return
            }
            return
        }

        if let error = message.error {
            log("Request \(requestID) failed with server error \(error.code): \(error.message)")
            if let policyError = classifiedPolicyError(
                kind: .serverError,
                message: error.message,
                requestMethod: method,
                errorCode: error.code
            ) {
                applyClassifiedPolicyError(policyError)
                continuation.resume(throwing: policyError)
            } else {
                continuation.resume(
                    throwing: MCPClientError.serverError(
                        code: error.code,
                        message: error.message
                    )
                )
            }
            return
        }

        guard let result = message.result else {
            log("Request \(requestID) failed: missing result")
            if let error = classifiedPolicyError(
                kind: .missingResult,
                requestMethod: method
            ) {
                applyClassifiedPolicyError(error)
                continuation.resume(throwing: error)
            } else {
                continuation.resume(throwing: MCPClientError.invalidResponse)
            }
            return
        }

        log("Request \(requestID) completed successfully")
        continuation.resume(returning: result)
    }

    func resumeAllPending(with error: Error) {
        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        pendingRequestMethods.removeAll()

        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    func cancelPendingResponse(id requestID: Int) {
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            return
        }
        pendingRequestMethods.removeValue(forKey: requestID)
        continuation.resume(throwing: CancellationError())
    }

    func exitError(for process: Process) -> MCPClientError {
        let stderrMessage = currentStderrMessage()
        if let policyError = classifiedPolicyError(
            kind: .processExited,
            message: stderrMessage,
            hasStderrOutput: !stderrMessage.isEmpty,
            terminationStatus: process.terminationStatus
        ) {
            return policyError
        }

        let message = stderrMessage.isEmpty
            ? "The local MCP server exited without diagnostics."
            : stderrMessage

        log("Bridge exited with status \(process.terminationStatus). stderr: \(message)")
        return .serverExited(status: process.terminationStatus, message: message)
    }

    func currentStderrMessage() -> String {
        String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func serverError(
        _ error: MCPErrorResponse,
        requestMethod: String?
    ) -> MCPClientError {
        classifiedPolicyError(
            kind: .serverError,
            message: error.message,
            requestMethod: requestMethod,
            errorCode: error.code
        ) ?? .serverError(code: error.code, message: error.message)
    }

    func classifiedPolicyError(
        kind: LocalMCPTransportEvent.Kind,
        message: String = "",
        requestMethod: String? = nil,
        errorCode: Int? = nil,
        hasStderrOutput: Bool = false,
        terminationStatus: Int32? = nil
    ) -> MCPClientError? {
        localTransportPolicy.errorClassifier(
            LocalMCPTransportEvent(
                kind: kind,
                message: message,
                requestMethod: requestMethod,
                errorCode: errorCode,
                pendingRequestMethods: pendingRequestMethods.values.sorted(),
                hasStderrOutput: hasStderrOutput,
                terminationStatus: terminationStatus
            )
        )
    }

    private func handleUnroutedPolicyMessage(_ message: MCPIncomingMessage) -> Bool {
        let text: String
        let errorCode: Int?
        if let error = message.error {
            text = error.message
            errorCode = error.code
        } else {
            text = "Unrouted MCP response"
            errorCode = nil
        }

        guard let policyError = classifiedPolicyError(
            kind: .unroutedMessage,
            message: text,
            errorCode: errorCode
        ) else {
            return false
        }

        applyClassifiedPolicyError(policyError)
        resumeAllPending(with: policyError)
        return true
    }

    func handleDiagnosticLine(_ line: String) {
        guard let policyError = classifiedPolicyError(
            kind: .diagnostic,
            message: line
        ) else {
            return
        }

        log("Detected local MCP transport policy error from diagnostic output: \(line)")
        applyClassifiedPolicyError(policyError)
        resumeAllPending(with: policyError)
    }

    func handleDiagnosticLine(_ line: String, connectionID: UUID) {
        guard activeConnectionID == connectionID,
              diagnosticMonitorConnectionID == connectionID,
              terminatingConnectionID != connectionID else {
            return
        }
        handleDiagnosticLine(line)
    }

    func handleDiagnosticReadFailure(_ error: Error, connectionID: UUID) {
        guard activeConnectionID == connectionID,
              diagnosticMonitorConnectionID == connectionID else {
            return
        }
        log("diagnostic monitor read failed: \(error.localizedDescription)")
    }

    func recordPendingRequestMethodForTesting(id: Int, method: String) {
        pendingRequestMethods[id] = method
    }

    func applyClassifiedPolicyError(_ error: MCPClientError) {
        terminalBridgeError = error
        guard localTransportPolicy.terminateProcessOnClassifiedError else {
            return
        }
        terminateLocalProcessAfterPolicyError(error)
    }

    func terminateLocalProcessAfterPolicyError(_ error: MCPClientError) {
        terminalBridgeError = error
        if let activeConnectionID {
            terminatingConnectionID = activeConnectionID
        }
        // Detach the writer's descriptor BEFORE closing it. This path closes stdin
        // synchronously while the writer's consumer may still hold a claimed
        // frame, so without the gate a job could write onto a closed — or already
        // recycled — descriptor. Invalidation is synchronous and needs no join,
        // so it is safe here; the full bounded teardown runs in
        // `handleProcessTermination` once the SIGKILLed process is reaped.
        writer?.invalidateDescriptor()
        inputHandle?.closeFile()
        inputHandle = nil

        guard let process else {
            return
        }

        if process.isRunning {
            importantLog("Terminating local MCP process after a classified transport error.")
            FeatureProcessTreeSupervisor.send(
                SIGKILL,
                to: process,
                processGroupLeader: FeatureProcessTreeSupervisor.isProcessGroupLeader(process)
            )
        }
    }

    func importantLog(_ message: String) {
        log(message)
    }

    func logBufferedPrefixIfNeeded() {
        let prefixData = buffer.prefix(200)
        let utf8Preview = String(data: prefixData, encoding: .utf8) ?? "<non-utf8>"
        let escapedPreview = utf8Preview
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let hexPreview = prefixData.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        let snapshot = "size=\(buffer.count) utf8=\"\(escapedPreview)\" hex=\(hexPreview)"

        guard snapshot != lastBufferedPrefixSnapshot else {
            return
        }

        lastBufferedPrefixSnapshot = snapshot
        log("buffered stdout prefix \(snapshot)")
    }

    func log(_ message: String) {
        _ = message
    }
}
#endif
