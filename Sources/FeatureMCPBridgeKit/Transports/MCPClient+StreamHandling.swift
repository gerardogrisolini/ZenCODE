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
import ToolCore

#if os(macOS)
extension MCPClient {
    public nonisolated static func readLoop(from handle: FileHandle, client: MCPClient) async {
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
        let fileDescriptor = handle.fileDescriptor
        var rawBuffer = [UInt8](repeating: 0, count: 4096)

        do {
            while !Task.isCancelled {
                let bytesRead = Darwin.read(fileDescriptor, &rawBuffer, rawBuffer.count)
                if bytesRead > 0 {
                    let chunk = Data(rawBuffer.prefix(bytesRead))
                    if let connectionID {
                        await client.handleStdoutChunk(chunk, connectionID: connectionID)
                        if await client.shouldStopReaderAfterProcessTermination(
                            connectionID: connectionID
                        ) {
                            return
                        }
                    } else {
                        await client.handleStdoutChunk(chunk)
                    }
                    continue
                }

                if bytesRead == 0 {
                    break
                }

                if errno == EINTR {
                    continue
                }

                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if let connectionID,
                       await client.shouldStopReaderAfterProcessTermination(
                           connectionID: connectionID
                       ) {
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    } catch {
                        return
                    }
                    continue
                }

                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if !Task.isCancelled {
                if let connectionID {
                    await client.handleStdoutReadFailure(error, connectionID: connectionID)
                } else {
                    await client.handleStdoutReadFailure(error)
                }
            }
            return
        }

        if let connectionID {
            await client.handleStdoutClosed(connectionID: connectionID)
        } else {
            await client.handleStdoutClosed()
        }
    }

    public nonisolated static func errorLoop(from handle: FileHandle, client: MCPClient) async {
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
        let fileDescriptor = handle.fileDescriptor
        var rawBuffer = [UInt8](repeating: 0, count: 4096)

        do {
            while !Task.isCancelled {
                let bytesRead = Darwin.read(fileDescriptor, &rawBuffer, rawBuffer.count)
                if bytesRead > 0 {
                    let chunk = Data(rawBuffer.prefix(bytesRead))
                    if let connectionID {
                        await client.handleStderrChunk(chunk, connectionID: connectionID)
                        if await client.shouldStopReaderAfterProcessTermination(
                            connectionID: connectionID
                        ) {
                            return
                        }
                    } else {
                        await client.handleStderrChunk(chunk)
                    }
                    continue
                }

                if bytesRead == 0 {
                    break
                }

                if errno == EINTR {
                    continue
                }

                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if let connectionID,
                       await client.shouldStopReaderAfterProcessTermination(
                           connectionID: connectionID
                       ) {
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    } catch {
                        return
                    }
                    continue
                }

                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if !Task.isCancelled {
                if let connectionID {
                    await client.handleStderrReadFailure(error, connectionID: connectionID)
                } else {
                    await client.handleStderrReadFailure(error)
                }
            }
        }
    }

    nonisolated static func diagnosticMonitorLoop(
        from handle: FileHandle,
        client: MCPClient,
        connectionID: UUID
    ) async {
        let fileDescriptor = handle.fileDescriptor
        var rawBuffer = [UInt8](repeating: 0, count: 4096)
        var lineBuffer = Data()

        do {
            while !Task.isCancelled {
                let bytesRead = Darwin.read(fileDescriptor, &rawBuffer, rawBuffer.count)
                if bytesRead > 0 {
                    lineBuffer.append(contentsOf: rawBuffer.prefix(bytesRead))
                    while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                        let lineData = lineBuffer.subdata(in: lineBuffer.startIndex ..< newlineIndex)
                        lineBuffer.removeSubrange(lineBuffer.startIndex ... newlineIndex)
                        guard let line = String(data: lineData, encoding: .utf8) else {
                            continue
                        }
                        await client.handleDiagnosticLine(line, connectionID: connectionID)
                        if await client.shouldStopDiagnosticMonitor(connectionID: connectionID) {
                            return
                        }
                    }
                    if await client.shouldStopDiagnosticMonitor(connectionID: connectionID) {
                        return
                    }
                    continue
                }

                if bytesRead == 0 {
                    return
                }

                if errno == EINTR {
                    continue
                }

                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if await client.shouldStopDiagnosticMonitor(connectionID: connectionID) {
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    } catch {
                        return
                    }
                    continue
                }

                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if !Task.isCancelled {
                await client.handleDiagnosticReadFailure(error, connectionID: connectionID)
            }
        }
    }

    public func handleStdoutChunk(_ chunk: Data) {
        log("stdout <- \(chunk.count) bytes")
        persistStdoutChunkTrace(chunk)
        append(chunk)
    }

    public func handleStdoutReadFailure(_ error: Error) {
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

    public func handleStdoutClosed() {
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
#if canImport(Darwin)
            kill(process.processIdentifier, SIGKILL)
#else
            process.terminate()
#endif
        }
    }

    public func handleStderrChunk(_ chunk: Data) {
        stderrBuffer.append(chunk)
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

    public func handleStderrReadFailure(_ error: Error) {
        stderrBuffer.append(Data(error.localizedDescription.utf8))
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

    public func handleProcessTermination(_ terminatedProcess: Process) {
        guard let activeConnectionID else {
            return
        }
        Task { [weak self] in
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
        activeConnectionID = nil
        terminatingConnectionID = nil
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        readLoopTask = nil
        errorLoopTask = nil
        terminatedProcess.terminationHandler = nil
        currentInputHandle?.closeFile()
        currentOutputHandle?.closeFile()
        currentErrorHandle?.closeFile()
        importantLog("MCP bridge terminated with error: \(detectedError.localizedDescription)")
        log("process terminated with error: \(detectedError.localizedDescription)")
        resumeAllPending(with: detectedError)
    }

    public func append(_ chunk: Data) {
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
        while let body = nextMessageBody() {
            guard !body.isEmpty else {
                continue
            }

            parsedMessageCount += 1
            handleMessage(body)
        }

        if parsedMessageCount == 0, !buffer.isEmpty {
            logBufferedPrefixIfNeeded()
        }

        persistReassembledBufferSnapshotIfNeeded()
    }

    public func nextMessageBody() -> Data? {
        MCPTransportCodec.nextMessageBody(from: &buffer)
    }

    public func handleMessage(_ body: Data) {
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

    public func resumeAllPending(with error: Error) {
        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        pendingRequestMethods.removeAll()

        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    public func cancelPendingResponse(id requestID: Int) {
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            return
        }
        pendingRequestMethods.removeValue(forKey: requestID)
        continuation.resume(throwing: CancellationError())
    }

    public func exitError(for process: Process) -> MCPClientError {
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

    public func currentStderrMessage() -> String {
        String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func serverError(
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
        inputHandle?.closeFile()
        inputHandle = nil

        guard let process else {
            return
        }

        if process.isRunning {
            importantLog("Terminating local MCP process after a classified transport error.")
#if canImport(Darwin)
            kill(process.processIdentifier, SIGKILL)
#else
            process.terminate()
#endif
        }
    }

    public func importantLog(_ message: String) {
        log(message)
    }

    public func logBufferedPrefixIfNeeded() {
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

    public func log(_ message: String) {
        guard isDebugLoggingEnabled else {
            return
        }

        appendDebugLogLine(message)
    }

    public func prepareStdoutTracingFiles() {
        guard isDebugLoggingEnabled else {
            return
        }

        let sessionTag = Self.traceSessionTag()
        stdoutChunkTraceURLs = traceURLs(fileName: "mcpclient-stdout-chunks-\(sessionTag).bin")
        stdoutReassembledBufferURLs = traceURLs(fileName: "mcpclient-stdout-reassembled-\(sessionTag).bin")
        lastReassembledBufferSize = -1

        for url in stdoutChunkTraceURLs + stdoutReassembledBufferURLs {
            overwrite(data: Data(), to: url)
        }

        if let chunkURL = stdoutChunkTraceURLs.first {
            log("Tracing stdout chunks to \(chunkURL.path)")
        }
        if let reassembledURL = stdoutReassembledBufferURLs.first {
            log("Tracing reassembled stdout buffer to \(reassembledURL.path)")
        }
    }

    public nonisolated static func traceSessionTag() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(formatter.string(from: Date()))-pid\(ProcessInfo.processInfo.processIdentifier)"
    }

    public func traceURLs(fileName: String) -> [URL] {
        let homeLogsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FeatureMCPBridgeKit", isDirectory: true)
        return [homeLogsDirectory.appendingPathComponent(fileName)]
    }

    public func persistStdoutChunkTrace(_ chunk: Data) {
        guard isDebugLoggingEnabled, !stdoutChunkTraceURLs.isEmpty else {
            return
        }

        for url in stdoutChunkTraceURLs {
            append(data: chunk, to: url)
        }
    }

    public func persistReassembledBufferSnapshotIfNeeded() {
        guard isDebugLoggingEnabled, !stdoutReassembledBufferURLs.isEmpty else {
            return
        }

        guard buffer.count != lastReassembledBufferSize else {
            return
        }

        lastReassembledBufferSize = buffer.count
        for url in stdoutReassembledBufferURLs {
            overwrite(data: buffer, to: url)
        }
    }

    public func appendDebugLogLine(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [pid:\(ProcessInfo.processInfo.processIdentifier)] [MCPClient] \(message)\n"
        let logURLs = debugLogURLs()

        for logURL in logURLs {
            append(line: line, to: logURL)
        }
    }

    public func debugLogURLs() -> [URL] {
        let homeLogsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FeatureMCPBridgeKit", isDirectory: true)
        return [homeLogsDirectory.appendingPathComponent("mcpclient.log")]
    }

    public func append(line: String, to logURL: URL) {
        let fileManager = FileManager.default
        let directoryURL = logURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: logURL.path) == false {
            try? Data(line.utf8).write(to: logURL)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            return
        }
    }

    public func append(data: Data, to logURL: URL) {
        let fileManager = FileManager.default
        let directoryURL = logURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: logURL.path) == false {
            try? data.write(to: logURL)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    public func overwrite(data: Data, to logURL: URL) {
        let fileManager = FileManager.default
        let directoryURL = logURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: logURL, options: .atomic)
    }
}
#endif
