//
//  FeaturePersistentProcess.swift
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

/// A session-scoped subprocess for a feature that explicitly supports
/// `FeaturePersistentService` (`--serve`).
///
/// The actor owns the process and all pipe endpoints. Requests are serialized,
/// stdout and stderr are drained concurrently, and an EOF/child exit invalidates
/// only this session so the next request can start a clean child. There is no
/// global registry or on-disk state.
public actor FeaturePersistentProcess {
    private static let maximumResponseFrameBytes = 32 * 1024 * 1024
    private static let maximumDiagnosticBytes = 65_536

    private let executableURL: URL
    private let workingDirectory: URL?
    private let environment: [String: String]?

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var exitMonitor: FeatureProcessExitMonitor?
    private var stdoutReader: Task<Void, Never>?
    private var stderrReader: Task<Void, Never>?
    private var generation: UUID?
    private var stdoutBuffer = Data()
    private var stderrTail = Data()

    private var pendingResponse: PendingResponse?
    private var isPerformingRequest = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var isClosing = false

    private struct PendingResponse {
        let id: UUID
        let continuation: CheckedContinuation<Data, Error>
    }

    /// Reader tasks must not retain their owner for the lifetime of the child;
    /// otherwise the actor and its task properties form a cycle and `deinit`
    /// can never close an abandoned session.
    private final class WeakOwner: Sendable {
        weak let value: FeaturePersistentProcess?

        init(_ value: FeaturePersistentProcess) {
            self.value = value
        }
    }

    public init(
        executableURL: URL,
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.environment = environment
    }

    deinit {
        stdoutReader?.cancel()
        stderrReader?.cancel()
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        if let process, process.isRunning {
            Self.killImmediately(process)
        }
    }

    /// The PID of the currently connected feature process, exposed primarily
    /// for diagnostics and deterministic lifecycle tests.
    public var processIdentifier: Int32? {
        guard let process, process.isRunning else {
            return nil
        }
        return process.processIdentifier
    }

    /// Sends one request and returns the exact response bytes from the
    /// equivalent one-shot feature command.
    public func response(
        to request: FeaturePersistentRequest,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        guard !isClosing else {
            throw transportError(kind: .closed, message: "Feature persistent session is closing.")
        }

        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        guard !isClosing else {
            throw transportError(kind: .closed, message: "Feature persistent session is closing.")
        }
        try Task.checkCancellation()

        do {
            return try await exchange(request, timeout: timeout)
        } catch {
            if shouldInvalidate(after: error) {
                await closeCurrentProcess(
                    failure: transportError(
                        kind: .closed,
                        message: "Feature persistent session was reset after a transport failure."
                    )
                )
            }
            throw error
        }
    }

    /// Gracefully asks an idle feature process to stop, then closes every pipe
    /// and force-terminates it if it did not exit. An in-flight request is
    /// interrupted instead of waiting forever during session teardown.
    public func shutdown() async {
        guard !isClosing else {
            return
        }
        isClosing = true

        guard process != nil, !isPerformingRequest else {
            await closeCurrentProcess(
                failure: transportError(kind: .closed, message: "Feature persistent session closed.")
            )
            return
        }

        let request = FeaturePersistentRequest(operation: .shutdown)
        _ = try? await exchange(request, timeout: 3, canStartProcess: false)
        await closeCurrentProcess(
            failure: transportError(kind: .closed, message: "Feature persistent session closed.")
        )
    }

    private func acquireRequestSlot() async {
        guard isPerformingRequest else {
            isPerformingRequest = true
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        if let continuation = requestWaiters.first {
            requestWaiters.removeFirst()
            continuation.resume()
        } else {
            isPerformingRequest = false
        }
    }

    private func exchange(
        _ request: FeaturePersistentRequest,
        timeout: TimeInterval?,
        canStartProcess: Bool = true
    ) async throws -> Data {
        try await ensureProcess(canStartProcess: canStartProcess)
        guard let generation else {
            throw transportError(kind: .unavailable, message: "Feature process did not start.")
        }

        stderrTail.removeAll(keepingCapacity: true)
        let payload = try FeatureProcessProtocol.renderJSON(request)
        let framedPayload = payload + Data("\n".utf8)

        if let timeout, timeout > 0 {
            do {
                return try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { [self] in
                        try await self.sendAndAwait(
                            requestID: request.id,
                            payload: framedPayload,
                            generation: generation
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw FeaturePersistentProcessError(
                            kind: .timedOut,
                            message: "Feature persistent request timed out."
                        )
                    }
                    defer { group.cancelAll() }
                    guard let response = try await group.next() else {
                        throw self.transportError(
                            kind: .closed,
                            message: "Feature persistent request ended without a response."
                        )
                    }
                    return response
                }
            } catch let error as FeaturePersistentProcessError where error.kind == .timedOut {
                throw transportError(kind: .timedOut, message: error.message)
            }
        }

        return try await sendAndAwait(
            requestID: request.id,
            payload: framedPayload,
            generation: generation
        )
    }

    private func ensureProcess(canStartProcess: Bool) async throws {
        if canStartProcess, isClosing {
            throw transportError(kind: .closed, message: "Feature persistent session is closing.")
        }
        if let process, process.isRunning, generation != nil {
            return
        }
        guard canStartProcess else {
            throw transportError(kind: .closed, message: "Feature persistent process is no longer running.")
        }
        await closeCurrentProcess(
            failure: transportError(kind: .closed, message: "Feature process exited before the request started.")
        )
        guard !isClosing else {
            throw transportError(kind: .closed, message: "Feature persistent session is closing.")
        }
        try startProcess()
    }

    private func startProcess() throws {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--serve"]
        process.currentDirectoryURL = workingDirectory
        if let environment {
            process.environment = environment
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let newGeneration = UUID()
        let monitor = FeatureProcessExitMonitor { [weak self] exitCode in
            Task(name: "Persistent feature process exit") {
                await self?.processExited(exitCode: exitCode, generation: newGeneration)
            }
        }
        monitor.install(on: process)

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }
        monitor.startMonitoring(processID: process.processIdentifier)

        let inputHandle = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        Self.setNonBlocking(inputHandle.fileDescriptor)
        Self.setNonBlocking(outputHandle.fileDescriptor)
        Self.setNonBlocking(errorHandle.fileDescriptor)

        self.process = process
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        self.exitMonitor = monitor
        self.generation = newGeneration
        self.stdoutBuffer.removeAll(keepingCapacity: true)
        self.stderrTail.removeAll(keepingCapacity: true)

        let weakOwner = WeakOwner(self)
        stdoutReader = Task.detached(name: "Persistent feature stdout reader") {
            await Self.readLoop(
                descriptor: outputHandle.fileDescriptor,
                stream: .stdout,
                owner: weakOwner,
                generation: newGeneration
            )
        }
        stderrReader = Task.detached(name: "Persistent feature stderr reader") {
            await Self.readLoop(
                descriptor: errorHandle.fileDescriptor,
                stream: .stderr,
                owner: weakOwner,
                generation: newGeneration
            )
        }
        #else
        throw transportError(kind: .unavailable, message: "Persistent feature processes are unavailable on this platform.")
        #endif
    }

    private func sendAndAwait(
        requestID: UUID,
        payload: Data,
        generation: UUID
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pendingResponse == nil else {
                    continuation.resume(throwing: transportError(
                        kind: .closed,
                        message: "Feature persistent request serialization was violated."
                    ))
                    return
                }
                pendingResponse = PendingResponse(id: requestID, continuation: continuation)
                Task(name: "Persistent feature request write") { [weak self] in
                    guard let self else {
                        return
                    }
                    do {
                        try await self.writePayload(payload, generation: generation)
                    } catch {
                        await self.failPendingRequest(
                            id: requestID,
                            error: self.transportError(
                                kind: .closed,
                                message: "Unable to write to feature persistent process: \(error.localizedDescription)"
                            )
                        )
                    }
                }
            }
        } onCancel: {
            Task(name: "Persistent feature request cancellation") { [weak self] in
                await self?.failPendingRequest(
                    id: requestID,
                    error: FeaturePersistentProcessError(
                        kind: .closed,
                        message: "Feature persistent request was cancelled."
                    )
                )
            }
        }
    }

    private func writePayload(_ payload: Data, generation: UUID) async throws {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        guard self.generation == generation,
              let inputHandle else {
            throw transportError(kind: .closed, message: "Feature persistent process is not connected.")
        }

        let descriptor = inputHandle.fileDescriptor
        var offset = 0
        while offset < payload.count {
            try Task.checkCancellation()
            guard self.generation == generation else {
                throw transportError(kind: .closed, message: "Feature persistent process was replaced during write.")
            }

            let bytesWritten = payload.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return 0
                }
                return write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
            }
            if bytesWritten > 0 {
                offset += bytesWritten
                continue
            }

            let capturedErrno = errno
            if capturedErrno == EINTR {
                continue
            }
            if capturedErrno == EAGAIN || capturedErrno == EWOULDBLOCK {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
        }
        #else
        _ = payload
        _ = generation
        throw transportError(kind: .unavailable, message: "Persistent feature processes are unavailable on this platform.")
        #endif
    }

    private enum Stream {
        case stdout
        case stderr
    }

    private nonisolated static func readLoop(
        descriptor: Int32,
        stream: Stream,
        owner: WeakOwner,
        generation: UUID
    ) async {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var scratch = [UInt8](repeating: 0, count: 16_384)
        while !Task.isCancelled {
            let bytesRead = scratch.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return 0
                }
                return read(descriptor, baseAddress, rawBuffer.count)
            }
            if bytesRead > 0 {
                await owner.value?.received(
                    Data(scratch[0 ..< bytesRead]),
                    from: stream,
                    generation: generation
                )
                continue
            }
            if bytesRead == 0 {
                await owner.value?.streamClosed(stream, generation: generation)
                return
            }

            let capturedErrno = errno
            if capturedErrno == EINTR {
                continue
            }
            if capturedErrno == EAGAIN || capturedErrno == EWOULDBLOCK {
                do {
                    // Readers remain alive for the whole agent session; avoid a
                    // high-frequency idle wake-up loop while retaining low
                    // interactive response latency.
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return
                }
                continue
            }

            await owner.value?.streamFailed(
                stream,
                message: POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
                    .localizedDescription,
                generation: generation
            )
            return
        }
        #else
        _ = descriptor
        _ = stream
        _ = owner
        _ = generation
        #endif
    }

    private func received(_ chunk: Data, from stream: Stream, generation: UUID) {
        guard self.generation == generation else {
            return
        }
        if stream == .stderr {
            appendDiagnostic(chunk)
            return
        }

        stdoutBuffer.append(chunk)
        guard stdoutBuffer.count <= Self.maximumResponseFrameBytes else {
            failCurrentRequest(
                transportError(kind: .malformedResponse, message: "Feature persistent response exceeded the frame limit.")
            )
            return
        }

        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let frame = stdoutBuffer.subdata(in: stdoutBuffer.startIndex ..< newline)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex ... newline)
            guard !frame.isEmpty else {
                continue
            }
            guard let response = try? JSONDecoder().decode(FeaturePersistentResponse.self, from: frame) else {
                failCurrentRequest(
                    transportError(kind: .malformedResponse, message: "Feature persistent process returned an invalid response frame.")
                )
                return
            }
            guard response.id == pendingResponse?.id else {
                continue
            }
            let pending = pendingResponse
            pendingResponse = nil
            if let error = response.error, !error.isEmpty {
                pending?.continuation.resume(throwing: transportError(kind: .remote, message: error))
            } else if let responseData = response.responseData {
                pending?.continuation.resume(returning: responseData)
            } else {
                pending?.continuation.resume(throwing: transportError(
                    kind: .malformedResponse,
                    message: "Feature persistent response did not include a payload."
                ))
            }
        }
    }

    private func streamClosed(_ stream: Stream, generation: UUID) {
        guard self.generation == generation else {
            return
        }
        guard stream == .stdout else {
            return
        }
        failCurrentRequest(
            transportError(kind: .closed, message: "Feature persistent process closed stdout unexpectedly.")
        )
    }

    private func streamFailed(_ stream: Stream, message: String, generation: UUID) {
        guard self.generation == generation else {
            return
        }
        if stream == .stderr {
            appendDiagnostic(Data(message.utf8))
            return
        }
        failCurrentRequest(
            transportError(
                kind: .closed,
                message: "Feature persistent stdout reader failed: \(message)"
            )
        )
    }

    private func processExited(exitCode: Int32, generation: UUID) {
        guard self.generation == generation else {
            return
        }
        failCurrentRequest(
            transportError(
                kind: .closed,
                message: "Feature persistent process exited unexpectedly with status \(exitCode)."
            )
        )
    }

    private func failPendingRequest(id: UUID, error: Error) {
        guard pendingResponse?.id == id else {
            return
        }
        failCurrentRequest(error)
    }

    private func failCurrentRequest(_ error: Error) {
        let pending = pendingResponse
        pendingResponse = nil
        pending?.continuation.resume(throwing: error)
    }

    private func appendDiagnostic(_ chunk: Data) {
        stderrTail.append(chunk)
        if stderrTail.count > Self.maximumDiagnosticBytes {
            stderrTail = Data(stderrTail.suffix(Self.maximumDiagnosticBytes))
        }
    }

    private func transportError(
        kind: FeaturePersistentProcessError.Kind,
        message: String
    ) -> FeaturePersistentProcessError {
        FeaturePersistentProcessError(
            kind: kind,
            message: message,
            stderr: String(decoding: stderrTail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func shouldInvalidate(after error: Error) -> Bool {
        guard let transportError = error as? FeaturePersistentProcessError else {
            return true
        }
        switch transportError.kind {
        case .remote:
            return false
        case .unavailable, .closed, .timedOut, .malformedResponse:
            return true
        }
    }

    private func closeCurrentProcess(failure: FeaturePersistentProcessError) async {
        let pending = pendingResponse
        pendingResponse = nil
        pending?.continuation.resume(throwing: failure)

        let stdoutReader = stdoutReader
        self.stdoutReader = nil
        let stderrReader = stderrReader
        self.stderrReader = nil
        stdoutReader?.cancel()
        stderrReader?.cancel()

        let currentProcess = process
        process = nil
        generation = nil
        exitMonitor = nil
        let inputHandle = inputHandle
        self.inputHandle = nil
        let outputHandle = outputHandle
        self.outputHandle = nil
        let errorHandle = errorHandle
        self.errorHandle = nil

        currentProcess?.terminationHandler = nil
        if let currentProcess, currentProcess.isRunning {
            Self.killImmediately(currentProcess)
        }
        try? inputHandle?.close()

        // Join cancelled readers before closing their descriptors. This avoids
        // an old reader racing a recycled file-descriptor number owned by an
        // unrelated process or pipe.
        if let stdoutReader {
            _ = await stdoutReader.value
        }
        if let stderrReader {
            _ = await stderrReader.value
        }
        try? outputHandle?.close()
        try? errorHandle?.close()

        stdoutBuffer.removeAll(keepingCapacity: true)
    }

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            return
        }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private static func killImmediately(_ process: Process) {
        let processID = process.processIdentifier
        guard processID > 0 else {
            return
        }
        _ = kill(processID, SIGTERM)
        _ = kill(processID, SIGKILL)
    }
    #endif
}
