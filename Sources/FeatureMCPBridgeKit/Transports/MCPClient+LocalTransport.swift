//
//  MCPClient+LocalTransport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#endif
import Foundation
import Synchronization
import ToolCore

#if os(macOS)
extension MCPClient {
    public func connect() async throws {
        if let httpTransport {
            try await httpTransport.connect()
            return
        }

        try await localConnectFlight.run { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            try await self.performLocalConnect()
        }
    }

    private func performLocalConnect() async throws {
        if let terminalBridgeError {
            throw terminalBridgeError
        }

        guard process == nil else {
            return
        }

        let connectionID = UUID()
        let process = Process()
        let executableURL = Self.resolvedExecutableURL(for: configuration)
        process.executableURL = executableURL
        process.arguments = configuration.arguments

        let environment = Self.resolvedEnvironment(for: configuration)
        process.environment = environment

        log(buildMarker)
        log("Launching MCP bridge: \(executableURL.path) \(configuration.arguments.joined(separator: " "))")
        if !configuration.environment.isEmpty {
            log("Bridge environment overrides: \(configuration.environment)")
        }

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { [weak self] terminatedProcess in
            Task(name: "MCP local process termination") {
                await self?.handleProcessTermination(
                    terminatedProcess,
                    connectionID: connectionID
                )
            }
        }

        try process.run()

        self.process = process
        activeConnectionID = connectionID
        terminatingConnectionID = nil
        let stdinHandle = standardInput.fileHandleForWriting
        inputHandle = stdinHandle
        // Make the bridge's stdin non-blocking and funnel every write through a
        // single serialized writer that runs OUTSIDE this actor. With a blocking
        // descriptor a full pipe would block writeAll while it executes on the
        // actor, preventing disconnect() and the onCancel handlers from ever
        // entering. The writer task provides async back-pressure instead.
        do {
            try Self.makeNonBlocking(stdinHandle)
        } catch {
            await disconnectLocalTransport(cancellingConnectFlight: false)
            throw error
        }
        // If a previous connection's writer is still around (e.g. the bridge
        // exited through its own termination handler, which does not own the
        // writer), tear it down before starting a fresh one so its detached
        // consumer task cannot leak across reconnections. Detach it from the
        // actor BEFORE awaiting the teardown: during that suspension the actor is
        // reentrant, and a `write()` that still saw the stale writer would
        // enqueue onto a descriptor belonging to the previous generation. The
        // teardown is bounded, so a stale writer wedged on a dead peer's pipe
        // cannot block a reconnect.
        if let staleWriter = writer {
            writer = nil
            await staleWriter.shutdown()
        }
        writer = MCPLocalTransportWriter(fileDescriptor: stdinHandle.fileDescriptor)
        startDiagnosticMonitor(for: process, connectionID: connectionID)

        signal(SIGPIPE, SIG_IGN)
        prepareStdoutTracingFiles()

        let outputHandle = standardOutput.fileHandleForReading
        self.outputHandle = outputHandle
        do {
            try Self.makeNonBlocking(outputHandle)
        } catch {
            await disconnectLocalTransport(cancellingConnectFlight: false)
            throw error
        }
        readLoopTask = Task.detached(name: "MCP local stdout reader") { [self] in
            await Self.readLoop(
                from: outputHandle,
                client: self,
                connectionID: connectionID
            )
        }

        let errorHandle = standardError.fileHandleForReading
        self.errorHandle = errorHandle
        do {
            try Self.makeNonBlocking(errorHandle)
        } catch {
            await disconnectLocalTransport(cancellingConnectFlight: false)
            throw error
        }
        errorLoopTask = Task.detached(name: "MCP local stderr reader") { [self] in
            await Self.errorLoop(
                from: errorHandle,
                client: self,
                connectionID: connectionID
            )
        }

        let initializeParams = MCPInitializeParams(
            protocolVersion: configuration.preferredProtocolVersion,
            capabilities: MCPClientCapabilities(),
            clientInfo: MCPClientInfo(name: "Feature MCP client", version: "1.0")
        )

        do {
            try Task.checkCancellation()

            if localTransportPolicy.handshake == .optimisticInitialized {
                let initializeRequestID = nextRequestID
                nextRequestID += 1

                let initializeRequest = MCPRequest(
                    jsonrpc: "2.0",
                    id: .int(initializeRequestID),
                    method: "initialize",
                    params: initializeParams
                )
                let initializePayload = try JSONEncoder().encode(initializeRequest)
                let initializedNotification = MCPNotification(
                    jsonrpc: "2.0",
                    method: "notifications/initialized",
                    params: JSONValue.object([:])
                )
                let initializedPayload = try JSONEncoder().encode(initializedNotification)
                let handshakeWriteHandle = MCPCancellableTaskHandle()

                log("Sending initialize request (optimistic local transport handshake)")
                log(
                    "Request \(initializeRequestID) -> initialize: " +
                    (String(data: initializePayload, encoding: .utf8) ?? "<non-utf8>")
                )
                _ = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                        pendingResponses[initializeRequestID] = continuation
                        pendingRequestMethods[initializeRequestID] = "initialize"

                        // The write is asynchronous (it goes through the serialized
                        // writer), so perform it off the synchronous continuation
                        // body. The response continuation is already registered, so
                        // an early response is captured; on write failure we claim
                        // and resume it exactly once.
                        // Unstructured task: it does not inherit cancellation,
                        // so publish it and let onCancel stop the handshake
                        // write instead of leaking it past cancellation.
                        handshakeWriteHandle.adopt(
                            Task(name: "MCP local initialize write") { [self] in
                                do {
                                    try await self.write(initializePayload)
                                    self.log("Sending initialized notification early")
                                    try await self.write(initializedPayload)
                                } catch {
                                    self.claimAndResumeResponse(
                                        id: initializeRequestID,
                                        with: .failure(error)
                                    )
                                }
                            }
                        )
                    }
                } onCancel: {
                    handshakeWriteHandle.cancel()
                    Task(name: "MCP local initialize cancellation") {
                        await self.cancelPendingResponse(id: initializeRequestID)
                    }
                }
                importantLog("Initialize completed successfully for request \(initializeRequestID).")
                log("MCP bridge connected successfully")
                return
            }

            log("Sending initialize request")
            _ = try await request(
                method: "initialize",
                params: initializeParams
            )

            log("Sending initialized notification")
            try await notify(method: "notifications/initialized", params: JSONValue.object([:]))

            log("MCP bridge connected successfully")
        } catch {
            // process.run() has already launched the bridge and its detached
            // readers. On handshake failure or cancellation tear everything down
            // (terminate -> SIGKILL) so a later connect() starts from a clean
            // state instead of returning early because process != nil.
            await disconnectLocalTransport(cancellingConnectFlight: false)
            throw error
        }
    }

    public func disconnect() async {
        if let httpTransport {
            await httpTransport.disconnect()
            return
        }
        await disconnectLocalTransport(cancellingConnectFlight: true)
    }

    private func disconnectLocalTransport(cancellingConnectFlight: Bool) async {
        if cancellingConnectFlight {
            // Fence any in-flight process launch/initialize before releasing this
            // generation's handles, so a late handshake cannot make a disconnected
            // client appear ready again.
            localConnectFlight.cancel()
        }

        let connectionID = activeConnectionID
        activeConnectionID = nil
        if terminatingConnectionID == connectionID {
            terminatingConnectionID = nil
        }

        let readTask = readLoopTask
        readLoopTask = nil
        let errorTask = errorLoopTask
        errorLoopTask = nil
        let diagnosticMonitor = stopDiagnosticMonitor()

        let currentInputHandle = inputHandle
        inputHandle = nil
        let currentOutputHandle = outputHandle
        outputHandle = nil
        let currentErrorHandle = errorHandle
        errorHandle = nil
        // Stop the serialized writer first: it must stop touching the write FD
        // before that FD is closed (and possibly recycled by a later
        // connection). Safety no longer depends on the consumer terminating:
        // `shutdown()` detaches the descriptor with a hard deadline, so a frame
        // wedged on a full pipe cannot stall teardown.
        let currentWriter = writer
        writer = nil
        currentWriter?.finish()
        currentWriter?.cancel()
        // The descriptors are non-blocking, so cancellation makes the readers
        // leave promptly without closing an FD that a reader may still hold.
        // Close their captured handles only after both readers have joined.
        readTask?.cancel()
        errorTask?.cancel()

        let bridgeProcess = process
        process = nil
        if let bridgeProcess {
            bridgeProcess.terminationHandler = nil
            if bridgeProcess.isRunning {
                // Ask nicely (SIGTERM), give the bridge a short grace window,
                // then force-kill (SIGKILL) so a wedged/orphan bridge cannot
                // survive disconnect().
                bridgeProcess.terminate()
                for _ in 0..<50 {
                    if !bridgeProcess.isRunning || Task.isCancelled {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                if bridgeProcess.isRunning {
                    Darwin.kill(bridgeProcess.processIdentifier, SIGKILL)
                }
            }
        }

        resumeAllPending(with: MCPClientError.connectionClosed)
        buffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
        terminalBridgeError = nil
        stdoutChunkTraceURLs.removeAll(keepingCapacity: false)
        stdoutReassembledBufferURLs.removeAll(keepingCapacity: false)
        lastReassembledBufferSize = -1

        await readTask?.value
        await errorTask?.value
        // Bounded writer teardown BEFORE closing stdin. `shutdown()` returns
        // within its deadline even if a descendant inherited the read end and
        // never drains it; on return the descriptor is detached and every job
        // continuation is concluded, so closing the FD can neither strand a
        // caller nor let a straggling write land on a recycled descriptor.
        await currentWriter?.shutdown()
        currentInputHandle?.closeFile()
        await diagnosticMonitor.task?.value
        currentOutputHandle?.closeFile()
        currentErrorHandle?.closeFile()
        diagnosticMonitor.outputHandle?.closeFile()
    }

    func startDiagnosticMonitor(for bridgeProcess: Process, connectionID: UUID) {
        guard diagnosticMonitorProcess == nil,
              let monitorConfiguration = localTransportPolicy.diagnosticMonitor(
                  Int32(bridgeProcess.processIdentifier)
              ) else {
            return
        }

        let monitorProcess = Process()
        monitorProcess.executableURL = URL(fileURLWithPath: monitorConfiguration.executablePath)
        monitorProcess.arguments = monitorConfiguration.arguments

        let outputPipe = Pipe()
        monitorProcess.standardOutput = outputPipe
        if monitorConfiguration.combinesStandardError {
            monitorProcess.standardError = outputPipe
        }

        do {
            try monitorProcess.run()
        } catch {
            log("Unable to start local MCP diagnostic monitor: \(error.localizedDescription)")
            return
        }

        let outputHandle = outputPipe.fileHandleForReading
        do {
            try Self.makeNonBlocking(outputHandle)
        } catch {
            outputHandle.closeFile()
            if monitorProcess.isRunning {
                monitorProcess.terminate()
            }
            log("Unable to prepare local MCP diagnostic monitor: \(error.localizedDescription)")
            return
        }

        diagnosticMonitorProcess = monitorProcess
        diagnosticMonitorOutputHandle = outputHandle
        diagnosticMonitorConnectionID = connectionID
        diagnosticMonitorTask = Task.detached(name: "MCP local diagnostic reader") { [self] in
            await Self.diagnosticMonitorLoop(
                from: outputHandle,
                client: self,
                connectionID: connectionID
            )
        }
    }

    @discardableResult
    func stopDiagnosticMonitor() -> (task: Task<Void, Never>?, outputHandle: FileHandle?) {
        let task = diagnosticMonitorTask
        diagnosticMonitorTask = nil
        let outputHandle = diagnosticMonitorOutputHandle
        diagnosticMonitorOutputHandle = nil
        diagnosticMonitorConnectionID = nil
        task?.cancel()

        if let monitorProcess = diagnosticMonitorProcess,
           monitorProcess.isRunning {
            monitorProcess.terminate()
        }
        diagnosticMonitorProcess = nil
        return (task, outputHandle)
    }

    nonisolated static func resolvedExecutableURL(for configuration: MCPServerConfiguration) -> URL {
        let executablePath = configuration.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executablePath.isEmpty else {
            return URL(fileURLWithPath: configuration.executablePath)
        }

        if executablePath.contains("/") {
            return URL(fileURLWithPath: executablePath)
        }

        return DeveloperToolEnvironment.executableURL(named: executablePath)
            ?? URL(fileURLWithPath: executablePath)
    }

    /// A detached reader must be cancellable even if the bridge or one of its
    /// descendants keeps a pipe open. `read(2)` on a blocking descriptor is not
    /// reliably interrupted when another task closes that descriptor on macOS,
    /// so use a non-blocking descriptor and let the async loop observe
    /// cancellation between bounded polls.
    nonisolated static func makeNonBlocking(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let currentFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    nonisolated static func resolvedEnvironment(for configuration: MCPServerConfiguration) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in configuration.environment {
            environment[key] = value
        }
        return DeveloperToolEnvironment.processEnvironment(base: environment)
    }

    public func listTools() async throws -> MCPListToolsResult {
        if let httpTransport {
            return try await httpTransport.listTools()
        }

        try await connect()
        log("Starting tools/list request")
        let response = try await request(method: "tools/list", params: JSONValue.object([:]))
        return try response.decode(MCPListToolsResult.self)
    }

    public func callTool(named name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        if let httpTransport {
            return try await httpTransport.callTool(named: name, arguments: arguments)
        }

        try await connect()
        return try await request(
            method: "tools/call",
            params: JSONValue.object([
                "name": .string(name),
                "arguments": .object(arguments)
            ])
        )
    }

    private func request<Params: Encodable>(
        method: String,
        params: Params,
        onRequestWritten: (@Sendable () -> Void)? = nil
    ) async throws -> JSONValue {
        if let terminalBridgeError {
            throw terminalBridgeError
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let request = MCPRequest(
            jsonrpc: "2.0",
            id: .int(requestID),
            method: method,
            params: params
        )

        let payload = try JSONEncoder().encode(request)
        log("Request \(requestID) -> \(method): \(String(data: payload, encoding: .utf8) ?? "<non-utf8>")")

        let writeHandle = MCPCancellableTaskHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pendingResponses[requestID] = continuation
                pendingRequestMethods[requestID] = method

                // Writes are serialized and asynchronous (routed through the
                // writer actor outside this actor), so perform the write off the
                // synchronous continuation body. The response continuation is
                // already registered, so an early response is captured; on write
                // failure or cancellation we claim and resume it exactly once.
                //
                // The write runs in an UNSTRUCTURED task, which does not inherit
                // the caller's cancellation. Publish it to the handle so the
                // onCancel below can cancel it too; otherwise a cancelled request
                // would still be delivered to the bridge, which would execute a
                // tool call whose result nobody awaits.
                writeHandle.adopt(
                    Task(name: "MCP local request write") { [self] in
                        do {
                            try await self.write(payload)
                            onRequestWritten?()
                        } catch {
                            self.claimAndResumeResponse(id: requestID, with: .failure(error))
                        }
                    }
                )
            }
        } onCancel: {
            writeHandle.cancel()
            Task(name: "MCP local request cancellation") {
                await self.cancelPendingResponse(id: requestID)
            }
        }
    }

    private func notify(method: String) async throws {
        let notification = MCPNotificationWithoutParams(
            jsonrpc: "2.0",
            method: method
        )

        let payload = try JSONEncoder().encode(notification)
        log("Notification -> \(method): \(String(data: payload, encoding: .utf8) ?? "<non-utf8>")")
        try await write(payload)
    }

    private func notify<Params: Encodable>(method: String, params: Params) async throws {
        let notification = MCPNotification(
            jsonrpc: "2.0",
            method: method,
            params: params
        )

        let payload = try JSONEncoder().encode(notification)
        log("Notification -> \(method): \(String(data: payload, encoding: .utf8) ?? "<non-utf8>")")
        try await write(payload)
    }

    private func write(_ payload: Data) async throws {
        if let terminalBridgeError {
            throw terminalBridgeError
        }

        // Do not hand a payload to the writer for a request the caller already
        // abandoned: the bridge would still execute the tool call whose result
        // nobody awaits.
        try Task.checkCancellation()

        guard let writer else {
            throw MCPClientError.connectionClosed
        }

        guard let process else {
            throw MCPClientError.connectionClosed
        }

        guard process.isRunning else {
            throw exitError(for: process)
        }

        do {
            try await writer.enqueue(payload)
        } catch is CancellationError {
            // Don't mask cooperative cancellation as a bridge-exit error.
            throw CancellationError()
        } catch {
            log("Write failed: \(error.localizedDescription)")
            throw exitError(for: process)
        }
    }

    /// Atomically claims a pending response continuation (if still registered)
    /// and resumes it. Idempotent with `cancelPendingResponse(id:)` and
    /// `resumeAllPending(with:)`: whichever removes the entry first wins, so a
    /// continuation is never resumed twice across the write-failure and
    /// cancellation paths.
    private func claimAndResumeResponse(id: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pendingRequestMethods.removeValue(forKey: id)
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

/// Bridges cooperative cancellation onto an unstructured task created inside a
/// `withCheckedThrowingContinuation` body.
///
/// Such a task does not inherit the caller's cancellation, so a cancelled MCP
/// request would otherwise still be written to the bridge. The handle also
/// records a cancellation that happens before the task is published, so the
/// adopted task is cancelled immediately in that race.
final class MCPCancellableTaskHandle: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var isCancelled = false
    }
    private let state = Mutex(State())

    func adopt(_ task: Task<Void, Never>) {
        let shouldCancelImmediately = state.withLock { state -> Bool in
            guard !state.isCancelled else { return true }
            state.task = task
            return false
        }
        if shouldCancelImmediately {
            task.cancel()
        }
    }

    func cancel() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isCancelled = true
            let pending = state.task
            state.task = nil
            return pending
        }
        task?.cancel()
    }
}
#endif
