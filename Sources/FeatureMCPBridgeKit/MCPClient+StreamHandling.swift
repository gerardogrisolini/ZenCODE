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
        let fileDescriptor = handle.fileDescriptor
        var rawBuffer = [UInt8](repeating: 0, count: 4096)

        do {
            while !Task.isCancelled {
                let bytesRead = Darwin.read(fileDescriptor, &rawBuffer, rawBuffer.count)
                if bytesRead > 0 {
                    await client.handleStdoutChunk(Data(rawBuffer.prefix(bytesRead)))
                    continue
                }

                if bytesRead == 0 {
                    break
                }

                if errno == EINTR {
                    continue
                }

                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            await client.handleStdoutReadFailure(error)
            return
        }

        await client.handleStdoutClosed()
    }

    public nonisolated static func errorLoop(from handle: FileHandle, client: MCPClient) async {
        let fileDescriptor = handle.fileDescriptor
        var rawBuffer = [UInt8](repeating: 0, count: 4096)

        do {
            while !Task.isCancelled {
                let bytesRead = Darwin.read(fileDescriptor, &rawBuffer, rawBuffer.count)
                if bytesRead > 0 {
                    await client.handleStderrChunk(Data(rawBuffer.prefix(bytesRead)))
                    continue
                }

                if bytesRead == 0 {
                    break
                }

                if errno == EINTR {
                    continue
                }

                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            await client.handleStderrReadFailure(error)
        }
    }

    nonisolated static func logMonitorLoop(from handle: FileHandle, client: MCPClient) async {
        let fileDescriptor = handle.fileDescriptor
        var rawBuffer = [UInt8](repeating: 0, count: 4096)
        var lineBuffer = Data()

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
                    await client.handleMCPBridgeDiagnosticLine(line)
                }
                continue
            }

            if bytesRead == 0 {
                break
            }

            if errno == EINTR {
                continue
            }

            break
        }
    }

    public func handleStdoutChunk(_ chunk: Data) {
        log("stdout <- \(chunk.count) bytes")
        persistStdoutChunkTrace(chunk)
        append(chunk)
    }

    public func handleStdoutReadFailure(_ error: Error) {
        log("stdout read failed: \(error.localizedDescription)")
        resumeAllPending(with: error)
    }

    public func handleStdoutClosed() {
        log("stdout closed")
        if let terminalBridgeError {
            resumeAllPending(with: terminalBridgeError)
            return
        }

        // mcpbridge closes its streams without any diagnostics when the user
        // denies the Xcode consent; mirror exitError so the closure surfaces
        // as the permission error instead of a generic connection failure.
        if configuration.usesMCPBridgeExecutable, currentStderrMessage().isEmpty {
            let error = MCPClientError.xcodePermissionRequired
            terminateLocalBridgeAfterPermissionDenied(error)
            resumeAllPending(with: error)
            return
        }

        resumeAllPending(with: MCPClientError.connectionClosed)
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
        guard let detectedError = permissionErrorIfPresent(in: stderrMessage) else {
            return
        }

        terminalBridgeError = detectedError
        importantLog("Detected Xcode MCP permission error from stderr: \(stderrMessage)")
        log("Detected terminal MCP bridge permission error from stderr")
        terminateLocalBridgeAfterPermissionDenied(detectedError)
        resumeAllPending(with: detectedError)
    }

    public func handleStderrReadFailure(_ error: Error) {
        stderrBuffer.append(Data(error.localizedDescription.utf8))
        log("stderr read failed: \(error.localizedDescription)")
    }

    public func handleProcessTermination(_ terminatedProcess: Process) {
        let detectedError = terminalBridgeError ?? exitError(for: terminatedProcess)
        terminalBridgeError = detectedError
        if process === terminatedProcess {
            process = nil
            inputHandle = nil
        }
        stopMCPBridgeLogMonitor()
        importantLog("MCP bridge terminated with error: \(detectedError.localizedDescription)")
        log("process terminated with error: \(detectedError.localizedDescription)")
        resumeAllPending(with: detectedError)
    }

    public func append(_ chunk: Data) {
        buffer.append(chunk)

        if mcpBridgeStdoutLooksLikePermissionDenied(buffer) {
            let error = MCPClientError.xcodePermissionRequired
            terminateLocalBridgeAfterPermissionDenied(error)
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
            if hasPendingMCPBridgeListToolsRequest()
                || mcpBridgeStdoutLooksLikePermissionDenied(body) {
                let error = MCPClientError.xcodePermissionRequired
                terminateLocalBridgeAfterPermissionDenied(error)
                resumeAllPending(with: error)
            }
            log("Failed to decode incoming MCP message")
            return
        }

        guard let id = message.id else {
            if handleUnroutedMCPBridgeMessage(message) {
                return
            }
            return
        }

        guard case let .int(requestID) = id else {
            if handleUnroutedMCPBridgeMessage(message) {
                return
            }
            resumeAllPending(with: MCPClientError.unsupportedMessageID)
            return
        }

        let method = pendingRequestMethods.removeValue(forKey: requestID)
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            if handleUnroutedMCPBridgeMessage(message) {
                return
            }
            return
        }

        if let error = message.error {
            log("Request \(requestID) failed with server error \(error.code): \(error.message)")
            let mappedError = serverError(error, requestMethod: method)
            if case .xcodePermissionRequired = mappedError {
                terminateLocalBridgeAfterPermissionDenied(mappedError)
            }
            continuation.resume(throwing: mappedError)
            return
        }

        guard let result = message.result else {
            log("Request \(requestID) failed: missing result")
            if configuration.usesMCPBridgeExecutable, method == "tools/list" {
                let error = MCPClientError.xcodePermissionRequired
                terminateLocalBridgeAfterPermissionDenied(error)
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
        if let detectedPermissionError = permissionErrorIfPresent(in: stderrMessage) {
            return detectedPermissionError
        }

        if configuration.usesMCPBridgeExecutable,
           stderrMessage.isEmpty {
            return .xcodePermissionRequired
        }

        let message = stderrMessage.isEmpty
            ? "Open Xcode, approve the MCP bridge if prompted, then retry."
            : stderrMessage

        log("Bridge exited with status \(process.terminationStatus). stderr: \(message)")
        return .serverExited(status: process.terminationStatus, message: message)
    }

    public func currentStderrMessage() -> String {
        String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func permissionErrorIfPresent(in stderrMessage: String) -> MCPClientError? {
        guard configuration.usesMCPBridgeExecutable else {
            return nil
        }

        let lowered = stderrMessage.lowercased()
        guard lowered.contains("permission")
            || lowered.contains("authorize")
            || lowered.contains("authorization")
            || lowered.contains("authorisation")
            || lowered.contains("consent")
            || lowered.contains("denied")
            || lowered.contains("not allowed")
            || lowered.contains("not permitted")
            || lowered.contains("rejected")
            || lowered.contains("declined")
            || lowered.contains("cancelled")
            || lowered.contains("canceled")
        else {
            return nil
        }

        return .xcodePermissionRequired
    }

    func serverError(
        _ error: MCPErrorResponse,
        requestMethod: String?
    ) -> MCPClientError {
        guard configuration.usesMCPBridgeExecutable else {
            return .serverError(code: error.code, message: error.message)
        }

        if requestMethod == "tools/list" {
            return .xcodePermissionRequired
        }

        if mcpBridgeRequestCanFailForPermission(requestMethod),
           mcpBridgeErrorLooksLikePermissionDenial(error) {
            return .xcodePermissionRequired
        }

        return .serverError(code: error.code, message: error.message)
    }

    private func mcpBridgeRequestCanFailForPermission(_ requestMethod: String?) -> Bool {
        switch requestMethod {
        case "initialize", "tools/call":
            return true
        default:
            return false
        }
    }

    private func mcpBridgeErrorLooksLikePermissionDenial(_ error: MCPErrorResponse) -> Bool {
        if permissionErrorIfPresent(in: error.message) != nil {
            return true
        }

        let lowered = error.message.lowercased()
        return error.code == 1
            || lowered.contains("bridgeerror code=1")
            || lowered.contains("bridgeerror error 1")
            || lowered.contains("bridgeerror code 1")
            || lowered.contains("bridgeerror 1")
    }

    private func handleUnroutedMCPBridgeMessage(_ message: MCPIncomingMessage) -> Bool {
        guard hasPendingMCPBridgeListToolsRequest() else {
            return false
        }

        if let error = message.error {
            log("Unrouted mcpbridge error \(error.code): \(error.message)")
        } else {
            log("Unrouted mcpbridge response while tools/list is pending")
        }
        let mappedError = MCPClientError.xcodePermissionRequired
        terminateLocalBridgeAfterPermissionDenied(mappedError)
        resumeAllPending(with: mappedError)
        return true
    }

    private func hasPendingMCPBridgeListToolsRequest() -> Bool {
        configuration.usesMCPBridgeExecutable
            && pendingRequestMethods.values.contains("tools/list")
    }

    func handleMCPBridgeDiagnosticLine(_ line: String) {
        guard hasPendingMCPBridgeListToolsRequest() else {
            return
        }

        let lowered = line.lowercased()
        guard lowered.contains("listtools request failed")
            || lowered.contains("bridgeerror code=1")
            || (lowered.contains("bridgeerror") && lowered.contains("code=1"))
        else {
            return
        }

        log("Detected Xcode MCP permission denial from system log: \(line)")
        let error = MCPClientError.xcodePermissionRequired
        terminateLocalBridgeAfterPermissionDenied(error)
        resumeAllPending(with: error)
    }

    func recordPendingRequestMethodForTesting(id: Int, method: String) {
        pendingRequestMethods[id] = method
    }

    func mcpBridgeStdoutLooksLikePermissionDenied(_ data: Data) -> Bool {
        guard configuration.usesMCPBridgeExecutable,
              let text = String(data: data, encoding: .utf8) else {
            return false
        }

        let lowered = text.lowercased()
        return lowered.contains("bridgeerror code=1")
            || lowered.contains("bridgeerror code 1")
            || lowered.contains("bridgeerror 1")
            || (lowered.contains("ideintelligencemessaging")
                && lowered.contains("bridgeerror")
                && lowered.contains("code=1"))
    }

    func terminateLocalBridgeAfterPermissionDenied(_ error: MCPClientError) {
        guard configuration.usesMCPBridgeExecutable else {
            return
        }

        terminalBridgeError = error
        inputHandle?.closeFile()
        inputHandle = nil
        stopMCPBridgeLogMonitor()

        guard let process else {
            return
        }

        if process.isRunning {
            importantLog("Terminating Xcode MCP bridge after permission denial.")
#if canImport(Darwin)
            kill(process.processIdentifier, SIGKILL)
#else
            process.terminate()
#endif
        }
        self.process = nil
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
