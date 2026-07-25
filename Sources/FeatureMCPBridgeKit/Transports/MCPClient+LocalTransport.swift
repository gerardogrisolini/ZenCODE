//
//  MCPClient+LocalTransport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#endif
import Dispatch
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
            Task {
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
            await disconnect()
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
            await disconnect()
            throw error
        }
        readLoopTask = Task.detached { [self] in
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
            await disconnect()
            throw error
        }
        errorLoopTask = Task.detached { [self] in
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
                            Task { [self] in
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
                    Task {
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
            await disconnect()
            throw error
        }
    }

    public func disconnect() async {
        if let httpTransport {
            await httpTransport.disconnect()
            return
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
        diagnosticMonitorTask = Task.detached { [self] in
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
                    Task { [self] in
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
            Task {
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

/// Serialized, non-blocking writer for a local MCP bridge's stdin.
///
/// All writes are funneled through a single detached consumer task that drains
/// an `AsyncStream`, so exactly one frame is ever in flight on the descriptor at
/// a time: concurrent producers cannot interleave bytes even though an
/// individual write suspends on back-pressure. Because the descriptor is
/// non-blocking, a full pipe yields async back-pressure (`Task.sleep` on
/// `EAGAIN`) instead of blocking a thread; `MCPClient` merely awaits the job's
/// continuation and stays free to run `disconnect()` or cancellation handlers.
struct MCPLocalTransportWriter: Sendable {
    /// Only the job identity travels through the stream. The continuation itself
    /// is owned by `registry`, never by the stream buffer — see the registry's
    /// documentation for why that distinction is what prevents the teardown leak.
    private struct Job: Sendable {
        let id: UInt64
        let payload: Data
    }

    /// Grace granted to a frame that was ALREADY partially written when teardown
    /// began. In normal operation a started frame is never truncated; during
    /// teardown the peer may be gone for good (a descendant can keep the read end
    /// open without ever draining it), so the wait must be finite.
    static let defaultTeardownFrameGraceNanoseconds: UInt64 = 500_000_000
    /// Back-pressure poll interval. Deliberately not a busy loop.
    private static let backPressurePollNanoseconds: UInt64 = 1_000_000

    private let task: Task<Void, Never>
    private let sink: AsyncStream<Job>.Continuation
    /// The single owner of every unresolved job continuation. Boxed in a class
    /// because `Mutex` is non-copyable while this writer is a value type shared
    /// by copy between the actor and its detached consumer.
    private let registry = MCPLocalTransportWriterJobRegistry()
    /// Sole holder of the stdin descriptor. Every syscall goes through it, so
    /// detaching it is what makes closing the FD safe — independently of whether
    /// the consumer task has finished unwinding.
    private let gate: MCPLocalTransportWriterDescriptorGate

    init(
        fileDescriptor: Int32,
        teardownFrameGraceNanoseconds: UInt64 = MCPLocalTransportWriter
            .defaultTeardownFrameGraceNanoseconds
    ) {
        let (stream, continuation) = AsyncStream<Job>.makeStream()
        sink = continuation
        let registry = self.registry
        let gate = MCPLocalTransportWriterDescriptorGate(descriptor: fileDescriptor)
        self.gate = gate
        task = Task.detached {
            var writeFailure: Error?
            for await job in stream {
                // Claim the job FOR WRITING. `nil` means it is no longer
                // writable: a cancelled request withdrew it while it was still
                // queued, a terminated yield reclaimed it, or the final drain
                // below already concluded it. In every case the payload must not
                // reach the wire and its continuation must not be resumed twice.
                guard let result = registry.claimForWrite(job.id) else {
                    continue
                }
                // From here the job is in flight: this loop owns `result` and no
                // cancellation may withdraw it any more, which is what keeps a
                // started frame from being truncated mid-write.
                defer { registry.completeInFlight(job.id) }
                // Once teardown has begun (or the writer task was cancelled),
                // stop writing but keep draining so buffered jobs fail fast
                // instead of riding on a descriptor that is about to close.
                if let writeFailure {
                    result.resume(throwing: writeFailure)
                    continue
                }
                if Task.isCancelled || registry.isTearingDown {
                    let error = CancellationError()
                    writeFailure = error
                    result.resume(throwing: error)
                    continue
                }
                do {
                    try await Self.writeAllNonBlocking(
                        MCPTransportCodec.frame(job.payload),
                        through: gate,
                        registry: registry,
                        teardownFrameGraceNanoseconds: teardownFrameGraceNanoseconds
                    )
                    result.resume()
                } catch {
                    // A failed descriptor stays failed: fail the remaining
                    // buffered jobs with the same error instead of retrying a
                    // write that cannot succeed.
                    writeFailure = error
                    result.resume(throwing: error)
                }
            }

            // A cancelled `for await` over an AsyncStream stops delivering
            // immediately and DROPS whatever is still buffered, so `finish()`
            // followed by `cancel()` (exactly what disconnect() does) can end the
            // loop with jobs still queued. Because the registry — not the stream
            // — owns those continuations, they are still reachable here and are
            // concluded before the task ends. This runs synchronously and without
            // an `await` on purpose: it must complete even though the task is
            // already cancelled, which is what makes `join()` a real guarantee
            // that no continuation stays suspended and the FD can be closed.
            let abandoned = registry.drainQueued()
            let terminalError = writeFailure ?? CancellationError()
            for result in abandoned {
                result.resume(throwing: terminalError)
            }
        }
    }

    /// Enqueues `payload` for serialized writing and suspends until it has been
    /// fully written (or fails).
    ///
    /// Cancelling the caller WITHDRAWS the job as long as it is still queued, so
    /// a cancelled MCP request never reaches the bridge even when the writer is
    /// wedged on a full pipe and the job was already buffered by the stream.
    /// Once the consumer claimed the job for writing, withdrawal deliberately
    /// fails: the frame is completed instead of being truncated on the wire.
    func enqueue(_ payload: Data) async throws {
        try Task.checkCancellation()
        // The job id only exists inside the continuation body, so publish it on a
        // ticket that the cancellation handler can read (and that records a
        // cancellation arriving before registration).
        let ticket = MCPLocalTransportWriterJobTicket()
        let registry = self.registry
        let sink = self.sink
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Register first: from this point the registry is the single owner
                // of the continuation, so every exit path below (rejection,
                // withdrawal, dropped yield, consumer drain, teardown) resolves it
                // exactly once, and none of them can resolve it twice.
                guard let id = registry.register(continuation) else {
                    // Teardown already started; the job could never be drained.
                    continuation.resume(throwing: CancellationError())
                    return
                }

                // Cancellation that fired before the id was published must still
                // withdraw the job, otherwise it would ride to the bridge.
                guard ticket.adopt(id) else {
                    registry.withdrawIfQueued(id)?.resume(throwing: CancellationError())
                    return
                }

                // If the stream has already been finished, `yield` discards the job
                // without delivering it. Claim it back and fail it ourselves so the
                // awaiting caller cannot hang forever.
                if case .terminated = sink.yield(Job(id: id, payload: payload)) {
                    registry.withdrawIfQueued(id)?.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            // Withdraw only while queued. `withdrawIfQueued` returns nil once the
            // consumer owns the job, so an already-started frame is never cut
            // short; the consumer resumes that caller when the frame completes.
            guard let id = ticket.cancel() else {
                return
            }
            registry.withdrawIfQueued(id)?.resume(throwing: CancellationError())
        }
    }

    /// Number of jobs the consumer currently owns for writing, i.e. frames that
    /// may already be partially on the wire and are therefore NOT withdrawable.
    /// Exposed so the cancellation invariants can be asserted directly.
    var inFlightJobCount: Int {
        registry.inFlightCount
    }

    /// Jobs registered but not yet claimed by the consumer: still withdrawable.
    var queuedJobCount: Int {
        registry.queuedCount
    }

    /// `true` once a frame is provably wedged: it has already put bytes on the
    /// wire AND has hit at least one `EAGAIN`. Tests await this instead of
    /// sleeping, which makes the "writer stuck on a full pipe" precondition a
    /// deterministic happens-before edge rather than a timing assumption.
    var didStallInFlightFrame: Bool {
        registry.didStallInFlightFrame
    }

    /// `true` while this writer may still issue a `write()` on its descriptor.
    /// Becomes `false` permanently once teardown detached it, which is the exact
    /// condition that makes closing/recycling the FD safe.
    var isDescriptorValid: Bool {
        gate.isValid
    }

    /// Stops accepting new jobs. Buffered jobs are still concluded by the
    /// consumer task (draining normally, or failing whatever remains in the
    /// registry when cancellation cut the drain short).
    ///
    /// This also arms the teardown deadline for a frame that is ALREADY on the
    /// wire: from here that frame gets a finite grace window instead of waiting
    /// for pipe capacity forever. Without it, a bridge that exited while a
    /// descendant still holds the read end open (and never drains it) would wedge
    /// the write on `EAGAIN` permanently and make `join()` non-terminating.
    func finish() {
        registry.beginTeardown()
        sink.finish()
    }

    func cancel() {
        // Cancelling the consumer IS a teardown signal: it must also arm the
        // deadline for a frame already on the wire. Otherwise `cancel()` without
        // `finish()` would leave a wedged frame waiting for pipe capacity that a
        // dead peer will never provide, and `join()` would never return.
        registry.beginTeardown()
        task.cancel()
    }

    func join() async {
        await task.value
    }

    /// Detaches the descriptor from the writer, permanently and idempotently.
    ///
    /// After this returns, no code path of this writer can ever issue another
    /// `write()` on that FD — including a consumer that is still unwinding. That
    /// is what makes closing (and letting the OS recycle) the descriptor safe
    /// WITHOUT first awaiting `join()`, which is exactly the dependency that
    /// could deadlock teardown.
    func invalidateDescriptor() {
        gate.invalidate()
    }

    /// Bounded teardown: stop accepting jobs, cancel the consumer, then wait for
    /// the consumer only up to `timeoutNanoseconds`.
    ///
    /// Returns `true` when the consumer finished on its own. On `false` the
    /// descriptor has still been detached and every registry-owned continuation
    /// has still been concluded, so the caller may close the FD immediately: the
    /// straggler can no longer touch it, it can only observe the closed gate and
    /// exit. Process teardown therefore always terminates.
    @discardableResult
    func shutdown(
        timeoutNanoseconds: UInt64 = MCPLocalTransportWriter.defaultTeardownFrameGraceNanoseconds * 2
    ) async -> Bool {
        finish()
        cancel()

        // Race "consumer finished" against a deadline. Both arms run on DETACHED
        // tasks so neither is shortened by a caller that is itself already
        // cancelled, and the outcome is published through a one-shot box so the
        // waiter is resumed exactly once and never waits for the loser.
        let outcome = MCPLocalTransportWriterDeadlineBox()
        let consumer = task
        Task.detached {
            await consumer.value
            outcome.resolve(completed: true)
        }
        Task.detached {
            await MCPLocalTransportWriter.sleepIgnoringCancellation(
                nanoseconds: timeoutNanoseconds
            )
            outcome.resolve(completed: false)
        }
        let completed = await outcome.value()

        // Whatever the outcome, the descriptor is now unreachable for this
        // writer and no continuation may stay suspended.
        gate.invalidate()
        let stragglers = registry.drainQueued()
        for straggler in stragglers {
            straggler.resume(throwing: CancellationError())
        }
        return completed
    }

    /// Suspends for `nanoseconds` WITHOUT observing cancellation.
    ///
    /// `Task.sleep` on an already-cancelled task returns immediately, which turns
    /// a "retry after a short pause" loop into a CPU spin. Teardown back-pressure
    /// and the teardown deadline both run on cancelled tasks by construction, so
    /// they must not be shortened by cancellation.
    static func sleepIgnoringCancellation(nanoseconds: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let deadline = DispatchTime.now() + .nanoseconds(Int(clamping: nanoseconds))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                continuation.resume()
            }
        }
    }

    /// Writes `payload` fully through `gate`, on a non-blocking descriptor. On
    /// `EAGAIN`/`EWOULDBLOCK` it suspends briefly (async back-pressure) instead of
    /// busy-spinning or blocking a thread. `errno` is captured inside the
    /// `withUnsafeBytes` body so it cannot be reset before it is inspected.
    ///
    /// Cancellation is honoured before the first byte of the frame reaches the
    /// pipe: aborting mid-frame would leave a truncated JSON-RPC message on the
    /// bridge's stdin and corrupt the wire format for every later message.
    ///
    /// A started frame is therefore never truncated in normal operation. It is
    /// only abandoned when BOTH conditions hold: teardown has begun and the pipe
    /// stayed full for the whole grace window — i.e. the peer is gone and the
    /// framing no longer has a consumer to corrupt. Safe process exit wins over
    /// wire purity at that point, and the abandonment is reported as an error so
    /// the caller's continuation is resolved rather than left suspended.
    private static func writeAllNonBlocking(
        _ payload: Data,
        through gate: MCPLocalTransportWriterDescriptorGate,
        registry: MCPLocalTransportWriterJobRegistry,
        teardownFrameGraceNanoseconds: UInt64
    ) async throws {
        var totalWritten = 0
        // Grace is measured from the moment teardown is first OBSERVED while this
        // frame is stalled, not from the start of the write, so a healthy slow
        // consumer is never cut off.
        var teardownStallDeadline: DispatchTime?
        while totalWritten < payload.count {
            if totalWritten == 0 {
                try Task.checkCancellation()
            }
            let outcome = try gate.withDescriptor { fileDescriptor in
                payload.withUnsafeBytes { rawBuffer -> (written: ssize_t, capturedErrno: Int32) in
                    guard let base = rawBuffer.baseAddress else {
                        return (written: 0, capturedErrno: 0)
                    }
                    let remaining = rawBuffer.count - totalWritten
                    let written = Darwin.write(
                        fileDescriptor,
                        base.advanced(by: totalWritten),
                        remaining
                    )
                    return (written: written, capturedErrno: written == -1 ? errno : 0)
                }
            }
            switch outcome.written {
            case 1...:
                totalWritten += Int(outcome.written)
                // Progress resets the stall budget: a draining peer is alive.
                teardownStallDeadline = nil
            case 0:
                throw POSIXError(.EIO)
            case -1:
                switch outcome.capturedErrno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    // A cancelled writer must still be able to leave before the
                    // first byte: nothing is on the wire yet.
                    if totalWritten == 0, Task.isCancelled || registry.isTearingDown {
                        throw CancellationError()
                    }
                    // Publish the wedged state: frame started AND pipe full.
                    registry.noteInFlightStall()
                    if registry.isTearingDown {
                        let now = DispatchTime.now()
                        let deadline = teardownStallDeadline ?? now + .nanoseconds(
                            Int(clamping: teardownFrameGraceNanoseconds)
                        )
                        teardownStallDeadline = deadline
                        if now >= deadline {
                            // The peer never drained within the grace window;
                            // abandoning the frame is what keeps teardown bounded.
                            throw MCPLocalTransportWriterError.teardownAbandonedFrame
                        }
                    }
                    // Uninterruptible on purpose: `try? await Task.sleep` on an
                    // already-cancelled task returns instantly and turns this
                    // retry loop into a CPU spin.
                    await sleepIgnoringCancellation(
                        nanoseconds: backPressurePollNanoseconds
                    )
                    continue
                default:
                    throw POSIXError(POSIXErrorCode(rawValue: outcome.capturedErrno) ?? .EIO)
                }
            default:
                throw POSIXError(.EIO)
            }
        }
    }
}

/// Failures specific to the local writer's bounded teardown.
enum MCPLocalTransportWriterError: Error, Equatable {
    /// A partially written frame was abandoned because teardown had begun and the
    /// peer did not drain the pipe within the grace window.
    case teardownAbandonedFrame
    /// The descriptor was detached (teardown completed) before this write.
    case descriptorClosed
}

/// Resolves a bounded wait exactly once, whichever racer wins.
///
/// The waiter is resumed by the FIRST of "consumer finished" / "deadline
/// elapsed" and never observes the loser, so a wedged consumer cannot keep the
/// waiter suspended and the late racer cannot double-resume it.
private final class MCPLocalTransportWriterDeadlineBox: Sendable {
    private struct State {
        var completed: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    /// Publishes the outcome. Only the first call resumes the waiter.
    func resolve(completed: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.completed == nil else { return nil }
            state.completed = completed
            let pending = state.waiter
            state.waiter = nil
            return pending
        }
        waiter?.resume(returning: completed)
    }

    /// Suspends until the first racer resolves the box. Returns immediately when
    /// the outcome was already published (the resolve-before-await race).
    func value() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resolved = state.withLock { state -> Bool? in
                if let completed = state.completed {
                    return completed
                }
                state.waiter = continuation
                return nil
            }
            if let resolved {
                continuation.resume(returning: resolved)
            }
        }
    }
}

/// Sole holder of the local bridge's stdin descriptor.
///
/// Every `write()` of the writer is issued inside `withDescriptor`, under a lock,
/// and only while the gate is still valid. `invalidate()` therefore establishes a
/// hard happens-before edge: once it returns, no write can be in progress and no
/// further write can ever start. That is what allows the owner to close the FD
/// without first joining the consumer task — the ordering constraint that made
/// teardown deadlock-prone when a wedged frame could not finish.
private final class MCPLocalTransportWriterDescriptorGate: Sendable {
    private struct State {
        var descriptor: Int32
        var isValid: Bool
    }

    private let state: Mutex<State>

    init(descriptor: Int32) {
        state = Mutex(State(descriptor: descriptor, isValid: true))
    }

    var isValid: Bool {
        state.withLock { $0.isValid }
    }

    /// Runs `body` with the descriptor while the gate is valid. Throws
    /// `descriptorClosed` once teardown detached it, so a straggling consumer
    /// fails fast instead of writing on a closed — or recycled — FD.
    func withDescriptor<T>(_ body: (Int32) -> T) throws -> T {
        try state.withLock { state -> T in
            guard state.isValid else {
                throw MCPLocalTransportWriterError.descriptorClosed
            }
            return body(state.descriptor)
        }
    }

    /// Permanently detaches the descriptor. Idempotent.
    func invalidate() {
        state.withLock { $0.isValid = false }
    }
}

/// Sole owner of the unresolved job continuations of `MCPLocalTransportWriter`.
///
/// Continuations are deliberately kept OUT of the `AsyncStream` buffer. A
/// cancelled `for await` drops buffered elements without delivering them, so a
/// continuation stored inside a `Job` would silently vanish during
/// `finish()` + `cancel()` and hang its caller forever. Holding them here keeps
/// them reachable no matter how the consumer loop ends.
///
/// The registry also tracks the job LIFECYCLE, which is what makes cancellation
/// safe on a byte stream:
/// - `queued`: registered, possibly buffered by the stream, no byte written.
///   Withdrawable, so a cancelled request never reaches the bridge.
/// - `inFlight`: claimed by the consumer, which may already have written part of
///   the frame. NOT withdrawable — truncating it would corrupt the wire format
///   for every later message.
///
/// Each transition is an exactly-once handoff: whoever receives the continuation
/// back owns resuming it, and every other site gets `nil`. A class box is
/// required because `Mutex` is non-copyable while the writer is a `Sendable`
/// value type copied between the actor and its detached consumer.
private final class MCPLocalTransportWriterJobRegistry: Sendable {
    private struct State {
        var nextID: UInt64 = 0
        /// Registered but not yet claimed by the consumer: withdrawable.
        var queued: [UInt64: CheckedContinuation<Void, Error>] = [:]
        /// Claimed by the consumer and possibly partially written: not
        /// withdrawable. Tracked so `drainQueued` can never double-resume a job
        /// the consumer still owns.
        var inFlight: Set<UInt64> = []
        /// Set once a frame that is already partially on the wire has observed at
        /// least one `EAGAIN`. Exposed so tests can synchronize on the REAL
        /// wedged state (frame started + pipe full) instead of a timing guess.
        var didStallInFlightFrame = false
        var isTearingDown = false
    }

    private let state = Mutex(State())

    var isTearingDown: Bool {
        state.withLock { $0.isTearingDown }
    }

    /// `true` once a partially written frame had to wait for pipe capacity.
    var didStallInFlightFrame: Bool {
        state.withLock { $0.didStallInFlightFrame }
    }

    /// Records that an in-flight frame is waiting for pipe capacity.
    func noteInFlightStall() {
        state.withLock { $0.didStallInFlightFrame = true }
    }

    /// Jobs claimed by the consumer and possibly partially written.
    var inFlightCount: Int {
        state.withLock { $0.inFlight.count }
    }

    /// Registered but not yet claimed: still withdrawable.
    var queuedCount: Int {
        state.withLock { $0.queued.count }
    }

    /// Takes ownership of `continuation`, returning its job id, or `nil` when
    /// teardown already started and the job could never be drained.
    func register(_ continuation: CheckedContinuation<Void, Error>) -> UInt64? {
        state.withLock { state -> UInt64? in
            guard !state.isTearingDown else { return nil }
            state.nextID &+= 1
            let id = state.nextID
            state.queued[id] = continuation
            return id
        }
    }

    /// Moves a job from `queued` to `inFlight` and hands its continuation to the
    /// consumer, or returns `nil` when the job was already withdrawn (cancelled
    /// request, terminated yield) or swept by teardown. Exactly one caller can
    /// ever receive a given continuation: a job that is already in flight is
    /// never handed out a second time.
    func claimForWrite(_ id: UInt64) -> CheckedContinuation<Void, Error>? {
        state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard !state.inFlight.contains(id),
                  let continuation = state.queued.removeValue(forKey: id) else {
                return nil
            }
            state.inFlight.insert(id)
            return continuation
        }
    }

    /// Releases the in-flight marker after the consumer resumed the job.
    func completeInFlight(_ id: UInt64) {
        _ = state.withLock { $0.inFlight.remove(id) }
    }

    /// Withdraws a job that has NOT started writing, returning its continuation
    /// so the canceller can fail it. Returns `nil` once the consumer claimed it
    /// for writing, which is what keeps a partially written frame intact.
    func withdrawIfQueued(_ id: UInt64) -> CheckedContinuation<Void, Error>? {
        state.withLock { $0.queued.removeValue(forKey: id) }
    }

    /// Marks teardown so no further job is accepted.
    func beginTeardown() {
        state.withLock { $0.isTearingDown = true }
    }

    /// Claims every job still queued, for the consumer's final sweep. In-flight
    /// jobs are intentionally excluded: the consumer loop already owns their
    /// continuations and resumes them itself.
    func drainQueued() -> [CheckedContinuation<Void, Error>] {
        state.withLock { state -> [CheckedContinuation<Void, Error>] in
            state.isTearingDown = true
            let queued = Array(state.queued.values)
            state.queued.removeAll()
            return queued
        }
    }
}

/// Publishes a writer job id to its own cancellation handler.
///
/// `enqueue` only learns the job id inside the continuation body, while the
/// `onCancel` handler runs outside it and may fire BEFORE registration. The
/// ticket closes that race: a cancellation that arrives first makes `adopt`
/// return `false`, so the registering side withdraws the job itself.
private final class MCPLocalTransportWriterJobTicket: Sendable {
    private struct State {
        var id: UInt64?
        var isCancelled = false
    }

    private let state = Mutex(State())

    /// Publishes `id`, or returns `false` when cancellation already fired and the
    /// caller must withdraw the job itself.
    func adopt(_ id: UInt64) -> Bool {
        state.withLock { state -> Bool in
            guard !state.isCancelled else { return false }
            state.id = id
            return true
        }
    }

    /// Returns the job id to withdraw, exactly once, or `nil` when no id was
    /// published yet (the registering side will observe the cancellation).
    func cancel() -> UInt64? {
        state.withLock { state -> UInt64? in
            state.isCancelled = true
            let id = state.id
            state.id = nil
            return id
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
